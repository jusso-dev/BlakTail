#!/usr/bin/env bash
# Disposable control plane: console, coordinator, and Australian relay.
# Works with local Docker and a remote DOCKER_CONTEXT. Certificates are
# generated inside Compose; secrets never travel through argv.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OWNER_EMAIL="${OWNER_EMAIL:-owner@example.org.au}"
OWNER_NAME="${OWNER_NAME:-First Owner}"
ORGANISATION_NAME="${ORGANISATION_NAME:-Local Organisation}"
OWNER_PASSWORD_FILE="${OWNER_PASSWORD_FILE:-$ROOT/owner-password}"
QUICKSTART_DIR="${QUICKSTART_DIR:-$ROOT/.quickstart}"
BOOTSTRAP_TOKEN_FILE="${BOOTSTRAP_TOKEN_FILE:-$QUICKSTART_DIR/bootstrap-token}"

die() {
  printf 'quickstart: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

need openssl
need docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)"

docker_endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
publish_host=localhost
if printf '%s' "$docker_endpoint" | grep -Eq '^(ssh|tcp)://'; then
  publish_host=$(printf '%s' "$docker_endpoint" | sed -E 's#^[a-z]+://([^@/]+@)?##' | sed -E 's#[:/].*$##')
  [ -n "$publish_host" ] || die "could not parse Docker host from $docker_endpoint"
fi

publish_ip=
if [ "$publish_host" != localhost ] && [ "$publish_host" != 127.0.0.1 ]; then
  publish_ip=$(python3 -c "import socket; print(socket.gethostbyname('${publish_host}'))" 2>/dev/null || true)
fi

# Browser and enrol URLs stay on loopback. HTTP is only valid for localhost
# in schema v1; a remote Docker engine is reached with SSH tunnels.
console_url="${BETTER_AUTH_URL:-http://localhost:3000}"
coord_url="https://127.0.0.1:8443"
relay_endpoint="${BLAKTAIL_RELAY_ENDPOINT:-127.0.0.1:3478}"
extra_san="${BLAKTAIL_TLS_EXTRA_SAN:-}"
ssh_target=
if [ "$publish_host" != localhost ] && [ "$publish_host" != 127.0.0.1 ]; then
  relay_endpoint="${BLAKTAIL_RELAY_ENDPOINT:-${publish_host}:3478}"
  ssh_target=$(printf '%s' "$docker_endpoint" | sed -E 's#^ssh://##')
  if [ -z "$extra_san" ]; then
    extra_san="DNS:${publish_host}"
    if [ -n "$publish_ip" ]; then
      extra_san="${extra_san},IP:${publish_ip}"
    fi
  fi
fi

printf 'BlakTail local quickstart\n'
if [ -n "$docker_endpoint" ]; then
  printf 'Docker endpoint: %s\n' "$docker_endpoint"
fi
printf 'Console will be %s\n' "$console_url"
printf 'The first compose build compiles Rust and the console; it can take several minutes.\n'

write_env() {
  umask 077
  cat >.env <<EOF
POSTGRES_PASSWORD=${1}
BETTER_AUTH_SECRET=${2}
BLAKTAIL_AUTH_HMAC_SECRET=${3}
BLAKTAIL_RELAY_AUTH_SECRET=${4}
BLAKTAIL_DIAGNOSTICS_TOKEN=${5}
BLAKTAIL_RELAY_ENDPOINT=${relay_endpoint}
BETTER_AUTH_URL=${console_url}
BLAKTAIL_REGION=ap-southeast-2
BLAKTAIL_TLS_EXTRA_SAN=${extra_san}
EOF
  chmod 600 .env
}

if [ ! -f .env ]; then
  write_env "$(openssl rand -hex 24)" "$(openssl rand -hex 32)" \
    "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
  printf 'wrote .env with local secrets (mode 0600)\n'
else
  tmp=$(mktemp)
  umask 077
  sed \
    -e "s#^BETTER_AUTH_URL=.*#BETTER_AUTH_URL=${console_url}#" \
    -e "s#^BLAKTAIL_RELAY_ENDPOINT=.*#BLAKTAIL_RELAY_ENDPOINT=${relay_endpoint}#" \
    .env >"$tmp"
  if grep -q '^BLAKTAIL_TLS_EXTRA_SAN=' "$tmp"; then
    sed -e "s#^BLAKTAIL_TLS_EXTRA_SAN=.*#BLAKTAIL_TLS_EXTRA_SAN=${extra_san}#" "$tmp" >.env
  else
    printf 'BLAKTAIL_TLS_EXTRA_SAN=%s\n' "$extra_san" >>"$tmp"
    cat "$tmp" >.env
  fi
  rm -f "$tmp"
  chmod 600 .env
  printf 'updated .env URLs for this Docker host\n'
fi

