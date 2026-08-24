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

mode=${1:-}
case "$mode" in
  reset | restart | retry | capture | relink) ;;
  *) die "usage: $0 reset|restart|retry|capture|relink" ;;
esac

case $(cat "$STAGE_FILE" 2>/dev/null || true) in
  prepare | activate) ;;
  *) die "prepared or activated control plane required" ;;
esac

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
}

recovery_file=$WORK_DIR/owner-recovery.json
bootstrap_file=$WORK_DIR/owner-bootstrap.ok
organisation_id=e2e-$RUN_ID
membership_id=e2e-owner-$RUN_ID

if [ "$mode" = reset ] || [ "$mode" = restart ] || [ "$mode" = retry ] || [ "$mode" = capture ]; then
  [ -f "$bootstrap_file" ] || die "completed owner bootstrap marker required"
  [ ! -e "$recovery_file" ] || die "owner recovery already in progress"
  if [ "$mode" = restart ] || [ "$mode" = retry ] || [ "$mode" = capture ]; then
    [ ! -e "$WORK_DIR/browser-proof.ok" ] || die "completed browser proof cannot be restarted"
    expected_account_count=1
    expected_credential_count=1
  else
    expected_account_count=0
    expected_credential_count=0
  fi
  if [ "$mode" = restart ]; then
    [ ! -e "$WORK_DIR/enrolment-started.json" ] || die "started enrollment requires retry mode"
    for agent_name in ubuntu al2023; do
      [ ! -e "$WORK_DIR/enroll-$agent_name.url" ] || die "exported enrollment requires retry mode"
    done
  fi
  if [ "$mode" = retry ]; then
    [ -f "$WORK_DIR/enrolment-started.json" ] || die "retry requires started enrollment"
    public_url=$(tf_output_raw public_url)
    instance_json=$(tf_output_json agent_instance_ids)
    for agent_name in ubuntu al2023; do
      enrollment_file=$WORK_DIR/enroll-$agent_name.url
      [ -f "$enrollment_file" ] || die "retry requires protected $agent_name enrollment URL"
      enrollment_url=$(cat "$enrollment_file")
      case "$enrollment_url" in
        "$public_url"/enroll?code=*) ;;
        *) die "invalid protected $agent_name enrollment URL" ;;
      esac
      instance_id=$(printf '%s' "$instance_json" | jq -er --arg key "$agent_name" '.[$key]')
      assert_ssm_online "$instance_id"
      pending_script="test ! -e /var/lib/blaktail/state.json
systemctl show blaktail-enrol-$RUN_ID-$agent_name --property=ActiveState --value | grep -Eq '^(active|activating)$'"
      ssm_send_script "$instance_id" "Verify pending BlakTail E2E enrollment $RUN_ID" "$pending_script"
      wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
    done
  fi
  if [ "$mode" = capture ]; then
    instance_json=$(tf_output_json agent_instance_ids)
    for agent_name in ubuntu al2023; do
      [ -s "$WORK_DIR/enrolment-$agent_name.ok" ] || die "capture requires $agent_name enrollment proof"
      [ -s "$WORK_DIR/network-proof-$agent_name.ok" ] || die "capture requires $agent_name network proof"
      instance_id=$(printf '%s' "$instance_json" | jq -er --arg key "$agent_name" '.[$key]')
      assert_ssm_online "$instance_id"
      enrolled_script='test -s /var/lib/blaktail/state.json
systemctl is-active --quiet blaktaild'
      ssm_send_script "$instance_id" "Verify enrolled BlakTail E2E agent $RUN_ID" "$enrolled_script"
      wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
    done
  fi
  coord_org_id=$(jq -er --arg run_id "$RUN_ID" \
    'select(.run_id == $run_id and .role == "owner") | .coord_org_id' "$bootstrap_file")
  printf '%s' "$coord_org_id" | jq -R -e \
    'test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")' >/dev/null || \
    die "owner bootstrap marker has invalid coordinator organisation ID"

  reset_script_file=$(mktemp "$WORK_DIR/owner-reset-script.XXXXXX")
  trap 'rm -f -- "$reset_script_file"' EXIT HUP INT TERM
  cat >"$reset_script_file" <<'REMOTE'
