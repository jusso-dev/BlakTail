#!/bin/sh
# Static plus local-process checks for the conformance lab runner (#42).
set -eu

die() {
  printf 'lab-static-test: %s\n' "$*" >&2
  exit 1
}

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
runner=$repo_root/scripts/conformance/run-lab.sh
[ -x "$runner" ] || die "run-lab.sh is not executable"
sh -n "$runner"
sh -n "$0"

# The runner must never delete a path it did not mint.
if grep -q 'rm -rf -- /' "$runner"; then
  die "runner contains an unscoped rm"
fi
grep -q 'run_id=' "$runner" || die "runner does not mint a run id"
grep -q 'redact_scan' "$runner" || die "runner is missing a secret scan"
grep -q 'self-test' "$runner" || die "runner is missing the per-PR self-test"
grep -q 'observability' "$runner" || die "runner is missing the observability scenario"
grep -q 'homelab-acl' "$runner" || die "runner is missing the homelab ACL scenario"

work=$(mktemp -d "${TMPDIR:-/tmp}/blaktail-lab-static.XXXXXX")
cleanup() {
  case "${work:-}" in
    "${TMPDIR:-/tmp}"/blaktail-lab-static.*) rm -rf -- "$work" ;;
  esac
}
trap cleanup EXIT INT TERM

export BLAKTAIL_LAB_EVIDENCE=$work

one=$work/one.out
two=$work/two.out
"$runner" --scenario self-test --keep-evidence >"$one" 2>&1 &
pid1=$!
"$runner" --scenario self-test --keep-evidence >"$two" 2>&1 &
pid2=$!
wait "$pid1" || {
  cat "$one" >&2
  die "first concurrent self-test failed"
}
wait "$pid2" || {
  cat "$two" >&2
  die "second concurrent self-test failed"
}
id1=$(awk '/manifest / { print $2; exit }' "$one")
id2=$(awk '/manifest / { print $2; exit }' "$two")
[ -n "$id1" ] && [ -n "$id2" ] || die "could not parse concurrent run IDs"
[ "$id1" != "$id2" ] || die "concurrent runs shared a run ID"
[ -d "$work/$id1" ] && [ -d "$work/$id2" ] || die "concurrent runs did not keep isolated evidence"
[ -f "$work/$id1/manifest.json" ] && [ -f "$work/$id2/manifest.json" ] \
  || die "concurrent runs did not write manifests"

if "$runner" --scenario fail --keep-evidence >"$work/fail.out" 2>&1; then
  cat "$work/fail.out" >&2
  die "fail scenario unexpectedly passed"
fi
fail_id=$(awk '/manifest / { print $2; exit }' "$work/fail.out")
[ -n "$fail_id" ] || die "failed run did not print a run ID"
[ -f "$work/$fail_id/manifest.json" ] || die "failed run did not keep a manifest"
grep -q '"status": "failed"' "$work/$fail_id/manifest.json" \
  || die "failed run manifest is not marked failed"
[ -f "$work/$fail_id/fail/reason.txt" ] || die "failed run dropped diagnostics"
[ -d "$work/$id1" ] || die "failed run cleanup touched an earlier run"

printf 'conformance lab static test passed\n'
