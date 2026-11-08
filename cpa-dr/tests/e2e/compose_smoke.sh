#!/usr/bin/env bash
# Exercise the one-command installer and repeat deployment on temporary data.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../integration/installer_fixture.sh
source "$ROOT/tests/installer_fixture.sh"
TMP=$(mktemp -d)
NAME="cpa-native-smoke-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
cleanup() {
  local rc=$?
  if (( rc != 0 )); then docker compose --env-file "$TMP/deployment/.env" -p "$NAME" logs --tail 30 >&2 2>/dev/null || true; fi
  if [[ -f $TMP/foreign.yaml ]]; then docker compose -f "$TMP/foreign.yaml" -p "$NAME" down >/dev/null 2>&1 || true; fi
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
COMPOSE=(docker compose --env-file "$TMP/deployment/.env" -p "$NAME")
COMPOSE_PROJECT_NAME="$NAME" bash "$ROOT/start.sh" --role backup --deployment docker --data-dir "$TMP/data" --source sample:file:sample.json --output "$TMP/deployment" --port "$PORT" --ssh-port "$SSH_PORT" > "$TMP/start-output"
"${COMPOSE[@]}" config --quiet
identity_before=$(sha256sum "$TMP/deployment/.env" "$TMP/deployment/state-native/admin.token" "$TMP/deployment/state-native/ssh/id_ed25519")
node_before=$(jq -r .node_id "$TMP/deployment/state-native/config.json")
COMPOSE_PROJECT_NAME="$NAME" bash "$ROOT/start.sh" --role backup --deployment docker --data-dir "$TMP/data" --source sample:file:sample.json --output "$TMP/deployment" --port "$PORT" --ssh-port "$SSH_PORT" > "$TMP/repeat-output"
[[ $(sha256sum "$TMP/deployment/.env" "$TMP/deployment/state-native/admin.token" "$TMP/deployment/state-native/ssh/id_ed25519") == "$identity_before" ]]
[[ $(jq -r .node_id "$TMP/deployment/state-native/config.json") == "$node_before" ]]
grep -q "http://127.0.0.1:$PORT" "$TMP/start-output"
grep -q '服务已启动' "$TMP/repeat-output"
bash "$ROOT/start.sh" status --output "$TMP/deployment" > "$TMP/status-output"
grep -q '服务状态：运行中' "$TMP/status-output"
grep -q '管理 API：正常' "$TMP/status-output"
cpa_test_idle_operation bash "$ROOT/start.sh" stop --yes --output "$TMP/deployment" > "$TMP/stop-output"
cpa_test_idle_operation timeout 30 bash "$ROOT/start.sh" start --yes --output "$TMP/deployment" > "$TMP/start-control-output"
cpa_test_idle_operation timeout 30 bash "$ROOT/start.sh" restart --yes --output "$TMP/deployment" > "$TMP/restart-output"
[[ $(sha256sum "$TMP/deployment/.env" "$TMP/deployment/state-native/admin.token" "$TMP/deployment/state-native/ssh/id_ed25519") == "$identity_before" ]]
printf 'PASS: real root Docker status/stop/start/restart without initialization lock deadlock\n'
for _ in {1..120}; do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
  sleep .5
done
TOKEN=$(< "$TMP/deployment/state-native/admin.token")
BASE="http://127.0.0.1:$PORT"
curl -fsS --max-time 10 -H "Authorization: Bearer $TOKEN" -H "Origin: $BASE" "$BASE/api/status" | jq -e '.phase=="backup_standby" and .node_role=="backup" and .enabled==false' >/dev/null
curl -fsS --max-time 10 -H "Authorization: Bearer $TOKEN" -H "Origin: $BASE" "$BASE/api/config" | jq -e '.sources==[{name:"sample",kind:"file",path:"/data/sample.json"}]' >/dev/null
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
COMPOSE_PROJECT_NAME="$NAME" cpa_test_idle_operation bash "$ROOT/start.sh" uninstall --output "$TMP/deployment" --yes > "$TMP/uninstall-output"
[[ -f $TMP/deployment/.env && -f $TMP/deployment/state-native/config.json && -f $TMP/data/sample.json ]]
[[ -z $("${COMPOSE[@]}" ps -q) ]]
# Reproduce a same-project/service collision using real Compose labels but
# different mounts. A readable host runtime must not authorize its removal.
mkdir "$TMP/foreign-state" "$TMP/foreign-data"
cat > "$TMP/foreign.yaml" <<YAML
services:
  cpa-dr:
    image: cpa-dr:native
    entrypoint: ["sleep", "600"]
    volumes:
      - "$TMP/foreign-state:/state"
      - "$TMP/foreign-data:/data"
YAML
FOREIGN=(docker compose -f "$TMP/foreign.yaml" -p "$NAME")
"${FOREIGN[@]}" up -d > "$TMP/foreign-up.out" 2>&1
FOREIGN_ID=$("${FOREIGN[@]}" ps --all -q cpa-dr)
[[ -n $FOREIGN_ID && -r $TMP/deployment/state-native/runtime.json ]]
jq '.status="ready"' "$TMP/deployment/.env.docker.json" > "$TMP/record.new"
mv "$TMP/record.new" "$TMP/deployment/.env.docker.json"
bash "$ROOT/start.sh" status --output "$TMP/deployment" > "$TMP/foreign-status"
grep -q '挂载与安装记录不符' "$TMP/foreign-status"
for purge_flag in '' --purge; do
  flags=(); [[ -z $purge_flag ]] || flags+=("$purge_flag")
  if bash "$ROOT/start.sh" uninstall "${flags[@]}" --output "$TMP/deployment" --yes > "$TMP/foreign-rejected" 2>&1; then
    echo 'uninstall accepted foreign container despite readable host runtime' >&2; exit 1
  fi
  grep -q '容器归属未知' "$TMP/foreign-rejected"
  [[ $(docker inspect --format '{{.State.Running}}' "$FOREIGN_ID") == true ]]
  jq -e '.status=="ready"' "$TMP/deployment/.env.docker.json" >/dev/null
  [[ -f $TMP/deployment/state-native/config.json && -f $TMP/deployment/.env ]]
done
"${FOREIGN[@]}" down > "$TMP/foreign-down.out" 2>&1
jq '.status="uninstalled"' "$TMP/deployment/.env.docker.json" > "$TMP/record.new"
mv "$TMP/record.new" "$TMP/deployment/.env.docker.json"
printf 'PASS: real Docker uninstall/purge preserve a same-label foreign container with mismatched mounts and readable host runtime\n'
COMPOSE_PROJECT_NAME="$NAME" bash "$ROOT/start.sh" --output "$TMP/deployment" > "$TMP/reinstall-output"
[[ $(jq -r .node_id "$TMP/deployment/state-native/config.json") == "$node_before" ]]
COMPOSE_PROJECT_NAME="$NAME" cpa_test_idle_operation bash "$ROOT/start.sh" uninstall --purge --output "$TMP/deployment" --yes > "$TMP/purge-output"
[[ ! -e $TMP/deployment/.env && ! -e $TMP/deployment/state-native && -f $TMP/data/sample.json ]]
printf 'PASS: real Docker role/data bootstrap, health/authentication, private identity preservation, uninstall/reinstall and purge without deleting original data\n'
