#!/usr/bin/env bash
# Generate throwaway coordinator certs into /certs when they are missing.
set -euo pipefail

if [ ! -f /certs/coord.crt ] || [ ! -f /certs/ca.crt ] || [ ! -f /certs/coord.key ]; then
  /usr/local/bin/dev-certs /certs
fi

# Coordinator runs as uid 10001; throwaway keys must be readable in-volume.
chmod 644 /certs/ca.crt /certs/coord.crt /certs/ca.key /certs/coord.key
printf 'coordinator certificates are ready in /certs\n'
