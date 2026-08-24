#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws curl git jq terraform; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity
assert_network_guards
validate_image_tfvars
[ "$(cat "$STAGE_FILE" 2>/dev/null || true)" = activate ] || die "activated stack required"

for required_file in \
  "$WORK_DIR/migration.ok" \
  "$WORK_DIR/owner-bootstrap.ok" \
  "$WORK_DIR/agent-install.ok" \
  "$WORK_DIR/enrolment-ubuntu.ok" \
  "$WORK_DIR/enrolment-al2023.ok" \
  "$WORK_DIR/network-proof-ubuntu.ok" \
  "$WORK_DIR/network-proof-al2023.ok" \
  "$PACKAGE_DIR/SHA256SUMS"; do
  [ -s "$required_file" ] || die "required evidence missing: $required_file"
done

public_url=$(tf_output_raw public_url)
case "$public_url" in https://*) ;; *) die "public URL must use HTTPS" ;; esac
console_status=$(curl --fail --silent --show-error --location --max-time 20 \
  --output /dev/null --write-out '%{http_code}' "$public_url/sign-in")
[ "$console_status" = 200 ] || die "console health proof failed: HTTP $console_status"
coord_status=$(curl --fail --silent --show-error --max-time 20 \
  --output /dev/null --write-out '%{http_code}' "$public_url/health")
[ "$coord_status" = 200 ] || die "coordinator health proof failed: HTTP $coord_status"

cluster_name=$(tf_output_raw cluster_name)
service_names="$(tf_output_raw name_prefix)-console $(tf_output_raw name_prefix)-coord $(tf_output_raw name_prefix)-relay"
aws_cli ecs wait services-stable --cluster "$cluster_name" --services $service_names
service_json=$(aws_cli ecs describe-services --cluster "$cluster_name" \
  --services $service_names --include TAGS --output json)
printf '%s' "$service_json" | jq -e --arg run_id "$RUN_ID" '
  (.failures | length == 0) and (.services | length == 3) and
  all(.services[]; .desiredCount > 0 and .runningCount == .desiredCount and
    any(.tags[]?; .key == "RunId" and .value == $run_id))
' >/dev/null || die "ECS service readiness proof failed"

evidence_dir=$WORK_DIR/evidence
[ ! -e "$evidence_dir" ] || die "evidence directory already exists: $evidence_dir"
mkdir -m 0700 "$evidence_dir"

terraform_outputs=$(terraform_exec output -state="$STATE_FILE" -json)
printf '%s' "$terraform_outputs" | jq '{
  name_prefix: .name_prefix.value,
  region: .region.value,
  public_url: .public_url.value,
  relay_endpoint: .relay_endpoint.value,
  cluster_name: .cluster_name.value,
  ecr_repository_urls: .ecr_repository_urls.value,
  artifact_bucket: .artifact_bucket.value,
  task_definition_arns: .task_definition_arns.value,
  private_subnet_ids: .private_subnet_ids.value,
  tasks_security_group_id: .tasks_security_group_id.value,
  agent_instance_ids: .agent_instance_ids.value,
  run_id: .run_id.value
}' >"$evidence_dir/terraform-outputs.json"

printf '%s' "$service_json" | jq '{services: [.services[] | {
  serviceName, status, desiredCount, runningCount, pendingCount, taskDefinition,
  deployments: [.deployments[] | {status, rolloutState, desiredCount, runningCount}]
}]}' >"$evidence_dir/ecs-services.json"

instance_ids=$(tf_output_json agent_instance_ids | jq -r '.ubuntu, .al2023')
aws_cli ec2 describe-instances --instance-ids $instance_ids --output json | jq --arg run_id "$RUN_ID" '{
  instances: [.Reservations[].Instances[] | {
    instance_id: .InstanceId,
    architecture: .Architecture,
    state: .State.Name,
    private_ip: .PrivateIpAddress,
    public_ip: .PublicIpAddress,
    run_id: ([.Tags[]? | select(.Key == "RunId") | .Value][0])
  }], expected_run_id: $run_id
}' >"$evidence_dir/agent-instances.json"

cp "$IMAGES_TFVARS" "$evidence_dir/image-digests.json"
cp "$PACKAGE_DIR/SHA256SUMS" "$evidence_dir/agent-package-SHA256SUMS"
cp "$WORK_DIR/owner-bootstrap.ok" "$evidence_dir/owner-bootstrap.json"
cp "$WORK_DIR/enrolment-ubuntu.ok" "$evidence_dir/enrolment-ubuntu.txt"
cp "$WORK_DIR/enrolment-al2023.ok" "$evidence_dir/enrolment-al2023.txt"
cp "$WORK_DIR/network-proof-ubuntu.ok" "$evidence_dir/network-proof-ubuntu.txt"
cp "$WORK_DIR/network-proof-al2023.ok" "$evidence_dir/network-proof-al2023.txt"

commit_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --arg run_id "$RUN_ID" \
  --arg region "$AWS_REGION" \
  --arg generated_at "$generated_at" \
  --arg commit_sha "$commit_sha" \
  --arg public_url "$public_url" \
  --argjson console_http_status "$console_status" \
  --argjson coordinator_http_status "$coord_status" \
  '{run_id: $run_id, region: $region, generated_at: $generated_at,
    commit_sha: $commit_sha, public_url: $public_url,
    console_http_status: $console_http_status,
    coordinator_http_status: $coordinator_http_status,
    assertions: ["supported one-shot first-owner bootstrap", "public signup disabled",
      "manual browser enrollment", "no public agent IP", "no inbound SSH",
      "immutable ARM64 images", "bidirectional IPv4", "bidirectional IPv6",
      "MagicDNS", "relay endpoint configured", "overlay routes", "SSH over BlakTail"]}' >"$evidence_dir/manifest.json"

if grep -R -E '(Code: [A-Z0-9-]{8,}|/enroll\?code=|device_code|join[_ -]?key|private[_ -]?key|secret[_ -]?access)' \
  "$evidence_dir" >/dev/null 2>&1; then
  die "credential-like content found in evidence"
fi
printf 'evidence complete: %s\n' "$evidence_dir"
