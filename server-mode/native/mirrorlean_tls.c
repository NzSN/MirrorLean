/*
 * MirrorLean server-mode — native TLS shim (Phase 1).
 *
 * TLS 1.3 mutual-auth client over a POSIX socket, plus the Lean-facing
 * `mirrorlean_tls_lean_*` extern wrappers.
 *
 * Lean ABI (validated in Phase 0, see plans/server-mode-phase0.md):
 *   - `@[extern]` IO functions return the IO result object directly
 *     (`lean_io_result_mk_ok` / `lean_io_result_mk_error`);
 *   - `UInt16`/`UInt64` are passed unboxed (`uint16_t`/`uint64_t`);
 *   - error payloads must be real `IO.Error` objects
 *     (`lean_mk_io_user_error(lean_mk_string(buf))`);
 *   - `ByteArray` read via `lean_sarray_size`/`lean_sarray_cptr`, built
 *     with `lean_alloc_sarray`; `String × α` pairs built with
 *     `lean_alloc_ctor(0, 2, 0)` (Prod.mk, tag 0).
 */

#include "mirrorlean_tls.h"

#include <lean/lean.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <errno.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

struct mirrorlean_tls {
  SSL_CTX *ctx;
  SSL *ssl;
  int fd;
};

/* ------------------------- error helpers ------------------------------- */

static void set_err(char *buf, size_t len, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, len, fmt, ap);
  va_end(ap);
}

/* Append all pending OpenSSL error-queue entries to the buffer. */
static void append_ssl_errors(char *buf, size_t len) {
  unsigned long e;
  char ebuf[256];
  while ((e = ERR_get_error()) != 0) {
    ERR_error_string_n(e, ebuf, sizeof ebuf);
    size_t used = strlen(buf);
    if (used + strlen(ebuf) + 2 >= len) break;
    snprintf(buf + used, len - used, "%s%s", used ? "; " : "", ebuf);
  }
}

/* --------------------- POSIX key-file permissions ---------------------- */

/*
 * Reject private key files readable by group/other (0600), as the
 * upstream client does. Windows: skipped (no POSIX mode bits).
 */
static int check_key_permissions(const char *key_file, char *errbuf,
                                 size_t errbuf_len) {
#ifndef _WIN32
  struct stat st;
  if (stat(key_file, &st) != 0) {
    set_err(errbuf, errbuf_len, "cannot stat key file '%s': %s",
            key_file, strerror(errno));
    return -1;
  }
  if ((st.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
    set_err(errbuf, errbuf_len,
            "key file '%s' must not be readable by group/others (mode %04o; chmod 600)",
            key_file, (unsigned)(st.st_mode & 0777));
    return -1;
  }
#else
  (void)key_file;
  (void)errbuf;
  (void)errbuf_len;
#endif
  return 0;
}

/* ------------------------- socket connect ------------------------------ */

/* POSIX connect with DNS via getaddrinfo (IPv4 + IPv6). */
static int connect_socket(const char *host, uint16_t port,
                          char *errbuf, size_t errbuf_len) {
  char service[16];
  snprintf(service, sizeof service, "%u", (unsigned)port);

  struct addrinfo hints;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo *res = NULL;
  int rc = getaddrinfo(host, service, &hints, &res);
  if (rc != 0) {
    set_err(errbuf, errbuf_len, "getaddrinfo('%s'): %s", host, gai_strerror(rc));
    return -1;
  }

  int fd = -1;
  for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) continue;
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
    close(fd);
    fd = -1;
  }
  if (fd < 0)
    set_err(errbuf, errbuf_len, "cannot connect to %s:%u: %s",
            host, (unsigned)port, strerror(errno));
  freeaddrinfo(res);
  return fd;
}

/* --------------------- TLS handshake timeout --------------------------- */

/*
 * Set/clear SO_RCVTIMEO + SO_SNDTIMEO on a connected socket. Used to bound
 * the TLS handshake so a dead or black-holed peer cannot block a caller
 * forever; the timeouts are cleared immediately after a successful
 * handshake so long-running sessions (e.g. an apalache check that takes a
 * minute) are never cut off mid-session.
 */