set -eu
psql "$DATABASE_URL" --set=ON_ERROR_STOP=1 \
  --set=owner_email="$OWNER_EMAIL" \
  --set=organisation_id="$ORGANISATION_ID" \
  --set=membership_id="$MEMBERSHIP_ID" \
  --set=coord_org_id="$COORD_ORG_ID" \
  --set=expected_account_count="$EXPECTED_ACCOUNT_COUNT" \
  --set=expected_credential_count="$EXPECTED_CREDENTIAL_COUNT" <<'SQL_RESET'
BEGIN;
SELECT 1 / CASE WHEN
  (SELECT count(*) FROM "user" WHERE lower(email) = lower(:'owner_email')) = 1
  AND (SELECT count(*) FROM account WHERE user_id IN (
    SELECT id FROM "user" WHERE lower(email) = lower(:'owner_email')
  )) = :'expected_account_count'::integer
  AND (SELECT count(*) FROM account WHERE provider_id = 'credential' AND user_id IN (
    SELECT id FROM "user" WHERE lower(email) = lower(:'owner_email')
  )) = :'expected_credential_count'::integer
  AND (SELECT count(*) FROM membership WHERE id = :'membership_id'
    AND organisation_id = :'organisation_id' AND role = 'owner'
    AND user_id IN (SELECT id FROM "user" WHERE lower(email) = lower(:'owner_email'))
  ) = 1
  AND (SELECT count(*) FROM organisation WHERE id = :'organisation_id'
    AND coord_org_id = :'coord_org_id'
  ) = 1
THEN 1 ELSE 0 END AS recovery_precondition;
WITH deleted AS (
  DELETE FROM "user" WHERE lower(email) = lower(:'owner_email') RETURNING id
)
SELECT 1 / CASE WHEN count(*) = 1 THEN 1 ELSE 0 END FROM deleted;
COMMIT;
SQL_RESET
printf 'partial_owner_removed\n'
REMOTE
  reset_overrides=$(jq -cn \
    --rawfile script "$reset_script_file" \
    --arg owner_email "$OWNER_EMAIL" \
    --arg organisation_id "$organisation_id" \
    --arg membership_id "$membership_id" \
    --arg coord_org_id "$coord_org_id" \
    --arg expected_account_count "$expected_account_count" \
    --arg expected_credential_count "$expected_credential_count" \
    '{containerOverrides:[{name:"console",command:["sh","-c",$script],environment:[
      {name:"OWNER_EMAIL",value:$owner_email},
      {name:"ORGANISATION_ID",value:$organisation_id},
      {name:"MEMBERSHIP_ID",value:$membership_id},
      {name:"COORD_ORG_ID",value:$coord_org_id},
      {name:"EXPECTED_ACCOUNT_COUNT",value:$expected_account_count},
      {name:"EXPECTED_CREDENTIAL_COUNT",value:$expected_credential_count}
    ]}]}')
  run_console_task "$mode" "$reset_overrides"
  rm -f -- "$reset_script_file"
  trap - EXIT HUP INT TERM

  umask 077
  jq -n --arg run_id "$RUN_ID" --arg coord_org_id "$coord_org_id" \
    '{run_id:$run_id,coord_org_id:$coord_org_id}' >"$recovery_file"
  rm -f -- "$bootstrap_file"
  printf 'browser signup %s; run relink before retrying browser signup\n' "$mode"
  exit 0
fi

[ -f "$recovery_file" ] || die "owner recovery marker required"
coord_org_id=$(jq -er --arg run_id "$RUN_ID" \
  'select(.run_id == $run_id) | .coord_org_id' "$recovery_file")

