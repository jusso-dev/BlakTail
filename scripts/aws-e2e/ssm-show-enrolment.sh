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

instance_json=$(tf_output_json agent_instance_ids)
for agent_name in ubuntu al2023; do
  instance_id=$(printf '%s' "$instance_json" | jq -er --arg key "$agent_name" '.[$key]')
  remote_script="test -f /var/log/blaktail-enrolment.log || exit 1
grep -E '^(https://|Code: )' /var/log/blaktail-enrolment.log | head -n 2"
  ssm_send_script "$instance_id" "Show BlakTail E2E enrollment URL $RUN_ID" "$remote_script"
  wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
  enrollment_output=$(ssm_command_output "$SSM_COMMAND_ID" "$instance_id")
  case "$enrollment_output" in
    *https://*Code:\ *) ;;
    *) die "enrollment URL not ready for $agent_name" ;;
  esac
  printf '\n%s agent:\n%s\n' "$agent_name" "$enrollment_output"
done
printf '%s\n' 'Do not save codes in evidence or screenshots. Sign in and approve both devices manually.'

