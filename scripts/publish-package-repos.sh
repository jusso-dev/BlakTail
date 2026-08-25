#!/bin/sh
# Build signed APT and RPM repository metadata from a release dist directory (#33).
set -eu
DIST=${1:?usage: publish-package-repos.sh DIST REPO_OUT}
OUT=${2:?usage: publish-package-repos.sh DIST REPO_OUT}
CHANNEL=${BLAKTAIL_REPO_CHANNEL:-stable}
ORIGIN=${BLAKTAIL_REPO_ORIGIN:-BlakTail}
LABEL=${BLAKTAIL_REPO_LABEL:-BlakTail}
CODENAME=${BLAKTAIL_REPO_CODENAME:-stable}

command -v dpkg-scanpackages >/dev/null || {
  printf 'dpkg-scanpackages is required\n' >&2
  exit 2
}
command -v gzip >/dev/null
[ -d "$DIST" ] || { printf 'dist directory missing\n' >&2; exit 2; }

mkdir -p "$OUT/apt/dists/$CHANNEL/main/binary-amd64" \
  "$OUT/apt/dists/$CHANNEL/main/binary-arm64" \
  "$OUT/apt/pool/main" \
  "$OUT/rpm/$CHANNEL"

cp "$DIST"/blaktaild-*-unknown-linux-gnu.deb "$OUT/apt/pool/main/" 2>/dev/null || true
cp "$DIST"/blaktaild-*-unknown-linux-gnu.rpm "$OUT/rpm/$CHANNEL/" 2>/dev/null || true
[ -n "$(find "$OUT/apt/pool/main" -name '*.deb' -print -quit)" ] \
  || { printf 'no Debian packages in %s\n' "$DIST" >&2; exit 1; }

(
  cd "$OUT/apt"
  dpkg-scanpackages --multiversion pool/main >"dists/$CHANNEL/main/binary-amd64/Packages"
  gzip -9c "dists/$CHANNEL/main/binary-amd64/Packages" >"dists/$CHANNEL/main/binary-amd64/Packages.gz"
  cp "dists/$CHANNEL/main/binary-amd64/Packages" "dists/$CHANNEL/main/binary-arm64/Packages"
  cp "dists/$CHANNEL/main/binary-amd64/Packages.gz" "dists/$CHANNEL/main/binary-arm64/Packages.gz"
)

{
  printf 'Origin: %s\n' "$ORIGIN"
  printf 'Label: %s\n' "$LABEL"
  printf 'Suite: %s\n' "$CHANNEL"
  printf 'Codename: %s\n' "$CODENAME"
  printf 'Architectures: amd64 arm64\n'
  printf 'Components: main\n'
  printf 'Description: BlakTail agent %s channel\n' "$CHANNEL"
  printf 'Date: %s\n' "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
} >"$OUT/apt/dists/$CHANNEL/Release"

if [ -n "${BLAKTAIL_REPO_GPG_KEY:-}" ]; then
  command -v gpg >/dev/null
  gpg --batch --yes --pinentry-mode loopback \
    --local-user "$BLAKTAIL_REPO_GPG_KEY" \
    --clearsign -o "$OUT/apt/dists/$CHANNEL/InRelease" \
    "$OUT/apt/dists/$CHANNEL/Release"
  gpg --batch --yes --pinentry-mode loopback \
    --local-user "$BLAKTAIL_REPO_GPG_KEY" \
    --detach-sign -a -o "$OUT/apt/dists/$CHANNEL/Release.gpg" \
    "$OUT/apt/dists/$CHANNEL/Release"
else
  printf 'BLAKTAIL_REPO_GPG_KEY unset; writing unsigned Release only\n' >&2
fi

if command -v createrepo_c >/dev/null; then
  createrepo_c "$OUT/rpm/$CHANNEL"
elif command -v createrepo >/dev/null; then
  createrepo "$OUT/rpm/$CHANNEL"
else
  printf 'createrepo not installed; RPM files copied without repodata\n' >&2
fi

printf 'package repositories written to %s\n' "$OUT"
