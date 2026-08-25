#!/bin/sh
# Live scrape proof for coordinator and relay metrics/health contracts (#31).
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/blaktail-obs.XXXXXX")
cleanup() {
  if [ -n "${COORD_PID:-}" ]; then kill "$COORD_PID" 2>/dev/null || true; fi
  if [ -n "${RELAY_PID:-}" ]; then kill "$RELAY_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

TOKEN='observability-proof-token-at-least-32b'
HMAC='observability-proof-hmac-secret-32bxx'
RELAY='observability-proof-relay-secret-32bxx'
CERTS="$WORK/certs"
DB="$WORK/coord.sqlite3"
EVIDENCE="${BLAKTAIL_EVIDENCE:-$ROOT/docs/e2e/observability-proof.md}"

command -v cargo >/dev/null
command -v curl >/dev/null
command -v openssl >/dev/null

cargo build --locked -p blaktail-coord -p blaktail-relay --offline 2>/dev/null \
  || cargo build --locked -p blaktail-coord -p blaktail-relay
COORD="$ROOT/target/debug/blaktail-coord"
RELAY_BIN="$ROOT/target/debug/blaktail-relay"
mkdir -p "$CERTS"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERTS/coord.key" -out "$CERTS/coord.crt" -days 1 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
cp "$CERTS/coord.crt" "$CERTS/ca.crt"
chmod 600 "$CERTS/coord.key"

BLAKTAIL_REGION=ap-southeast-2 \
BLAKTAIL_BIND=127.0.0.1:18443 \
BLAKTAIL_COORD_METRICS_BIND=127.0.0.1:19701 \
BLAKTAIL_COORD_ALLOW_PUBLIC_METRICS=true \
BLAKTAIL_COORD_DIAGNOSTICS_TOKEN="$TOKEN" \
BLAKTAIL_DATABASE="$DB" \
BLAKTAIL_TLS_CERT="$CERTS/coord.crt" \
BLAKTAIL_TLS_KEY="$CERTS/coord.key" \
BLAKTAIL_AUTH_HMAC_SECRET="$HMAC" \
BLAKTAIL_RELAY_AUTH_SECRET="$RELAY" \
BLAKTAIL_RELAYS=127.0.0.1:13478 \
BLAKTAIL_CONSOLE_URL=http://127.0.0.1:3000 \
  "$COORD" migrate

BLAKTAIL_REGION=ap-southeast-2 \
BLAKTAIL_BIND=127.0.0.1:18443 \
BLAKTAIL_COORD_METRICS_BIND=127.0.0.1:19701 \
BLAKTAIL_COORD_ALLOW_PUBLIC_METRICS=true \
BLAKTAIL_COORD_DIAGNOSTICS_TOKEN="$TOKEN" \
BLAKTAIL_DATABASE="$DB" \
BLAKTAIL_TLS_CERT="$CERTS/coord.crt" \
BLAKTAIL_TLS_KEY="$CERTS/coord.key" \
BLAKTAIL_AUTH_HMAC_SECRET="$HMAC" \
BLAKTAIL_RELAY_AUTH_SECRET="$RELAY" \
BLAKTAIL_RELAYS=127.0.0.1:13478 \
BLAKTAIL_CONSOLE_URL=http://127.0.0.1:3000 \
  "$COORD" serve >"$WORK/coord.log" 2>&1 &
COORD_PID=$!

BLAKTAIL_REGION=ap-southeast-2 \
BLAKTAIL_RELAY_BIND=127.0.0.1:13478 \
BLAKTAIL_RELAY_METRICS_BIND=127.0.0.1:19702 \
BLAKTAIL_RELAY_ALLOW_PUBLIC_METRICS=true \
BLAKTAIL_RELAY_DIAGNOSTICS_TOKEN="$TOKEN" \
BLAKTAIL_RELAY_AUTH_SECRET="$RELAY" \
  "$RELAY_BIN" >"$WORK/relay.log" 2>&1 &
RELAY_PID=$!

ready=0
i=0
while [ "$i" -lt 50 ]; do
  if curl --fail --silent --cacert "$CERTS/ca.crt" https://127.0.0.1:18443/livez >/dev/null \
    && curl --fail --silent -H "Authorization: Bearer $TOKEN" http://127.0.0.1:19702/livez >/dev/null; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
[ "$ready" = 1 ] || {
  cat "$WORK/coord.log" "$WORK/relay.log" >&2
  printf 'services did not become ready\n' >&2
  exit 1
}

coord_metrics=$(curl --fail --silent -H "Authorization: Bearer $TOKEN" http://127.0.0.1:19701/metrics)
relay_metrics=$(curl --fail --silent -H "Authorization: Bearer $TOKEN" http://127.0.0.1:19702/metrics)
printf '%s\n' "$coord_metrics" | grep -q 'blaktail_coord_active_nodes' \
  || { printf 'coordinator metrics missing active nodes\n' >&2; exit 1; }
printf '%s\n' "$relay_metrics" | grep -q 'blaktail_relay_registers_total' \
  || { printf 'relay metrics missing registers\n' >&2; exit 1; }

unauth_coord=$(curl --silent --write-out '%{http_code}' -o /dev/null http://127.0.0.1:19701/metrics)
unauth_relay=$(curl --silent --write-out '%{http_code}' -o /dev/null http://127.0.0.1:19702/metrics)
[ "$unauth_coord" = 401 ] && [ "$unauth_relay" = 401 ] \
  || { printf 'metrics must require the diagnostics bearer token\n' >&2; exit 1; }

public_metrics=$(curl --silent --cacert "$CERTS/ca.crt" --write-out '%{http_code}' -o /dev/null \
  -H "Authorization: Bearer $TOKEN" https://127.0.0.1:18443/metrics)
[ "$public_metrics" = 404 ] \
  || { printf 'public coordinator listener must not serve /metrics (got %s)\n' "$public_metrics" >&2; exit 1; }

livez=$(curl --fail --silent --cacert "$CERTS/ca.crt" https://127.0.0.1:18443/livez)
readyz=$(curl --fail --silent --cacert "$CERTS/ca.crt" https://127.0.0.1:18443/readyz)
printf '%s' "$livez" | grep -q '"status":"ok"' || { printf 'livez is not status-only ok\n' >&2; exit 1; }
printf '%s' "$readyz" | grep -q '"status":"ready"' || { printf 'readyz is not ready\n' >&2; exit 1; }
printf '%s%s' "$livez" "$readyz" | grep -Ei 'org|node|schema|version|error|path' \
  && { printf 'public health leaked diagnostic fields\n' >&2; exit 1; } || true

printf '%s\n%s\n' "$coord_metrics" "$relay_metrics" | grep -Ei 'org_id|user_id|node_id|email|dns_name|100\\.64\\.' \
  && { printf 'metrics labels contain identifiers\n' >&2; exit 1; } || true

mkdir -p "$(dirname "$EVIDENCE")"
{
  printf '# Observability live proof\n\n'
  printf -- '- UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '- Git: %s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
  printf -- '- Coordinator /metrics: scraped on 127.0.0.1:19701 with diagnostics bearer; unauthenticated 401\n'
  printf -- '- Relay /metrics: scraped on 127.0.0.1:19702 with diagnostics bearer; unauthenticated 401\n'
  printf -- '- Public TLS listener /metrics: %s\n' "$public_metrics"
  printf -- '- Public /livez and /readyz: status only\n'
  printf -- '- Metric labels: no org/node/user/DNS/IP identifiers\n'
  printf '\nCoordinator sample:\n\n```\n'
  printf '%s\n' "$coord_metrics" | sed -n '1,20p'
  printf '```\n\nRelay sample:\n\n```\n'
  printf '%s\n' "$relay_metrics" | sed -n '1,20p'
  printf '```\n'
} >"$EVIDENCE"
printf 'observability proof written to %s\n' "$EVIDENCE"
