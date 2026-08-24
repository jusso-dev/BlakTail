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
[ "$(cat "$STAGE_FILE" 2>/dev/null || true)" = prepare ] || die "prepared infrastructure required"

cluster_name=$(tf_output_raw cluster_name)
task_definitions=$(tf_output_json task_definition_arns)
coord_task_definition=$(printf '%s' "$task_definitions" | jq -er .coord_migration)
console_task_definition=$(printf '%s' "$task_definitions" | jq -er .console)
security_group_id=$(tf_output_raw tasks_security_group_id)
subnet_json=$(tf_output_json private_subnet_ids | jq -c '.fargate')
[ "$(printf '%s' "$subnet_json" | jq 'length')" -ge 2 ] || die "at least two Fargate subnets required"

running_tasks=$(aws_cli ecs list-tasks --cluster "$cluster_name" --desired-status RUNNING \
  --query 'taskArns | length(@)' --output text)
[ "$running_tasks" = 0 ] || die "services must remain stopped before explicit migration"

network_configuration=$(jq -cn \
  --argjson subnets "$subnet_json" --arg security_group "$security_group_id" \
  '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$security_group],assignPublicIp:"DISABLED"}}')

coord_task_arn=$(aws_cli ecs run-task --cluster "$cluster_name" --launch-type FARGATE \
  --task-definition "$coord_task_definition" --network-configuration "$network_configuration" \
  --started-by "$RUN_ID" --tags key=RunId,value="$RUN_ID" \
  --query 'tasks[0].taskArn' --output text)
case "$coord_task_arn" in
  arn:aws:ecs:*) ;;
  *) die "coordinator migration task did not start" ;;
esac

aws_cli ecs wait tasks-stopped --cluster "$cluster_name" --tasks "$coord_task_arn"
coord_task_result=$(aws_cli ecs describe-tasks --cluster "$cluster_name" \
  --tasks "$coord_task_arn" --output json)
printf '%s' "$coord_task_result" | jq -e '
  .tasks | length == 1 and
  .[0].stopCode == "EssentialContainerExited" and
  any(.[0].containers[]; .name == "coord-migration" and .exitCode == 0)
' >/dev/null || die "coordinator migration task failed"

overrides=$(jq -cn \
  '{containerOverrides:[{name:"console",command:["sh","-c","blaktail-config dump-config --service console --redacted && exec bun scripts/migrate.mjs"]}]}')

console_task_arn=$(aws_cli ecs run-task --cluster "$cluster_name" --launch-type FARGATE \
  --task-definition "$console_task_definition" --network-configuration "$network_configuration" \
  --overrides "$overrides" --started-by "$RUN_ID" \
  --tags key=RunId,value="$RUN_ID" --query 'tasks[0].taskArn' --output text)
case "$console_task_arn" in
  arn:aws:ecs:*) ;;
  *) die "console migration task did not start" ;;
esac

aws_cli ecs wait tasks-stopped --cluster "$cluster_name" --tasks "$console_task_arn"
console_task_result=$(aws_cli ecs describe-tasks --cluster "$cluster_name" \
  --tasks "$console_task_arn" --output json)
printf '%s' "$console_task_result" | jq -e '
  .tasks | length == 1 and
  .[0].stopCode == "EssentialContainerExited" and
  any(.[0].containers[]; .name == "console" and .exitCode == 0)
' >/dev/null || die "console migration task failed"

name_prefix=$(tf_output_raw name_prefix)
config_evidence="$WORK_DIR/config-validation.log"
: >"$config_evidence"
for component in coord console; do
  aws_cli logs filter-log-events \
    --log-group-name "/ecs/$name_prefix/$component" \
    --query 'events[].message' --output text >>"$config_evidence"
done
grep -q 'configuration valid: schema 1, service console' "$config_evidence" || \
  die "console config validation evidence missing"
grep -q 'effective_sources' "$config_evidence" || \
  die "redacted effective config evidence missing"
if grep -Eiq '(password|secret|token|cookie)[[:space:]]*[:=][[:space:]]*[^<[:space:]]' "$config_evidence"; then
  die "config validation evidence contains a possible secret value"
fi

printf '%s\n%s\n' "$coord_task_arn" "$console_task_arn" >"$WORK_DIR/migration.ok"
printf 'coordinator migration complete: %s\n' "$coord_task_arn"
printf 'console migration complete: %s\n' "$console_task_arn"
