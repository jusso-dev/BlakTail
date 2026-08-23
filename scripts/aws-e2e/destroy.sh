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
assert_stack_identity

current_stage=$(cat "$STAGE_FILE" 2>/dev/null || printf bootstrap)
case "$current_stage" in bootstrap | prepare | activate) ;; *) die "unknown deployment stage: $current_stage" ;; esac
artifact_bucket=$(tf_output_raw artifact_bucket)
repositories=$(tf_output_json ecr_repository_urls)
if [ "$current_stage" != bootstrap ]; then
  cluster_name=$(tf_output_raw cluster_name)
  security_group_id=$(tf_output_raw tasks_security_group_id)
  instances=$(tf_output_json agent_instance_ids)
  task_definitions=$(tf_output_json task_definition_arns)
fi

bucket_run_id=$(aws_cli s3api get-bucket-tagging --bucket "$artifact_bucket" \
  --query 'TagSet[?Key==`RunId`].Value | [0]' --output text)
[ "$bucket_run_id" = "$RUN_ID" ] || die "artifact bucket RunId mismatch"
if [ "$current_stage" != bootstrap ]; then
  assert_network_guards
fi

aws_cli s3 rm "s3://$artifact_bucket/$RUN_ID/" --recursive --only-show-errors

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
  instance_residue=$(aws_cli ec2 describe-instances --instance-ids $instance_ids \
    --query 'Reservations[].Instances[?State.Name!=`terminated`] | length(@)' --output text 2>/dev/null || printf 0)
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
      --query 'taskDefinition.status' --output text 2>/dev/null || printf INACTIVE)
    [ "$task_status" = INACTIVE ] || die "active task definition residue remains: $task_definition"
  done
fi

tagged_residue=$(aws_cli resourcegroupstaggingapi get-resources \
  --tag-filters "Key=RunId,Values=$RUN_ID" --query 'ResourceTagMappingList | length(@)' --output text)
[ "$tagged_residue" = 0 ] || die "RunId-tagged AWS residue remains: $tagged_residue resources"
if [ -d "$WORK_DIR/evidence" ]; then
  printf 'run_id=%s\nregion=%s\nscoped_residue=0\n' \
    "$RUN_ID" "$AWS_REGION" >"$WORK_DIR/evidence/teardown.txt"
fi
printf 'destroy complete; no scoped residue: run_id=%s\n' "$RUN_ID"