static void set_socket_timeout(int fd, int ms) {
  struct timeval tv;
  tv.tv_sec = ms / 1000;
  tv.tv_usec = (ms % 1000) * 1000;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

/* Handshake timeout in ms: 10000 default, overridable via
 * MIRRORLEAN_TLS_HANDSHAKE_TIMEOUT_MS (1..600000). */
static int handshake_timeout_ms(void) {
  const char *env = getenv("MIRRORLEAN_TLS_HANDSHAKE_TIMEOUT_MS");
  if (env != NULL && *env != '\0') {
    char *end = NULL;
    long v = strtol(env, &end, 10);
    if (end != NULL && *end == '\0' && v > 0 && v <= 600000)
      return (int)v;
  }
  return 10000;
}

/* ------------------------- public C ABI -------------------------------- */

mirrorlean_tls *mirrorlean_tls_connect(
    const char *ca_file, const char *cert_file, const char *key_file,
    const char *server_name, const char *host, uint16_t port,
    char *errbuf, size_t errbuf_len) {
  errbuf[0] = '\0';

  if (check_key_permissions(key_file, errbuf, errbuf_len) != 0)
    return NULL;

  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (ctx == NULL) {
    set_err(errbuf, errbuf_len, "SSL_CTX_new failed");
    append_ssl_errors(errbuf, errbuf_len);
    return NULL;
  }

  /* TLS 1.3 only. */
  if (SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION) != 1 ||
      SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION) != 1) {
    set_err(errbuf, errbuf_len, "cannot restrict protocol to TLS 1.3");
    append_ssl_errors(errbuf, errbuf_len);
    SSL_CTX_free(ctx);
    return NULL;
  }

  /* Trust anchor + verification of the server chain. */
  if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) {
    set_err(errbuf, errbuf_len, "cannot load CA file '%s'", ca_file);
    append_ssl_errors(errbuf, errbuf_len);
    SSL_CTX_free(ctx);
    return NULL;
  }
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

  /* Client identity. */
  if (SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1) {
    set_err(errbuf, errbuf_len, "cannot load client certificate '%s'", cert_file);
    append_ssl_errors(errbuf, errbuf_len);
    SSL_CTX_free(ctx);
    return NULL;
  }
  if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1) {
    set_err(errbuf, errbuf_len, "cannot load client private key '%s'", key_file);
    append_ssl_errors(errbuf, errbuf_len);
    SSL_CTX_free(ctx);
    return NULL;
  }
  if (SSL_CTX_check_private_key(ctx) != 1) {
    set_err(errbuf, errbuf_len,
            "client private key '%s' does not match certificate '%s'",
            key_file, cert_file);
    append_ssl_errors(errbuf, errbuf_len);
    SSL_CTX_free(ctx);
    return NULL;
  }

  int fd = connect_socket(host, port, errbuf, errbuf_len);
  if (fd < 0) {
    SSL_CTX_free(ctx);
    return NULL;
  }

  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL) {
    set_err(errbuf, errbuf_len, "SSL_new failed");
    append_ssl_errors(errbuf, errbuf_len);
    close(fd);
    SSL_CTX_free(ctx);
    return NULL;
  }
  SSL_set_fd(ssl, fd);

  /* Bound the handshake (env-overridable ms); cleared after success so
   * session traffic stays blocking. */
  set_socket_timeout(fd, handshake_timeout_ms());

  /* SNI + hostname (SAN) verification. */
  if (server_name != NULL && *server_name != '\0') {
    if (SSL_set_tlsext_host_name(ssl, server_name) != 1) {
      set_err(errbuf, errbuf_len, "cannot set SNI server name '%s'", server_name);
      SSL_free(ssl);
      close(fd);
      SSL_CTX_free(ctx);
      return NULL;
    }
    if (SSL_set1_host(ssl, server_name) != 1) {
      set_err(errbuf, errbuf_len, "cannot set hostname verification for '%s'", server_name);
      SSL_free(ssl);
      close(fd);
      SSL_CTX_free(ctx);
      return NULL;
    }
  }

  if (SSL_connect(ssl) != 1) {
    set_err(errbuf, errbuf_len, "TLS 1.3 handshake with '%s:%u' failed",
            host, (unsigned)port);
    /* Surface the specific verification reason (CA, hostname, expiry...). */
    long vr = SSL_get_verify_result(ssl);
    if (vr != X509_V_OK) {
      size_t used = strlen(errbuf);
      snprintf(errbuf + used, errbuf_len - used, "; verification failed: %s",
               X509_verify_cert_error_string((int)vr));
    }
    /* A socket-level timeout surfaces as SSL_ERROR_SYSCALL + EAGAIN. */
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      size_t used = strlen(errbuf);
      snprintf(errbuf + used, errbuf_len - used,
               "; handshake timed out (MIRRORLEAN_TLS_HANDSHAKE_TIMEOUT_MS=%d)",
               handshake_timeout_ms());
    }
    append_ssl_errors(errbuf, errbuf_len);
    SSL_free(ssl);
    close(fd);
    SSL_CTX_free(ctx);
    return NULL;
  }
  /* Handshake done: restore blocking I/O for the session. */
  set_socket_timeout(fd, 0);

  mirrorlean_tls *t = (mirrorlean_tls *)malloc(sizeof *t);
  if (t == NULL) {
    set_err(errbuf, errbuf_len, "out of memory");
    SSL_free(ssl);
    close(fd);
    SSL_CTX_free(ctx);
    return NULL;
  }
  t->ctx = ctx;
  t->ssl = ssl;
  t->fd = fd;
  return t;
}

