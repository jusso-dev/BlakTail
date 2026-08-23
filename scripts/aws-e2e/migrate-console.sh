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
task_definition=$(tf_output_json task_definition_arns | jq -er .console)
security_group_id=$(tf_output_raw tasks_security_group_id)
subnet_json=$(tf_output_json private_subnet_ids | jq -c '.fargate')
[ "$(printf '%s' "$subnet_json" | jq 'length')" -ge 2 ] || die "at least two Fargate subnets required"

running_tasks=$(aws_cli ecs list-tasks --cluster "$cluster_name" --desired-status RUNNING \
  --query 'taskArns | length(@)' --output text)
[ "$running_tasks" = 0 ] || die "services must remain stopped before explicit migration"

network_configuration=$(jq -cn \
  --argjson subnets "$subnet_json" --arg security_group "$security_group_id" \
  '{awsvpcConfiguration:{subnets:$subnets,securityGroups:[$security_group],assignPublicIp:"DISABLED"}}')
overrides=$(jq -cn \
  '{containerOverrides:[{name:"console",command:["npx","drizzle-kit","migrate","--config","drizzle.config.ts"]}]}')

task_arn=$(aws_cli ecs run-task --cluster "$cluster_name" --launch-type FARGATE \
  --task-definition "$task_definition" --network-configuration "$network_configuration" \
  --overrides "$overrides" --started-by "$RUN_ID" \
  --tags key=RunId,value="$RUN_ID" --query 'tasks[0].taskArn' --output text)
case "$task_arn" in
  arn:aws:ecs:*) ;;
  *) die "console migration task did not start" ;;
esac

aws_cli ecs wait tasks-stopped --cluster "$cluster_name" --tasks "$task_arn"
task_result=$(aws_cli ecs describe-tasks --cluster "$cluster_name" --tasks "$task_arn" --output json)
printf '%s' "$task_result" | jq -e '
  .tasks | length == 1 and
  .[0].stopCode == "EssentialContainerExited" and
  any(.[0].containers[]; .name == "console" and .exitCode == 0)
' >/dev/null || die "console migration task failed"
printf '%s\n' "$task_arn" >"$WORK_DIR/migration.ok"
printf 'console migration complete: %s\n' "$task_arn"

