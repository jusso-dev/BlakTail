#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws curl jq terraform; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity
[ "$(cat "$STAGE_FILE" 2>/dev/null || true)" = activate ] || die "activated control plane required"
[ ! -e "$WORK_DIR/owner-bootstrap.ok" ] || die "owner bootstrap already completed"

case ${OWNER_EMAIL:-} in
  '' | *[!A-Za-z0-9._+@-]* | *@*@* | @* | *@) die "OWNER_EMAIL must be a valid operator email" ;;
esac
OWNER_WAIT_TIMEOUT=${OWNER_WAIT_TIMEOUT:-480}
case "$OWNER_WAIT_TIMEOUT" in '' | *[!0-9]*) die "OWNER_WAIT_TIMEOUT must be seconds" ;; esac
[ "$OWNER_WAIT_TIMEOUT" -ge 60 ] && [ "$OWNER_WAIT_TIMEOUT" -le 480 ] || \
  die "OWNER_WAIT_TIMEOUT must be between 60 and 480 seconds"

cluster_name=$(tf_output_raw cluster_name)
task_definition=$(tf_output_json task_definition_arns | jq -er .console)
security_group_id=$(tf_output_raw tasks_security_group_id)
subnet_json=$(tf_output_json private_subnet_ids | jq -c '.fargate')
[ "$(printf '%s' "$subnet_json" | jq 'length')" -ge 2 ] || die "at least two Fargate subnets required"
network_configuration=$(jq -cn \
  --argjson subnets "$subnet_json" --arg security_group "$security_group_id" \
  '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$security_group],assignPublicIp:"DISABLED"}}')

run_console_task() {
  task_label=$1
  task_overrides=$2
  owner_task_arn=$(aws_cli ecs run-task --cluster "$cluster_name" --launch-type FARGATE \
    --task-definition "$task_definition" --network-configuration "$network_configuration" \
    --overrides "$task_overrides" --started-by "$RUN_ID-$task_label" \
    --tags key=RunId,value="$RUN_ID" --query 'tasks[0].taskArn' --output text)
  case "$owner_task_arn" in arn:aws:ecs:*) ;; *) die "owner $task_label task did not start" ;; esac
  aws_cli ecs wait tasks-stopped --cluster "$cluster_name" --tasks "$owner_task_arn"
  owner_task_result=$(aws_cli ecs describe-tasks --cluster "$cluster_name" \
    --tasks "$owner_task_arn" --output json)
  printf '%s' "$owner_task_result" | jq -e '
    .tasks | length == 1 and
    any(.[0].containers[]; .name == "console" and .exitCode == 0)
  ' >/dev/null || die "owner $task_label task failed"
}

wait_script_file=$(mktemp "$WORK_DIR/owner-wait-script.XXXXXX")
cat >"$wait_script_file" <<'REMOTE'
set -eu
deadline=$(( $(date -u +%s) + OWNER_WAIT_TIMEOUT ))
while [ "$(date -u +%s)" -lt "$deadline" ]; do
  owner_count=$(psql "$DATABASE_URL" --no-align --tuples-only \
    --set=ON_ERROR_STOP=1 --set=owner_email="$OWNER_EMAIL" <<'SQL_WAIT'
SELECT count(*) FROM "user" WHERE lower(email) = lower(:'owner_email');
SQL_WAIT
  )
  case "$owner_count" in
    1) printf 'owner_user_ready\n'; exit 0 ;;
    0) sleep 10 ;;
    *) printf 'owner email is not unique\n' >&2; exit 1 ;;
  esac
done
printf 'timed out waiting for browser signup\n' >&2
exit 1
REMOTE
wait_overrides=$(jq -cn \
  --rawfile script "$wait_script_file" --arg owner_email "$OWNER_EMAIL" \
  --arg owner_wait_timeout "$OWNER_WAIT_TIMEOUT" \
  '{containerOverrides:[{name:"console",command:["sh","-c",$script],environment:[
    {name:"OWNER_EMAIL",value:$owner_email},
    {name:"OWNER_WAIT_TIMEOUT",value:$owner_wait_timeout}
  ]}]}')
