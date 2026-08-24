#!/bin/sh
set -eu

die() {
  printf 'config-contract-test: %s\n' "$*" >&2
  exit 1
}

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
config_binary=${1:-"$repo_root/target/debug/blaktail-config"}
coord_binary=${2:-"$repo_root/target/debug/blaktail-coord"}
for command_name in curl jq grep openssl sed; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done
for binary in "$config_binary" "$coord_binary"; do
  [ -x "$binary" ] || die "binary is missing or not executable: $binary"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/blaktail-config-test.XXXXXX")
coord_pid=
cleanup() {
  if [ -n "$coord_pid" ]; then
    kill "$coord_pid" 2>/dev/null || true
    wait "$coord_pid" 2>/dev/null || true
  fi
  case "${work:-}" in
    "${TMPDIR:-/tmp}"/blaktail-config-test.*) rm -rf -- "$work" ;;
    *) die "refusing unsafe test cleanup" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

secret_marker=CONFIG_CONTRACT_SECRET_MUST_NOT_LEAK_0123456789
printf '%s\n' "$secret_marker" >"$work/console-hmac"
printf '%s\n' "RELAY_${secret_marker}" >"$work/relay-hmac"
printf '%s\n' "AUTH_${secret_marker}" >"$work/better-auth"
printf '%s\n' "postgres://blaktail:${secret_marker}@db.example/blaktail" >"$work/database-url"
cat >"$work/openssl.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = server
prompt = no

[subject]
CN = localhost

