#!/bin/sh
# Operator smoke for /api/v1 against a disposable coordinator.
set -eu
BASE=${1:?usage: admin-api-smoke.sh BASE_URL ORG_ID TOKEN}
ORG=${2:?usage: admin-api-smoke.sh BASE_URL ORG_ID TOKEN}
TOKEN=${3:?usage: admin-api-smoke.sh BASE_URL ORG_ID TOKEN}

auth() {
  curl --fail --silent --show-error \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-BlakTail-Organisation: $ORG" \
    -H "content-type: application/json" \
    "$@"
}

auth "$BASE/api/v1/status" | grep -q '"api":"v1"'
first=$(auth -X POST -H 'Idempotency-Key: smoke-key-1' \
  -d '{"expires_in_seconds":60}' "$BASE/api/v1/keys")
second=$(auth -X POST -H 'Idempotency-Key: smoke-key-1' \
  -d '{"expires_in_seconds":60}' "$BASE/api/v1/keys")
printf '%s\n%s\n' "$first" "$second" | awk 'NR==1 {a=$0} NR==2 {exit !(a==$0)}'
printf 'admin API smoke passed\n'
