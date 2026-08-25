#!/bin/sh
set -eu
umask 077
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

validate_base_inputs
for command_name in curl jq stat terraform; do
  require_command "$command_name"
done
assert_stack_identity
[ "$(cat "$STAGE_FILE" 2>/dev/null || true)" = activate ] || die "activated control plane required"

case ${OWNER_EMAIL:-} in
  '' | *[!A-Za-z0-9._+@-]* | *@*@* | @* | *@) die "OWNER_EMAIL must be a valid operator email" ;;
esac
owner_password_file=${OWNER_PASSWORD_FILE:-$WORK_DIR/owner-password}
[ -f "$owner_password_file" ] || die "owner password file is required"
owner_password_mode=$(stat -f '%Lp' "$owner_password_file" 2>/dev/null || stat -c '%a' "$owner_password_file")
case "$owner_password_mode" in 400 | 600) ;; *) die "owner password file mode must be 0400 or 0600" ;; esac
[ -s "$owner_password_file" ] || die "owner password file must not be empty"

public_url=$(tf_output_raw public_url)
case "$public_url" in https://*) ;; *) die "public URL must use HTTPS" ;; esac

signup_request=$(mktemp "$WORK_DIR/auth-signup-request.XXXXXX")
signup_response=$(mktemp "$WORK_DIR/auth-signup-response.XXXXXX")
login_request=$(mktemp "$WORK_DIR/auth-login-request.XXXXXX")
login_response=$(mktemp "$WORK_DIR/auth-login-response.XXXXXX")
cookie_jar=$(mktemp "$WORK_DIR/auth-cookie.XXXXXX")
devices_page=$(mktemp "$WORK_DIR/auth-devices.XXXXXX")
cleanup() {
  rm -f -- "$signup_request" "$signup_response" "$login_request" \
    "$login_response" "$cookie_jar" "$devices_page"
}
trap cleanup EXIT HUP INT TERM

jq -n '{name:"Public signup probe",email:"public-signup-probe@example.test",password:"Probe-only-password-123!"}' \
  >"$signup_request"
signup_status=$(curl --silent --show-error --output "$signup_response" \
  --max-time 20 --write-out '%{http_code}' --header 'content-type: application/json' \
  --data-binary @"$signup_request" "$public_url/api/auth/sign-up/email")
signup_code=$(jq -er '.code // empty' "$signup_response")
[ "$signup_status" = 400 ] || die "public signup returned HTTP $signup_status"
[ "$signup_code" = EMAIL_PASSWORD_SIGN_UP_DISABLED ] || \
  die "public signup did not return the disabled code"

jq -n --arg email "$OWNER_EMAIL" --rawfile password "$owner_password_file" \
  '{email:$email,password:($password | rtrimstr("\n"))}' >"$login_request"
login_status=$(curl --silent --show-error --output "$login_response" \
  --max-time 20 --write-out '%{http_code}' --cookie-jar "$cookie_jar" \
  --header 'content-type: application/json' --data-binary @"$login_request" \
  "$public_url/api/auth/sign-in/email")
[ "$login_status" = 200 ] || die "owner login returned HTTP $login_status"
[ "$(jq -er '.user.email' "$login_response")" = "$OWNER_EMAIL" ] || \
  die "owner login returned the wrong identity"

devices_status=$(curl --silent --show-error --output "$devices_page" \
  --max-time 20 --write-out '%{http_code}' --cookie "$cookie_jar" "$public_url/devices")
[ "$devices_status" = 200 ] || die "authenticated devices page returned HTTP $devices_status"
grep -q '>All networks<' "$devices_page" || die "authenticated all-networks heading missing"
if grep -q '>Sign in<' "$devices_page"; then
  die "authenticated devices request rendered sign-in"
fi

jq -n --arg run_id "$RUN_ID" --arg signup_code "$signup_code" \
  --argjson signup_http_status "$signup_status" \
  --argjson login_http_status "$login_status" \
  --argjson devices_http_status "$devices_status" \
  '{run_id:$run_id,public_signup:{http_status:$signup_http_status,code:$signup_code},
    owner_login:{http_status:$login_http_status},
    authenticated_devices_page:{http_status:$devices_http_status,heading:true}}' \
  >"$WORK_DIR/owner-auth.ok"
chmod 0600 "$WORK_DIR/owner-auth.ok"
printf 'public signup disabled and owner portal login verified\n'
