#!/usr/bin/env bash
# Structural checks for the macOS desktop app. Runs on Linux CI hosts too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MISSION="Built by Indigenous Australians for Indigenous Australian organisations. Data stays onshore, Indigenous Australian organisations stay in control, and the code stays public."

fail() { echo "validate-macos-desktop: $*" >&2; exit 1; }

test -f apps/macos/Package.swift || fail "missing Package.swift"
test -f apps/macos/Sources/BlakTail/BlakTailApp.swift || fail "missing BlakTailApp"
test -f apps/macos/Sources/BlakTailCore/Support/Tagline.swift || fail "missing Tagline"
test -f apps/macos/Sources/BlakTailCore/Agent/AgentController.swift || fail "missing AgentController"
test -f apps/macos/Sources/BlakTail/Views/EndpointManagerView.swift || fail "missing endpoint manager"
test -f apps/macos/Sources/BlakTail/Views/EndpointDetailView.swift || fail "missing endpoint detail"
test -f apps/macos/Sources/BlakTail/Views/SettingsView.swift || fail "missing native settings"
test -f apps/macos/Sources/BlakTailCore/Auth/KeychainStore.swift || fail "missing KeychainStore"
test -f apps/macos/Sources/BlakTailCore/Auth/BrowserSignIn.swift || fail "missing BrowserSignIn"
test -f docs/macos-desktop.md || fail "missing desktop docs"
test -f apps/console/src/app/desktop/auth/page.tsx || fail "missing desktop auth page"
test -f apps/console/src/app/api/desktop/join-key/route.ts || fail "missing join-key route"
test -f apps/console/src/app/api/desktop/devices/route.ts || fail "missing desktop inventory route"
test -f 'apps/console/src/app/api/desktop/devices/[nodeId]/route.ts' || fail "missing desktop mutation route"

grep -Fq "NavigationSplitView" apps/macos/Sources/BlakTail/Views/EndpointManagerView.swift \
  || fail "endpoint manager must use native split-view navigation"
grep -Fq ".searchable" apps/macos/Sources/BlakTail/Views/EndpointManagerView.swift \
  || fail "endpoint manager must provide native search"
grep -Fq "Settings {" apps/macos/Sources/BlakTail/BlakTailApp.swift \
  || fail "app must provide a native Settings scene"
grep -Fq "organisation_id" apps/console/src/app/api/desktop/devices/route.ts \
  || fail "desktop inventory must keep network scope on every endpoint"
grep -Fq "friendlyName" 'apps/console/src/app/api/desktop/devices/[nodeId]/route.ts' \
  || fail "desktop endpoint API must support friendly names"
grep -Fq 'arguments: ["pause"]' apps/macos/Sources/BlakTailCore/Agent/AgentController.swift \
  || fail "Disconnect must pause without revoking enrolment"
if grep -Fq 'arguments: ["down"]' apps/macos/Sources/BlakTailCore/Agent/AgentController.swift; then
  fail "desktop app must not call destructive blaktaild down for Disconnect"
fi

grep -Fq "$MISSION" apps/macos/Sources/BlakTailCore/Support/Tagline.swift \
  || fail "Tagline.swift does not contain the shared project mission"
grep -Fq "$MISSION" docs/macos-desktop.md \
  || fail "desktop docs must quote the shared project mission"
grep -Fq "$MISSION" README.md \
  || fail "README must keep the shared project mission"

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
grep -Fq "organisation" apps/macos/Sources/BlakTail/Views/EndpointManagerView.swift \
  || fail "UI should use Australian English 'organisation'"

echo "validate-macos-desktop: ok"
