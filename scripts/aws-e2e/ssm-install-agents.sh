#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in aws jq terraform; do
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
command -v aws >/dev/null 2>&1 || { echo 'AWS CLI missing on agent' >&2; exit 1; }
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait >/dev/null
fi
work=$(mktemp -d /var/tmp/blaktail-package.XXXXXX)
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT HUP INT TERM

aws s3 cp "s3://$ARTIFACT_BUCKET/$RUN_ID/SHA256SUMS" "$work/SHA256SUMS" --only-show-errors
if [ -f /etc/debian_version ]; then
  package=blaktaild-aarch64-unknown-linux-gnu.deb
  aws s3 cp "s3://$ARTIFACT_BUCKET/$RUN_ID/$package" "$work/$package" --only-show-errors
  (cd "$work" && sha256sum --check --ignore-missing SHA256SUMS)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq iproute2 wireguard-tools iptables iputils-ping jq procps openssh-server
  dpkg -i "$work/$package"
  ssh_service=ssh
else
  package=blaktaild-aarch64-unknown-linux-gnu.rpm
  aws s3 cp "s3://$ARTIFACT_BUCKET/$RUN_ID/$package" "$work/$package" --only-show-errors
  (cd "$work" && sha256sum --check --ignore-missing SHA256SUMS)
  dnf install -y -q "$work/$package" iputils jq openssh-server
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

for agent_name in ubuntu al2023; do
  instance_id=$(printf '%s' "$instance_json" | jq -er --arg key "$agent_name" '.[$key]')
  assert_ssm_online "$instance_id"
  remote_script="RUN_ID=$RUN_ID
ARTIFACT_BUCKET=$artifact_bucket
$remote_body"
  ssm_send_script "$instance_id" "BlakTail E2E package install $RUN_ID" "$remote_script"
  wait_ssm_command "$SSM_COMMAND_ID" "$instance_id"
  version_output=$(ssm_command_output "$SSM_COMMAND_ID" "$instance_id" | tail -n 1)
  case "$version_output" in
    blaktaild\ *) ;;
    *) die "agent version proof missing for $agent_name" ;;
  esac
  printf '%s\n' "$instance_id $version_output" >>"$WORK_DIR/agent-install.ok"
done
printf 'agent packages installed through SSM\n'