int mirrorlean_tls_write(mirrorlean_tls *t, const uint8_t *data, size_t len,
                         char *errbuf, size_t errbuf_len) {
  size_t off = 0;
  while (off < len) {
    int n = SSL_write(t->ssl, data + off, (int)(len - off));
    if (n > 0) {
      off += (size_t)n;
      continue;
    }
    int e = SSL_get_error(t->ssl, n);
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) continue;
    set_err(errbuf, errbuf_len, "TLS write failed");
    append_ssl_errors(errbuf, errbuf_len);
    return -1;
  }
  return 0;
}

long mirrorlean_tls_read(mirrorlean_tls *t, uint8_t *buf, size_t max,
                         char *errbuf, size_t errbuf_len) {
  if (max > (size_t)0x7fffffff) max = (size_t)0x7fffffff;
  for (;;) {
    int n = SSL_read(t->ssl, buf, (int)max);
    if (n > 0) return (long)n;
    int e = SSL_get_error(t->ssl, n);
    if (e == SSL_ERROR_ZERO_RETURN) return 0; /* clean close_notify */
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) continue;
    set_err(errbuf, errbuf_len, "TLS read failed");
    append_ssl_errors(errbuf, errbuf_len);
    return -1;
  }
}

void mirrorlean_tls_close(mirrorlean_tls *t) {
  if (t == NULL) return;
  if (t->ssl != NULL) {
    /* Best-effort close_notify; ignore errors and peer-already-closed. */
    int rc = SSL_shutdown(t->ssl);
    if (rc == 0) SSL_shutdown(t->ssl); /* complete the two-step shutdown */
  }
  if (t->fd >= 0) close(t->fd);
  if (t->ssl != NULL) SSL_free(t->ssl);
  if (t->ctx != NULL) SSL_CTX_free(t->ctx);
  free(t);
}

int mirrorlean_tls_peer_cert_sha256(mirrorlean_tls *t, uint8_t out[32],
                                    char *errbuf, size_t errbuf_len) {
  X509 *cert = SSL_get1_peer_certificate(t->ssl);
  if (cert == NULL) {
    set_err(errbuf, errbuf_len, "peer did not present a certificate");
    return -1;
  }
  unsigned int len = 0;
  if (X509_digest(cert, EVP_sha256(), out, &len) != 1 || len != 32) {
    set_err(errbuf, errbuf_len, "failed to digest peer certificate");
    X509_free(cert);
    return -1;
  }
  X509_free(cert);
  return 0;
}

int mirrorlean_tls_client_cert_warning(mirrorlean_tls *t,
                                       char *buf, size_t buf_len) {
  X509 *cert = SSL_CTX_get0_certificate(t->ctx);
  if (cert == NULL) {
    set_err(buf, buf_len, "no client certificate loaded");
    return -1;
  }
  const ASN1_TIME *not_after = X509_get0_notAfter(cert);
  if (not_after == NULL) {
    set_err(buf, buf_len, "client certificate has no notAfter");
    return -1;
  }
  time_t now = time(NULL);
  /* X509_cmp_time takes time_t* in OpenSSL 3.0 (value in 1.1.1). */
  if (X509_cmp_time(not_after, &now) == -1) {
    snprintf(buf, buf_len, "client certificate is expired");
    return 0;
  }
  time_t soon = now + 7 * 24 * 3600; /* 7 days */
  if (X509_cmp_time(not_after, &soon) == -1) {
    struct tm tm_buf;
    memset(&tm_buf, 0, sizeof tm_buf);
    if (ASN1_TIME_to_tm(not_after, &tm_buf) == 1) {
      time_t expiry = timegm(&tm_buf);
      long days = (long)((expiry - now) / 86400);
      snprintf(buf, buf_len,
               "client certificate expires within 7 days (%ld day%s)",
               days, days == 1 ? "" : "s");
    } else {
      snprintf(buf, buf_len, "client certificate expires within 7 days");
    }
    return 0;
  }
  buf[0] = '\0';
  return 0;
}

/* ------------------- Lean extern wrappers ------------------------------ */

/* Prod.mk is constructor tag 0 with two object fields. */
static lean_object *mk_pair(lean_object *a, lean_object *b) {
  lean_object *o = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(o, 0, a);
  lean_ctor_set(o, 1, b);
  return o;
}

