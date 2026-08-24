#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws jq terraform; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity
[ -f "$WORK_DIR/enrolment-started.json" ] || die "browser enrollment has not started"

ENROLMENT_TIMEOUT=${ENROLMENT_TIMEOUT:-1200}
case "$ENROLMENT_TIMEOUT" in
  '' | *[!0-9]*) die "ENROLMENT_TIMEOUT must be seconds" ;;
esac
[ "$ENROLMENT_TIMEOUT" -ge 60 ] && [ "$ENROLMENT_TIMEOUT" -le 3600 ] || \
  die "ENROLMENT_TIMEOUT must be between 60 and 3600 seconds"

instance_json=$(tf_output_json agent_instance_ids)
deadline=$(( $(date -u +%s) + ENROLMENT_TIMEOUT ))
for agent_name in ubuntu al2023; do
  instance_id=$(printf '%s' "$instance_json" | jq -er --arg key "$agent_name" '.[$key]')
  ready=false
  while [ "$(date -u +%s)" -lt "$deadline" ]; do
    ssm_send_script "$instance_id" "Check BlakTail E2E enrollment $RUN_ID" \
      "if systemctl is-active --quiet blaktaild; then echo ready; else echo waiting; fi"
    wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
    if [ "$(ssm_command_output "$SSM_COMMAND_ID" "$instance_id" | tr -d '\r\n')" = ready ]; then
      ready=true
      break
    fi
    sleep 10
  done
  [ "$ready" = true ] || die "manual enrollment timed out for $agent_name"

  ssm_send_script "$instance_id" "Record BlakTail E2E enrollment proof $RUN_ID" \
    "/usr/local/bin/blaktaild status | sed -n '1,10p'; systemctl is-active blaktaild"
  wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
  status_output=$(ssm_command_output "$SSM_COMMAND_ID" "$instance_id")
  printf '%s' "$status_output" | grep -q '^joined$' || die "joined status missing for $agent_name"
  printf '%s' "$status_output" | grep -q '^active$' || die "active service proof missing for $agent_name"
  printf '%s\n' "$status_output" >"$WORK_DIR/enrolment-$agent_name.ok"
done
printf 'authenticated enrollment complete on both agents\n'
