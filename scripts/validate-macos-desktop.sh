#!/usr/bin/env bash
# Structural checks for the macOS desktop app. Runs on Linux CI hosts too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAGLINE="Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency."

fail() { echo "validate-macos-desktop: $*" >&2; exit 1; }

test -f apps/macos/Package.swift || fail "missing Package.swift"
test -f apps/macos/Sources/BlakTail/BlakTailApp.swift || fail "missing BlakTailApp"
test -f apps/macos/Sources/BlakTailCore/Support/Tagline.swift || fail "missing Tagline"
test -f apps/macos/Sources/BlakTailCore/Agent/AgentController.swift || fail "missing AgentController"
test -f apps/macos/Sources/BlakTailCore/Auth/KeychainStore.swift || fail "missing KeychainStore"
test -f apps/macos/Sources/BlakTailCore/Auth/BrowserSignIn.swift || fail "missing BrowserSignIn"
test -f docs/macos-desktop.md || fail "missing desktop docs"
test -f apps/console/src/app/desktop/auth/page.tsx || fail "missing desktop auth page"
test -f apps/console/src/app/api/desktop/join-key/route.ts || fail "missing join-key route"

grep -Fq "$TAGLINE" apps/macos/Sources/BlakTailCore/Support/Tagline.swift \
  || fail "Tagline.swift does not contain the locked tagline"
grep -Fq "$TAGLINE" docs/macos-desktop.md \
  || fail "docs must quote the locked tagline context via About or README"
grep -Fq "$TAGLINE" README.md \
  || fail "README must keep the locked tagline"

grep -Fq "Notarisation" docs/macos-desktop.md \
  || fail "docs must cover Notarisation (Australian English)"
grep -Fq "do not buy" docs/macos-desktop.md \
  || fail "docs must say CI must not buy certificates"
grep -Fq "macOS 14" docs/macos-desktop.md \
  || fail "docs must state minimum macOS 14"

# Join key must not be wired through --join-key or env in the Swift driver.
if grep -R --include='*.swift' -n -- '--join-key' apps/macos/Sources; then
  fail "Swift sources must not pass --join-key"
fi
if grep -R --include='*.swift' -n 'BLAKTAIL_JOIN_KEY' apps/macos/Sources; then
  fail "Swift sources must not set BLAKTAIL_JOIN_KEY"
fi

grep -Fq "assertNoJoinKeyInArguments" apps/macos/Sources/BlakTailCore/Agent/AgentController.swift \
  || fail "agent driver must assert join key is absent from argv"
grep -Fq "organisation" apps/macos/Sources/BlakTail/Views/StatusWindow.swift \
  || fail "UI should use Australian English 'organisation'"

echo "validate-macos-desktop: ok"
