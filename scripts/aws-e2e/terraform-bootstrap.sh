#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
validate_expiry
require_command jq
assert_aws_identity
[ -d "$TF_DIR_ABS" ] || die "Terraform directory missing: $TF_DIR_ABS"

write_context_tfvars true false 0
terraform_exec init -input=false
terraform_exec apply -state="$STATE_FILE" -input=false -auto-approve \
  -lock-timeout=5m -var-file="$CONTEXT_TFVARS"
assert_stack_identity

repositories=$(tf_output_json ecr_repository_urls)
for repository_key in console coord relay coord_proxy; do
  repository_url=$(printf '%s' "$repositories" | jq -er --arg key "$repository_key" '.[$key]') || \
    die "missing ECR repository output: $repository_key"
  repository_name=${repository_url#*/}
  repository_arn=arn:aws:ecr:$AWS_REGION:$EXPECTED_AWS_ACCOUNT:repository/$repository_name
  require_resource_tag "$repository_arn"
done

artifact_bucket=$(tf_output_raw artifact_bucket)
bucket_run_id=$(aws_cli s3api get-bucket-tagging --bucket "$artifact_bucket" \
  --query 'TagSet[?Key==`RunId`].Value | [0]' --output text)
[ "$bucket_run_id" = "$RUN_ID" ] || die "artifact bucket RunId mismatch"
printf '%s\n' bootstrap >"$STAGE_FILE"
terraform_exec output -state="$STATE_FILE" -json >"$WORK_DIR/bootstrap-outputs.json"
printf 'bootstrap ready: %s\n' "$(tf_output_raw name_prefix)"

