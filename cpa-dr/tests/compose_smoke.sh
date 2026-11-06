#!/usr/bin/env bash
# Exercise the documented setup + Compose deployment on temporary native data.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
NAME="cpa-native-smoke-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
cleanup() {
  local rc=$?
  if (( rc != 0 )); then docker compose --env-file "$TMP/deployment/.env" -p "$NAME" logs --tail 30 >&2 2>/dev/null || true; fi
  docker compose --env-file "$TMP/deployment/.env" -p "$NAME" down >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
cd "$ROOT"
mkdir "$TMP/data"
printf '{"fixture":true}\n' > "$TMP/data/sample.json"
# Isolated test projects use random high ports, not either live service port.
PORT=$(( 32000 + RANDOM % 8000 )); SSH_PORT=$(( 41000 + RANDOM % 8000 ))
bash scripts/setup.sh --data-dir "$TMP/data" --output "$TMP/deployment" --port "$PORT" --ssh-port "$SSH_PORT" > "$TMP/setup-output"
COMPOSE=(docker compose --env-file "$TMP/deployment/.env" -p "$NAME")
"${COMPOSE[@]}" config --quiet
"${COMPOSE[@]}" up -d --build
for _ in {1..120}; do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
  sleep .5
done
TOKEN=$(< "$TMP/deployment/state-native/admin.token")
BASE="http://127.0.0.1:$PORT"
curl -fsS --max-time 10 -H "Authorization: Bearer $TOKEN" -H "Origin: $BASE" "$BASE/api/status" | jq -e '.phase=="unconfigured"' >/dev/null
KEY=$(cat "$TMP/deployment/state-native/ssh/id_ed25519.pub")
curl -fsS --max-time 10 -H "Authorization: Bearer $TOKEN" -H "Origin: $BASE" -H 'Content-Type: application/json' \
  --data "$(jq -n --arg key "$KEY" '{public_key:$key}')" "$BASE/api/pairing" | jq -e '.trusted==true' >/dev/null
CODE=$(curl -sS --max-time 10 -o "$TMP/cross-origin.json" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H 'Origin: https://fixture.invalid' "$BASE/api/status")
[[ $CODE == 403 ]]
ID=$("${COMPOSE[@]}" ps -q cpa-dr)
for _ in {1..80}; do
  [[ $(docker inspect --format '{{.State.Health.Status}}' "$ID") != healthy ]] || break
  sleep .5
done
[[ $(docker inspect --format '{{.State.Health.Status}}' "$ID") == healthy ]]
[[ $(stat -c %a "$TMP/deployment/.env") == 600 ]]
[[ -f $TMP/deployment/state-native/config.json && -f $TMP/deployment/state-native/ssh/ssh_host_ed25519_key ]]
printf 'PASS: documented native setup + hardened Compose, real CGI authentication, same-origin writes, cross-origin rejection and healthcheck\n'
