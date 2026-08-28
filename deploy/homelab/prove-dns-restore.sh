#!/usr/bin/env bash
# Enrol one Linux agent and prove disabling managed DNS drops extras and keeps MagicDNS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export COMPOSE_HTTP_TIMEOUT="${COMPOSE_HTTP_TIMEOUT:-300}"
export DOCKER_CLIENT_TIMEOUT="${DOCKER_CLIENT_TIMEOUT:-300}"
COMPOSE=(docker compose -p blaktail -f compose.yaml -f compose.homelab.yml --profile acl-prove)
WORKDIR="/tmp/blaktail-dns-restore-prove"
COORD="https://coord:8443"
LISTEN_PORT=51820
suffix="$(openssl rand -hex 2)"
office_name="office-restore-${suffix}"
RECORD_NAME="wiki.internal.example"
RECORD_IP="10.0.0.10"

status_of() {
  "${COMPOSE[@]}" exec -T agent-office blaktaild --coord-ca /certs/ca.crt status
}

magic_dns_ip() {
  local text
  text="$(status_of)" || return 1
  awk '/^ipv6 address:/ { sub("/128","",$3); print $3; exit }' <<<"$text"
}

node_dns_name() {
  local text
  text="$(status_of)" || return 1
  awk '$1 == "dns:" { print $2; exit }' <<<"$text"
}

container_ip() {
  "${COMPOSE[@]}" exec -T agent-office sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1"
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
  fi
}

dig_at() {
  local nameserver="$1"
  local name="$2"
  "${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 +short "@${nameserver}" "$name" A
}

dig_full() {
  local nameserver="$1"
  local name="$2"
  "${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 "@${nameserver}" "$name" A
}

wait_record() {
  local nameserver="$1"
  local expect_ip="$2"
  local label="$3"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    local answer
    answer="$(dig_at "$nameserver" "$RECORD_NAME" || true)"
    if [[ "$answer" == *"${expect_ip}"* ]]; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  status_of >&2 || true
  dig_full "$nameserver" "$RECORD_NAME" >&2 || true
  return 1
}

wait_unmanaged() {
  local nameserver="$1"
  local node_name="$2"
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    local text extra peer
    text="$(status_of)" || true
    extra="$(dig_full "$nameserver" "$RECORD_NAME" || true)"
    peer="$(dig_at "$nameserver" "$node_name" || true)"
    if [[ "$text" == *"dns managed: no"* && "$extra" == *REFUSED* && -n "$peer" ]]; then
      echo "ok managed DNS disabled; extra A refused; ${node_name} still answers"
      return 0
    fi
    sleep 3
  done
  echo "FAIL agent did not restore after managed DNS was disabled" >&2
  status_of >&2 || true
  dig_full "$nameserver" "$RECORD_NAME" >&2 || true
  dig_full "$nameserver" "$node_name" >&2 || true
  return 1
}

sudo rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
cp deploy/homelab/acl-prove.mjs "$WORKDIR/acl-prove.mjs"
sudo chown -R 999:999 "$WORKDIR"

echo "== purge leftover prove nodes"
console_bun purge-nodes

echo "== build and start office agent"
"${COMPOSE[@]}" rm -sf agent-office >/dev/null 2>&1 || true
docker volume rm -f blaktail_agent-office-data >/dev/null 2>&1 || true
"${COMPOSE[@]}" build agent-office
"${COMPOSE[@]}" up -d --force-recreate agent-office

echo "== mint office join key"
console_bun mint
sudo chmod 755 "$WORKDIR"
sudo chmod 644 "$WORKDIR/acl-prove.mjs"
if [[ -f "$WORKDIR/office" ]]; then
  sudo chmod 644 "$WORKDIR/office"
fi

office_id="$("${COMPOSE[@]}" ps -q agent-office)"
docker cp "$WORKDIR/office" "${office_id}:/tmp/office.key"
sudo rm -f "$WORKDIR/office" "$WORKDIR/store"

office_lan="$(container_ip)"
echo "== enrol ${office_name} at ${office_lan}:${LISTEN_PORT}"
"${COMPOSE[@]}" exec -T agent-office sh -ceu '
  chmod 600 /tmp/office.key
  printf "%s" "$(tr -d "\n" < /tmp/office.key)" | blaktaild --coord-ca /certs/ca.crt up \
    --coord "'"$COORD"'" --name "'"$office_name"'" \
    --endpoint "'"${office_lan}:${LISTEN_PORT}"'" --poll-seconds 5 --exit-after-join
  shred -u /tmp/office.key || rm -f /tmp/office.key
'
"${COMPOSE[@]}" exec -d agent-office blaktaild --coord-ca /certs/ca.crt run --poll-seconds 5
office_up=
for _ in $(seq 1 45); do
  if "${COMPOSE[@]}" exec -T agent-office wg show blaktail0 >/dev/null 2>&1; then
    office_up=1
    break
  fi
  sleep 1
done
if [[ -z "$office_up" ]]; then
  echo "FAIL office WireGuard interface missing" >&2
  "${COMPOSE[@]}" exec -T agent-office sh -c 'ip link' >&2 || true
  exit 1
fi

ensure_dig
office_dns="$(magic_dns_ip)"
node_name="$(node_dns_name)"
[[ -n "$office_dns" && -n "$node_name" ]]

echo "== publish extra A ${RECORD_NAME} -> ${RECORD_IP}"
console_bun put-dns "$(python3 -c "import json; print(json.dumps({
  'managed': True,
  'search_domains': ['internal.example'],
  'records': [{'name': '''$RECORD_NAME''', 'type': 'A', 'value': '''$RECORD_IP'''}]
}))")"

wait_record "$office_dns" "$RECORD_IP" "office MagicDNS answers ${RECORD_NAME}"
status_text="$(status_of)"
if [[ "$status_text" != *"dns managed: yes"* ]]; then
  echo "FAIL expected managed DNS after first publish" >&2
  printf '%s\n' "$status_text" >&2
  exit 1
fi

echo "== disable managed organisation DNS"
console_bun put-dns "$(python3 -c "import json; print(json.dumps({
  'managed': False,
  'search_domains': ['internal.example'],
  'records': [{'name': '''$RECORD_NAME''', 'type': 'A', 'value': '''$RECORD_IP'''}]
}))")"

wait_unmanaged "$office_dns" "$node_name"
leftover="$(dig_at "$office_dns" "$RECORD_NAME" || true)"
if [[ "$leftover" == *"${RECORD_IP}"* ]]; then
  echo "FAIL extra A still answered after managed DNS was disabled" >&2
  printf '%s\n' "$leftover" >&2
  status_of >&2 || true
  exit 1
fi
echo "ok extra A ${RECORD_IP} is gone after restore"

echo "org_dns_restore_on_disable passed"
