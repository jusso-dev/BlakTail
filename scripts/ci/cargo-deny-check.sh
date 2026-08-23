#!/usr/bin/env bash
# Run cargo deny against the workspace, or probe deny.toml when the crates
# have not landed on this branch yet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATH="${BLAKTAIL_CI_TOOLS:-${HOME}/.cache/blaktail-ci-tools}:${PATH}"
export PATH
cd "${ROOT}"

if [[ ! -f deny.toml ]]; then
  echo "deny.toml is required" >&2
  exit 1
fi

if ! command -v cargo-deny >/dev/null; then
  echo "cargo-deny not on PATH; run scripts/ci/install-security-tools.sh" >&2
  exit 1
fi

cargo-deny --version

if [[ -f Cargo.toml ]]; then
  cargo-deny --config "${ROOT}/deny.toml" check
  exit 0
fi

echo "No Cargo workspace on this branch; probing deny.toml with an empty Apache-2.0 crate."
if ! command -v cargo >/dev/null; then
  echo "cargo is required to probe deny.toml" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/src"
cat > "${tmp}/Cargo.toml" <<'EOF'
[package]
name = "blaktail-deny-probe"
version = "0.1.0"
edition = "2021"
license = "Apache-2.0"
publish = false
EOF
echo "pub fn probe() {}" > "${tmp}/src/lib.rs"
(
  cd "${tmp}"
  cargo generate-lockfile
  cargo-deny --config "${ROOT}/deny.toml" check
)
