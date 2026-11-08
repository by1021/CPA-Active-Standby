#!/usr/bin/env bash
# The real CGI exercises auth/routing/filtering; a fixture CLI isolates its contract.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
mkdir -p "$TEMP/source/"{cgi,bin} "$TEMP/state"
cp "$ROOT/cgi/api.cgi" "$TEMP/source/cgi/api.cgi"
TOKEN=test-fake-enrollment-admin-token-123456789
printf '%s' "$TOKEN" > "$TEMP/state/admin.token"
export ENROLLMENT_FIXTURE_LOG="$TEMP/cli.log"
cat > "$TEMP/source/bin/cpa-dr" <<'CLI'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == --state-dir ]]; shift 2
printf '%s\n' "$*" >> "$ENROLLMENT_FIXTURE_LOG"
[[ $1 == enrollment ]]; shift
case $1 in
 list) printf '{"invites":[{"invite_id":"test-invite","status":"pending","expires_at":"2099-01-01T00:00:00Z","backup_host":"standby-fixture","backup_port":2222,"deployment":"docker","private_key":"test-fake-never-emit","invite_base64":"test-fake-never-emit"}]}\n';;
 create) jq -e '.primary_host=="HOST" and .ttl_seconds==1800' "$2" >/dev/null; printf '{"invite_id":"test-invite","command":"test-fake-install-command","expires_at":"2099-01-01T00:00:00Z","invite":{"private_key":"test-fake-never-emit"},"invite_base64":"test-fake-never-emit"}\n';;
 revoke) [[ $2 == test-invite ]]; printf '{"invite_id":"test-invite","revoked":true}\n';;
 *) exit 1;;
esac
CLI
chmod +x "$TEMP/source/bin/cpa-dr"
cgi() {
 local method=$1 route=$2 token=$3 body=${4:-} origin=${5:-http://localhost}
 printf '%s' "$body" | env CPA_STATE_DIR="$TEMP/state" REQUEST_METHOD="$method" PATH_INFO="$route" HTTP_AUTHORIZATION="$token" HTTP_HOST=localhost HTTP_ORIGIN="$origin" CONTENT_TYPE=application/json CONTENT_LENGTH="${#body}" "$TEMP/source/cgi/api.cgi"
}
body() { sed '1,/^\r$/d'; }
cgi GET /api/enrollment invalid > "$TEMP/result"
grep -q '^Status: 401' "$TEMP/result"
[[ ! -e $ENROLLMENT_FIXTURE_LOG ]]
cgi POST /api/enrollment "Bearer $TOKEN" '{}' https://other.test > "$TEMP/result"
grep -q '^Status: 403' "$TEMP/result"
[[ ! -e $ENROLLMENT_FIXTURE_LOG ]]
cgi GET /api/enrollment "Bearer $TOKEN" > "$TEMP/result"
grep -q '^Status: 200' "$TEMP/result"
body < "$TEMP/result" | jq -e '.invites[0].invite_id=="test-invite" and (.invites[0]|has("private_key")|not)' >/dev/null
[[ $(grep -c test-fake-never-emit "$TEMP/result" || true) == 0 ]]
cgi POST /api/enrollment "Bearer $TOKEN" '{"primary_host":"HOST","ttl_seconds":1800}' > "$TEMP/result"
grep -q '^Status: 200' "$TEMP/result"
body < "$TEMP/result" | jq -e '.command=="test-fake-install-command" and (has("invite")|not) and (has("invite_base64")|not)' >/dev/null
cgi POST /api/enrollment/revoke "Bearer $TOKEN" '{"invite_id":"../secret"}' > "$TEMP/result"
grep -q '^Status: 400' "$TEMP/result"
cgi POST /api/enrollment/revoke "Bearer $TOKEN" '{"invite_id":12}' > "$TEMP/result"
grep -q '^Status: 400' "$TEMP/result"
cgi POST /api/enrollment/revoke "Bearer $TOKEN" '{"invite_id":"test-invite"}' > "$TEMP/result"
grep -q '^Status: 200' "$TEMP/result"
body < "$TEMP/result" | jq -e '.revoked==true' >/dev/null
cgi PUT /api/enrollment "Bearer $TOKEN" '{}' > "$TEMP/result"
grep -q '^Status: 404' "$TEMP/result"
printf 'PASS: real CGI enrollment authentication, same-origin routing, bounded IDs and secret projection\n'
