#!/usr/bin/env bash
#
# Generate an ephemeral test PKI for server-mode tests:
#   CA -> server cert (SAN: DNS:localhost, IP:127.0.0.1) + client cert
#
# Usage: gen-test-certs.sh OUTDIR
#
# Everything is written into OUTDIR with mode 0600 where applicable.
# NEVER commit the generated keys — this script exists so tests can
# generate a fresh PKI per run into a temp directory.
set -euo pipefail

OUT="${1:?usage: gen-test-certs.sh OUTDIR}"
mkdir -p "$OUT"
umask 077

# --- CA -----------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$OUT/ca.key" -out "$OUT/ca.crt" -days 2 \
  -subj "/CN=MirrorLean Test CA" >/dev/null 2>&1

# --- server certificate (SAN localhost / 127.0.0.1) ----------------------
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/server.key" -out "$OUT/server.csr" \
  -subj "/CN=localhost" >/dev/null 2>&1
SERVEREXT="basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1"
openssl x509 -req -in "$OUT/server.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/server.crt" -days 2 \
  -extfile <(printf '%b\n' "$SERVEREXT") >/dev/null 2>&1

# --- client certificate --------------------------------------------------
# X509v3 with clientAuth EKU: ModelMirrors' server (Haskell `tls` package)
# rejects X509v1 leaves ("certificate rejected: [LeafNotV3]").
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/client.key" -out "$OUT/client.csr" \
  -subj "/CN=mirrorlean-client" >/dev/null 2>&1
CLIENTEXT="basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth"
openssl x509 -req -in "$OUT/client.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/client.crt" -days 2 \
  -extfile <(printf '%b\n' "$CLIENTEXT") >/dev/null 2>&1

# --- second server certificate (different key -> different fingerprint) ---
# Same CA and SAN as server.crt; used by the Phase 3 pinned-discovery test
# to offer one bad-pin candidate and one good-pin candidate.
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/server2.key" -out "$OUT/server2.csr" \
  -subj "/CN=localhost" >/dev/null 2>&1
openssl x509 -req -in "$OUT/server2.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/server2.crt" -days 2 \
  -extfile <(printf '%b\n' "$SERVEREXT") >/dev/null 2>&1

# --- unrelated CA (negative tests: wrong trust anchor) -------------------
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$OUT/ca2.key" -out "$OUT/ca2.crt" -days 2 \
  -subj "/CN=MirrorLean Unrelated CA" >/dev/null 2>&1

# --- client certificate signed by the UNRELATED CA (negative mTLS test) ---
# The server requires a client certificate verified against `ca.crt`
# (`-Verify 1`), so a client presenting this certificate must be rejected
# during the handshake. Same v3 extensions as client.crt so the only
# difference from the good client is the trust anchor.
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/client-bad.key" -out "$OUT/client-bad.csr" \
  -subj "/CN=mirrorlean-bad-client" >/dev/null 2>&1
openssl x509 -req -in "$OUT/client-bad.csr" \
  -CA "$OUT/ca2.crt" -CAkey "$OUT/ca2.key" -CAcreateserial \
  -out "$OUT/client-bad.crt" -days 2 \
  -extfile <(printf '%b\n' "$CLIENTEXT") >/dev/null 2>&1

chmod 600 "$OUT/ca.key" "$OUT/server.key" "$OUT/server2.key" "$OUT/client.key" "$OUT/ca2.key" "$OUT/client-bad.key"
rm -f "$OUT"/*.csr "$OUT/ca.srl" "$OUT/ca2.srl"
echo "$OUT"
