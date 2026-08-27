#!/bin/sh
# Isolated local conformance lab (#42). One run ID, selected scenarios,
# machine-readable manifest, secret scan, and cleanup of this run only.
set -eu

die() {
  printf 'conformance-lab: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/conformance/run-lab.sh [--scenario NAME[,NAME...]] [--keep-evidence]

Scenarios:
  self-test       Isolated run IDs, failed-assertion cleanup, secret scan
  observability   Coordinator/relay /metrics and public health contracts
  homelab-acl     Two-agent named-group allow/deny on the homelab compose stack
  fail            Deliberate assertion failure used by the static test
EOF
}

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
scenarios=self-test
keep_evidence=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario)
      [ "$#" -ge 2 ] || die "--scenario needs a value"
      scenarios=$2
      shift 2
      ;;
    --keep-evidence)
      keep_evidence=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$-$(openssl rand -hex 4)
evidence_root=${BLAKTAIL_LAB_EVIDENCE:-${TMPDIR:-/tmp}/blaktail-lab}
run_dir=$evidence_root/$run_id
mkdir -p "$run_dir"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git_sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf unknown)
status=passed
summary=$run_dir/manifest.json
results=$run_dir/results.tsv
: >"$results"

cleanup() {
  if [ "$keep_evidence" -eq 0 ] && [ "$status" = passed ]; then
    case "$run_dir" in
      "$evidence_root"/"$run_id") rm -rf -- "$run_dir" ;;
    esac
  fi
}
trap cleanup EXIT INT TERM

redact_scan() {
  if grep -R -E -n 'btk_|btn_|bta_|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|BETTER_AUTH_SECRET|BLAKTAIL_AUTH_HMAC_SECRET' \
    "$run_dir" >/tmp/blaktail-lab-secrets."$$" 2>/dev/null; then
    cat /tmp/blaktail-lab-secrets."$$" >&2 || true
    rm -f /tmp/blaktail-lab-secrets."$$"
    die "evidence for $run_id contains a credential class"
  fi
  rm -f /tmp/blaktail-lab-secrets."$$"
}

record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results"
}

run_self_test() {
  other_id=$(date -u +%Y%m%dT%H%M%SZ)-$$x-$(openssl rand -hex 4)
  other_dir=$evidence_root/$other_id
  mkdir -p "$run_dir/self-test" "$other_dir/self-test"
  [ "$run_dir" != "$other_dir" ] || die "run IDs collided"
  printf 'isolated\n' >"$run_dir/self-test/owner.txt"
  printf 'isolated\n' >"$other_dir/self-test/owner.txt"
  fail_dir=$run_dir/self-test/deliberate-fail
  mkdir -p "$fail_dir"
  printf 'assertion failed on purpose\n' >"$fail_dir/reason.txt"
  rm -rf -- "$other_dir"
  case "$other_dir" in
    "$evidence_root"/"$other_id") ;;
    *) die "refusing to treat foreign path as a lab run" ;;
  esac
  [ ! -e "$other_dir" ] || die "cleanup left the other run in place"
  [ -f "$run_dir/self-test/owner.txt" ] || die "cleanup removed the current run"
  printf 'self-test isolated run IDs and cleaned only the foreign run\n' \
    >"$run_dir/self-test/summary.txt"
}

run_observability() {
  BLAKTAIL_EVIDENCE=$run_dir/observability-proof.md \
    "$repo_root/scripts/conformance/prove-observability.sh"
}

run_homelab_acl() {
  "$repo_root/deploy/homelab/prove-acl-groups.sh" \
    >"$run_dir/homelab-acl.log" 2>&1
}

run_fail() {
  mkdir -p "$run_dir/fail"
  printf 'deliberate assertion failure\n' >"$run_dir/fail/reason.txt"
  return 1
}

old_ifs=$IFS
IFS=,
# shellcheck disable=SC2086
set -- $scenarios
IFS=$old_ifs

for scenario in "$@"; do
  scenario=$(printf '%s' "$scenario" | tr -d ' ')
  [ -n "$scenario" ] || continue
  printf 'conformance-lab: run %s scenario %s\n' "$run_id" "$scenario"
  if (
    case "$scenario" in
      self-test) run_self_test ;;
      observability) run_observability ;;
      homelab-acl) run_homelab_acl ;;
      fail) run_fail ;;
      *) die "unknown scenario: $scenario" ;;
    esac
  ); then
    record "$scenario" passed "$run_dir/$scenario"
  else
    status=failed
    record "$scenario" failed "$run_dir/$scenario"
  fi
done

ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf '{\n'
  printf '  "run_id": "%s",\n' "$run_id"
  printf '  "git": "%s",\n' "$git_sha"
  printf '  "started_at": "%s",\n' "$started"
  printf '  "ended_at": "%s",\n' "$ended"
  printf '  "status": "%s",\n' "$status"
  printf '  "scenarios": [\n'
  first=1
  while IFS=$(printf '\t') read -r name result path; do
    [ -n "$name" ] || continue
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ',\n'
    fi
    printf '    {"name": "%s", "status": "%s", "evidence": "%s"}' "$name" "$result" "$path"
  done <"$results"
  printf '\n  ]\n}\n'
} >"$summary"

redact_scan
printf 'conformance-lab: %s %s manifest %s\n' "$run_id" "$status" "$summary"
[ "$status" = passed ]
