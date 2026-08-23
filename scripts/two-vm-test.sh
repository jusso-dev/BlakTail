#!/bin/sh
set -eu
# Run on a controller that can SSH as root to two disposable Linux VMs.
# Required: VM1, VM2, COORD, JOIN_KEY1, JOIN_KEY2, BLAKTAILD.
# ENDPOINT1/ENDPOINT2 are optional; omit them to exercise relay/NAT fallback.
: "${VM1:?}" "${VM2:?}" "${COORD:?}" "${JOIN_KEY1:?}" "${JOIN_KEY2:?}" "${BLAKTAILD:?}"
ENDPOINT_ARG1=""
ENDPOINT_ARG2=""
if [ -n "${ENDPOINT1:-}" ]; then ENDPOINT_ARG1="--endpoint $ENDPOINT1"; fi
if [ -n "${ENDPOINT2:-}" ]; then ENDPOINT_ARG2="--endpoint $ENDPOINT2"; fi
scp "$BLAKTAILD" "$VM1:/usr/local/bin/blaktaild"
scp "$BLAKTAILD" "$VM2:/usr/local/bin/blaktaild"
printf '%s' "$JOIN_KEY1" | ssh "$VM1" "chmod 0755 /usr/local/bin/blaktaild && blaktaild up --coord '$COORD' --name vm-one $ENDPOINT_ARG1 --exit-after-join && { nohup blaktaild run >/tmp/blaktaild.log 2>&1 </dev/null & }"
printf '%s' "$JOIN_KEY2" | ssh "$VM2" "chmod 0755 /usr/local/bin/blaktaild && blaktaild up --coord '$COORD' --name vm-two $ENDPOINT_ARG2 --exit-after-join && { nohup blaktaild run >/tmp/blaktaild.log 2>&1 </dev/null & }"
sleep 35
IP1=$(ssh "$VM1" "blaktaild status | awk '/address:/ {sub(\"/32\",\"\",\$2); print \$2}'")
IP2=$(ssh "$VM2" "blaktaild status | awk '/address:/ {sub(\"/32\",\"\",\$2); print \$2}'")
DNS1=$(ssh "$VM1" "blaktaild status | awk '/dns:/ {print \$2}'")
DNS2=$(ssh "$VM2" "blaktaild status | awk '/dns:/ {print \$2}'")
ssh "$VM1" "ping -c 3 '$IP2'"
ssh "$VM2" "ping -c 3 '$IP1'"
ssh "$VM1" "getent hosts vm-two && getent hosts '$DNS2' && ping -c 1 vm-two"
ssh "$VM2" "getent hosts vm-one && getent hosts '$DNS1' && ping -c 1 vm-one"
printf 'two-VM WireGuard + MagicDNS passed: %s (%s) <-> %s (%s)\n' "$IP1" "$DNS1" "$IP2" "$DNS2"
