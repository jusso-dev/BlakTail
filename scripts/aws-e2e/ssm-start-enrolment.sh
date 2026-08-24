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
[ -f "$WORK_DIR/agent-install.ok" ] || die "agent installation proof missing"

public_url=$(tf_output_raw public_url)
case "$public_url" in
  https://*) ;;
  *) die "public URL must use HTTPS" ;;
esac
instance_json=$(tf_output_json agent_instance_ids)
started_tmp=$(mktemp "$WORK_DIR/enrolment-started.XXXXXX")
cleanup_started() {
  rm -f -- "$started_tmp"
}
trap cleanup_started EXIT HUP INT TERM
printf '{' >"$started_tmp"
separator=

for agent_name in ubuntu al2023; do
  instance_id=$(printf '%s' "$instance_json" | jq -er --arg key "$agent_name" '.[$key]')
  node_name=$agent_name-$RUN_ID
  unit_name=blaktail-enrol-$RUN_ID-$agent_name
  remote_script="PUBLIC_URL=$public_url
NODE_NAME=$node_name
UNIT_NAME=$unit_name
set -eu
[ ! -e /var/lib/blaktail/state.json ] || { echo 'existing enrollment refused' >&2; exit 1; }
if systemctl show \$UNIT_NAME --property=ActiveState --value 2>/dev/null | \
  grep -Eq '^(active|activating)$'; then
  printf 'browser enrollment already active: %s\\n' \$NODE_NAME
  exit 0
fi
log=/var/log/blaktail-enrolment.log
install -m 0600 /dev/null \"\$log\"
systemd-run --quiet --collect --no-block --unit=\"\$UNIT_NAME\" --property=Type=oneshot \\
  /bin/sh -c 'exec >>\"\$1\" 2>&1; /usr/local/bin/blaktaild up --coord \"\$2\" --name \"\$3\" --exit-after-join && systemctl enable --now blaktaild' \\
  sh \"\$log\" \"\$PUBLIC_URL\" \"\$NODE_NAME\"
printf 'browser enrollment started: %s\\n' \"\$NODE_NAME\""
  ssm_send_script "$instance_id" "BlakTail E2E browser enrolment $RUN_ID" "$remote_script"
  wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
  printf '%s\"%s\":\"%s\"' "$separator" "$agent_name" "$SSM_COMMAND_ID" >>"$started_tmp"
  separator=,
done
printf '}\n' >>"$started_tmp"
mv "$started_tmp" "$WORK_DIR/enrolment-started.json"
trap - EXIT HUP INT TERM
printf '%s\n' 'Browser enrollment started. Use ssm-show-enrolment.sh locally; approval remains manual.'