static lean_object *mk_user_error(const char *msg) {
  return lean_mk_io_user_error(lean_mk_string(msg));
}

/*
 * (caFile certFile keyFile serverName host : String) (port : UInt16)
 *   : IO (String × UInt64)
 * Returns ("", handle) on success, (errorMessage, 0) on failure.
 */
lean_object *mirrorlean_tls_lean_connect(
    lean_obj_arg ca_file, lean_obj_arg cert_file, lean_obj_arg key_file,
    lean_obj_arg server_name, lean_obj_arg host, uint16_t port) {
  char errbuf[512];
  mirrorlean_tls *t = mirrorlean_tls_connect(
      lean_string_cstr(ca_file), lean_string_cstr(cert_file),
      lean_string_cstr(key_file), lean_string_cstr(server_name),
      lean_string_cstr(host), port, errbuf, sizeof errbuf);
  if (t == NULL)
    return lean_io_result_mk_ok(
        mk_pair(lean_mk_string(errbuf[0] ? errbuf : "TLS connect failed"),
                lean_box_uint64(0)));
  return lean_io_result_mk_ok(
      mk_pair(lean_mk_string(""), lean_box_uint64((uint64_t)(uintptr_t)t)));
}

/* (h : UInt64) (max : UInt64) : IO (String × ByteArray)
   ("", bytes) on success; ("", empty) on clean EOF; (error, empty) on error. */
lean_object *mirrorlean_tls_lean_read(uint64_t h, uint64_t max) {
  mirrorlean_tls *t = (mirrorlean_tls *)(uintptr_t)h;
  char errbuf[256];
  if (max == 0 || max > 65536) max = 65536;
  uint8_t *buf = (uint8_t *)malloc((size_t)max);
  if (buf == NULL)
    return lean_io_result_mk_ok(
        mk_pair(lean_mk_string("out of memory"), lean_alloc_sarray(1, 0, 0)));
  long n = mirrorlean_tls_read(t, buf, (size_t)max, errbuf, sizeof errbuf);
  lean_object *res;
  if (n < 0) {
    res = mk_pair(lean_mk_string(errbuf), lean_alloc_sarray(1, 0, 0));
  } else {
    lean_object *ba = lean_alloc_sarray(1, (size_t)n, (size_t)n);
    memcpy(lean_sarray_cptr(ba), buf, (size_t)n);
    res = mk_pair(lean_mk_string(""), ba);
  }
  free(buf);
  return lean_io_result_mk_ok(res);
}

/* (h : UInt64) (data : ByteArray) : IO String — "" on success, else error. */
lean_object *mirrorlean_tls_lean_write(uint64_t h, lean_obj_arg data) {
  mirrorlean_tls *t = (mirrorlean_tls *)(uintptr_t)h;
  char errbuf[256];
  int rc = mirrorlean_tls_write(t, lean_sarray_cptr(data),
                                lean_sarray_size(data), errbuf, sizeof errbuf);
  if (rc != 0) return lean_io_result_mk_ok(lean_mk_string(errbuf));
  return lean_io_result_mk_ok(lean_mk_string(""));
}

/* (h : UInt64) : IO Unit — best-effort close, never fails. */
lean_object *mirrorlean_tls_lean_close(uint64_t h) {
  mirrorlean_tls_close((mirrorlean_tls *)(uintptr_t)h);
  return lean_io_result_mk_ok(lean_box(0));
}

/* (h : UInt64) : IO (String × ByteArray) — ("", 32-byte digest). */
lean_object *mirrorlean_tls_lean_peer_cert_sha256(uint64_t h) {
  mirrorlean_tls *t = (mirrorlean_tls *)(uintptr_t)h;
  char errbuf[256];
  uint8_t digest[32];
  if (mirrorlean_tls_peer_cert_sha256(t, digest, errbuf, sizeof errbuf) != 0)
    return lean_io_result_mk_ok(
        mk_pair(lean_mk_string(errbuf), lean_alloc_sarray(1, 0, 0)));
  lean_object *ba = lean_alloc_sarray(1, 32, 32);
  memcpy(lean_sarray_cptr(ba), digest, 32);
  return lean_io_result_mk_ok(mk_pair(lean_mk_string(""), ba));
}

/* (h : UInt64) : IO String — "" when fine, else an expiry warning. */
lean_object *mirrorlean_tls_lean_cert_warning(uint64_t h) {
  mirrorlean_tls *t = (mirrorlean_tls *)(uintptr_t)h;
  char buf[256];
  if (mirrorlean_tls_client_cert_warning(t, buf, sizeof buf) != 0)
    return lean_io_result_mk_ok(lean_mk_string(buf));
  return lean_io_result_mk_ok(lean_mk_string(buf));
}