relink_script_file=$(mktemp "$WORK_DIR/owner-relink-script.XXXXXX")
trap 'rm -f -- "$relink_script_file"' EXIT HUP INT TERM
cat >"$relink_script_file" <<'REMOTE'
set -eu
deadline=$(( $(date -u +%s) + OWNER_WAIT_TIMEOUT ))
while [ "$(date -u +%s)" -lt "$deadline" ]; do
  completed_signup_count=$(psql "$DATABASE_URL" --no-align --tuples-only \
    --set=ON_ERROR_STOP=1 --set=owner_email="$OWNER_EMAIL" <<'SQL_WAIT'
SELECT count(*) FROM "user" u
WHERE lower(u.email) = lower(:'owner_email')
  AND EXISTS (SELECT 1 FROM account a WHERE a.user_id = u.id);
SQL_WAIT
  )
  case "$completed_signup_count" in
    1) break ;;
    0) sleep 5 ;;
    *) printf 'completed owner signup is not unique\n' >&2; exit 1 ;;
  esac
done
[ "${completed_signup_count:-0}" = 1 ] || {
  printf 'timed out waiting for completed browser signup\n' >&2
  exit 1
}

psql "$DATABASE_URL" --set=ON_ERROR_STOP=1 \
  --set=owner_email="$OWNER_EMAIL" \
  --set=organisation_id="$ORGANISATION_ID" \
  --set=membership_id="$MEMBERSHIP_ID" \
  --set=coord_org_id="$COORD_ORG_ID" <<'SQL_RELINK'
BEGIN;
SELECT 1 / CASE WHEN
  (SELECT count(*) FROM "user" WHERE lower(email) = lower(:'owner_email')) = 1
  AND (SELECT count(*) FROM organisation WHERE id = :'organisation_id'
    AND coord_org_id = :'coord_org_id'
  ) = 1
  AND (SELECT count(*) FROM membership WHERE id = :'membership_id'
    OR organisation_id = :'organisation_id'
  ) = 0
THEN 1 ELSE 0 END AS recovery_precondition;
WITH selected_user AS (
  SELECT id FROM "user" WHERE lower(email) = lower(:'owner_email')
), inserted_membership AS (
  INSERT INTO membership (id, organisation_id, user_id, role)
  SELECT :'membership_id', :'organisation_id', selected_user.id, 'owner'
  FROM selected_user
  RETURNING id
)
SELECT 1 / CASE WHEN count(*) = 1 THEN 1 ELSE 0 END FROM inserted_membership;
COMMIT;
SQL_RELINK
printf 'owner_membership_relinked\n'
REMOTE
relink_overrides=$(jq -cn \
  --rawfile script "$relink_script_file" \
  --arg owner_email "$OWNER_EMAIL" \
  --arg owner_wait_timeout "$OWNER_WAIT_TIMEOUT" \
  --arg organisation_id "$organisation_id" \
  --arg membership_id "$membership_id" \
  --arg coord_org_id "$coord_org_id" \
  '{containerOverrides:[{name:"console",command:["sh","-c",$script],environment:[
    {name:"OWNER_EMAIL",value:$owner_email},
    {name:"OWNER_WAIT_TIMEOUT",value:$owner_wait_timeout},
    {name:"ORGANISATION_ID",value:$organisation_id},
    {name:"MEMBERSHIP_ID",value:$membership_id},
    {name:"COORD_ORG_ID",value:$coord_org_id}
  ]}]}')
run_console_task relink "$relink_overrides"
rm -f -- "$relink_script_file"
trap - EXIT HUP INT TERM

umask 077
jq --arg role owner '. + {role:$role,browser_signup:true,recovered:true}' \
  "$recovery_file" >"$bootstrap_file"
rm -f -- "$recovery_file"
printf 'browser-created user relinked as owner\n'
