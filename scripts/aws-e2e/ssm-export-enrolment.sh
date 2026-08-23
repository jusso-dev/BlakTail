#!/bin/sh
set -eu
umask 077
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws jq terraform; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity
[ -f "$WORK_DIR/enrolment-started.json" ] || die "browser enrollment has not started"

public_url=$(tf_output_raw public_url)
instance_json=$(tf_output_json agent_instance_ids)
for agent_name in ubuntu al2023; do
  instance_id=$(printf '%s' "$instance_json" | jq -er --arg key "$agent_name" '.[$key]')
  remote_script="test -f /var/log/blaktail-enrolment.log || exit 1
awk '/^https:\/\// { print; exit }' /var/log/blaktail-enrolment.log"
  ssm_send_script "$instance_id" "Export BlakTail E2E enrollment URL $RUN_ID" "$remote_script"
  wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
  enrollment_url=$(ssm_command_output "$SSM_COMMAND_ID" "$instance_id")
  case "$enrollment_url" in
    "$public_url"/enroll?code=*) ;;
    *) die "enrollment URL not ready for $agent_name" ;;
  esac
  printf '%s\n' "$enrollment_url" >"$WORK_DIR/enroll-$agent_name.url"
  chmod 0600 "$WORK_DIR/enroll-$agent_name.url"
done
printf '%s\n' 'Enrollment URLs exported to protected work files.'
