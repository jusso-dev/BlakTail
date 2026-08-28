#!/usr/bin/env bash
# Enrol one Linux agent and prove a vanilla wg peer reaches an allowed service
# while the adjacent port is denied on the managed side.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export COMPOSE_HTTP_TIMEOUT="${COMPOSE_HTTP_TIMEOUT:-300}"
export DOCKER_CLIENT_TIMEOUT="${DOCKER_CLIENT_TIMEOUT:-300}"
COMPOSE=(docker compose -p blaktail -f compose.yaml -f compose.homelab.yml --profile acl-prove)
WORKDIR="/tmp/blaktail-wg-only-svc-prove"
COORD="https://coord:8443"
LISTEN_PORT=51820
VANILLA_OVERLAY="10.8.0.2"
suffix="$(openssl rand -hex 2)"
office_name="office-wgsvc-${suffix}"
vanilla_name="vanilla-svc-${suffix}"

status_of() {
  "${COMPOSE[@]}" exec -T agent-office blaktaild --coord-ca /certs/ca.crt status
}

container_ip() {
  "${COMPOSE[@]}" exec -T "$1" sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1"
}

office_overlay() {
  local text
  text="$(status_of)" || return 1
  awk '$1 == "address:" { sub("/32","",$2); print $2; exit }' <<<"$text"
}

office_pub() {
  "${COMPOSE[@]}" exec -T agent-office wg show blaktail0 public-key
}

console_bun() {
  "${COMPOSE[@]}" run --rm \
    -e ACL_PROVE_KEY_DIR=/bootstrap \
    -v "${WORKDIR}:/bootstrap" \
    console bun /bootstrap/acl-prove.mjs "$@"
}

wait_office_peer() {
  local label="$1"
  local pubkey="$2"
  local want="$3"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    local text
    text="$("${COMPOSE[@]}" exec -T agent-office wg show blaktail0 || true)"
    if [[ "$want" == "present" && "$text" == *"${pubkey}"* ]]; then
      echo "ok ${label}"
      return 0
    fi
    if [[ "$want" == "absent" && "$text" != *"${pubkey}"* ]]; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  "${COMPOSE[@]}" exec -T agent-office wg show blaktail0 >&2 || true
  status_of >&2 || true
  return 1
}

wait_ingress() {
  local label="$1"
  local needle="$2"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    local text
    text="$(status_of)" || true
    if [[ "$text" == *"${needle}"* ]]; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  status_of >&2 || true
  "${COMPOSE[@]}" exec -T agent-office iptables -S BLAKTAIL-ACL >&2 || true
  return 1
}

wait_connect() {
  local label="$1"
  local ip="$2"
  local port="$3"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if "${COMPOSE[@]}" exec -T vanilla-wg nc -w 2 -q 1 "$ip" "$port" >/tmp/blaktail-wg-svc-allow.log 2>&1; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  cat /tmp/blaktail-wg-svc-allow.log >&2 || true
  status_of >&2 || true
  "${COMPOSE[@]}" exec -T agent-office iptables -S BLAKTAIL-ACL >&2 || true
  return 1
}

expect_refused() {
  local label="$1"
  local ip="$2"
  local port="$3"
  if "${COMPOSE[@]}" exec -T vanilla-wg nc -w 2 -q 1 "$ip" "$port" >/tmp/blaktail-wg-svc-deny.log 2>&1; then
    echo "FAIL ${label}: connect succeeded" >&2
    cat /tmp/blaktail-wg-svc-deny.log >&2 || true
    "${COMPOSE[@]}" exec -T agent-office iptables -S BLAKTAIL-ACL >&2 || true
    return 1
  fi
  echo "ok ${label}"
}

sudo rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
cp deploy/homelab/acl-prove.mjs "$WORKDIR/acl-prove.mjs"
sudo chown -R 999:999 "$WORKDIR"

echo "== purge leftover prove nodes"
console_bun purge-nodes

echo "== build and start office agent and vanilla wg"
"${COMPOSE[@]}" rm -sf agent-office vanilla-wg >/dev/null 2>&1 || true
docker volume rm -f blaktail_agent-office-data >/dev/null 2>&1 || true
"${COMPOSE[@]}" build agent-office
"${COMPOSE[@]}" up -d --force-recreate agent-office vanilla-wg

echo "== reset ACL to default same-tag only"
console_bun put-acl '{"groups":{},"rules":[]}'

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

office_lan="$(container_ip agent-office)"
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
  "${COMPOSE[@]}" exec -T agent-office sh -c 'ps aux; ip link' >&2 || true
  exit 1
