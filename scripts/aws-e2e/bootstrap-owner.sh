#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws jq openssl stat terraform; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity
[ "$(cat "$STAGE_FILE" 2>/dev/null || true)" = activate ] || die "activated control plane required"
[ ! -e "$WORK_DIR/owner-bootstrap.ok" ] || die "owner bootstrap already completed"

case ${OWNER_EMAIL:-} in
  '' | *[!A-Za-z0-9._+@-]* | *@*@* | @* | *@) die "OWNER_EMAIL must be a valid operator email" ;;
esac
OWNER_NAME=${OWNER_NAME:-BlakTail E2E Owner}
ORGANISATION_NAME=${ORGANISATION_NAME:-BlakPath E2E $RUN_ID}
carriage_return=$(printf '\r')
case "$OWNER_NAME$ORGANISATION_NAME" in
  *'
'* | *"$carriage_return"*) die "owner and organisation names must be single-line" ;;
esac

umask 077
owner_password_file=${OWNER_PASSWORD_FILE:-$WORK_DIR/owner-password}
if [ ! -e "$owner_password_file" ]; then
  openssl rand -base64 32 >"$owner_password_file"
  chmod 600 "$owner_password_file"
fi
[ -f "$owner_password_file" ] || die "OWNER_PASSWORD_FILE must be a regular file"
owner_password_mode=$(stat -f '%Lp' "$owner_password_file" 2>/dev/null || stat -c '%a' "$owner_password_file")
case "$owner_password_mode" in 400 | 600) ;; *) die "owner password file mode must be 0400 or 0600" ;; esac
[ -s "$owner_password_file" ] || die "owner password file must not be empty"

cluster_name=$(tf_output_raw cluster_name)
task_definition=$(tf_output_json task_definition_arns | jq -er .console)
security_group_id=$(tf_output_raw tasks_security_group_id)
subnet_json=$(tf_output_json private_subnet_ids | jq -c '.fargate')
artifact_bucket=$(tf_output_raw artifact_bucket)
[ "$(printf '%s' "$subnet_json" | jq 'length')" -ge 2 ] || die "at least two Fargate subnets required"
network_configuration=$(jq -cn \
  --argjson subnets "$subnet_json" --arg security_group "$security_group_id" \
  '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$security_group],assignPublicIp:"DISABLED"}}')

credential_key=bootstrap/$RUN_ID/owner-password
cleanup_owner_bootstrap() {
  aws_cli s3api delete-object --bucket "$artifact_bucket" --key "$credential_key" >/dev/null 2>&1 || true
  rm -f -- "${task_script_file:-}"
}
trap cleanup_owner_bootstrap EXIT HUP INT TERM
aws_cli s3 cp "$owner_password_file" "s3://$artifact_bucket/$credential_key" \
  --sse AES256 --only-show-errors

task_script_file=$(mktemp "$WORK_DIR/owner-bootstrap-script.XXXXXX")
cat >"$task_script_file" <<'REMOTE'
set -eu
umask 077
token_file=/tmp/blaktail-bootstrap-token
password_file=/tmp/blaktail-owner-password
cleanup() { rm -f -- "$token_file" "$password_file"; }
trap cleanup EXIT HUP INT TERM
bun scripts/s3-get.mjs "$ARTIFACT_BUCKET" "$CREDENTIAL_KEY" "$password_file"
chmod 600 "$password_file"
bun scripts/bootstrap.mjs init --token-file "$token_file"
bun scripts/bootstrap.mjs claim \
  --token-file "$token_file" \
  --password-file "$password_file" \
  --email "$OWNER_EMAIL" \
  --name "$OWNER_NAME" \
  --organisation-name "$ORGANISATION_NAME"
bun scripts/bootstrap.mjs status
REMOTE
task_overrides=$(jq -cn \
  --rawfile script "$task_script_file" \
  --arg artifact_bucket "$artifact_bucket" \
  --arg credential_key "$credential_key" \
  --arg aws_region "$AWS_REGION" \
  --arg owner_email "$OWNER_EMAIL" \
  --arg owner_name "$OWNER_NAME" \
  --arg organisation_name "$ORGANISATION_NAME" \
  '{containerOverrides:[{name:"console",command:["sh","-c",$script],environment:[
    {name:"ARTIFACT_BUCKET",value:$artifact_bucket},
    {name:"CREDENTIAL_KEY",value:$credential_key},
    {name:"AWS_REGION",value:$aws_region},
    {name:"OWNER_EMAIL",value:$owner_email},
    {name:"OWNER_NAME",value:$owner_name},
    {name:"ORGANISATION_NAME",value:$organisation_name}
  ]}]}')

owner_task_arn=$(aws_cli ecs run-task --cluster "$cluster_name" --launch-type FARGATE \
  --task-definition "$task_definition" --network-configuration "$network_configuration" \
  --overrides "$task_overrides" --started-by "$RUN_ID-owner-bootstrap" \
  --tags key=RunId,value="$RUN_ID" --query 'tasks[0].taskArn' --output text)
case "$owner_task_arn" in arn:aws:ecs:*) ;; *) die "owner bootstrap task did not start" ;; esac
aws_cli ecs wait tasks-stopped --cluster "$cluster_name" --tasks "$owner_task_arn"
owner_task_result=$(aws_cli ecs describe-tasks --cluster "$cluster_name" \
  --tasks "$owner_task_arn" --output json)
printf '%s' "$owner_task_result" | jq -e '
  .tasks | length == 1 and
  any(.[0].containers[]; .name == "console" and .exitCode == 0)
' >/dev/null || die "supported owner bootstrap task failed"

jq -n --arg run_id "$RUN_ID" --arg task_arn "$owner_task_arn" \
  '{run_id:$run_id,role:"owner",supported_bootstrap:true,task_arn:$task_arn}' \
  >"$WORK_DIR/owner-bootstrap.ok"
printf 'owner bootstrap locked; login=%s password_file=%s\n' "$OWNER_EMAIL" "$owner_password_file"
