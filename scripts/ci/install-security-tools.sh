#!/usr/bin/env bash
# Download pinned gitleaks and cargo-deny onto the self-hosted runner.
# Checksums are verified. The BlakTail tree is never uploaded to a scanner SaaS.
set -euo pipefail

TOOLS="${BLAKTAIL_CI_TOOLS:-${HOME}/.cache/blaktail-ci-tools}"
mkdir -p "${TOOLS}"

GITLEAKS_VER="8.30.1"
GITLEAKS_TAR="gitleaks_${GITLEAKS_VER}_linux_x64.tar.gz"
GITLEAKS_URL="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VER}/${GITLEAKS_TAR}"
GITLEAKS_SHA="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

DENY_VER="0.20.2"
DENY_TAR="cargo-deny-${DENY_VER}-x86_64-unknown-linux-musl.tar.gz"
DENY_URL="https://github.com/EmbarkStudios/cargo-deny/releases/download/${DENY_VER}/${DENY_TAR}"
DENY_SHA="9f12ed4c49936e09b48bf862b595cde2fe64fcbd9d74dfacac6131ca824c8d5f"

need_install() {
  local bin="$1"
  local ver_flag="$2"
  local expect="$3"
  if [[ -x "${TOOLS}/${bin}" ]] && "${TOOLS}/${bin}" ${ver_flag} 2>/dev/null | grep -q "${expect}"; then
    return 1
  fi
  return 0
}

fetch_verified() {
  local url="$1"
  local sha="$2"
  local dest="$3"
  curl -fsSL -o "${dest}" "${url}"
  echo "${sha}  ${dest}" | sha256sum -c - >&2
}

# Some self-hosted filesystems reject GNU tar member metadata
# ("Function not implemented"). Pull the named regular file out with Python.
extract_member() {
  local archive="$1"
  local basename="$2"
  local dest="$3"
  python3 - "${archive}" "${basename}" "${dest}" <<'PY'
import os, sys, tarfile
archive, basename, dest = sys.argv[1], sys.argv[2], sys.argv[3]
with tarfile.open(archive, "r:*") as tf:
    for member in tf.getmembers():
        if member.isfile() and os.path.basename(member.name) == basename:
            src = tf.extractfile(member)
            if src is None:
                raise SystemExit(f"empty member {member.name}")
            with open(dest, "wb") as out:
                out.write(src.read())
            break
    else:
        raise SystemExit(f"{basename} not in {archive}")
PY
}

if need_install gitleaks version "${GITLEAKS_VER}"; then
  tmp="$(mktemp -d)"
  fetch_verified "${GITLEAKS_URL}" "${GITLEAKS_SHA}" "${tmp}/${GITLEAKS_TAR}"
  extract_member "${tmp}/${GITLEAKS_TAR}" "gitleaks" "${tmp}/gitleaks"
  install -m 0755 "${tmp}/gitleaks" "${TOOLS}/gitleaks"
  rm -rf "${tmp}"
fi

if need_install cargo-deny --version "${DENY_VER}"; then
  tmp="$(mktemp -d)"
  fetch_verified "${DENY_URL}" "${DENY_SHA}" "${tmp}/${DENY_TAR}"
  extract_member "${tmp}/${DENY_TAR}" "cargo-deny" "${tmp}/cargo-deny"
  install -m 0755 "${tmp}/cargo-deny" "${TOOLS}/cargo-deny"
  rm -rf "${tmp}"
fi

export PATH="${TOOLS}:${PATH}"
echo "${TOOLS}"
gitleaks version >/dev/null
cargo-deny --version >/dev/null