[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -config "$work/openssl.cnf" -keyout "$work/tls.key" -out "$work/tls.crt" \
  >/dev/null 2>&1
chmod 0600 "$work"/*

api_port=$((20000 + ($$ % 10000)))
metrics_port=$((api_port + 1))

config="$work/blaktail.toml"
cat >"$config" <<EOF
schema_version = 1

[deployment]
profile = "production"

[coordinator]
region = "ap-southeast-2"
bind = "127.0.0.1:$api_port"
metrics_bind = "127.0.0.1:$metrics_port"
database = "$work/coordinator.sqlite3"
tls_cert = "$work/tls.crt"
tls_key = "file:$work/tls.key"
auth_hmac_secret = "file:$work/console-hmac"
relay_auth_secret = "file:$work/relay-hmac"
relays = ["relay.example:3478"]
console_url = "https://console.example"

[relay]
region = "ap-southeast-2"
auth_secret = "file:$work/relay-hmac"

[agent]
state_dir = "$work/agent"
coordinator_url = "https://coord.example"

[console]
region = "ap-southeast-2"
database_url = "file:$work/database-url"
base_url = "https://console.example"
trusted_origins = ["https://console.example"]
coordinator_url = "https://coord.example"
auth_secret = "file:$work/better-auth"
coordinator_auth_secret = "file:$work/console-hmac"
EOF

"$config_binary" --config "$config" check-config --service all >/dev/null
[ ! -e "$work/coordinator.sqlite3" ] || die "check-config created coordinator state"
"$config_binary" schema >"$work/schema.json"
jq -e '.schema.properties.schema_version.const == 1 and
  any(.environment_overrides[]; .name == "BLAKTAIL_REGION")' \
  "$work/schema.json" >/dev/null || die "schema command omitted checked contract"

dump="$work/dump.json"
"$config_binary" --config "$config" dump-config --service all --redacted >"$dump"
jq -e '.config.schema_version == 1 and .effective_sources["coordinator.region"] == "file"' \
  "$dump" >/dev/null || die "redacted dump omitted effective precedence"
if grep -F "$secret_marker" "$dump" >/dev/null; then
  die "redacted dump exposed a secret marker"
fi

runtime_log="$work/console-runtime.log"
env -i PATH="$PATH" EXPECT_CONFIG_ROOT="$work" \
  "$config_binary" --config "$config" run-console -- sh -ceu '
    [ "$BLAKTAIL_REGION" = ap-southeast-2 ]
    [ "$PORT" = 3000 ]
    [ "$DATABASE_URL" = "$(cat "$EXPECT_CONFIG_ROOT/database-url")" ]
    [ "$BETTER_AUTH_URL" = https://console.example ]
    [ "$BETTER_AUTH_TRUSTED_ORIGINS" = https://console.example ]
    [ "$COORD_BASE_URL" = https://coord.example ]
    [ "$BETTER_AUTH_SECRET" = "$(cat "$EXPECT_CONFIG_ROOT/better-auth")" ]
    [ "$BLAKTAIL_AUTH_HMAC_SECRET" = "$(cat "$EXPECT_CONFIG_ROOT/console-hmac")" ]
  ' >"$runtime_log"
grep -q 'configuration valid: schema 1, service console' "$runtime_log" || \
  die "console runtime adapter skipped validation"
if grep -F "$secret_marker" "$runtime_log" >/dev/null; then
  die "console runtime adapter logged a secret marker"
fi

"$coord_binary" --config "$config" migrate >/dev/null
"$coord_binary" --config "$config" serve >"$work/coord.stdout" 2>"$work/coord.stderr" &
coord_pid=$!
coord_ready=false
attempt=0
while [ "$attempt" -lt 10 ]; do
  attempt=$((attempt + 1))
  if curl --fail --insecure --silent --max-time 1 \
    "https://127.0.0.1:$api_port/health" >/dev/null; then
    coord_ready=true
    break
  fi
  if ! kill -0 "$coord_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [ "$coord_ready" != true ]; then
  cat "$work/coord.stderr" >&2
  die "coordinator TLS runtime did not become healthy"
fi
kill "$coord_pid"
wait "$coord_pid" 2>/dev/null || true
coord_pid=

printf '%s\n' \
  "owner@example.com token=$secret_marker peer=203.0.113.7 ipv6=2001:db8::7 id=7d9d69ab-1bc5-4d73-9492-d3df8f06b834 database_url=postgres://owner:password@db.example/blaktail enroll=https://console.example/enroll?code=ABCD-EFGH" \
  >"$work/service.log"
preview="$work/preview.json"
"$config_binary" --config "$config" support-bundle --service coordinator \
  --log-file "$work/service.log" >"$preview"
confirmation=$(jq -er '.confirmation_digest | select(length == 64)' "$preview")
bundle="$work/support.json"
"$config_binary" --config "$config" support-bundle --service coordinator \
  --log-file "$work/service.log" --output "$bundle" --confirm "$confirmation" >/dev/null
if grep -E "($secret_marker|owner@example.com|203[.]0[.]113[.]7|2001:db8::7|7d9d69ab-1bc5|postgres://owner:password|ABCD-EFGH)" \
  "$bundle" >/dev/null; then
  die "support bundle exposed secret or PII marker"
fi
if stat -f '%Lp' "$bundle" >/dev/null 2>&1; then
  bundle_mode=$(stat -f '%Lp' "$bundle")
else
  bundle_mode=$(stat -c '%a' "$bundle")
fi
[ "$bundle_mode" = 600 ] || die "support bundle mode is $bundle_mode, expected 600"

invalid="$work/invalid.toml"
sed -e 's/ap-southeast-2/us-east-1/' \
  -e 's/coordinator[.]sqlite3/invalid.sqlite3/' "$config" >"$invalid"
if "$coord_binary" --config "$invalid" serve >"$work/invalid.stdout" 2>"$work/invalid.stderr"; then
  die "coordinator accepted invalid region"
fi
[ ! -e "$work/invalid.sqlite3" ] || die "invalid coordinator startup created or migrated state"
grep -q 'coordinator.region' "$work/invalid.stderr" || die "invalid startup lacked field-specific error"

unknown="$work/unknown.toml"
printf '%s\n' 'schema_version = 1' '[relay]' 'unknown_debug_bind = true' >"$unknown"
if "$config_binary" --config "$unknown" check-config --service relay >/dev/null 2>&1; then
  die "unknown configuration field was accepted"
fi

for unit in blaktaild blaktail-coord blaktail-relay; do
  file="$repo_root/packaging/systemd/$unit.service"
  grep -q '^Restart=on-failure$' "$file" || die "$unit restart policy missing"
  grep -q '^ProtectSystem=strict$' "$file" || die "$unit filesystem sandbox missing"
  grep -q '^LimitNOFILE=65536$' "$file" || die "$unit file-descriptor limit missing"
  grep -q 'blaktail-config check-config' "$file" || die "$unit preflight missing"
  grep -q '^ExecReload=/bin/kill -HUP [$]MAINPID$' "$file" || die "$unit reload signal missing"
done
grep -q '^User=root$' "$repo_root/packaging/systemd/blaktaild.service" || \
  die "agent root requirement is not explicit"
grep -q '^CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE$' \
  "$repo_root/packaging/systemd/blaktaild.service" || die "agent capabilities are not narrow"
grep -q '^User=blaktail$' "$repo_root/packaging/systemd/blaktail-coord.service" || \
  die "coordinator dedicated user missing"
grep -q '^ReadWritePaths=/var/lib/blaktail-coord$' \
  "$repo_root/packaging/systemd/blaktail-coord.service" || \
  die "coordinator writable state is not isolated"
grep -q '^DynamicUser=true$' "$repo_root/packaging/systemd/blaktail-relay.service" || \
  die "relay dynamic user missing"

grep -q '^USER blaktail$' "$repo_root/deploy/docker/coord.Dockerfile" || \
  die "coordinator image is not non-root"
grep -q '^USER blaktail$' "$repo_root/deploy/docker/relay.Dockerfile" || \
  die "relay image is not non-root"
grep -q '^USER blaktail$' "$repo_root/apps/console/Dockerfile" || \
  die "console image is not non-root"
grep -q '^FROM oven/bun:1[.]4[.]0-slim' "$repo_root/apps/console/Dockerfile" || \
  die "console image is not pinned to Bun 1.4.0"
if grep -q '^FROM node:' "$repo_root/apps/console/Dockerfile"; then
  die "console image still includes a Node.js runtime"
fi
grep -q '^CMD \["bun", "run", "start"\]$' "$repo_root/apps/console/Dockerfile" || \
  die "console image does not start through Bun"
grep -q 'bun ci --production' "$repo_root/apps/console/Dockerfile" || \
  die "console image still includes build-only dependencies"
grep -q 'drizzle-orm/bun-sql' "$repo_root/apps/console/src/lib/db/client.ts" || \
  die "console database adapter is not Bun SQL"
grep -q 'drizzle-orm/bun-sql/migrator' \
  "$repo_root/apps/console/scripts/migrate.mjs" || \
  die "console migrations do not use Bun SQL"
if grep -q '"postgres"[[:space:]]*:' "$repo_root/apps/console/package.json"; then
  die "console still depends on the standalone postgres client"
fi
if grep -Eq 'awscli|postgresql-client|\bcurl\b' "$repo_root/apps/console/Dockerfile"; then
  die "console image still includes replaceable runtime tools"
fi
if grep -R -q 'drizzle-kit migrate' \
  "$repo_root/compose.yaml" "$repo_root/scripts/aws-e2e/migrate-console.sh"; then
  die "runtime migration still requires the Drizzle CLI"
fi
grep -q 'readonlyRootFilesystem = true' \
  "$repo_root/deploy/aws/e2e/modules/runtime/ecs.tf" || die "Fargate read-only root missing"
grep -q 'read_only: true' "$repo_root/compose.yaml" || die "Compose read-only root missing"
if grep -q 'drizzle-kit migrate.*next start' "$repo_root/apps/console/Dockerfile"; then
  die "console image still performs implicit migration"
fi
grep -q 'blaktail-config run-console' "$repo_root/deploy/docker/console-entrypoint.sh" || \
  die "console effective-config runtime adapter missing"

printf 'operator configuration and hardening contract passed\n'
