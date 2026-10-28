#!/bin/sh
set -eu
body=$(mktemp)
trap 'rm -f "$body"' EXIT HUP INT TERM
status=$(curl --silent --show-error --max-time 10 --output "$body" --write-out '%{http_code}' \
  --header 'X-Forwarded-Proto: https' http://127.0.0.1:4000/api/health)
test "$status" = 200
grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' "$body"
grep -Eq '"service"[[:space:]]*:[[:space:]]*"itsm_backend"' "$body"
# This is Phoenix liveness, not downstream AI/provider acceptance.
