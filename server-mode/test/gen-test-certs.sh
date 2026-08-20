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
SAN="subjectAltName=DNS:localhost,IP:127.0.0.1"
openssl x509 -req -in "$OUT/server.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/server.crt" -days 2 \
  -extfile <(printf '%s\n' "$SAN") >/dev/null 2>&1

# --- client certificate --------------------------------------------------
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/client.key" -out "$OUT/client.csr" \
  -subj "/CN=mirrorlean-client" >/dev/null 2>&1
openssl x509 -req -in "$OUT/client.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/client.crt" -days 2 >/dev/null 2>&1

# --- second server certificate (different key -> different fingerprint) ---
# Same CA and SAN as server.crt; used by the Phase 3 pinned-discovery test
# to offer one bad-pin candidate and one good-pin candidate.
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/server2.key" -out "$OUT/server2.csr" \
  -subj "/CN=localhost" >/dev/null 2>&1
openssl x509 -req -in "$OUT/server2.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/server2.crt" -days 2 \
  -extfile <(printf '%s\n' "$SAN") >/dev/null 2>&1

# --- unrelated CA (negative tests: wrong trust anchor) -------------------
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$OUT/ca2.key" -out "$OUT/ca2.crt" -days 2 \
  -subj "/CN=MirrorLean Unrelated CA" >/dev/null 2>&1

chmod 600 "$OUT/ca.key" "$OUT/server.key" "$OUT/server2.key" "$OUT/client.key" "$OUT/ca2.key"
rm -f "$OUT"/*.csr "$OUT/ca.srl"
echo "$OUT"
