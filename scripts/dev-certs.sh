#!/usr/bin/env bash
# Generates a throwaway local CA plus a coord leaf cert for compose quickstarts.
# Production uses real certificates (ACM + NLB/ALB); never reuse these.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT/certs}"

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

mkdir -p "$DIR"
umask 077

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$DIR/ca.key" -out "$DIR/ca.crt" -days 3650 \
  -subj "/CN=BlakTail Development CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign"

openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$DIR/coord.key" -out "$DIR/coord.csr" \
  -subj "/CN=coord" \
  -addext "subjectAltName=DNS:coord,DNS:localhost,IP:127.0.0.1"

openssl x509 -req -in "$DIR/coord.csr" \
  -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
  -out "$DIR/coord.crt" -days 825 \
  -extfile <(printf "subjectAltName=DNS:coord,DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth")

rm -f "$DIR/coord.csr"
chmod 600 "$DIR/coord.key" "$DIR/ca.key"
echo "dev certificates written to $DIR (coord.crt, coord.key, ca.crt)"
