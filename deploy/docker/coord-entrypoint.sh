#!/bin/sh
# Coord entrypoint. Accepts TLS material as PEM env vars (Fargate/Secrets
# Manager inject secrets as environment variables only), or plain file paths.
set -eu

CERT_PATH="${BLAKTAIL_TLS_CERT:-}"
KEY_PATH="${BLAKTAIL_TLS_KEY:-}"

if [ -n "${BLAKTAIL_TLS_CERT_PEM:-}" ] && [ -n "${BLAKTAIL_TLS_KEY_PEM:-}" ]; then
    mkdir -p /tmp/blaktail-tls
    CERT_PATH=/tmp/blaktail-tls/tls.crt
    KEY_PATH=/tmp/blaktail-tls/tls.key
    printf '%s\n' "$BLAKTAIL_TLS_CERT_PEM" > "$CERT_PATH"
    printf '%s\n' "$BLAKTAIL_TLS_KEY_PEM" > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
fi

export BLAKTAIL_TLS_CERT="$CERT_PATH" BLAKTAIL_TLS_KEY="$KEY_PATH"
exec /usr/local/bin/blaktail-coord