rm -f -- "$wait_script_file"
run_console_task ownerwait "$wait_overrides"

public_url=$(tf_output_raw public_url)
case "$public_url" in https://*) ;; *) die "public URL must use HTTPS" ;; esac
org_name="BlakTail E2E $RUN_ID"
org_request=$(mktemp "$WORK_DIR/org-request.XXXXXX")
org_response=$(mktemp "$WORK_DIR/org-response.XXXXXX")
cleanup_owner() {
  rm -f -- "$org_request" "$org_response"
}
trap cleanup_owner EXIT HUP INT TERM
jq -n --arg name "$org_name" '{name:$name,acl:{rules:[]}}' >"$org_request"
org_http_status=$(curl --silent --show-error --max-time 20 \
  --output "$org_response" --write-out '%{http_code}' \
  --header 'content-type: application/json' --data-binary "@$org_request" \
  "$public_url/v1/orgs")
[ "$org_http_status" = 201 ] || die "coordinator organisation creation failed: HTTP $org_http_status"
coord_org_id=$(jq -er .id "$org_response")
printf '%s' "$coord_org_id" | jq -R -e \
  'test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")' >/dev/null || \
  die "coordinator returned invalid organisation ID"

organisation_id=e2e-$RUN_ID
membership_id=e2e-owner-$RUN_ID
link_script_file=$(mktemp "$WORK_DIR/owner-link-script.XXXXXX")
cat >"$link_script_file" <<'REMOTE'
set -eu
psql "$DATABASE_URL" --set=ON_ERROR_STOP=1 \
  --set=owner_email="$OWNER_EMAIL" \
  --set=organisation_id="$ORGANISATION_ID" \
  --set=membership_id="$MEMBERSHIP_ID" \
  --set=organisation_name="$ORGANISATION_NAME" \
  --set=coord_org_id="$COORD_ORG_ID" <<'SQL_LINK'
WITH selected_user AS (
  SELECT id FROM "user" WHERE lower(email) = lower(:'owner_email')
), inserted_org AS (
  INSERT INTO organisation (id, name, coord_org_id)
  VALUES (:'organisation_id', :'organisation_name', :'coord_org_id')
  RETURNING id
), inserted_membership AS (
  INSERT INTO membership (id, organisation_id, user_id, role)
  SELECT :'membership_id', inserted_org.id, selected_user.id, 'owner'
  FROM inserted_org CROSS JOIN selected_user
  RETURNING id
)
SELECT 1 / count(*) FROM inserted_membership;
SQL_LINK
printf 'owner_membership_linked\n'
REMOTE
link_overrides=$(jq -cn \
  --rawfile script "$link_script_file" \
  --arg owner_email "$OWNER_EMAIL" \
  --arg organisation_id "$organisation_id" \
  --arg membership_id "$membership_id" \
  --arg organisation_name "$org_name" \
  --arg coord_org_id "$coord_org_id" \
  '{containerOverrides:[{name:"console",command:["sh","-c",$script],environment:[
    {name:"OWNER_EMAIL",value:$owner_email},
    {name:"ORGANISATION_ID",value:$organisation_id},
    {name:"MEMBERSHIP_ID",value:$membership_id},
    {name:"ORGANISATION_NAME",value:$organisation_name},
    {name:"COORD_ORG_ID",value:$coord_org_id}
  ]}]}')
rm -f -- "$link_script_file"
run_console_task ownerlink "$link_overrides"

jq -n --arg run_id "$RUN_ID" --arg coord_org_id "$coord_org_id" \
  '{run_id:$run_id,coord_org_id:$coord_org_id,role:"owner",browser_signup:true}' \
  >"$WORK_DIR/owner-bootstrap.ok"
printf 'browser-created user linked as owner; refresh portal session\n'
