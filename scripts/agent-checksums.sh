#!/bin/sh
set -eu

directory=${1:-dist}
[ -d "$directory" ] || {
  printf 'agent-checksums: directory not found: %s\n' "$directory" >&2
  exit 1
}

output="$directory/SHA256SUMS"
work=$(mktemp "${TMPDIR:-/tmp}/blaktail-checksums.XXXXXX")
cleanup() {
  if [ -n "${work:-}" ] && [ -f "$work" ]; then
    rm -f -- "$work"
  fi
}
trap cleanup EXIT HUP INT TERM

found=0
for asset in "$directory"/blaktaild-*.pkg "$directory"/blaktaild-*.deb "$directory"/blaktaild-*.rpm; do
  [ -f "$asset" ] || continue
  found=1
  name=$(basename -- "$asset")
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$asset" | awk '{ print $1 }')
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$asset" | awk '{ print $1 }')
  else
    printf 'agent-checksums: sha256sum or shasum is required\n' >&2
    exit 1
  fi
  printf '%s  %s\n' "$digest" "$name" >>"$work"
done
[ "$found" -eq 1 ] || {
  printf 'agent-checksums: no agent packages found in %s\n' "$directory" >&2
  exit 1
}
LC_ALL=C sort "$work" >"$output"
printf '%s\n' "$output"
