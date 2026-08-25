#!/bin/sh
set -eu
# Run on a controller that can SSH as root to two disposable Linux VMs.
# Required: VM1, VM2, COORD, JOIN_KEY1, JOIN_KEY2.
# Supply BLAKTAILD for a development binary, or PREINSTALLED=1 after installing
# the same published package on both VMs.
# ENDPOINT1/ENDPOINT2 are optional; omit them to exercise relay/NAT fallback.
: "${VM1:?}" "${VM2:?}" "${COORD:?}" "${JOIN_KEY1:?}" "${JOIN_KEY2:?}"
case "$COORD" in
  https://*) ;;
  *) printf 'COORD must be an HTTPS URL\n' >&2; exit 2 ;;
esac
case "$COORD" in
  *[!A-Za-z0-9:./_-]*) printf 'unsafe COORD value\n' >&2; exit 2 ;;
esac
ENDPOINT_ARG1=""
ENDPOINT_ARG2=""
if [ -n "${ENDPOINT1:-}" ]; then
  case "$ENDPOINT1" in *[!0-9A-Fa-f:.\[\]-]*) printf 'unsafe ENDPOINT1 value\n' >&2; exit 2 ;; esac
  ENDPOINT_ARG1="--endpoint $ENDPOINT1"
fi
if [ -n "${ENDPOINT2:-}" ]; then
  case "$ENDPOINT2" in *[!0-9A-Fa-f:.\[\]-]*) printf 'unsafe ENDPOINT2 value\n' >&2; exit 2 ;; esac
  ENDPOINT_ARG2="--endpoint $ENDPOINT2"
fi
if [ "${PREINSTALLED:-0}" = 1 ]; then
  ssh "$VM1" "command -v blaktaild && blaktaild --version"
  ssh "$VM2" "command -v blaktaild && blaktaild --version"
else
  : "${BLAKTAILD:?set BLAKTAILD or PREINSTALLED=1}"
  scp "$BLAKTAILD" "$VM1:/usr/local/bin/blaktaild"
  scp "$BLAKTAILD" "$VM2:/usr/local/bin/blaktaild"
