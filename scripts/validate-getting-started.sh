#!/usr/bin/env bash
# Structural checks so the Nebula-style first-run path cannot silently rot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MISSION="Built by Indigenous Australians for Indigenous Australian organisations. Data stays onshore, Indigenous Australian organisations stay in control, and the code stays public."

fail() { echo "validate-getting-started: $*" >&2; exit 1; }

test -f README.md || fail "missing README.md"
test -x scripts/quickstart.sh || fail "scripts/quickstart.sh must be executable"
test -f Makefile || fail "missing Makefile"
test -f docs/getting-started.md || fail "missing docs/getting-started.md"
test -f docs/project-status.md || fail "missing docs/project-status.md"
test -f examples/README.md || fail "missing examples/README.md"
test -f examples/env.local || fail "missing examples/env.local"
test -f examples/agent.toml || fail "missing examples/agent.toml"
test -f .env.example || fail "missing .env.example"
test -f compose.yaml || fail "missing compose.yaml"
test -f scripts/dev-certs.sh || fail "missing scripts/dev-certs.sh"

bash -n scripts/quickstart.sh || fail "scripts/quickstart.sh failed bash -n"
bash -n scripts/dev-certs.sh || fail "scripts/dev-certs.sh failed bash -n"
bash -n scripts/validate-getting-started.sh || fail "self syntax check failed"

grep -Fq "$MISSION" README.md \
  || fail "README must keep the shared project mission"
grep -Fq "## Getting started (quickly)" README.md \
  || fail "README must have a Getting started (quickly) section"
grep -Fq "./scripts/quickstart.sh" README.md \
  || fail "README must name scripts/quickstart.sh as the first-run command"
grep -Fq "make up" README.md \
  || fail "README must mention make up"
grep -Fq -- "--coord-ca" README.md \
  || fail "README must show the local coordinator CA flag"
grep -Fq "http://localhost:3000" README.md \
  || fail "README must send operators to the local console"

grep -Fq "127.0.0.1:3478" .env.example \
  || fail ".env.example must advertise a local relay endpoint"
grep -Fq "http://localhost:3000" .env.example \
  || fail ".env.example must use a local console URL"
if grep -Eq 'example\.org\.au' .env.example; then
  fail ".env.example must not use production example.org.au hostnames"
fi

grep -Fq "127.0.0.1:3478" examples/env.local \
  || fail "examples/env.local must use a local relay endpoint"
grep -Fq "https://127.0.0.1:8443" examples/agent.toml \
  || fail "examples/agent.toml must point at the local coordinator"

grep -Eq '^up:' Makefile || fail "Makefile must define an up target"
grep -Fq './scripts/quickstart.sh' Makefile \
  || fail "make up must invoke scripts/quickstart.sh"

grep -Fq "scripts/quickstart.sh" docs/getting-started.md \
  || fail "docs/getting-started.md must document the quickstart script"
grep -Fq "scripts/quickstart.sh" docs/deploy-aws.md \
  || fail "docs/deploy-aws.md must point laptop users at quickstart"

grep -Fq "certs-init:" compose.yaml || fail "compose.yaml must generate certs in-stack"
grep -Fq "coordcerts:" compose.yaml || fail "compose.yaml must use a named certs volume"
if grep -Eq '\./certs:' compose.yaml; then
  fail "compose.yaml must not bind-mount ./certs (breaks remote Docker contexts)"
fi

if grep -E '^\s*(\./)?scripts/install-agent\.sh' README.md docs/getting-started.md; then
  fail "getting-started docs must not present install-agent.sh as a command to run"
fi

# Compose still requires the documented secrets; local examples must name them all.
for name in POSTGRES_PASSWORD BETTER_AUTH_SECRET BLAKTAIL_AUTH_HMAC_SECRET \
  BLAKTAIL_RELAY_AUTH_SECRET BLAKTAIL_DIAGNOSTICS_TOKEN BLAKTAIL_RELAY_ENDPOINT \
  BETTER_AUTH_URL; do
  grep -Eq "^${name}=" .env.example || fail ".env.example missing $name"
  grep -Eq "^${name}=" examples/env.local || fail "examples/env.local missing $name"
done

printf 'validate-getting-started: ok\n'
