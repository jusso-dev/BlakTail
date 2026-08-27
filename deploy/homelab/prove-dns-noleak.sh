#!/usr/bin/env bash
# Enrol one Linux agent and prove private DNS queries never hit a public resolver.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
COMPOSE=(docker compose -p blaktail -f compose.yaml -f compose.homelab.yml --profile acl-prove)
WORKDIR="/tmp/blaktail-dns-noleak-prove"
COORD="https://coord:8443"
LISTEN_PORT=51820
suffix="$(openssl rand -hex 2)"
office_name="office-noleak-${suffix}"
RECORD_NAME="wiki.internal.example"
RECORD_IP="10.0.0.10"
SPLIT_NAME="leaky.internal.example"
SPLIT_IP="10.9.9.9"
DECOY_PUBLIC="1.1.1.1"

status_of() {
  "${COMPOSE[@]}" exec -T agent-office blaktaild --coord-ca /certs/ca.crt status
}

magic_dns_ip() {
  status_of | awk '/^ipv6 address:/ { sub("/128","",$3); print $3; exit }'
}

container_ip() {
  local id
  id="$("${COMPOSE[@]}" ps -q "$1")"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id"
}

console_bun() {
  "${COMPOSE[@]}" run --rm \
    -e ACL_PROVE_KEY_DIR=/bootstrap \
    -v "${WORKDIR}:/bootstrap" \
    console bun /bootstrap/acl-prove.mjs "$@"
}

dig_at() {
  local nameserver="$1"
  local name="$2"
  shift 2
  "${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 +short "@${nameserver}" "$name" A "$@"
}

wait_record() {
  local nameserver="$1"
  local label="$2"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    local answer
    answer="$(dig_at "$nameserver" "$RECORD_NAME" || true)"
    if [[ "$answer" == *"${RECORD_IP}"* ]]; then
      echo "ok ${label}"
      return 0
    fi
    sleep 3
  done
  echo "FAIL ${label}" >&2
  status_of >&2 || true
  "${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 "@${nameserver}" "$RECORD_NAME" A >&2 || true
  return 1
}

sudo rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
cp deploy/homelab/acl-prove.mjs "$WORKDIR/acl-prove.mjs"
sudo chown -R 999:999 "$WORKDIR"

echo "== build and start office agent and dns sink"
"${COMPOSE[@]}" rm -sf agent-office dns-sink >/dev/null 2>&1 || true
docker volume rm -f blaktail_agent-office-data >/dev/null 2>&1 || true
"${COMPOSE[@]}" build agent-office
"${COMPOSE[@]}" up -d --force-recreate agent-office dns-sink

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
sink_lan="$(container_ip dns-sink)"
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

echo "== install capture and sink tools"
"${COMPOSE[@]}" exec -T agent-office sh -ceu '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends dnsutils tcpdump >/dev/null
'
"${COMPOSE[@]}" exec -T dns-sink sh -ceu '
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends dnsmasq >/dev/null
'
"${COMPOSE[@]}" exec -d dns-sink dnsmasq --no-daemon --no-resolv --no-hosts \
  --address="/${SPLIT_NAME}/${SPLIT_IP}"
sink_up=
for _ in $(seq 1 15); do
  if "${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 +short "@${sink_lan}" "$SPLIT_NAME" A \
    | grep -q "$SPLIT_IP"; then
    sink_up=1
    break
  fi
  sleep 1
done
if [[ -z "$sink_up" ]]; then
  echo "FAIL dns-sink is not answering ${SPLIT_NAME}" >&2
  "${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 "@${sink_lan}" "$SPLIT_NAME" A >&2 || true
  exit 1
fi
echo "ok dns-sink ${sink_lan}:53 answers ${SPLIT_NAME}"

office_dns="$(magic_dns_ip)"
[[ -n "$office_dns" && -n "$sink_lan" ]]

echo "== publish extra A, split ${sink_lan}, and decoy public resolver ${DECOY_PUBLIC}"
console_bun put-dns "$(python3 -c "import json; print(json.dumps({
  'managed': True,
  'global_resolvers': ['${DECOY_PUBLIC}'],
  'search_domains': ['internal.example'],
  'split': [{'suffix': 'internal.example', 'resolvers': ['${sink_lan}']}],
  'records': [{'name': '''$RECORD_NAME''', 'type': 'A', 'value': '''$RECORD_IP'''}]
}))")"

wait_record "$office_dns" "office MagicDNS answers ${RECORD_NAME}"

