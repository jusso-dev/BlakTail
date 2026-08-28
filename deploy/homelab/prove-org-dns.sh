#!/usr/bin/env bash
# Enrol two Linux agents and prove both answer published extra A and AAAA records.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export COMPOSE_HTTP_TIMEOUT="${COMPOSE_HTTP_TIMEOUT:-300}"
export DOCKER_CLIENT_TIMEOUT="${DOCKER_CLIENT_TIMEOUT:-300}"
COMPOSE=(docker compose -p blaktail -f compose.yaml -f compose.homelab.yml --profile acl-prove)
WORKDIR="/tmp/blaktail-dns-prove"
COORD="https://coord:8443"
LISTEN_PORT=51820
suffix="$(openssl rand -hex 2)"
office_name="office-dns-${suffix}"
store_name="store-dns-${suffix}"
RECORD_NAME="wiki.internal.example"
RECORD_IP="10.0.0.10"
RECORD_IP6="fd12:3456:789a:bcde::10"

status_of() {
  "${COMPOSE[@]}" exec -T "$1" blaktaild --coord-ca /certs/ca.crt status
}

magic_dns_ip() {
  local text
  text="$(status_of "$1")" || return 1
  awk '/^ipv6 address:/ { sub("/128","",$3); print $3; exit }' <<<"$text"
}

container_ip() {
  "${COMPOSE[@]}" exec -T "$1" sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1"
}

console_bun() {
  "${COMPOSE[@]}" run --rm \
    -e ACL_PROVE_KEY_DIR=/bootstrap \
    -v "${WORKDIR}:/bootstrap" \
    console bun /bootstrap/acl-prove.mjs "$@"
}

ensure_dig() {
  if ! "${COMPOSE[@]}" exec -T agent-office sh -c "command -v dig >/dev/null"; then
    "${COMPOSE[@]}" exec -T agent-office sh -ceu 'apt-get update -qq && apt-get install -y -qq --no-install-recommends dnsutils >/dev/null'
    "${COMPOSE[@]}" exec -T agent-store sh -ceu 'apt-get update -qq && apt-get install -y -qq --no-install-recommends dnsutils >/dev/null'
  fi
}

dig_at() {
  local agent="$1"
  local nameserver="$2"
  local name="$3"
  local qtype="${4:-A}"
  "${COMPOSE[@]}" exec -T "$agent" dig +time=1 +tries=1 +short "@${nameserver}" "$name" "$qtype"
}

wait_record() {
  local agent="$1"
  local nameserver="$2"
  local qtype="$3"
  local expect="$4"
  local label="$5"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    local answer
    answer="$(dig_at "$agent" "$nameserver" "$RECORD_NAME" "$qtype" || true)"
    if [[ "$answer" == *"${expect}"* ]]; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  status_of "$agent" >&2 || true
  "${COMPOSE[@]}" exec -T "$agent" dig +time=1 +tries=1 "@${nameserver}" "$RECORD_NAME" "$qtype" >&2 || true
  return 1
}

sudo rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
cp deploy/homelab/acl-prove.mjs "$WORKDIR/acl-prove.mjs"
sudo chown -R 999:999 "$WORKDIR"

echo "== purge leftover prove nodes"
console_bun purge-nodes

echo "== build and start agents"
"${COMPOSE[@]}" rm -sf agent-office agent-store >/dev/null 2>&1 || true
docker volume rm -f blaktail_agent-office-data blaktail_agent-store-data >/dev/null 2>&1 || true
"${COMPOSE[@]}" build agent-office
"${COMPOSE[@]}" up -d --force-recreate agent-office agent-store

echo "== mint join keys"
console_bun mint
sudo chmod 755 "$WORKDIR"
sudo chmod 644 "$WORKDIR/acl-prove.mjs" "$WORKDIR/office" "$WORKDIR/store"

