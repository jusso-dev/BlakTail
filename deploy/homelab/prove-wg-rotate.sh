#!/usr/bin/env bash
# Enrol one Linux agent and prove WireGuard-only key rotation keeps traffic during overlap.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export COMPOSE_HTTP_TIMEOUT="${COMPOSE_HTTP_TIMEOUT:-300}"
export DOCKER_CLIENT_TIMEOUT="${DOCKER_CLIENT_TIMEOUT:-300}"
COMPOSE=(docker compose -p blaktail -f compose.yaml -f compose.homelab.yml --profile acl-prove)
WORKDIR="/tmp/blaktail-wg-rotate-prove"
COORD="https://coord:8443"
LISTEN_PORT=51820
VANILLA_OVERLAY="10.8.0.2"
suffix="$(openssl rand -hex 2)"
office_name="office-rot-${suffix}"
vanilla_name="vanilla-rot-${suffix}"
OVERLAP_SECONDS=20

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
  local deadline=$((SECONDS + 70))
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

wait_ping() {
  local label="$1"
  local from="$2"
  shift 2
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if "${COMPOSE[@]}" exec -T "$from" ping -c 2 -W 2 "$@" >/tmp/blaktail-wg-only-ping.log 2>&1; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  cat /tmp/blaktail-wg-only-ping.log >&2 || true
  "${COMPOSE[@]}" exec -T agent-office wg show >&2 || true
  "${COMPOSE[@]}" exec -T vanilla-wg wg show >&2 || true
  return 1
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

echo "== install vanilla wg tools"
"${COMPOSE[@]}" exec -T vanilla-wg sh -ceu '
  if ! command -v wg >/dev/null; then
    apt-get update
    apt-get install -y --no-install-recommends wireguard-tools iproute2 iputils-ping
  fi
'
vanilla_lan="$(container_ip vanilla-wg)"
echo "== bring up vanilla wg0 at ${VANILLA_OVERLAY} (${vanilla_lan}:${LISTEN_PORT})"
# Host AppArmor profile `wg` allows private-key reads from /etc/wireguard, not /tmp.
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
kind="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["kind"])' "$created")"
if [[ "$kind" != "wireguard_only" ]]; then
  echo "FAIL stored kind was ${kind}" >&2
  exit 1
fi
echo "ok created ${peer_id} kind=${kind}"

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

wait_ping "vanilla wg pings office overlay" vanilla-wg "$office_overlay_ip"
wait_ping "office agent pings vanilla AllowedIP" agent-office "$VANILLA_OVERLAY"

echo "== rotate vanilla public key with ${OVERLAP_SECONDS}s overlap"
next_pub="$("${COMPOSE[@]}" exec -T vanilla-wg sh -ceu '
  umask 077
  wg genkey > /etc/wireguard/vanilla-next.key
  wg pubkey < /etc/wireguard/vanilla-next.key
')"
next_pub="$(printf '%s' "$next_pub" | tr -d '\r\n ')"
if [[ -z "$next_pub" || "$next_pub" == "$vanilla_pub" ]]; then
  echo "FAIL rotated public key missing" >&2
  exit 1
fi
rotated="$(console_bun rotate-wg-only "$peer_id" "$next_pub" "$OVERLAP_SECONDS" | grep '^{')"
rotated_key="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["wg_public_key"])' "$rotated")"
previous_key="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("previous_wg_public_key") or "")' "$rotated")"
if [[ "$rotated_key" != "$next_pub" || "$previous_key" != "$vanilla_pub" ]]; then
  echo "FAIL rotate response keys were ${rotated_key} / ${previous_key}" >&2
  exit 1
fi
echo "ok stored overlap ${previous_key} -> ${rotated_key}"

# Kernel WireGuard routes each AllowedIP to one peer, so the agent keeps the
# on-interface key until overlap_until and only then installs the successor.
wait_office_peer "office kept old key during overlap" "$vanilla_pub" present
wait_ping "old vanilla key still reaches office during overlap" vanilla-wg "$office_overlay_ip"

wait_office_peer "office dropped old key after overlap" "$vanilla_pub" absent
wait_office_peer "office installed new key after overlap" "$next_pub" present

echo "== switch vanilla wg0 to the new private key"
"${COMPOSE[@]}" exec -T vanilla-wg sh -ceu '
  wg set wg0 private-key /etc/wireguard/vanilla-next.key
  shred -u /etc/wireguard/vanilla.key /etc/wireguard/vanilla-next.key || rm -f /etc/wireguard/vanilla.key /etc/wireguard/vanilla-next.key
'
wait_ping "new vanilla key reaches office after overlap" vanilla-wg "$office_overlay_ip"

echo "wg_only_overlap_rotation passed"
