#!/usr/bin/env bash
# Public bootstrap with fixture HTTPS, real Docker, and stable management entries.
# No production services, real GitHub requests, or host systemd changes.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROJECT=$(dirname -- "$ROOT")
# shellcheck source=../integration/installer_fixture.sh
source "$ROOT/tests/integration/installer_fixture.sh"
TMP=$(mktemp -d)
NAME="cpa-location-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
cleanup_project() {
  local cid owner
  while IFS= read -r cid; do
    [[ -z $cid ]] || docker rm -f "$cid" >/dev/null 2>&1 || true
  done < <(docker ps -aq --filter "label=com.docker.compose.project=$NAME")
  owner=$(timeout 10 docker network inspect --format '{{ index .Labels "com.docker.compose.project" }}' "${NAME}_default" 2>/dev/null) || return 0
  [[ $owner == "$NAME" ]] || return 0
  timeout 10 docker network rm "${NAME}_default" >/dev/null 2>&1 || true
}
cleanup() {
  local rc=$?
  cleanup_project
  if ((rc)); then
    printf 'FAIL: public installer runtime; sanitized output follows\n' >&2
    for file in "$TMP"/*.out; do
      [[ ! -f $file ]] || grep -Ev '管理员令牌|^bash -c|^ssh-ed25519' "$file" | tail -18 >&2 || true
    done
  fi
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
COMMIT=1111111111111111111111111111111111111111
export FIXTURE="$TMP" GITHUB_HELPER="$ROOT/scripts/packaging/github.sh" COMMIT
export HOME="$TMP/home" COMPOSE_PROJECT_NAME="$NAME"
mkdir -p "$TMP/bin" "$HOME" "$TMP/run" "$TMP/elsewhere" "$TMP/data"
ln -s "$TMP/run" "$TMP/logical-run"
printf '{"fixture":"public-bootstrap"}\n' > "$TMP/data/sample.json"
mkdir -p "$TMP/repo/CPA-Active-Standby-$COMMIT"
cp -a "$ROOT" "$TMP/repo/CPA-Active-Standby-$COMMIT/cpa-dr"
tar -czf "$TMP/source.tar.gz" -C "$TMP/repo" "CPA-Active-Standby-$COMMIT"
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
arguments=("$@")
url='' output=''
while (($#)); do
  case $1 in
    -o|--output) output=$2; shift 2;;
    -H|--header|--connect-timeout|--max-time|--retry|--max-filesize|--proto|--proto-redir) shift 2;;
    https://*) url=$1; shift;;
    *) shift;;
  esac
done
case $url in
  https://api.github.com/repos/by1021/CPA-Active-Standby/commits/main)
    printf '%s\n' "$url" >> "$FIXTURE/requests"; printf '%s\n' "$COMMIT";;
  "https://raw.githubusercontent.com/by1021/CPA-Active-Standby/$COMMIT/cpa-dr/scripts/packaging/github.sh")
    printf '%s\n' "$url" >> "$FIXTURE/requests"; cp "$GITHUB_HELPER" "$output";;
  "https://raw.githubusercontent.com/by1021/CPA-Active-Standby/$COMMIT/cpa-dr/scripts/packaging/location.sh")
    printf '%s\n' "$url" >> "$FIXTURE/requests"; cp "${GITHUB_HELPER%/*}/location.sh" "$output";;
  "https://codeload.github.com/by1021/CPA-Active-Standby/tar.gz/$COMMIT")
    printf '%s\n' "$url" >> "$FIXTURE/requests"; cp "$FIXTURE/source.tar.gz" "$output";;
  https://*) printf 'unexpected external request: %s\n' "$url" >&2; exit 1;;
  *) exec /usr/bin/curl "${arguments[@]}";;
esac
CURL
chmod 755 "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
PORT=$((32000 + RANDOM % 7000)); SSH_PORT=$((41000 + RANDOM % 7000))
(
  cd "$TMP/logical-run"
  [[ $PWD == "$TMP/logical-run" ]]
  bash "$PROJECT/install.sh" --deployment docker --data-dir "$TMP/data" \
    --source sample:file:sample.json --port "$PORT" --ssh-port "$SSH_PORT" \
    --ssh-bind-host 0.0.0.0 --yes --generate-backup \
    --primary-host 127.0.0.1 --primary-port "$SSH_PORT" \
    --backup-host backup-fixture --backup-port 2222 --backup-bind-host 0.0.0.0 \
    --backup-data-dir /fixture/data --backup-deployment native --no-auto-enable
) > "$TMP/install.out" 2>&1
SITE="$TMP/run/cpa-dr"
[[ -f $SITE/start.sh && -f $TMP/run/start.sh && -f $SITE/install.json ]]
SOURCE=$(jq -r .source_root "$SITE/install.json")
CONFIG=$(jq -r .config_dir "$SITE/install.json")
[[ $SOURCE == "$SITE/releases/$COMMIT/cpa-dr" && $CONFIG == "$SITE/config" ]]
COMPOSE=(docker compose --project-directory "$SOURCE" --file "$SOURCE/compose.yaml" --env-file "$CONFIG/.env" --project-name "$NAME")
CID=$("${COMPOSE[@]}" ps --all --quiet cpa-dr)
[[ -n $CID ]]
STATE=$(jq -r .state_dir "$CONFIG/.env.docker.json")
grep -Fxq "状态目录：$STATE" "$TMP/install.out"
identity=$(sha256sum "$CONFIG/.env" "$STATE/admin.token" "$STATE/ssh/id_ed25519" "$STATE/ssh/ssh_host_ed25519_key")
node=$(jq -r .node_id "$STATE/config.json")
docker exec "$CID" /opt/cpa-dr/bin/cpa-dr --state-dir /state enrollment list > "$TMP/invites.json"
jq -e '.invites|length==1 and .[0].status=="issued"' "$TMP/invites.json" >/dev/null
printf 'PASS: public GitHub bootstrap creates current-directory project and noninteractive invitation with real Docker\n'
(
  cd "$TMP/run"
  bash start.sh status > "$TMP/current.out"
  printf '3\n0\n' | script -q -e -c 'bash start.sh' /dev/null > "$TMP/menu.out"
  cd "$SITE"
  bash start.sh status > "$TMP/project.out"
  cd "$TMP/elsewhere"
  bash "$TMP/run/start.sh" status > "$TMP/cross.out"
  bash "$SITE/start.sh" status --output "$CONFIG" > "$TMP/explicit.out"
  bash "$SOURCE/start.sh" status > "$TMP/source.out"
  bash "$SITE/start.sh" logs --tail 2 > "$TMP/logs.out"
)
for file in current project cross explicit source menu; do
  grep -q '服务状态：运行中' "$TMP/$file.out"
  if grep -q "$(cat "$STATE/admin.token")" "$TMP/$file.out"; then
    echo 'management entry printed administrator token' >&2; exit 1
  fi
done
printf 'PASS: current/project/source/cross-directory entries locate the installed deployment; menu masks secrets\n'
before=$(wc -l < "$TMP/requests")
config_before=$(sha256sum "$STATE/config.json")
(
  cd "$TMP/run"
  bash "$PROJECT/install.sh" --yes
) > "$TMP/repeat.out" 2>&1
[[ $(wc -l < "$TMP/requests") == "$before" ]]
[[ $(sha256sum "$CONFIG/.env" "$STATE/admin.token" "$STATE/ssh/id_ed25519" "$STATE/ssh/ssh_host_ed25519_key") == "$identity" ]]
[[ $(sha256sum "$STATE/config.json") == "$config_before" ]]
[[ $(jq -r .node_id "$STATE/config.json") == "$node" ]]
[[ $("${COMPOSE[@]}" ps --all --quiet cpa-dr) == "$CID" ]]
docker exec "$CID" /opt/cpa-dr/bin/cpa-dr --state-dir /state enrollment list | jq -e '.invites|length==1' >/dev/null
printf 'PASS: installer rerun uses pinned existing deployment without network, duplicate invitation or identity reset\n'
cpa_test_idle_operation bash "$SITE/start.sh" stop --yes > "$TMP/stop.out" 2>&1
bash "$TMP/run/start.sh" status > "$TMP/stopped.out"
grep -q '已安装' "$TMP/stopped.out"; grep -q '已停止' "$TMP/stopped.out"
cpa_test_idle_operation bash "$SITE/start.sh" start --yes > "$TMP/start.out" 2>&1
bash "$SITE/start.sh" status > "$TMP/started.out"
grep -q '服务状态：运行中' "$TMP/started.out"
[[ $(sha256sum "$CONFIG/.env" "$STATE/admin.token" "$STATE/ssh/id_ed25519" "$STATE/ssh/ssh_host_ed25519_key") == "$identity" ]]
[[ $(jq -r .node_id "$STATE/config.json") == "$node" ]]
printf 'PASS: stable entries stop/start the same real container and preserve private identity\n'
cpa_test_idle_operation bash "$SITE/start.sh" uninstall --yes > "$TMP/uninstall.out" 2>&1
[[ -f $STATE/config.json && -f $CONFIG/.env && -f $TMP/data/sample.json ]]
printf 'PASS: stable-entry uninstall preserves original data, configuration and history\n'

# A real purge removes managed state and leaves a receipt. Reinstall must
# finish with the fresh actual identity and usable stable/source status entries.
old_install_id=$(jq -r .install_id "$SITE/install.json")
data_before=$(sha256sum "$TMP/data/sample.json")
requests_before=$(wc -l < "$TMP/requests")
cpa_test_idle_operation bash "$SITE/start.sh" uninstall --purge --yes > "$TMP/purge.out" 2>&1
jq -e --arg id "$old_install_id" '.status=="purged" and .install_id==$id' "$SITE/install.json" >/dev/null
[[ ! -e $CONFIG/.env.docker.json && ! -e $CONFIG/.env.native.json && ! -e $CONFIG/.env && ! -e $STATE/config.json ]]
[[ $(sha256sum "$TMP/data/sample.json") == "$data_before" ]]
bash "$SITE/start.sh" install --role primary --deployment docker --data-dir "$TMP/data" \
  --source sample:file:sample.json --port "$PORT" --ssh-port "$SSH_PORT" \
  --ssh-bind-host 0.0.0.0 --yes > "$TMP/purged-reinstall.out" 2>&1
new_install_id=$(jq -r .install_id "$CONFIG/.env.docker.json")
[[ $new_install_id != "$old_install_id" && $(wc -l < "$TMP/requests") == "$requests_before" ]]
jq -e --arg id "$new_install_id" '.install_id==$id and .status==null' "$SITE/install.json" >/dev/null
bash "$SITE/start.sh" status > "$TMP/purged-reinstalled-status.out"
bash "$SOURCE/start.sh" status > "$TMP/purged-reinstalled-source-status.out"
for file in purged-reinstalled-status purged-reinstalled-source-status; do
  grep -q '安装状态：已安装' "$TMP/$file.out"; grep -q '服务状态：运行中' "$TMP/$file.out"
done
[[ $(sha256sum "$TMP/data/sample.json") == "$data_before" ]]
cpa_test_idle_operation bash "$SITE/start.sh" uninstall --yes > "$TMP/reinstalled-uninstall.out" 2>&1
[[ -f $STATE/config.json && -f $CONFIG/.env && $(sha256sum "$TMP/data/sample.json") == "$data_before" ]]
printf 'PASS: real stable purge/reinstall registers a fresh ID, preserves original data and restores stable/source status without download\n'

# Recreate a genuine pre-layout GitHub deployment, not a new-source lookalike.
# Tests run in a Git checkout; the approved old service has no location helpers.
BASELINE=5282bd97ce566192f84684dee9e4f53942e93a23
mkdir -p "$TMP/old-build" "$HOME/.local/share/cpa-dr/github/$COMMIT" "$TMP/legacy-run"
git -C "$PROJECT" archive "$BASELINE" cpa-dr | tar -xf - -C "$TMP/old-build"
jq -cn --arg commit "$COMMIT" '{format_version:1,repository:"by1021/CPA-Active-Standby",commit:$commit}' \
  > "$TMP/old-build/cpa-dr/scripts/packaging/github-source.json"
bash "$ROOT/scripts/packaging/build-install-bundle.sh" "$TMP/old-build/cpa-dr" "$TMP/old-bundle.tar" > "$TMP/old-bundle.json"
tar -xf "$TMP/old-bundle.tar" -C "$HOME/.local/share/cpa-dr/github/$COMMIT"
OLD_SOURCE="$HOME/.local/share/cpa-dr/github/$COMMIT/cpa-dr"
OLD_CONFIG="$HOME/.local/share/cpa-dr/deployments/primary"
[[ ! -e $OLD_SOURCE/scripts/packaging/location.sh && ! -e $OLD_SOURCE/scripts/packaging/manage.sh ]]
bash "$OLD_SOURCE/start.sh" --role primary --deployment docker --data-dir "$TMP/data" \
  --source sample:file:sample.json --port "$PORT" --ssh-port "$SSH_PORT" \
  --ssh-bind-host 0.0.0.0 --output "$OLD_CONFIG" --yes > "$TMP/old-install.out" 2>&1
COMPOSE=(docker compose --project-directory "$OLD_SOURCE" --file "$OLD_SOURCE/compose.yaml" --env-file "$OLD_CONFIG/.env" --project-name "$NAME")
OLD_CID=$("${COMPOSE[@]}" ps --all --quiet cpa-dr)
OLD_STATE=$(jq -r .state_dir "$OLD_CONFIG/.env.docker.json")
old_identity=$(sha256sum "$OLD_CONFIG/.env" "$OLD_CONFIG/.env.docker.json" "$OLD_STATE/admin.token" "$OLD_STATE/ssh/id_ed25519" "$OLD_STATE/ssh/ssh_host_ed25519_key" "$OLD_STATE/config.json")
old_source_hash=$(sha256sum "$OLD_SOURCE/start.sh" "$OLD_SOURCE/install-manifest.json")
before=$(grep -c 'codeload.github.com' "$TMP/requests")
(
  cd "$TMP/legacy-run"
  bash "$PROJECT/install.sh" --output "$OLD_CONFIG" --yes
) > "$TMP/adopt.out" 2>&1
grep -Fxq "状态目录：$OLD_STATE" "$TMP/adopt.out"
[[ $(grep -c 'codeload.github.com' "$TMP/requests") == "$before" ]]
[[ $(sha256sum "$OLD_CONFIG/.env" "$OLD_CONFIG/.env.docker.json" "$OLD_STATE/admin.token" "$OLD_STATE/ssh/id_ed25519" "$OLD_STATE/ssh/ssh_host_ed25519_key" "$OLD_STATE/config.json") == "$old_identity" ]]
[[ $(sha256sum "$OLD_SOURCE/start.sh" "$OLD_SOURCE/install-manifest.json") == "$old_source_hash" ]]
[[ $("${COMPOSE[@]}" ps --all --quiet cpa-dr) == "$OLD_CID" ]]
bash "$TMP/legacy-run/start.sh" status > "$TMP/adopt-status.out"
grep -q '服务状态：运行中' "$TMP/adopt-status.out"
jq -e --arg source "$OLD_SOURCE" --arg config "$OLD_CONFIG" '.source_root==$source and .config_dir==$config' \
  "$TMP/legacy-run/cpa-dr/install.json" >/dev/null
printf 'PASS: genuine old-version hidden deployment gains a stable entry without source redownload, restart, source mutation or identity reset\n'
cleanup_project
remaining=$(timeout 10 docker network ls --filter "name=^${NAME}_default$" --format '{{.Name}}')
if [[ -n $remaining ]]; then
  printf 'FAIL: project cleanup left Compose network %s\n' "${NAME}_default" >&2; exit 1
fi
printf 'PASS: exact-project cleanup leaves no Compose default network\n'
