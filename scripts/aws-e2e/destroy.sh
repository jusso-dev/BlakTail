#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws jq terraform; do
  require_command "$command_name"
done
[ "${CONFIRM_DESTROY:-}" = "destroy-$RUN_ID-$EXPECTED_AWS_ACCOUNT" ] || \
  die "set CONFIRM_DESTROY=destroy-$RUN_ID-$EXPECTED_AWS_ACCOUNT"
assert_aws_identity
destroy_context=$WORK_DIR/destroy-context.json
state_outputs=$(terraform_exec output -state="$STATE_FILE" -json)
if printf '%s' "$state_outputs" | jq -e '.run_id.value? != null' >/dev/null; then
  assert_stack_identity
  current_stage=$(cat "$STAGE_FILE" 2>/dev/null || printf bootstrap)
  case "$current_stage" in bootstrap | prepare | activate) ;; *) die "unknown deployment stage: $current_stage" ;; esac
  artifact_bucket=$(tf_output_raw artifact_bucket)
  repositories=$(tf_output_json ecr_repository_urls)
  cluster_name=
  security_group_id=
  instances='{}'
  task_definitions='{}'
  if [ "$current_stage" != bootstrap ]; then
    cluster_name=$(tf_output_raw cluster_name)
    security_group_id=$(tf_output_raw tasks_security_group_id)
    instances=$(tf_output_json agent_instance_ids)
    task_definitions=$(tf_output_json task_definition_arns)
  fi
  destroy_context_tmp=$(mktemp "$WORK_DIR/destroy-context.XXXXXX")
  jq -n \
    --arg expected_aws_account "$EXPECTED_AWS_ACCOUNT" \
    --arg region "$AWS_REGION" \
    --arg run_id "$RUN_ID" \
    --arg name_prefix "blaktail-e2e-$RUN_ID" \
    --arg stage "$current_stage" \
    --arg artifact_bucket "$artifact_bucket" \
    --argjson repositories "$repositories" \
    --arg cluster_name "$cluster_name" \
    --arg security_group_id "$security_group_id" \
    --argjson instances "$instances" \
    --argjson task_definitions "$task_definitions" \
    '{expected_aws_account:$expected_aws_account,region:$region,run_id:$run_id,
      name_prefix:$name_prefix,stage:$stage,artifact_bucket:$artifact_bucket,
      repositories:$repositories,cluster_name:$cluster_name,
      security_group_id:$security_group_id,instances:$instances,
      task_definitions:$task_definitions}' >"$destroy_context_tmp"
  mv "$destroy_context_tmp" "$destroy_context"
  resumed_destroy=false
else
  [ -s "$destroy_context" ] || die "partial destroy requires protected destroy context"
  jq -e \
    --arg expected_aws_account "$EXPECTED_AWS_ACCOUNT" \
    --arg region "$AWS_REGION" \
    --arg run_id "$RUN_ID" \
    --arg name_prefix "blaktail-e2e-$RUN_ID" \
    'select(.expected_aws_account == $expected_aws_account and .region == $region and
      .run_id == $run_id and .name_prefix == $name_prefix and
      (.stage == "bootstrap" or .stage == "prepare" or .stage == "activate"))' \
    "$destroy_context" >/dev/null || die "partial destroy context mismatch"
  current_stage=$(jq -er .stage "$destroy_context")
  artifact_bucket=$(jq -er .artifact_bucket "$destroy_context")
  repositories=$(jq -c .repositories "$destroy_context")
  cluster_name=$(jq -er .cluster_name "$destroy_context")
  security_group_id=$(jq -er .security_group_id "$destroy_context")
  instances=$(jq -c .instances "$destroy_context")
  task_definitions=$(jq -c .task_definitions "$destroy_context")
  resumed_destroy=true
fi

bucket_present=$(aws_cli s3api list-buckets --output json | \
  jq -r --arg bucket "$artifact_bucket" 'any(.Buckets[]; .Name == $bucket)')
