#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in awk aws curl jq terraform; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity
[ "$(cat "$STAGE_FILE" 2>/dev/null || true)" = activate ] || die "activated stack required"
[ -s "$WORK_DIR/network-proof-ubuntu.ok" ] || die "network proof required before coordinator failover"
[ -s "$WORK_DIR/network-proof-al2023.ok" ] || die "network proof required before coordinator failover"

cluster_name=$(tf_output_raw cluster_name)
name_prefix=$(tf_output_raw name_prefix)
coord_service=$name_prefix-coord
expected_task_definition=$(tf_output_json task_definition_arns | jq -er .coord)
public_url=$(tf_output_raw public_url)
case "$public_url" in https://*) ;; *) die "public URL must use HTTPS" ;; esac

aws_cli ecs wait services-stable --cluster "$cluster_name" --services "$coord_service"
service_json=$(aws_cli ecs describe-services --cluster "$cluster_name" \
  --services "$coord_service" --include TAGS --output json)
printf '%s' "$service_json" | jq -e --arg run_id "$RUN_ID" '
  (.failures | length == 0) and (.services | length == 1) and
  (.services[0].desiredCount == 2) and (.services[0].runningCount == 2) and
  (.services[0].pendingCount == 0) and
  any(.services[0].tags[]?; .key == "RunId" and .value == $run_id)
' >/dev/null || die "coordinator service must begin stable at 2/2"

task_arns=$(aws_cli ecs list-tasks --cluster "$cluster_name" \
  --service-name "$coord_service" --desired-status RUNNING --output json | \
  jq -er '.taskArns | sort | if length == 2 then .[] else error("expected two tasks") end') || \
  die "expected exactly two running coordinator tasks"
task_json=$(aws_cli ecs describe-tasks --cluster "$cluster_name" \
  --tasks $task_arns --include TAGS --output json)
printf '%s' "$task_json" | jq -e \
  --arg coord_group "service:$coord_service" \
  --arg task_definition "$expected_task_definition" '
  (.failures | length == 0) and (.tasks | length == 2) and
  all(.tasks[]; .lastStatus == "RUNNING" and .group == $coord_group and
    .taskDefinitionArn == $task_definition)
' >/dev/null || die "coordinator tasks do not belong to the expected service revision"
stopped_task=$(printf '%s\n' "$task_arns" | sed -n '1p')

probe_file=$(mktemp "$WORK_DIR/coord-ha-probes.XXXXXX")
probe_stop=$(mktemp "$WORK_DIR/coord-ha-stop.XXXXXX")
rm -f -- "$probe_stop"
probe_pid=
cleanup() {
  if [ -n "$probe_pid" ]; then
    kill "$probe_pid" >/dev/null 2>&1 || true
    wait "$probe_pid" >/dev/null 2>&1 || true
  fi
  rm -f -- "$probe_file" "$probe_stop"
}
trap cleanup EXIT HUP INT TERM

baseline_remaining=3
while [ "$baseline_remaining" -gt 0 ]; do
  baseline_code=$(curl --silent --show-error --max-time 5 \
    --output /dev/null --write-out '%{http_code}' "$public_url/health") || \
    die "coordinator baseline health request failed"
  [ "$baseline_code" = 200 ] || die "coordinator baseline health returned HTTP $baseline_code"
  baseline_remaining=$((baseline_remaining - 1))
done

(
  probe_number=0
  while [ ! -e "$probe_stop" ]; do
    probe_number=$((probe_number + 1))
    if probe_code=$(curl --silent --show-error --max-time 5 \
      --output /dev/null --write-out '%{http_code}' "$public_url/health"); then
      :
    else
      probe_code=000
    fi
    printf '%s\t%s\t%s\n' "$probe_number" "$probe_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >>"$probe_file"
    sleep 1
  done
) &
probe_pid=$!
sleep 2

aws_cli ecs stop-task --cluster "$cluster_name" --task "$stopped_task" \
  --reason "BlakTail E2E coordinator HA proof $RUN_ID" >/dev/null
aws_cli ecs wait tasks-stopped --cluster "$cluster_name" --tasks "$stopped_task"
stopped_json=$(aws_cli ecs describe-tasks --cluster "$cluster_name" \
  --tasks "$stopped_task" --include TAGS --output json)
printf '%s' "$stopped_json" | jq -e \
  --arg coord_group "service:$coord_service" \
  --arg task_definition "$expected_task_definition" '
  (.failures | length == 0) and (.tasks | length == 1) and
  (.tasks[0].lastStatus == "STOPPED") and (.tasks[0].stopCode == "UserInitiated") and
  (.tasks[0].group == $coord_group) and
  (.tasks[0].taskDefinitionArn == $task_definition)
' >/dev/null || die "stopped coordinator task did not preserve proof identity"

aws_cli ecs wait services-stable --cluster "$cluster_name" --services "$coord_service"
replacement_arns=$(aws_cli ecs list-tasks --cluster "$cluster_name" \
  --service-name "$coord_service" --desired-status RUNNING --output json | \
  jq -er '.taskArns | sort | if length == 2 then .[] else error("expected replacement") end') || \
  die "coordinator service did not return to two tasks"
if printf '%s\n' "$replacement_arns" | grep -Fx "$stopped_task" >/dev/null; then
  die "stopped coordinator task still appears in replacement set"
fi
replacement_json=$(aws_cli ecs describe-tasks --cluster "$cluster_name" \
  --tasks $replacement_arns --include TAGS --output json)
printf '%s' "$replacement_json" | jq -e \
  --arg coord_group "service:$coord_service" \
  --arg task_definition "$expected_task_definition" '
  (.failures | length == 0) and (.tasks | length == 2) and
  all(.tasks[]; .lastStatus == "RUNNING" and .group == $coord_group and
    .taskDefinitionArn == $task_definition)
' >/dev/null || die "replacement coordinator tasks do not match the expected service revision"

final_code=$(curl --silent --show-error --max-time 5 \
  --output /dev/null --write-out '%{http_code}' "$public_url/health") || \
  die "coordinator final health request failed"
[ "$final_code" = 200 ] || die "coordinator final health returned HTTP $final_code"

: >"$probe_stop"
wait "$probe_pid"
probe_pid=
probe_total=$(awk 'END { print NR + 0 }' "$probe_file")
probe_failures=$(awk '$2 != "200" { failures++ } END { print failures + 0 }' "$probe_file")
[ "$probe_total" -ge 5 ] || die "coordinator failover probe sample too small: $probe_total"
[ "$probe_failures" -eq 0 ] || die "coordinator failover had $probe_failures failed health probes"

proof_tmp=$(mktemp "$WORK_DIR/coord-ha.XXXXXX")
jq -n \
  --arg run_id "$RUN_ID" \
  --arg stopped_task "$stopped_task" \
  --argjson continuous_health_probes "$probe_total" \
  --argjson failed_health_probes "$probe_failures" \
  --argjson replacement_running_tasks 2 \
  '{run_id: $run_id, stopped_task: $stopped_task,
    continuous_health_probes: $continuous_health_probes,
    failed_health_probes: $failed_health_probes,
    replacement_running_tasks: $replacement_running_tasks}' >"$proof_tmp"
mv "$proof_tmp" "$WORK_DIR/coord-ha.ok"
chmod 0600 "$WORK_DIR/coord-ha.ok"

printf 'coordinator failover complete: %s probes, zero failures, service restored 2/2\n' \
  "$probe_total"
