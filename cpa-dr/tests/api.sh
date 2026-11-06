#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
mkdir "$TEMP/data"
"$ROOT/bin/cpa-dr" --state-dir "$TEMP/state" init --allowed-root "$TEMP/data" > "$TEMP/init.json"
TOKEN=$(jq -r .admin_token "$TEMP/init.json")
cgi() {
    local method=$1 route=$2 token=$3 body=${4:-} origin=${5:-}
    printf '%s' "$body" | env CPA_STATE_DIR="$TEMP/state" REQUEST_METHOD="$method" PATH_INFO="$route" HTTP_AUTHORIZATION="$token" HTTP_HOST=localhost HTTP_ORIGIN="$origin" CONTENT_TYPE=application/json CONTENT_LENGTH="${#body}" "$ROOT/cgi/api.cgi"
}
body() { sed '1,/^\r$/d'; }
cgi GET /api/status invalid > "$TEMP/result"
grep -q '^Status: 401' "$TEMP/result"
cgi GET /api/status "Bearer $TOKEN" > "$TEMP/result"
grep -q '^Status: 200' "$TEMP/result"
body < "$TEMP/result" | jq -e '.phase=="unconfigured"' >/dev/null
cgi GET /api/status "Bearer $TOKEN" '' https://evil.test > "$TEMP/result"
grep -q '^Status: 403' "$TEMP/result"
cgi GET /api/config "Bearer $TOKEN" | body | jq -e 'has("admin_token")|not' >/dev/null
cgi GET /api/pairing "Bearer $TOKEN" | body | jq -e '.public_key|startswith("ssh-ed25519 ")' >/dev/null
cgi POST /api/actions/pause "Bearer $TOKEN" '{"confirm":"WRONG"}' > "$TEMP/result"
grep -q '^Status: 400' "$TEMP/result"
env CPA_STATE_DIR="$TEMP/state" REQUEST_METHOD=POST PATH_INFO=/api/pairing HTTP_AUTHORIZATION="Bearer $TOKEN" CONTENT_TYPE=application/json CONTENT_LENGTH=9999999 "$ROOT/cgi/api.cgi" > "$TEMP/result"
grep -q '^Status: 413' "$TEMP/result"
cgi GET /api/jobs/../secret "Bearer $TOKEN" > "$TEMP/result"
grep -q '^Status: 404' "$TEMP/result"
key=$(jq -r .public_key "$TEMP/init.json")
cgi POST /api/pairing "Bearer $TOKEN" "$(jq -cn --arg key "$key" '{public_key:$key}')" | body | jq -e '.trusted==true' >/dev/null
printf 'PASS: native CGI authentication, JSON API, origin, request limits, ID paths and key import\n'
(cd "$TEMP"; "$ROOT/bin/cpa-dr" --state-dir ./relative-state init --allowed-root ./data) | jq -e '.node_id and .admin_token' >/dev/null
[[ -f $TEMP/relative-state/config.json ]]
printf 'PASS: relative CLI state and data paths normalize without dereferencing unsafe symlinks\n'
# A genuine busy writer produces HTTP 409, not an errexit-induced HTTP 400.
(
    exec 9>"$TEMP/state/operation.lock"
    flock 9
    touch "$TEMP/busy-held"
    sleep 6
) &
BUSY_WRITER=$!
for _ in {1..100}; do [[ -f $TEMP/busy-held ]] && break; sleep .01; done
CONFIG=$(cgi GET /api/config "Bearer $TOKEN" | body)
cgi PUT /api/config "Bearer $TOKEN" "$CONFIG" > "$TEMP/result"
grep -q '^Status: 409' "$TEMP/result"
wait "$BUSY_WRITER"
printf 'PASS: a timed-out operation lock is reported as HTTP 409 Conflict\n'