case "$bucket_present" in
  true)
    bucket_run_id=$(aws_cli s3api get-bucket-tagging --bucket "$artifact_bucket" \
      --query 'TagSet[?Key==`RunId`].Value | [0]' --output text)
    [ "$bucket_run_id" = "$RUN_ID" ] || die "artifact bucket RunId mismatch"
    aws_cli s3 rm "s3://$artifact_bucket/$RUN_ID/" --recursive --only-show-errors
    aws_cli s3 rm "s3://$artifact_bucket/bootstrap/$RUN_ID/" --recursive --only-show-errors
    ;;
  false) ;;
  *) die "could not determine artifact bucket presence" ;;
esac
if [ "$current_stage" != bootstrap ] && [ "$resumed_destroy" = false ]; then
  assert_network_guards
fi

case "$current_stage" in
  bootstrap)
    write_context_tfvars true false 0
    terraform_exec destroy -state="$STATE_FILE" -input=false -auto-approve \
      -lock-timeout=5m -var-file="$CONTEXT_TFVARS"
    ;;
  prepare | activate)
    validate_image_tfvars
    if [ "$current_stage" = activate ]; then
      write_context_tfvars false true 1
    else
      write_context_tfvars false false 0
    fi
    terraform_exec destroy -state="$STATE_FILE" -input=false -auto-approve \
      -lock-timeout=5m -var-file="$CONTEXT_TFVARS" -var-file="$IMAGES_TFVARS"
    ;;
  *) die "unknown deployment stage: $current_stage" ;;
esac

[ -z "$(terraform_exec state list -state="$STATE_FILE")" ] || die "Terraform state still contains resources"

active_task_definitions=$(aws_cli ecs list-task-definitions \
  --family-prefix "blaktail-e2e-$RUN_ID-" --status ACTIVE --output json | \
  jq '.taskDefinitionArns | length')
[ "$active_task_definitions" = 0 ] || die "active run task definitions remain"
inactive_task_definition_arns=$(aws_cli ecs list-task-definitions \
  --family-prefix "blaktail-e2e-$RUN_ID-" --status INACTIVE --output json | \
  jq -r '.taskDefinitionArns[]')
delete_batch=
delete_batch_size=0
for inactive_task_definition_arn in $inactive_task_definition_arns; do
  case "$inactive_task_definition_arn" in
    arn:aws:ecs:"$AWS_REGION":"$EXPECTED_AWS_ACCOUNT":task-definition/blaktail-e2e-"$RUN_ID"-*) ;;
    *) die "refusing unexpected inactive task definition: $inactive_task_definition_arn" ;;
  esac
  delete_batch="$delete_batch $inactive_task_definition_arn"
  delete_batch_size=$((delete_batch_size + 1))
  if [ "$delete_batch_size" = 10 ]; then
    aws_cli ecs delete-task-definitions --task-definitions $delete_batch >/dev/null
    delete_batch=
    delete_batch_size=0
  fi
done
if [ "$delete_batch_size" -gt 0 ]; then
  aws_cli ecs delete-task-definitions --task-definitions $delete_batch >/dev/null
fi
task_definition_delete_deadline=$(( $(date -u +%s) + 300 ))
remaining_inactive_task_definitions=1
while [ "$(date -u +%s)" -lt "$task_definition_delete_deadline" ]; do
  remaining_inactive_task_definitions=$(aws_cli ecs list-task-definitions \
    --family-prefix "blaktail-e2e-$RUN_ID-" --status INACTIVE --output json | \
    jq '.taskDefinitionArns | length')
  [ "$remaining_inactive_task_definitions" = 0 ] && break
  sleep 5
done
[ "$remaining_inactive_task_definitions" = 0 ] || die "inactive run task definitions remain"

if aws_cli s3api head-bucket --bucket "$artifact_bucket" >/dev/null 2>&1; then
  die "artifact bucket residue remains"
