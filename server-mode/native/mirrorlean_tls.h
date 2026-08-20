/*
 * MirrorLean server-mode — native TLS shim (stable C ABI).
 *
 * Phase 1 of plans/server-mode.md: TLS 1.3 mutual-auth client transport
 * for `ModelMirrors --server --tls`. The C-side functions below are the
 * stable, testable ABI (error messages in caller-provided buffers); the
 * Lean-facing `mirrorlean_tls_lean_*` wrappers live in mirrorlean_tls.c.
 *
 * Design notes:
 *  - TLS 1.3 only (min == max == TLS1_3_VERSION).
 *  - Server verified against a CA file AND the hostname/SAN.
 *  - Client presents its own certificate/key (server requires it).
 *  - Peer certificate SHA-256 available after the handshake (for
 *    registry `cert-sha256` fingerprint pinning).
 *  - POSIX: private key files must not be readable by group/other (0600).
 */

#ifndef MIRRORLEAN_TLS_H
#define MIRRORLEAN_TLS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a connected TLS session. */
typedef struct mirrorlean_tls mirrorlean_tls;

/*
 * Connect to `host:port` over TLS 1.3 with mutual auth.
 *
 * `server_name` is used for SNI and hostname verification (SAN); pass the
 * host when no explicit server name is configured.
 *
 * Returns an owned handle, or NULL on failure with a human-readable
 * message in `errbuf`.
 */
mirrorlean_tls *mirrorlean_tls_connect(
    const char *ca_file, const char *cert_file, const char *key_file,
    const char *server_name, const char *host, uint16_t port,
    char *errbuf, size_t errbuf_len);

/* Write all `len` bytes; returns 0 on success, -1 on error (errbuf set). */
int mirrorlean_tls_write(mirrorlean_tls *t, const uint8_t *data, size_t len,
                         char *errbuf, size_t errbuf_len);

/*
 * Read up to `max` bytes.
 * Returns the number of bytes read (> 0), 0 on clean EOF (close_notify),
 * or -1 on error (errbuf set).
 */
long mirrorlean_tls_read(mirrorlean_tls *t, uint8_t *buf, size_t max,
                         char *errbuf, size_t errbuf_len);

/* Best-effort TLS close_notify + resource release; never fails. */
void mirrorlean_tls_close(mirrorlean_tls *t);

/*
 * SHA-256 of the peer certificate, 32 bytes into `out[32]`.
 * Returns 0 on success, -1 on error (errbuf set).
 */
int mirrorlean_tls_peer_cert_sha256(mirrorlean_tls *t, uint8_t out[32],
                                    char *errbuf, size_t errbuf_len);

/*
 * Client-certificate expiry warning: fills `buf` with "" when the client
 * certificate is valid for more than 7 days, or with a warning when it is
 * expired or expires within 7 days. Returns 0 on success, -1 on error.
 */
int mirrorlean_tls_client_cert_warning(mirrorlean_tls *t,
                                       char *buf, size_t buf_len);

#ifdef __cplusplus
}
#endif

#endif /* MIRRORLEAN_TLS_H */
