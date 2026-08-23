#!/usr/bin/env bash
# Scan this checkout. Must exit 0 on a clean tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATH="${BLAKTAIL_CI_TOOLS:-${HOME}/.cache/blaktail-ci-tools}:${PATH}"
export PATH
cd "${ROOT}"

if ! command -v gitleaks >/dev/null; then
  echo "gitleaks not on PATH; run scripts/ci/install-security-tools.sh" >&2
  exit 1
fi

# History (needs fetch-depth: 0 in CI) and the working tree.
gitleaks detect --source "${ROOT}" --verbose --redact --exit-code 1
gitleaks detect --source "${ROOT}" --no-git --verbose --redact --exit-code 1
