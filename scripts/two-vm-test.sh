#!/bin/sh
set -eu
# Run on a controller that can SSH as root to two disposable Linux VMs.
# Required: VM1, VM2, COORD, JOIN_KEY1, JOIN_KEY2, ENDPOINT1, ENDPOINT2, BLAKTAILD.
: "${VM1:?}" "${VM2:?}" "${COORD:?}" "${JOIN_KEY1:?}" "${JOIN_KEY2:?}" "${ENDPOINT1:?}" "${ENDPOINT2:?}" "${BLAKTAILD:?}"
scp "$BLAKTAILD" "$VM1:/usr/local/bin/blaktaild"
scp "$BLAKTAILD" "$VM2:/usr/local/bin/blaktaild"
ssh "$VM1" "chmod 0755 /usr/local/bin/blaktaild && nohup blaktaild up --coord '$COORD' --join-key '$JOIN_KEY1' --endpoint '$ENDPOINT1' >/tmp/blaktaild.log 2>&1 &"
ssh "$VM2" "chmod 0755 /usr/local/bin/blaktaild && nohup blaktaild up --coord '$COORD' --join-key '$JOIN_KEY2' --endpoint '$ENDPOINT2' >/tmp/blaktaild.log 2>&1 &"
sleep 35
IP1=$(ssh "$VM1" "blaktaild status | awk '/address:/ {sub(\"/32\",\"\",\$2); print \$2}'")
IP2=$(ssh "$VM2" "blaktaild status | awk '/address:/ {sub(\"/32\",\"\",\$2); print \$2}'")
ssh "$VM1" "ping -c 3 '$IP2'"
ssh "$VM2" "ping -c 3 '$IP1'"
printf 'two-VM WireGuard ping passed: %s <-> %s\n' "$IP1" "$IP2"