ensure_ssh_tunnels() {
  [ -n "$ssh_target" ] || return 0
  need ssh
  if curl -fsS http://127.0.0.1:3000/sign-in >/dev/null 2>&1 \
    && curl -fsS --insecure https://127.0.0.1:8443/readyz >/dev/null 2>&1; then
    printf 'localhost:3000 and :8443 already reach the remote stack\n'
    return 0
  fi
  printf 'forwarding localhost:3000 and :8443 to %s\n' "$ssh_target"
  ssh -f -N -o ExitOnForwardFailure=yes -o BatchMode=yes \
    -L 3000:127.0.0.1:3000 \
    -L 8443:127.0.0.1:8443 \
    "$ssh_target" || die "could not SSH-forward ports to $ssh_target; sign in with ssh $ssh_target first"
}

if ! docker compose up -d --build --wait --wait-timeout 600; then
  docker compose logs certs-init coord-migrate console-migrate --no-color --tail=80 || true
  die "compose failed to become ready. Leftover volumes from another revision? docker compose down -v"
fi
ensure_ssh_tunnels

wait_inside() {
  local i=0
  while [ "$i" -lt 90 ]; do
    if docker compose exec -T console bun -e 'const r = await fetch("http://127.0.0.1:3000/sign-in"); if (!r.ok) process.exit(1)'; then
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  die "timed out waiting for the console inside Compose"
}

printf 'waiting for console...\n'
wait_inside

mkdir -p certs
chmod 700 certs
# compose cp cannot read some remote tmpfs/volume paths; exec cat is reliable.
docker compose exec -T --user root coord cat /certs/ca.crt >certs/ca.crt
chmod 644 certs/ca.crt
printf 'copied coordinator CA to %s/certs/ca.crt\n' "$ROOT"

bootstrap_status() {
  docker compose exec -T console bun scripts/bootstrap.mjs status
}

ensure_owner_password() {
  mkdir -p "$QUICKSTART_DIR"
  chmod 700 "$QUICKSTART_DIR"
  if [ ! -f "$OWNER_PASSWORD_FILE" ]; then
    umask 077
    openssl rand -base64 32 >"$OWNER_PASSWORD_FILE"
    chmod 600 "$OWNER_PASSWORD_FILE"
    printf 'wrote %s (mode 0600)\n' "$OWNER_PASSWORD_FILE"
  fi
}

write_secret_into_console() {
  local host_file=$1
  local dest=$2
  docker compose exec -T --user root console \
    sh -ceu "cat > \"$dest\" && chmod 600 \"$dest\"" <"$host_file"
}

claim_from_files() {
  write_secret_into_console "$BOOTSTRAP_TOKEN_FILE" /tmp/bootstrap-token
  write_secret_into_console "$OWNER_PASSWORD_FILE" /tmp/owner-password
  docker compose exec -T --user root \
    -e OWNER_EMAIL="$OWNER_EMAIL" \
    -e OWNER_NAME="$OWNER_NAME" \
    -e ORGANISATION_NAME="$ORGANISATION_NAME" \
    console \
    bun scripts/bootstrap.mjs claim \
      --token-file /tmp/bootstrap-token \
      --password-file /tmp/owner-password \
      --email "$OWNER_EMAIL" \
      --name "$OWNER_NAME" \
      --organisation-name "$ORGANISATION_NAME"
}

init_and_claim() {
  docker compose exec -T --user root console \
    bun scripts/bootstrap.mjs init --token-file /tmp/bootstrap-token
  mkdir -p "$QUICKSTART_DIR"
  chmod 700 "$QUICKSTART_DIR"
  umask 077
  docker compose exec -T --user root console cat /tmp/bootstrap-token >"$BOOTSTRAP_TOKEN_FILE"
  chmod 600 "$BOOTSTRAP_TOKEN_FILE"
  claim_from_files
}

status_json=$(bootstrap_status)
if printf '%s\n' "$status_json" | grep -q '"status": "locked"'; then
  printf 'first owner already claimed\n'
elif printf '%s\n' "$status_json" | grep -q '"status": "claimable"' \
  && [ -f "$BOOTSTRAP_TOKEN_FILE" ]; then
  printf 'retrying first-owner claim with existing bootstrap token\n'
  ensure_owner_password
  claim_from_files
elif printf '%s\n' "$status_json" | grep -q '"status": "claimable"'; then
  die "bootstrap is claimable but $BOOTSTRAP_TOKEN_FILE is missing; wait 15 minutes or run: docker compose down -v"
else
  ensure_owner_password
  init_and_claim
fi

cat <<EOF

BlakTail is up.

  Console:      $console_url
  Email:        $OWNER_EMAIL
  Password:     $OWNER_PASSWORD_FILE
  Coordinator:  $coord_url
  Relay:        ${relay_endpoint}/udp
  Coordinator CA: $ROOT/certs/ca.crt

Sign in, then enrol this machine:

  cargo build --locked --release -p blaktaild -p blaktail-config
  sudo install -m 0755 target/release/blaktaild /usr/local/bin/blaktaild
  sudo install -m 0755 target/release/blaktail-config /usr/local/bin/blaktail-config
  sudo blaktaild up --coord $coord_url --coord-ca $ROOT/certs/ca.crt

Open the printed enrol link, approve the device, then run: sudo blaktaild status

Stop the stack:    docker compose down
Delete local data: docker compose down -v

More detail: docs/getting-started.md
EOF
