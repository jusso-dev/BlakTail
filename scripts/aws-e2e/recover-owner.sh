#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws jq stat terraform; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity

mode=${1:-}
case "$mode" in status | recover) ;; *) die "usage: $0 status|recover" ;; esac
case $(cat "$STAGE_FILE" 2>/dev/null || true) in
  prepare | activate) ;;
  *) die "prepared or activated control plane required" ;;
esac

cluster_name=$(tf_output_raw cluster_name)
task_definition=$(tf_output_json task_definition_arns | jq -er .console)
security_group_id=$(tf_output_raw tasks_security_group_id)
subnet_json=$(tf_output_json private_subnet_ids | jq -c '.fargate')
artifact_bucket=$(tf_output_raw artifact_bucket)
network_configuration=$(jq -cn \
  --argjson subnets "$subnet_json" --arg security_group "$security_group_id" \
  '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$security_group],assignPublicIp:"DISABLED"}}')

run_console_task() {
  task_label=$1
  task_overrides=$2
  recovery_task_arn=$(aws_cli ecs run-task --cluster "$cluster_name" --launch-type FARGATE \
    --task-definition "$task_definition" --network-configuration "$network_configuration" \
    --overrides "$task_overrides" --started-by "$RUN_ID-owner-$task_label" \
    --tags key=RunId,value="$RUN_ID" --query 'tasks[0].taskArn' --output text)
  case "$recovery_task_arn" in arn:aws:ecs:*) ;; *) die "owner $task_label task did not start" ;; esac
  aws_cli ecs wait tasks-stopped --cluster "$cluster_name" --tasks "$recovery_task_arn"
  recovery_task_result=$(aws_cli ecs describe-tasks --cluster "$cluster_name" \
    --tasks "$recovery_task_arn" --output json)
  printf '%s' "$recovery_task_result" | jq -e '
    .tasks | length == 1 and
    any(.[0].containers[]; .name == "console" and .exitCode == 0)
  ' >/dev/null || die "owner $task_label task failed"
  printf '%s\n' "$recovery_task_arn"
}

if [ "$mode" = status ]; then
  overrides=$(jq -cn \
    '{containerOverrides:[{name:"console",command:["bun","scripts/bootstrap.mjs","status"]}]}')
  task_arn=$(run_console_task status "$overrides")
  printf 'bootstrap status completed in task %s; inspect its redacted log stream\n' "$task_arn"
  exit 0
fi

case ${OWNER_EMAIL:-} in
  '' | *[!A-Za-z0-9._+@-]* | *@*@* | @* | *@) die "OWNER_EMAIL must be the exact sole owner email" ;;
esac
owner_password_file=${OWNER_PASSWORD_FILE:-$WORK_DIR/owner-password}
[ -f "$owner_password_file" ] || die "protected owner password file required"
owner_password_mode=$(stat -f '%Lp' "$owner_password_file" 2>/dev/null || stat -c '%a' "$owner_password_file")
case "$owner_password_mode" in 400 | 600) ;; *) die "owner password file mode must be 0400 or 0600" ;; esac

credential_key=bootstrap/$RUN_ID/recovery-password
cleanup_recovery() {
  aws_cli s3api delete-object --bucket "$artifact_bucket" --key "$credential_key" >/dev/null 2>&1 || true
  rm -f -- "${recovery_script_file:-}"
}
trap cleanup_recovery EXIT HUP INT TERM
aws_cli s3 cp "$owner_password_file" "s3://$artifact_bucket/$credential_key" \
  --sse AES256 --only-show-errors

recovery_script_file=$(mktemp "$WORK_DIR/owner-recovery-script.XXXXXX")
cat >"$recovery_script_file" <<'REMOTE'
set -eu
umask 077
password_file=/tmp/blaktail-owner-recovery-password
trap 'rm -f -- "$password_file"' EXIT HUP INT TERM
aws s3 cp "s3://$ARTIFACT_BUCKET/$CREDENTIAL_KEY" "$password_file" --only-show-errors
chmod 600 "$password_file"
bun scripts/bootstrap.mjs recover-owner \
  --email "$OWNER_EMAIL" --password-file "$password_file"
REMOTE
overrides=$(jq -cn \
  --rawfile script "$recovery_script_file" \
  --arg artifact_bucket "$artifact_bucket" \
  --arg credential_key "$credential_key" \
  --arg owner_email "$OWNER_EMAIL" \
  '{containerOverrides:[{name:"console",command:["sh","-c",$script],environment:[
    {name:"ARTIFACT_BUCKET",value:$artifact_bucket},
    {name:"CREDENTIAL_KEY",value:$credential_key},
    {name:"OWNER_EMAIL",value:$owner_email}
  ]}]}')
task_arn=$(run_console_task recover "$overrides")
jq -n --arg run_id "$RUN_ID" --arg task_arn "$task_arn" \
  '{run_id:$run_id,recovery:"on_host",sessions_revoked:true,task_arn:$task_arn}' \
  >"$WORK_DIR/owner-recovery.ok"
printf 'owner credential recovered and existing sessions revoked: %s\n' "$task_arn"
