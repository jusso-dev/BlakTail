#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

stage=${1:-prepare}
case "$stage" in
  prepare | activate) ;;
  *) die "usage: terraform-apply.sh <prepare|activate>" ;;
esac

validate_base_inputs
validate_expiry
require_command jq
assert_aws_identity
assert_stack_identity
validate_image_tfvars

case "$stage" in
  prepare)
    write_context_tfvars false false 0
    ;;
  activate)
    [ -f "$WORK_DIR/migration.ok" ] || die "successful explicit migration required before activation"
    write_context_tfvars false true 1
    ;;
esac

terraform_exec apply -state="$STATE_FILE" -input=false -auto-approve \
  -lock-timeout=5m -var-file="$CONTEXT_TFVARS" -var-file="$IMAGES_TFVARS"
assert_stack_identity
assert_network_guards
printf '%s\n' "$stage" >"$STAGE_FILE"
terraform_exec output -state="$STATE_FILE" -json >"$WORK_DIR/$stage-outputs.json"
printf 'Terraform %s complete: %s\n' "$stage" "$(tf_output_raw public_url)"

