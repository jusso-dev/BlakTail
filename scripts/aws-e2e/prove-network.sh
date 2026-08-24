#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws awk grep jq terraform tr; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity
assert_network_guards
for agent_name in ubuntu al2023; do
  [ -f "$WORK_DIR/enrolment-$agent_name.ok" ] || die "enrollment proof missing for $agent_name"
done

instance_json=$(tf_output_json agent_instance_ids)
ubuntu_id=$(printf '%s' "$instance_json" | jq -er .ubuntu)
al2023_id=$(printf '%s' "$instance_json" | jq -er .al2023)
relay_endpoint=$(tf_output_raw relay_endpoint)
relay_endpoint=${relay_endpoint#udp://}

status_command="/usr/local/bin/blaktaild status | sed -n '/^address: /p;/^ipv6 address: /p;/^dns: /p'"
ssm_send_script "$ubuntu_id" "Read BlakTail E2E status $RUN_ID" "$status_command"
wait_ssm_command "$SSM_COMMAND_ID" "$ubuntu_id"
ubuntu_status=$(ssm_command_output "$SSM_COMMAND_ID" "$ubuntu_id")
ssm_send_script "$al2023_id" "Read BlakTail E2E status $RUN_ID" "$status_command"
wait_ssm_command "$SSM_COMMAND_ID" "$al2023_id"
al2023_status=$(ssm_command_output "$SSM_COMMAND_ID" "$al2023_id")

status_value() {
  printf '%s\n' "$1" | awk -v key="$2" '$1 == key { print $2; exit }'
}
ubuntu_ipv4=$(status_value "$ubuntu_status" address:)
ubuntu_ipv6=$(printf '%s\n' "$ubuntu_status" | awk '$1 == "ipv6" && $2 == "address:" { print $3; exit }')
ubuntu_dns=$(status_value "$ubuntu_status" dns:)
al2023_ipv4=$(status_value "$al2023_status" address:)
al2023_ipv6=$(printf '%s\n' "$al2023_status" | awk '$1 == "ipv6" && $2 == "address:" { print $3; exit }')
al2023_dns=$(status_value "$al2023_status" dns:)
ubuntu_ipv4=${ubuntu_ipv4%/*}
ubuntu_ipv6=${ubuntu_ipv6%/*}
al2023_ipv4=${al2023_ipv4%/*}
al2023_ipv6=${al2023_ipv6%/*}

for address in "$ubuntu_ipv4" "$al2023_ipv4"; do
  printf '%s' "$address" | jq -R -e 'test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")' >/dev/null || die "invalid IPv4 proof value"
done
for address in "$ubuntu_ipv6" "$al2023_ipv6"; do
  case "$address" in *:*) ;; *) die "invalid IPv6 proof value" ;; esac
done
for dns_name in "$ubuntu_dns" "$al2023_dns"; do
  case "$dns_name" in '' | *[!A-Za-z0-9.-]*) die "invalid MagicDNS proof value" ;; esac
done

make_key() {
  key_instance_id=$1
  ssm_send_script "$key_instance_id" "Create ephemeral BlakTail E2E SSH proof key $RUN_ID" \
    "install -d -m 0700 /var/lib/blaktail-e2e; test -f /var/lib/blaktail-e2e/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -f /var/lib/blaktail-e2e/id_ed25519; cat /var/lib/blaktail-e2e/id_ed25519.pub"
  wait_ssm_command "$SSM_COMMAND_ID" "$key_instance_id"
  PROOF_PUBLIC_KEY=$(ssm_command_output "$SSM_COMMAND_ID" "$key_instance_id" | \
    tr -d '\r' | awk '/^ssh-ed25519 / { key = $0 } END { print key }')
  case "$PROOF_PUBLIC_KEY" in
    *"'"*) die "invalid SSH proof public key" ;;
    ssh-ed25519\ *) ;;
    *) die "invalid SSH proof public key" ;;
  esac
}

install_key() {
  key_instance_id=$1
  key_value=$2
  remote_script="PUBLIC_KEY='$key_value'
set -eu
install -d -m 0700 -o blaktail-e2e -g blaktail-e2e /home/blaktail-e2e/.ssh
printf '%s\\n' \"\$PUBLIC_KEY\" > /home/blaktail-e2e/.ssh/authorized_keys
chown blaktail-e2e:blaktail-e2e /home/blaktail-e2e/.ssh/authorized_keys
chmod 0600 /home/blaktail-e2e/.ssh/authorized_keys"
  ssm_send_script "$key_instance_id" "Install ephemeral BlakTail E2E SSH proof key $RUN_ID" "$remote_script"
  wait_ssm_command "$SSM_COMMAND_ID" "$key_instance_id"
}

make_key "$ubuntu_id"
ubuntu_public_key=$PROOF_PUBLIC_KEY
make_key "$al2023_id"
al2023_public_key=$PROOF_PUBLIC_KEY
install_key "$al2023_id" "$ubuntu_public_key"
install_key "$ubuntu_id" "$al2023_public_key"

run_proof() {
  source_name=$1
  source_id=$2
  target_ipv4=$3
  target_ipv6=$4
  target_dns=$5
  remote_script="TARGET_IPV4=$target_ipv4
TARGET_IPV6=$target_ipv6
TARGET_DNS=$target_dns
RELAY_ENDPOINT=$relay_endpoint
set -eu
ping -c 3 -W 3 \"\$TARGET_IPV4\" >/dev/null
ping -6 -c 3 -W 3 \"\$TARGET_IPV6\" >/dev/null
getent ahosts \"\$TARGET_DNS\" >/dev/null
jq -e --arg relay \"\$RELAY_ENDPOINT\" '.relays | index(\$relay) != null' \
  /var/lib/blaktail/state.json >/dev/null
ip route get \"\$TARGET_IPV4\" | grep -F 'dev blaktail0' >/dev/null
ip -6 route get \"\$TARGET_IPV6\" | grep -F 'dev blaktail0' >/dev/null
ssh -i /var/lib/blaktail-e2e/id_ed25519 -o BatchMode=yes \\
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/lib/blaktail-e2e/known_hosts \\
  -o ConnectTimeout=10 \"blaktail-e2e@\$TARGET_DNS\" 'printf ssh=ok; uname -m'
printf '\\nipv4=ok\\nipv6=ok\\nmagicdns=ok\\nrelay_configured=ok\\noverlay_routes=ok\\n'"
  ssm_send_script "$source_id" "Prove BlakTail E2E network from $source_name $RUN_ID" "$remote_script"
  wait_ssm_command "$SSM_COMMAND_ID" "$source_id"
  proof_output=$(ssm_command_output "$SSM_COMMAND_ID" "$source_id")
  for expected_line in ssh=ok ipv4=ok ipv6=ok magicdns=ok relay_configured=ok overlay_routes=ok; do
    printf '%s' "$proof_output" | grep -q "$expected_line" || die "$source_name proof missing $expected_line"
  done
  printf '%s\n' "$proof_output" >"$WORK_DIR/network-proof-$source_name.ok"
}

run_proof ubuntu "$ubuntu_id" "$al2023_ipv4" "$al2023_ipv6" "$al2023_dns"
run_proof al2023 "$al2023_id" "$ubuntu_ipv4" "$ubuntu_ipv6" "$ubuntu_dns"
printf 'bidirectional IPv4, IPv6, MagicDNS, overlay-route, and SSH proof complete; relay endpoint configured\n'