fi
for repository_url in $(printf '%s' "$repositories" | jq -r '.[]'); do
  repository_name=${repository_url#*/}
  if aws_cli ecr describe-repositories --repository-names "$repository_name" >/dev/null 2>&1; then
    die "ECR repository residue remains: $repository_name"
  fi
done

if [ "$current_stage" != bootstrap ]; then
  instance_ids=$(printf '%s' "$instances" | jq -r '.ubuntu, .al2023')
  instance_residue=$(aws_cli ec2 describe-instances --instance-ids $instance_ids --output json | \
    jq '[.Reservations[].Instances[] | select(.State.Name != "terminated")] | length')
  [ "$instance_residue" = 0 ] || die "active agent instance residue remains"
  if aws_cli ec2 describe-security-groups --group-ids "$security_group_id" >/dev/null 2>&1; then
    die "security group residue remains: $security_group_id"
  fi

  cluster_status=$(aws_cli ecs describe-clusters --clusters "$cluster_name" \
    --query 'clusters[0].status' --output text 2>/dev/null || printf INACTIVE)
  case "$cluster_status" in
    INACTIVE | None) ;;
    *) die "ECS cluster residue remains: $cluster_name ($cluster_status)" ;;
  esac
  for task_definition in $(printf '%s' "$task_definitions" | jq -r '.[]'); do
    task_status=$(aws_cli ecs describe-task-definition --task-definition "$task_definition" \
      --query 'taskDefinition.status' --output text 2>/dev/null || printf None)
    case "$task_status" in
      INACTIVE | DELETE_IN_PROGRESS | None) ;;
      *) die "active task definition residue remains: $task_definition" ;;
    esac
  done
fi

tagged_arns=$(aws_cli resourcegroupstaggingapi get-resources \
  --tag-filters "Key=RunId,Values=$RUN_ID" --output json | \
  jq -r '.ResourceTagMappingList[].ResourceARN')
active_tagged_residue=0
for tagged_arn in $tagged_arns; do
  case "$tagged_arn" in
    arn:aws:ec2:"$AWS_REGION":"$EXPECTED_AWS_ACCOUNT":instance/*)
      tagged_instance_id=${tagged_arn##*/}
      tagged_instance_state=$(aws_cli ec2 describe-instances --instance-ids "$tagged_instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)
      [ "$tagged_instance_state" = terminated ] || active_tagged_residue=$((active_tagged_residue + 1))
      ;;
    arn:aws:ecs:"$AWS_REGION":"$EXPECTED_AWS_ACCOUNT":cluster/"$cluster_name" | \
    arn:aws:ecs:"$AWS_REGION":"$EXPECTED_AWS_ACCOUNT":service/"$cluster_name"/* | \
    arn:aws:ecs:"$AWS_REGION":"$EXPECTED_AWS_ACCOUNT":task/"$cluster_name"/*)
      case "$cluster_status" in INACTIVE | None) ;; *) active_tagged_residue=$((active_tagged_residue + 1)) ;; esac
      ;;
    arn:aws:ecs:"$AWS_REGION":"$EXPECTED_AWS_ACCOUNT":task-definition/blaktail-e2e-"$RUN_ID"-*)
      tagged_task_status=$(aws_cli ecs describe-task-definition --task-definition "$tagged_arn" \
        --query 'taskDefinition.status' --output text 2>/dev/null || printf None)
      case "$tagged_task_status" in
        INACTIVE | DELETE_IN_PROGRESS | None) ;;
        *) active_tagged_residue=$((active_tagged_residue + 1)) ;;
      esac
      ;;
    *) active_tagged_residue=$((active_tagged_residue + 1)) ;;
  esac
done
[ "$active_tagged_residue" = 0 ] || \
  die "active RunId-tagged AWS residue remains: $active_tagged_residue resources"
if [ -d "$WORK_DIR/evidence" ]; then
  printf 'run_id=%s\nregion=%s\nscoped_residue=0\n' \
    "$RUN_ID" "$AWS_REGION" >"$WORK_DIR/evidence/teardown.txt"
fi
rm -f -- "$WORK_DIR/owner-password"
printf 'destroy complete; no scoped residue: run_id=%s\n' "$RUN_ID"
