#!/usr/bin/env bash
# Enrol two Linux agents and prove a read-only overlay share.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export COMPOSE_HTTP_TIMEOUT="${COMPOSE_HTTP_TIMEOUT:-300}"
export DOCKER_CLIENT_TIMEOUT="${DOCKER_CLIENT_TIMEOUT:-300}"
COMPOSE=(docker compose -p blaktail -f compose.yaml -f compose.homelab.yml --profile acl-prove)
WORKDIR="/tmp/blaktail-share-prove"
COORD="https://coord:8443"
LISTEN_PORT=51820

pin_listen_port() {
  "${COMPOSE[@]}" exec -T "$1" wg set blaktail0 listen-port "$LISTEN_PORT"
}

pin_peer_endpoints() {
  local office_lan store_lan office_pub store_pub
  office_lan="$(container_ip agent-office)"
  store_lan="$(container_ip agent-store)"
  office_pub="$("${COMPOSE[@]}" exec -T agent-office wg show blaktail0 public-key)"
  store_pub="$("${COMPOSE[@]}" exec -T agent-store wg show blaktail0 public-key)"
  pin_listen_port agent-office
  pin_listen_port agent-store
  "${COMPOSE[@]}" exec -T agent-office wg set blaktail0 peer "$store_pub" endpoint "${store_lan}:${LISTEN_PORT}"
  "${COMPOSE[@]}" exec -T agent-store wg set blaktail0 peer "$office_pub" endpoint "${office_lan}:${LISTEN_PORT}"
}
suffix="$(openssl rand -hex 2)"
office_name="office-share-${suffix}"
store_name="store-share-${suffix}"

status_of() {
  "${COMPOSE[@]}" exec -T "$1" blaktaild --coord-ca /certs/ca.crt status
}

overlay_ip() {
  local text
  text="$(status_of "$1")" || return 1
  awk '$1 == "address:" { sub("/32","",$2); print $2; exit }' <<<"$text"
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
pin_peer_endpoints

echo "== publish store share"
"${COMPOSE[@]}" exec -T agent-store sh -ceu '
  mkdir -p /srv/shared
  printf "hello-from-store\n" > /srv/shared/note.txt
  blaktaild --coord-ca /certs/ca.crt share enable --path /srv/shared --name files
'

echo "== allow overlay reachability"
console_bun put-acl '{"defaults":"deny","groups":{},"rules":[{"action":"allow","src_tags":["office","store"],"dst_tags":["office","store"]}]}'

store_ip=""
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  pin_peer_endpoints || true
  store_ip="$(overlay_ip agent-store || true)"
  if [[ -n "$store_ip" ]]; then
    body="$("${COMPOSE[@]}" exec -T agent-office sh -c \
      "wget -qO- --timeout=5 --tries=1 http://${store_ip}:5647/files/note.txt" || true)"
    if [[ "$body" == *hello-from-store* ]]; then
      echo "ok office fetched store share over the overlay"
      dav="$("${COMPOSE[@]}" exec -T agent-office sh -c \
        "wget -qS --timeout=5 --tries=1 --method=PROPFIND --header='Depth: 1' -O- http://${store_ip}:5647/files/" \
        2>&1 || true)"
      if [[ "$dav" == *"207"* && "$dav" == *note.txt* ]]; then
        echo "ok office listed store share over WebDAV"
      else
        echo "FAIL office could not PROPFIND the store share" >&2
        printf '%s\n' "$dav" >&2
        exit 1
      fi
      echo "overlay_share passed"
      exit 0
    fi
  fi
  sleep 3
done

echo "FAIL office could not read the store share" >&2
status_of agent-office >&2 || true
status_of agent-store >&2 || true
exit 1