fi
# Values interpolated into remote commands are restricted to safe characters above.
# shellcheck disable=SC2029
printf '%s' "$JOIN_KEY1" | ssh "$VM1" "chmod 0755 /usr/local/bin/blaktaild && blaktaild up --coord '$COORD' --name vm-one $ENDPOINT_ARG1 --exit-after-join && { nohup blaktaild run >/tmp/blaktaild.log 2>&1 </dev/null & }"
# shellcheck disable=SC2029
printf '%s' "$JOIN_KEY2" | ssh "$VM2" "chmod 0755 /usr/local/bin/blaktaild && blaktaild up --coord '$COORD' --name vm-two $ENDPOINT_ARG2 --exit-after-join && { nohup blaktaild run >/tmp/blaktaild.log 2>&1 </dev/null & }"
sleep 35
IP1=$(ssh "$VM1" "blaktaild status | awk '\$1 == \"address:\" {sub(\"/32\",\"\",\$2); print \$2; exit}'")
IP2=$(ssh "$VM2" "blaktaild status | awk '\$1 == \"address:\" {sub(\"/32\",\"\",\$2); print \$2; exit}'")
IPV61=$(ssh "$VM1" "blaktaild status | awk '\$1 == \"ipv6\" && \$2 == \"address:\" {sub(\"/128\",\"\",\$3); print \$3; exit}'")
IPV62=$(ssh "$VM2" "blaktaild status | awk '\$1 == \"ipv6\" && \$2 == \"address:\" {sub(\"/128\",\"\",\$3); print \$3; exit}'")
DNS1=$(ssh "$VM1" "blaktaild status | awk '/dns:/ {print \$2}'")
DNS2=$(ssh "$VM2" "blaktaild status | awk '/dns:/ {print \$2}'")
[ -n "$IP1" ] && [ -n "$IP2" ] || { printf 'missing IPv4 status output\n' >&2; exit 1; }
[ -n "$IPV61" ] && [ -n "$IPV62" ] || { printf 'missing IPv6 status output\n' >&2; exit 1; }
[ -n "$DNS1" ] && [ -n "$DNS2" ] || { printf 'missing DNS status output\n' >&2; exit 1; }
case "$IP1:$IP2" in *[!0-9.:]*) printf 'invalid IPv4 status output\n' >&2; exit 1 ;; esac
case "$IPV61:$IPV62" in *[!0-9A-Fa-f:]*) printf 'invalid IPv6 status output\n' >&2; exit 1 ;; esac
case "$DNS1:$DNS2" in *[!A-Za-z0-9.:-]*) printf 'invalid DNS status output\n' >&2; exit 1 ;; esac
# shellcheck disable=SC2029
ssh "$VM1" "ping -c 3 '$IP2'"
# shellcheck disable=SC2029
ssh "$VM2" "ping -c 3 '$IP1'"
# shellcheck disable=SC2029
ssh "$VM1" "ping -6 -c 3 '$IPV62'"
# shellcheck disable=SC2029
ssh "$VM2" "ping -6 -c 3 '$IPV61'"
# shellcheck disable=SC2029
ssh "$VM1" "getent hosts vm-two && getent hosts '$DNS2' && ping -c 1 vm-two"
# shellcheck disable=SC2029
ssh "$VM2" "getent hosts vm-one && getent hosts '$DNS1' && ping -c 1 vm-one"
if [ "${FORCE_RELAY:-0}" = 1 ]; then
  # Block peer-direct UDP while leaving coordinator HTTPS and relay UDP open.
  ssh "$VM1" "command -v iptables >/dev/null"
  ssh "$VM2" "command -v iptables >/dev/null"
  EP1=$(ssh "$VM1" "blaktaild status | awk '\$1 == \"endpoint:\" {print \$2; exit}'")
  EP2=$(ssh "$VM2" "blaktaild status | awk '\$1 == \"endpoint:\" {print \$2; exit}'")
  host_of() { printf '%s' "$1" | awk -F: '{ print $1 }'; }
  H1=$(host_of "$EP1")
  H2=$(host_of "$EP2")
  case "$H1:$H2" in
    '' | *[!0-9.]*) printf 'forced relay requires IPv4 peer endpoints\n' >&2; exit 2 ;;
  esac
  ssh "$VM1" "iptables -I OUTPUT 1 -p udp -d '$H2' -j DROP"
  ssh "$VM2" "iptables -I OUTPUT 1 -p udp -d '$H1' -j DROP"
  sleep 35
  # shellcheck disable=SC2029
  ssh "$VM1" "ping -c 3 '$IP2'"
  ssh "$VM1" "blaktaild status | grep -E 'relay|path'" || true
  ssh "$VM1" "iptables -D OUTPUT -p udp -d '$H2' -j DROP" || true
  ssh "$VM2" "iptables -D OUTPUT -p udp -d '$H1' -j DROP" || true
  sleep 35
  # shellcheck disable=SC2029
  ssh "$VM1" "ping -c 3 '$IP2'"
  printf 'forced-relay and restore probe completed\n'
fi
if [ -n "${ADVERTISE_SUBNET:-}" ]; then
  case "$ADVERTISE_SUBNET" in *[!0-9./]*) printf 'unsafe ADVERTISE_SUBNET\n' >&2; exit 2 ;; esac
  ssh "$VM1" "blaktaild status | grep -F '$ADVERTISE_SUBNET'" \
    || { printf 'advertised subnet missing from status\n' >&2; exit 1; }
  printf 'subnet advertisement visible on vm-one\n'
fi
if [ "${IPV6_ONLY:-0}" = 1 ]; then
  ssh "$VM1" "ip -4 addr del '$IP1/32' dev blaktail0 || ifconfig blaktail0 inet $IP1 -alias"
  ssh "$VM2" "ip -4 addr del '$IP2/32' dev blaktail0 || ifconfig blaktail0 inet $IP2 -alias"
  # shellcheck disable=SC2029
  ssh "$VM1" "ping -6 -c 3 '$IPV62'"
  # shellcheck disable=SC2029
  ssh "$VM2" "ping -6 -c 3 '$IPV61'"
  printf 'IPv6-only drill passed\n'
fi
printf 'two-VM WireGuard + MagicDNS passed: %s, %s (%s) <-> %s, %s (%s)\n' \
  "$IP1" "$IPV61" "$DNS1" "$IP2" "$IPV62" "$DNS2"
