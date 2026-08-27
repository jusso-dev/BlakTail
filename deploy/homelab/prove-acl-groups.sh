#!/usr/bin/env bash
# Enrol two Linux agent containers and prove named ACL groups change reachability.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
COMPOSE=(docker compose -p blaktail -f compose.yaml -f compose.homelab.yml --profile acl-prove)
WORKDIR="/tmp/blaktail-acl-prove"
COORD="https://coord:8443"
LISTEN_PORT=51820
suffix="$(openssl rand -hex 2)"
office_name="office-${suffix}"
store_name="store-${suffix}"

status_of() {
  "${COMPOSE[@]}" exec -T "$1" blaktaild --coord-ca /certs/ca.crt status
}

wait_for() {
  local label="$1"
  local want="$2"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    local text
    text="$(status_of agent-office || true)"
    if [[ "$want" == "present" && "$text" == *"${store_name}"* ]]; then
      echo "ok ${label}"
      return 0
    fi
    if [[ "$want" == "absent" && "$text" != *"${store_name}"* ]]; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  status_of agent-office >&2 || true
  return 1
}

store_ip() {
  status_of agent-store | awk '$1 == "address:" { sub("/32","",$2); print $2; exit }'
}

ping_store() {
  local ip
  ip="$(store_ip)"
  [[ -n "$ip" ]]
  "${COMPOSE[@]}" exec -T agent-office ping -c 2 -W 2 "$ip"
}

container_ip() {
  "${COMPOSE[@]}" exec -T "$1" sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1"
}

pin_listen_port() {
  "${COMPOSE[@]}" exec -T "$1" wg set blaktail0 listen-port "$LISTEN_PORT"
}

wait_ping() {
  local label="$1"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if ping_store >/tmp/blaktail-allow-ping.log 2>&1; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  cat /tmp/blaktail-allow-ping.log >&2 || true
  status_of agent-office >&2 || true
  "${COMPOSE[@]}" exec -T agent-office wg show >&2 || true
  return 1
}

console_bun() {
  "${COMPOSE[@]}" run --rm \
    -e ACL_PROVE_KEY_DIR=/bootstrap \
    -v "${WORKDIR}:/bootstrap" \
    console bun /bootstrap/acl-prove.mjs "$@"
}

acl() {
  console_bun put-acl "$1"
}

sudo rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
cp deploy/homelab/acl-prove.mjs "$WORKDIR/acl-prove.mjs"
sudo chown -R 999:999 "$WORKDIR"

echo "== build and start agents"
"${COMPOSE[@]}" rm -sf agent-office agent-store >/dev/null 2>&1 || true
docker volume rm -f blaktail_agent-office-data blaktail_agent-store-data >/dev/null 2>&1 || true
"${COMPOSE[@]}" build agent-office
"${COMPOSE[@]}" up -d --force-recreate agent-office agent-store

echo "== reset ACL to default same-tag only"
acl '{"groups":{},"rules":[]}'

echo "== mint join keys"
console_bun mint
sudo chmod 755 "$WORKDIR"
sudo chmod 644 "$WORKDIR/acl-prove.mjs" "$WORKDIR/office" "$WORKDIR/store"

office_id="$("${COMPOSE[@]}" ps -q agent-office)"
store_id="$("${COMPOSE[@]}" ps -q agent-store)"
docker cp "$WORKDIR/office" "${office_id}:/tmp/office.key"
docker cp "$WORKDIR/store" "${store_id}:/tmp/store.key"
sudo rm -f "$WORKDIR/office" "$WORKDIR/store"

office_ip="$(container_ip agent-office)"
store_ip_lan="$(container_ip agent-store)"
echo "== enrol ${office_name} at ${office_ip}:${LISTEN_PORT}"
"${COMPOSE[@]}" exec -T agent-office sh -ceu '
  chmod 600 /tmp/office.key
  printf "%s" "$(tr -d "\n" < /tmp/office.key)" | blaktaild --coord-ca /certs/ca.crt up \
    --coord "'"$COORD"'" --name "'"$office_name"'" \
    --endpoint "'"${office_ip}:${LISTEN_PORT}"'" --poll-seconds 5 --exit-after-join
  shred -u /tmp/office.key || rm -f /tmp/office.key
'
echo "== enrol ${store_name} at ${store_ip_lan}:${LISTEN_PORT}"
"${COMPOSE[@]}" exec -T agent-store sh -ceu '
  chmod 600 /tmp/store.key
  printf "%s" "$(tr -d "\n" < /tmp/store.key)" | blaktaild --coord-ca /certs/ca.crt up \
    --coord "'"$COORD"'" --name "'"$store_name"'" \
    --endpoint "'"${store_ip_lan}:${LISTEN_PORT}"'" --poll-seconds 5 --exit-after-join
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
pin_listen_port agent-office
pin_listen_port agent-store

echo "== default different tags should deny"
wait_for "default ACL hides ${store_name}" absent
if ping_store >/tmp/blaktail-deny-ping.log 2>&1; then
  echo "FAIL ping succeeded before group allow" >&2
  cat /tmp/blaktail-deny-ping.log >&2 || true
  exit 1
fi
echo "ok ping denied under default ACL"

identity="$(console_bun identity | grep '^{')"
user_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["userId"])' "$identity")"
email="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["email"])' "$identity")"

echo "== allow named group testers"
acl "$(python3 -c "import json; print(json.dumps({
  'groups': {'testers': ['''$email''', '''$user_id''']},
  'rules': [{'action':'allow','src_groups':['testers'],'dst_groups':['testers']}]
}))")"
wait_for "group allow lists ${store_name}" present
wait_ping "ping allowed under testers group"

echo "== deny office -> store wins"
acl "$(python3 -c "import json; print(json.dumps({
  'groups': {'testers': ['''$email''', '''$user_id''']},
  'rules': [
    {'action':'allow','src_groups':['testers'],'dst_groups':['testers']},
    {'action':'deny','src_tags':['office'],'dst_tags':['store']}
  ]
}))")"
wait_for "deny removes ${store_name}" absent
if ping_store >/tmp/blaktail-deny2-ping.log 2>&1; then
  echo "FAIL ping succeeded after deny" >&2
  cat /tmp/blaktail-deny2-ping.log >&2 || true
  exit 1
fi
echo "ok ping denied after explicit deny"

echo "acl_group_reachability passed"
