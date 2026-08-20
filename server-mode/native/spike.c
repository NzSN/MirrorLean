/*
 * MirrorLean server-mode — Phase 0 spike FFI shim (throwaway).
 *
 * Deliberately tiny: its only job is to validate the build and ABI
 * mechanics before any real TLS code is written
 * (plans/server-mode.md §6 Phase 0).
 *
 * ABI notes (verified against the generated C in this build):
 *   * `opaque f : IO α`  ->  `lean_object* f(args)` returning the *IO
 *     result object*: `lean_io_result_mk_ok(v)` / `lean_io_result_mk_error(...)`.
 *     (The old `lean_obj_arg *out` convention is not used by Lean 4.33.)
 *   * `Bool` is passed unboxed as `uint8_t`.
 *   * `ByteArray` is a Lean scalar-array object; size via `lean_sarray_size`,
 *     raw bytes via `lean_sarray_cptr`; construct one with `lean_alloc_sarray`.
 *
 * `OpenSSL_version` / `EVP_sha256` are real OpenSSL calls, so the link
 * flags are actually exercised (with `--as-needed` the libraries are only
 * kept when referenced).
 */

#include <lean/lean.h>
#include <openssl/crypto.h>   /* OpenSSL_version */
#include <openssl/evp.h>      /* EVP digest helpers */
#include <openssl/opensslv.h> /* OPENSSL_VERSION */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/*
 * Caller-provided error buffer helper.
 *
 * This mirrors the internal shape of the Phase 1 TLS shim: C functions
 * format human-readable messages into a caller-supplied `char buf[]`
 * (e.g. OpenSSL `ERR_error_string_n`), and only at the very boundary is
 * the message turned into a Lean error result.
 */
static void set_error(char *buf, size_t buflen, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, buflen, fmt, ap);
  va_end(ap);
}

/* ---- String -> String: UTF-8 roundtrip (pure String ABI) -------------- */

lean_object *mirrorlean_spike_echo(lean_object *s) {
  const char *c = lean_string_cstr(s);
  return lean_mk_string_from_bytes(c, strlen(c));
}

/* ---- OpenSSL version: proves -lssl -lcrypto are linked AND used ------- */

lean_object *mirrorlean_spike_openssl_version(void) {
  return lean_io_result_mk_ok(lean_mk_string(OpenSSL_version(OPENSSL_VERSION)));
}

/* ---- ByteArray -> hex String via libcrypto EVP -------------------------
 * The exact pattern Phase 1 will use for peer-certificate SHA-256:
 * read a Lean ByteArray from C, digest it, return a hex String.
 * ---------------------------------------------------------------------- */

static int sha256_of(lean_object *data, unsigned char digest[EVP_MAX_MD_SIZE],
                     unsigned int *len, char *errbuf, size_t errbuf_len) {
  size_t n = lean_sarray_size(data);
  uint8_t const *p = lean_sarray_cptr(data);
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  if (!ctx) {
    set_error(errbuf, errbuf_len, "EVP_MD_CTX_new failed");
    return 0;
  }
  EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
  EVP_DigestUpdate(ctx, p, n);
  EVP_DigestFinal_ex(ctx, digest, len);
  EVP_MD_CTX_free(ctx);
  return 1;
}

lean_object *mirrorlean_spike_sha256_hex(lean_object *data) {
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int len = 0;
  char hex[EVP_MAX_MD_SIZE * 2 + 1];
  char errbuf[256];
  if (!sha256_of(data, digest, &len, errbuf, sizeof errbuf))
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(errbuf)));
  for (unsigned int i = 0; i < len; i++)
    snprintf(hex + 2 * i, sizeof hex - 2 * i, "%02x", digest[i]);
  return lean_io_result_mk_ok(lean_mk_string(hex));
}

/* ---- ByteArray -> ByteArray: C constructs a Lean ByteArray -------------
 * The pattern Phase 1 will use to return raw digests to Lean
 * (e.g. `peer_cert_sha256 : IO ByteArray`).
 * ---------------------------------------------------------------------- */

lean_object *mirrorlean_spike_sha256_bytes(lean_object *data) {
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int len = 0;
  char errbuf[256];
  if (!sha256_of(data, digest, &len, errbuf, sizeof errbuf))
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(errbuf)));
  lean_object *ba = lean_alloc_sarray(1, len, len);
  memcpy(lean_sarray_cptr(ba), digest, len);
  return lean_io_result_mk_ok(ba);
}

/* ---- Error-buffer marshalling demo -------------------------------------
 * `fail == true` formats a message into a C stack buffer and reports it
 * as an `IO` error; otherwise the message is echoed.
 * ---------------------------------------------------------------------- */

lean_object *mirrorlean_spike_io_demo(uint8_t fail, lean_object *msg) {
  char errbuf[256];
  const char *m = lean_string_cstr(msg);
  if (fail) {
    set_error(errbuf, sizeof errbuf,
              "mirrorlean spike failure (msg='%s', code=%d)", m, 42);
    /* A proper `IO.Error.userError` payload, as thrown by `IO.userError`. */
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(errbuf)));
  } else {
    return lean_io_result_mk_ok(lean_mk_string_from_bytes(m, strlen(m)));
  }
}
