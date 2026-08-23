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
[ -d "$PACKAGE_DIR" ] || die "package directory missing: $PACKAGE_DIR"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$PACKAGE_DIR" && sha256sum --check SHA256SUMS)
elif command -v shasum >/dev/null 2>&1; then
  (cd "$PACKAGE_DIR" && shasum -a 256 --check SHA256SUMS)
else
  die "sha256sum or shasum is required"
fi

artifact_bucket=$(tf_output_raw artifact_bucket)
bucket_run_id=$(aws_cli s3api get-bucket-tagging --bucket "$artifact_bucket" \
  --query 'TagSet[?Key==`RunId`].Value | [0]' --output text)
[ "$bucket_run_id" = "$RUN_ID" ] || die "artifact bucket RunId mismatch"

for package_name in \
  blaktaild-aarch64-unknown-linux-gnu.deb \
  blaktaild-aarch64-unknown-linux-gnu.rpm \
  SHA256SUMS; do
  [ -f "$PACKAGE_DIR/$package_name" ] || die "package missing: $package_name"
  aws_cli s3api put-object --bucket "$artifact_bucket" --key "$RUN_ID/$package_name" \
    --body "$PACKAGE_DIR/$package_name" --server-side-encryption AES256 \
    --metadata "{\"run-id\":\"$RUN_ID\"}" --tagging "RunId=$RUN_ID" >/dev/null
  object_run_id=$(aws_cli s3api head-object --bucket "$artifact_bucket" \
    --key "$RUN_ID/$package_name" --query 'Metadata."run-id"' --output text)
  [ "$object_run_id" = "$RUN_ID" ] || die "uploaded package metadata mismatch: $package_name"
done
printf 'agent packages uploaded: s3://%s/%s/\n' "$artifact_bucket" "$RUN_ID"

