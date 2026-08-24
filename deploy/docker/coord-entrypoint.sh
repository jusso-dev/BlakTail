#!/bin/sh
# Coord entrypoint. Accepts TLS material as PEM env vars (Fargate/Secrets
# Manager inject secrets as environment variables only), or plain file paths.
set -eu

CERT_PATH="${BLAKTAIL_TLS_CERT:-}"
KEY_PATH="${BLAKTAIL_TLS_KEY:-}"
CERT_PEM_SET=false
KEY_PEM_SET=false
if [ -n "${BLAKTAIL_TLS_CERT_PEM:-}" ]; then
    CERT_PEM_SET=true
fi
if [ -n "${BLAKTAIL_TLS_KEY_PEM:-}" ]; then
    KEY_PEM_SET=true
fi

if [ "$CERT_PEM_SET" != "$KEY_PEM_SET" ]; then
    printf '%s\n' 'coord-entrypoint: TLS PEM certificate and key must be set together' >&2
    exit 1
fi

if [ "$CERT_PEM_SET" = true ]; then
    if [ -n "$CERT_PATH" ] || [ -n "$KEY_PATH" ]; then
        printf '%s\n' 'coord-entrypoint: TLS PEM material and file paths are ambiguous' >&2
        exit 1
    fi
    mkdir -p /tmp/blaktail-tls
    CERT_PATH=/tmp/blaktail-tls/tls.crt
    KEY_PATH=/tmp/blaktail-tls/tls.key
    printf '%s\n' "$BLAKTAIL_TLS_CERT_PEM" > "$CERT_PATH"
    printf '%s\n' "$BLAKTAIL_TLS_KEY_PEM" > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    unset BLAKTAIL_TLS_CERT_PEM BLAKTAIL_TLS_KEY_PEM
fi

export BLAKTAIL_TLS_CERT="$CERT_PATH" BLAKTAIL_TLS_KEY="$KEY_PATH"
/usr/local/bin/blaktail-config check-config --service coordinator
exec /usr/local/bin/blaktail-coord "$@"
