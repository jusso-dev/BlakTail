#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws awk base64 jq terraform tr; do
  require_command "$command_name"
done
assert_aws_identity
assert_stack_identity
assert_network_guards
case "$(cat "$STAGE_FILE" 2>/dev/null || true)" in
  activate) ;;
  *) die "activated control plane required" ;;
esac

artifact_bucket=$(tf_output_raw artifact_bucket)
bucket_run_id=$(aws_cli s3api get-bucket-tagging --bucket "$artifact_bucket" \
  --query 'TagSet[?Key==`RunId`].Value | [0]' --output text)
[ "$bucket_run_id" = "$RUN_ID" ] || die "artifact bucket RunId mismatch"
instance_json=$(tf_output_json agent_instance_ids)

remote_body=$(cat <<'REMOTE'
set -eu
umask 077
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait >/dev/null 2>&1 || true
fi

package_ready=false
if [ -f /etc/debian_version ]; then
  export DEBIAN_FRONTEND=noninteractive
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if apt-get update -o Acquire::ForceIPv4=true -qq && \
      apt-get install -y -qq ca-certificates curl iproute2 iptables iputils-ping jq \
        openssh-server procps wireguard-tools; then
      package_ready=true
      break
    fi
    sleep 10
  done
else
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if dnf install -y -q ca-certificates iproute iptables iputils jq openssh-server \
      procps-ng wireguard-tools; then
      package_ready=true
      break
    fi
    sleep 10
  done
fi
[ "$package_ready" = true ] || { echo 'agent dependency bootstrap failed' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'curl missing on agent' >&2; exit 1; }

work=$(mktemp -d /var/tmp/blaktail-package.XXXXXX)
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT HUP INT TERM

sha256_url=$(printf '%s' "$SHA256_URL_B64" | base64 --decode)
package_url=$(printf '%s' "$PACKAGE_URL_B64" | base64 --decode)
curl --fail --silent --show-error --location --max-time 180 \
  --output "$work/SHA256SUMS" "$sha256_url"
if [ -f /etc/debian_version ]; then
  package=blaktaild-aarch64-unknown-linux-gnu.deb
  [ "$PACKAGE_NAME" = "$package" ] || exit 1
  curl --fail --silent --show-error --location --max-time 180 \
    --output "$work/$package" "$package_url"
  (cd "$work" && sha256sum --check --ignore-missing SHA256SUMS)
  dpkg -i "$work/$package"
  ssh_service=ssh
else
  package=blaktaild-aarch64-unknown-linux-gnu.rpm
  [ "$PACKAGE_NAME" = "$package" ] || exit 1
  curl --fail --silent --show-error --location --max-time 180 \
    --output "$work/$package" "$package_url"
  (cd "$work" && sha256sum --check --ignore-missing SHA256SUMS)
  dnf install -y -q "$work/$package"
  systemctl enable --now systemd-resolved
  if grep -Eq '^[[:space:]]*hosts:[[:space:]]+files[[:space:]]+dns[[:space:]]+myhostname[[:space:]]*$' /etc/nsswitch.conf; then
    sed -i -E 's/^[[:space:]]*hosts:[[:space:]]+files[[:space:]]+dns[[:space:]]+myhostname[[:space:]]*$/hosts:      files resolve [!UNAVAIL=return] dns myhostname/' /etc/nsswitch.conf
  elif ! grep -Eq '^[[:space:]]*hosts:.*[[:space:]]resolve([[:space:]]|$)' /etc/nsswitch.conf; then
    echo 'unsupported AL2023 hosts configuration' >&2
    exit 1
  fi
  ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
  ssh_service=sshd
fi

id blaktail-e2e >/dev/null 2>&1 || useradd --create-home --shell /bin/sh blaktail-e2e
install -d -m 0700 -o blaktail-e2e -g blaktail-e2e /home/blaktail-e2e/.ssh
install -d -m 0755 /etc/ssh/sshd_config.d
printf '%s\n' 'PasswordAuthentication no' 'PermitRootLogin no' > /etc/ssh/sshd_config.d/90-blaktail-e2e.conf
systemctl enable --now "$ssh_service"
[ "$(systemctl is-enabled blaktaild 2>/dev/null || true)" != enabled ] || {
  echo 'blaktaild unexpectedly enabled before enrollment' >&2
  exit 1
}
/usr/local/bin/blaktaild --version
REMOTE
)

install_tmp=$(mktemp "$WORK_DIR/agent-install.XXXXXX")
cleanup_install() {
  rm -f -- "$install_tmp"
}
trap cleanup_install EXIT HUP INT TERM
for agent_name in ubuntu al2023; do
  instance_id=$(printf '%s' "$instance_json" | jq -er --arg key "$agent_name" '.[$key]')
  assert_ssm_online "$instance_id"
  case "$agent_name" in
    ubuntu) package_name=blaktaild-aarch64-unknown-linux-gnu.deb ;;
    al2023) package_name=blaktaild-aarch64-unknown-linux-gnu.rpm ;;
    *) die "unsupported agent platform: $agent_name" ;;
  esac
  sha256_url=$(aws_cli s3 presign "s3://$artifact_bucket/$RUN_ID/SHA256SUMS" --expires-in 900)
  package_url=$(aws_cli s3 presign "s3://$artifact_bucket/$RUN_ID/$package_name" --expires-in 900)
  sha256_url_b64=$(printf '%s' "$sha256_url" | base64 | tr -d '\n')
  package_url_b64=$(printf '%s' "$package_url" | base64 | tr -d '\n')
  remote_script="SHA256_URL_B64=$sha256_url_b64
PACKAGE_URL_B64=$package_url_b64
PACKAGE_NAME=$package_name
$remote_body"
  ssm_send_script "$instance_id" "BlakTail E2E package install $RUN_ID" "$remote_script"
  wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
  version_output=$(ssm_command_output "$SSM_COMMAND_ID" "$instance_id" | \
    tr -d '\r' | awk '/^blaktaild [0-9]+\.[0-9]+\.[0-9]+$/ { version = $0 } END { print version }')
  case "$version_output" in
    blaktaild\ *) ;;
    *) die "agent version proof missing for $agent_name" ;;
  esac
  printf '%s\n' "$instance_id $version_output" >>"$install_tmp"
done
mv -- "$install_tmp" "$WORK_DIR/agent-install.ok"
trap - EXIT HUP INT TERM
printf 'agent packages installed through SSM\n'