fi
pinned=
for _ in $(seq 1 10); do
  if "${COMPOSE[@]}" exec -T agent-office wg set blaktail0 listen-port "$LISTEN_PORT"; then
    pinned=1
    break
  fi
  sleep 1
done
if [[ -z "$pinned" ]]; then
  echo "FAIL could not pin office listen-port" >&2
  "${COMPOSE[@]}" exec -T agent-office wg show >&2 || true
  exit 1
fi

echo "== install vanilla wg and netcat"
"${COMPOSE[@]}" exec -T vanilla-wg sh -ceu '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends wireguard-tools iproute2 iputils-ping netcat-openbsd >/dev/null
'
"${COMPOSE[@]}" exec -T agent-office sh -ceu '
  if ! command -v nc >/dev/null; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends netcat-openbsd >/dev/null
  fi
'
vanilla_lan="$(container_ip vanilla-wg)"
echo "== bring up vanilla wg0 at ${VANILLA_OVERLAY} (${vanilla_lan}:${LISTEN_PORT})"
vanilla_pub="$("${COMPOSE[@]}" exec -T vanilla-wg sh -ceu '
  mkdir -p /etc/wireguard
  umask 077
  wg genkey > /etc/wireguard/vanilla.key
  pubkey="$(wg pubkey < /etc/wireguard/vanilla.key)"
  ip link del dev wg0 2>/dev/null || true
  ip link add dev wg0 type wireguard
  ip address add '"${VANILLA_OVERLAY}"'/32 dev wg0
  wg set wg0 private-key /etc/wireguard/vanilla.key listen-port '"${LISTEN_PORT}"'
  ip link set up dev wg0
  shred -u /etc/wireguard/vanilla.key || rm -f /etc/wireguard/vanilla.key
  printf "%s\n" "$pubkey"
')"
vanilla_pub="$(printf '%s' "$vanilla_pub" | tr -d '\r\n ')"
if [[ -z "$vanilla_pub" ]]; then
  echo "FAIL vanilla public key missing" >&2
  exit 1
fi
echo "ok vanilla interface is wg0 with no blaktaild"

echo "== register wireguard_only peer ${vanilla_name}"
created="$(console_bun create-wg-only "$vanilla_name" "$vanilla_pub" "${vanilla_lan}:${LISTEN_PORT}" "${VANILLA_OVERLAY}/32" office | grep '^{')"
peer_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$created")"
echo "ok created ${peer_id}"
wait_office_peer "office agent exported vanilla peer" "$vanilla_pub" present

office_overlay_ip="$(office_overlay)"
office_public="$(office_pub | tr -d '\r\n')"
if [[ -z "$office_overlay_ip" || -z "$office_public" ]]; then
  echo "FAIL office overlay identity missing" >&2
  status_of >&2 || true
  exit 1
fi
echo "== configure vanilla AllowedIPs ${office_overlay_ip}/32"
"${COMPOSE[@]}" exec -T vanilla-wg sh -ceu '
  wg set wg0 peer "'"$office_public"'" endpoint "'"${office_lan}:${LISTEN_PORT}"'" allowed-ips "'"${office_overlay_ip}/32"'" persistent-keepalive 25
  ip route replace "'"${office_overlay_ip}/32"'" dev wg0
'
if "${COMPOSE[@]}" exec -T vanilla-wg sh -c 'command -v blaktaild >/dev/null'; then
  echo "FAIL vanilla container has blaktaild" >&2
  exit 1
fi

echo "== allow office TCP 8080 and deny the adjacent port"
console_bun put-acl '{"defaults":"deny","groups":{},"rules":[{"action":"allow","src_tags":["office"],"dst_tags":["office"],"dst_ports":["8080"],"protocols":["tcp"]}]}'
wait_ingress "office ingress for vanilla is tcp:8080" "tcp:8080"

echo "== listen on office 8080 and 8081"
"${COMPOSE[@]}" exec -d agent-office sh -ceu 'while true; do printf allowed | nc -l -p 8080 -q 1 || true; done'
"${COMPOSE[@]}" exec -d agent-office sh -ceu 'while true; do printf denied | nc -l -p 8081 -q 1 || true; done'

wait_connect "vanilla wg reaches allowed TCP 8080 on office" "$office_overlay_ip" 8080
expect_refused "vanilla wg denied adjacent TCP 8081 on office" "$office_overlay_ip" 8081
echo "ok managed BLAKTAIL-ACL on office enforces the adjacent deny; vanilla has no BlakTail policy"

echo "wg_only_denied_adjacent_service passed"