echo "== capture eth0 and lo DNS while querying private and public names"
"${COMPOSE[@]}" exec -T agent-office sh -ceu '
  rm -f /tmp/dns-eth0.pcap /tmp/dns-lo.pcap
  tcpdump -i eth0 -n -U -w /tmp/dns-eth0.pcap udp port 53 or tcp port 53 >/tmp/tcpdump-eth0.log 2>&1 &
  echo $! >/tmp/tcpdump-eth0.pid
  tcpdump -i lo -n -U -w /tmp/dns-lo.pcap udp port 53 or tcp port 53 >/tmp/tcpdump-lo.log 2>&1 &
  echo $! >/tmp/tcpdump-lo.pid
  sleep 1
'
magic_domain="$(status_of | awk '$1 == "dns:" { sub(/^[^.]+./, "", $2); print $2; exit }')"
dig_at "$office_dns" "$RECORD_NAME" >/dev/null || true
dig_at "$office_dns" "ghost.${magic_domain:-blaktail}" >/dev/null || true
dig_at "$office_dns" "${office_name}.invalid.blaktail" >/dev/null || true
office_public="$("${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 "@${office_dns}" example.com A || true)"
split_answer="$(dig_at "$office_dns" "$SPLIT_NAME" || true)"
sleep 1
"${COMPOSE[@]}" exec -T agent-office sh -ceu '
  kill "$(cat /tmp/tcpdump-eth0.pid)" "$(cat /tmp/tcpdump-lo.pid)" 2>/dev/null || true
  sleep 1
'

if [[ "$office_public" != *REFUSED* ]]; then
  echo "FAIL public lookup was not REFUSED" >&2
  printf '%s\n' "$office_public" >&2
  exit 1
fi
echo "ok public names refused"

if [[ "$split_answer" != *"${SPLIT_IP}"* ]]; then
  echo "FAIL split name was not answered by the published sink" >&2
  printf '%s\n' "$split_answer" >&2
  "${COMPOSE[@]}" exec -T agent-office dig +time=1 +tries=1 "@${office_dns}" "$SPLIT_NAME" A >&2 || true
  exit 1
fi
echo "ok split ${SPLIT_NAME} answered ${SPLIT_IP} via published sink"

eth0_text="$("${COMPOSE[@]}" exec -T agent-office tcpdump -r /tmp/dns-eth0.pcap -n -tt 2>/dev/null || true)"
lo_text="$("${COMPOSE[@]}" exec -T agent-office tcpdump -r /tmp/dns-lo.pcap -n -tt 2>/dev/null || true)"
export BLAKTAIL_DNS_SINK="$sink_lan"
export BLAKTAIL_DNS_MAGIC="$office_dns"
export BLAKTAIL_DNS_ETH0="$eth0_text"
export BLAKTAIL_DNS_LO="$lo_text"
python3 - <<'PY'
import os, re, sys

sink = os.environ["BLAKTAIL_DNS_SINK"]
magic = os.environ["BLAKTAIL_DNS_MAGIC"].strip("[]")
public = {
    "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9",
    "208.67.222.222", "208.67.220.220", "127.0.0.11",
    "2606:4700:4700::1111", "2001:4860:4860::8888",
}
dest_re = re.compile(r"> ([0-9a-fA-F:.]+)\.53:")

def dests(text):
    found = []
    for line in text.splitlines():
        match = dest_re.search(line)
        if match:
            found.append(match.group(1).strip("[]"))
    return found

eth0 = dests(os.environ["BLAKTAIL_DNS_ETH0"])
lo = dests(os.environ["BLAKTAIL_DNS_LO"])
observed = eth0 + lo
leaked = sorted({ip for ip in observed if ip in public})
if leaked:
    print("FAIL private DNS reached a public or default resolver: " + ", ".join(leaked), file=sys.stderr)
    print(os.environ["BLAKTAIL_DNS_ETH0"], file=sys.stderr)
    print(os.environ["BLAKTAIL_DNS_LO"], file=sys.stderr)
    sys.exit(1)
other = sorted({ip for ip in eth0 if ip != sink})
if other:
    print("FAIL eth0 DNS went somewhere other than the published sink: " + ", ".join(other), file=sys.stderr)
    print(os.environ["BLAKTAIL_DNS_ETH0"], file=sys.stderr)
    sys.exit(1)
if sink not in eth0:
    print("FAIL capture missed the split forward to the published sink", file=sys.stderr)
    print(os.environ["BLAKTAIL_DNS_ETH0"], file=sys.stderr)
    sys.exit(1)
lo_foreign = sorted({ip for ip in lo if ip not in {magic, sink}})
if lo_foreign:
    print("FAIL loopback captured DNS to " + ", ".join(lo_foreign), file=sys.stderr)
    print(os.environ["BLAKTAIL_DNS_LO"], file=sys.stderr)
    sys.exit(1)
print(f"ok capture: split forwarded only to {sink}; extra/.blaktail/public stayed on MagicDNS {magic}")
PY

echo "org_dns_no_public_leak passed"
