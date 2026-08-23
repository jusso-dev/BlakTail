#!/usr/bin/env bash
# Simulate a test branch that commits dummy secrets. CI must fail that branch.
# Secrets are assembled at runtime so this script is not itself a leak.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATH="${BLAKTAIL_CI_TOOLS:-${HOME}/.cache/blaktail-ci-tools}:${PATH}"
export PATH

if ! command -v gitleaks >/dev/null; then
  echo "gitleaks not on PATH; run scripts/ci/install-security-tools.sh" >&2
  exit 1
fi

# AWS access-key *shape* only (AKIA + 16 A-Z/0-9). Split so this file is not
# itself a hit. Not an Amazon example id; not a real credential.
aws_id="AKIA"
aws_id+="BLKTAIL0TEST0001"

# Join-key shape used by blaktail-coord (prefix + 43-char URL-safe body).
join_body="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
join_body="${join_body}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
join_key="btk_${join_body:0:43}"

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

git init -b test-gitleaks-dummy --quiet "${scratch}"
git -C "${scratch}" config user.email "ci@blaktail.invalid"
git -C "${scratch}" config user.name "BlakTail CI"
cp "${ROOT}/.gitleaks.toml" "${scratch}/.gitleaks.toml"
printf 'aws_access_key_id = %s\njoin_key = %s\n' "${aws_id}" "${join_key}" \
  > "${scratch}/leaked.env"
git -C "${scratch}" add .gitleaks.toml leaked.env
git -C "${scratch}" commit --quiet -m "test branch with dummy secrets"

set +e
gitleaks detect --source "${scratch}" --verbose --redact --exit-code 1
status=$?
set -e

if [[ "${status}" -eq 0 ]]; then
  echo "gitleaks accepted a dummy secret on a test branch; scanner is not working" >&2
  exit 1
fi

echo "gitleaks correctly failed the dummy-secret test branch (exit ${status})"