office_id="$("${COMPOSE[@]}" ps -q agent-office)"
store_id="$("${COMPOSE[@]}" ps -q agent-store)"
docker cp "$WORKDIR/office" "${office_id}:/tmp/office.key"
docker cp "$WORKDIR/store" "${store_id}:/tmp/store.key"
sudo rm -f "$WORKDIR/office" "$WORKDIR/store"

office_lan="$(container_ip agent-office)"
store_lan="$(container_ip agent-store)"
echo "== enrol ${office_name} at ${office_lan}:${LISTEN_PORT}"
"${COMPOSE[@]}" exec -T agent-office sh -ceu '
  chmod 600 /tmp/office.key
  printf "%s" "$(tr -d "\n" < /tmp/office.key)" | blaktaild --coord-ca /certs/ca.crt up \
    --coord "'"$COORD"'" --name "'"$office_name"'" \
    --endpoint "'"${office_lan}:${LISTEN_PORT}"'" --poll-seconds 5 --exit-after-join
  shred -u /tmp/office.key || rm -f /tmp/office.key
'
echo "== enrol ${store_name} at ${store_lan}:${LISTEN_PORT}"
"${COMPOSE[@]}" exec -T agent-store sh -ceu '
  chmod 600 /tmp/store.key
  printf "%s" "$(tr -d "\n" < /tmp/store.key)" | blaktaild --coord-ca /certs/ca.crt up \
    --coord "'"$COORD"'" --name "'"$store_name"'" \
    --endpoint "'"${store_lan}:${LISTEN_PORT}"'" --poll-seconds 5 --exit-after-join
  shred -u /tmp/store.key || rm -f /tmp/store.key
'

"${COMPOSE[@]}" exec -d agent-office blaktaild --coord-ca /certs/ca.crt run --poll-seconds 5
"${COMPOSE[@]}" exec -d agent-store blaktaild --coord-ca /certs/ca.crt run --poll-seconds 5
for _ in $(seq 1 15); do
  if "${COMPOSE[@]}" exec -T agent-office wg show blaktail0 >/dev/null 2>&1 \
    && "${COMPOSE[@]}" exec -T agent-store wg show blaktail0 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ensure_dig
office_dns="$(magic_dns_ip agent-office)"
store_dns="$(magic_dns_ip agent-store)"
[[ -n "$office_dns" && -n "$store_dns" ]]

echo "== publish extra A/AAAA ${RECORD_NAME} -> ${RECORD_IP} / ${RECORD_IP6}"
console_bun put-dns "$(python3 -c "import json; print(json.dumps({
  'managed': True,
  'search_domains': ['internal.example'],
  'records': [
    {'name': '''$RECORD_NAME''', 'type': 'A', 'value': '''$RECORD_IP'''},
    {'name': '''$RECORD_NAME''', 'type': 'AAAA', 'value': '''$RECORD_IP6'''}
  ]
}))")"

wait_record agent-office "$office_dns" A "$RECORD_IP" "office MagicDNS answers ${RECORD_NAME} A"
wait_record agent-store "$store_dns" A "$RECORD_IP" "store MagicDNS answers ${RECORD_NAME} A"
wait_record agent-office "$office_dns" AAAA "$RECORD_IP6" "office MagicDNS answers ${RECORD_NAME} AAAA"
wait_record agent-store "$store_dns" AAAA "$RECORD_IP6" "store MagicDNS answers ${RECORD_NAME} AAAA"

echo "== public names stay refused"
office_public="$("${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 "@${office_dns}" example.com A)"
store_public="$("${COMPOSE[@]}" exec -T agent-store dig +time=1 +tries=1 "@${store_dns}" example.com A)"
if [[ "$office_public" != *REFUSED* || "$store_public" != *REFUSED* ]]; then
  echo "FAIL public lookup was not REFUSED" >&2
  printf '%s\n' "$office_public" "$store_public" >&2
  exit 1
fi
echo "ok public names refused on both agents"

echo "org_dns_extra_records passed"
