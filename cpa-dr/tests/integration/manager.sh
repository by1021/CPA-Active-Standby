#!/usr/bin/env bash
# All service operations below run against disposable records and tool fixtures.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/tools" "$TMP/data" "$TMP/config/state" "$TMP/native" "$TMP/native-root"
export FIXTURE_LOG="$TMP/commands" FIXTURE_STATE="$TMP/config/state" FIXTURE_MODE=running
export FIXTURE_DATA="$TMP/data" FIXTURE_CONFIG="$TMP/config"
export FIXTURE_CURRENT="$TMP/current"
export PATH="$TMP/tools:$PATH"
: > "$FIXTURE_LOG"
id=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
printf '%s\n' "$id" > "$FIXTURE_STATE/.cpa-dr-install-id"
printf '%s\n' "$id" > "$TMP/native-root/.cpa-dr-install-id"
jq -n --arg config "$TMP/config" --arg state "$FIXTURE_STATE" --arg data "$TMP/data" --arg source "$ROOT" --arg id "$id" \
  '{version:1,managed_by:"cpa-dr-start",deployment:"docker",status:"ready",install_id:$id,data_dir:$data,state_dir:$state,source_root:$source,install_root:"",config_dir:$config,run_dir:"",project_name:"manager-fixture",port:18787,ssh_port:22333,bind_host:"127.0.0.1",read_only:false,initial_config:null,unit_hashes:{}}' > "$TMP/config/.env.docker.json"
printf 'ADMIN_TOKEN=SECRET_TOKEN_DO_NOT_PRINT\n' > "$TMP/config/.env"
printf 'SECRET_TOKEN_DO_NOT_PRINT\n' > "$FIXTURE_STATE/admin.token"
printf '{"node_role":"backup","enabled":false,"sources":[],"peer":{"host":"","node_id":""}}\n' > "$FIXTURE_STATE/config.json"
printf '{"phase":"backup_standby","job":{"running":false},"peer":{"reachable":false},"last_backup":null}\n' > "$FIXTURE_STATE/runtime.json"
cat > "$TMP/tools/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'docker %s\n' "$*" >> "$FIXTURE_LOG"
if [[ -f $FIXTURE_CURRENT ]]; then FIXTURE_MODE=$(cat "$FIXTURE_CURRENT"); fi
[[ ${FIXTURE_MODE:-} != denied ]] || { echo 'permission denied' >&2; exit 1; }
case $1 in
  info) ;;
  ps)
    [[ ${FIXTURE_QUERY_FAIL:-} != ps ]] || exit 13
    [[ $FIXTURE_MODE != absent ]] || exit 0
    echo fixture-container
    [[ $FIXTURE_MODE != multiple ]] || echo fixture-container-2;;
  inspect)
    jq -n --arg state "${FIXTURE_MOUNT_STATE:-$FIXTURE_STATE}" --arg data "$FIXTURE_DATA" --arg mode "$FIXTURE_MODE" --arg service "${FIXTURE_SERVICE:-cpa-dr}" \
      '[{Id:"fixture-container",Config:{Labels:{"com.docker.compose.project":"manager-fixture","com.docker.compose.service":$service}},Mounts:[{Type:"bind",Source:$state,Destination:"/state"},{Type:"bind",Source:$data,Destination:"/data"}],State:{Running:($mode=="running"),Status:(if $mode=="running" then "running" else "exited" end)},NetworkSettings:{Ports:{"8787/tcp":[{HostIp:"127.0.0.1",HostPort:"18787"}],"22/tcp":[{HostIp:"127.0.0.1",HostPort:"22333"}]}}}]';;
  exec)
    shift 2
    [[ $FIXTURE_MODE == running ]] || exit 1
    if [[ $1 == flock ]]; then
      shift; [[ $1 != -n ]] || shift; shift
      exec "$@"
    fi
    if [[ $1 == /opt/cpa-dr/bin/cpa-dr ]]; then
      jq -n --slurpfile c "$FIXTURE_STATE/config.json" --slurpfile r "$FIXTURE_STATE/runtime.json" '$r[0]+{node_role:$c[0].node_role,enabled:$c[0].enabled,peer:($r[0].peer+{configured:false})}'
    elif [[ $1 == cat ]]; then cat "$FIXTURE_STATE/runtime.json"
    else echo "unexpected exec: $*" >&2; exit 9; fi;;
  start|stop|restart)
    [[ ${FIXTURE_FAIL:-} != "$1" ]] || exit 17
    if [[ $1 == stop ]]; then printf 'stopped\n' > "$FIXTURE_CURRENT"; else printf 'running\n' > "$FIXTURE_CURRENT"; fi;;
  logs) echo 'fixture log line';;
  compose)
    shift
    while (($#)); do
      case $1 in --project-directory|--file|--env-file|--project-name) shift 2;; *) break;; esac
    done
    case ${1:-} in
      version) ;;
      up) [[ ${2:-} == --help ]] && echo '--wait --wait-timeout';;
      config)
        if [[ ${2:-} == --format && ${3:-} == json ]]; then
          jq -n --arg state "$FIXTURE_STATE" --arg data "$FIXTURE_DATA" \
            '{services:{"cpa-dr":{environment:{CPA_ADMIN_TOKEN:"SECRET_TOKEN_DO_NOT_PRINT"},volumes:[{type:"bind",source:$data,target:"/data",read_only:false},{type:"bind",source:$state,target:"/state"}],ports:[{target:8787,published:"18787"},{target:22,published:"22333"}]}}}'
        fi;;
      down) printf 'absent\n' > "$FIXTURE_CURRENT";;
      *) echo "unexpected compose: $*" >&2; exit 9;;
    esac;;
  *) echo "unexpected docker: $*" >&2; exit 9;;
esac
MOCK
cat > "$TMP/tools/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl\n' >> "$FIXTURE_LOG"
[[ ${FIXTURE_HEALTH:-ok} == ok ]] || exit 7
if [[ $* == *'/api/status'* ]]; then printf '{"node_role":"backup","enabled":false,"job":{"running":false}}\n'
else printf '{"ok":true}\n'; fi
MOCK
cat > "$TMP/tools/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$FIXTURE_LOG"
case $1 in
  show) printf 'loaded\n';;
  is-active) [[ $FIXTURE_MODE == running ]] && echo active;;
  start|stop|restart) [[ ${FIXTURE_FAIL:-} != "$1" ]];;
  *) exit 9;;
esac
MOCK
cat > "$TMP/tools/timeout" <<'MOCK'
#!/usr/bin/env bash
# Simulate only the SSH banner probe; all other timeouts use the real utility.
if [[ $* == *'/dev/tcp/'* ]]; then exit 0; fi
exec /usr/bin/timeout "$@"
MOCK
chmod +x "$TMP/tools/"*
run() { bash "$ROOT/start.sh" "$@"; }
reject() { if run "$@" > "$TMP/failure" 2>&1; then echo "accepted invalid operation: $*" >&2; exit 1; fi; }
hashes() { find "$TMP/config" -type f -exec sha256sum {} + | sort; }
# Coprocess descriptors are closed in subshells. Verify an explicit release
# reaches the lock holder, rather than relying on Docker forwarding stdin EOF.
# shellcheck source=../../scripts/start-manager.sh
source "$ROOT/scripts/start-manager.sh"
coproc CPA_GUARD {
  printf 'LOCKED\n'
  release=''
  IFS= read -r release || true
  printf '%s\n' "$release" > "$TMP/guard-release"
}
manager_guard_pid=$CPA_GUARD_PID
manager_guard_read=${CPA_GUARD[0]}; manager_guard_write=${CPA_GUARD[1]}
[[ $manager_guard_pid =~ ^[0-9]+$ && $manager_guard_write =~ ^[0-9]+$ ]]
IFS= read -r -t 3 guard_ready <&"$manager_guard_read"
[[ $guard_ready == LOCKED ]]
cpa_manager_release_guard
grep -qx RELEASE "$TMP/guard-release" || { echo 'guard release must send RELEASE explicitly, not subshell/EOF' >&2; exit 1; }
printf 'PASS: coprocess guard receives explicit release before another lifecycle operation\n'
coproc CPA_GUARD { printf 'LOCKED\n'; }
manager_guard_pid=$CPA_GUARD_PID
# Keep ordinary duplicates open after the holder exits to force a broken pipe.
exec {manager_guard_read}<&"${CPA_GUARD[0]}"
exec {manager_guard_write}>&"${CPA_GUARD[1]}"
IFS= read -r -t 3 guard_ready <&"$manager_guard_read"
wait "$manager_guard_pid"
cpa_manager_release_guard
printf 'PASS: releasing a terminated guard contains SIGPIPE without aborting cleanup\n'
before=$(hashes)
run status --output "$TMP/config" > "$TMP/status"
grep -q '运行中' "$TMP/status"
grep -q '备机' "$TMP/status"
if grep -q SECRET_TOKEN "$TMP/status"; then exit 1; fi
[[ $(hashes) == "$before" ]]
if grep -Eq 'docker (start|stop|restart|compose .* (up|build|run))|systemctl (start|stop|restart)' "$FIXTURE_LOG"; then exit 1; fi
FIXTURE_MODE=stopped run status --output "$TMP/config" > "$TMP/stopped"
grep -q '已停止' "$TMP/stopped"
FIXTURE_MODE=denied run status --output "$TMP/config" > "$TMP/unknown"
grep -q '未知' "$TMP/unknown"
run status --output "$TMP/missing" > "$TMP/missing.out"
grep -q '未安装' "$TMP/missing.out"
[[ ! -e $TMP/missing ]]
printf 'not json\n' > "$TMP/config/.env.native.json"
reject stop --output "$TMP/config" --yes
rm "$TMP/config/.env.native.json"
printf 'PASS: read-only status separates records/runtime, masks secrets, handles missing/denied/ambiguous targets\n'

run doctor --output "$TMP/config" > "$TMP/doctor"
grep -q '依赖' "$TMP/doctor"
[[ $(hashes) == "$before" ]]
run logs --output "$TMP/config" --tail 5 > "$TMP/logs"
grep -q 'fixture log line' "$TMP/logs"
reject logs --output "$TMP/config" --tail invalid
reject status --output "$TMP/config" --role primary
reject status --output "$TMP/config" --tail 50
reject install status --output "$TMP/config"
printf 'PASS: diagnostic/log commands and strict action/options dispatch\n'

pty=$(printf '%q ' bash "$ROOT/start.sh" menu --output "$TMP/missing")
printf 'bad\n3\n5\n0\n' | script -q -e -c "$pty" /dev/null > "$TMP/menu" 2>&1
grep -q '安装 / 恢复已有安装' "$TMP/menu"
grep -q '未安装' "$TMP/menu"
[[ ! -e $TMP/missing ]]
reject menu --output "$TMP/config" < /dev/null
reject stop --output "$TMP/config" < /dev/null
mkdir "$TMP/source"
cp "$ROOT/start.sh" "$TMP/source/"
cp -a "$ROOT/scripts" "$ROOT/lib" "$TMP/source/"
if ((EUID == 0)) && command -v setpriv >/dev/null; then
  mkdir -p "$TMP/private/config"
  cp "$TMP/config/.env.docker.json" "$TMP/private/config/"
  chmod 755 "$TMP" "$TMP/source" "$TMP/tools"
  chmod -R a+rX "$TMP/source"
  chmod 700 "$TMP/private"
  setpriv --reuid 65534 --regid 65534 --clear-groups bash "$TMP/source/start.sh" status --output "$TMP/private/config" > "$TMP/ancestor-denied"
  grep -q '状态未知' "$TMP/ancestor-denied" || { echo 'inaccessible ancestor reported as uninstalled, expected unknown' >&2; cat "$TMP/ancestor-denied" >&2; exit 1; }
  if grep -q '未安装' "$TMP/ancestor-denied"; then exit 1; fi
  printf 'PASS: non-root status reports inaccessible ancestors as unknown, not uninstalled\n'
fi
bare=$(printf '%q ' bash "$TMP/source/start.sh")
printf '0\n' | script -q -e -c "$bare" /dev/null > "$TMP/bare-menu" 2>&1
grep -q 'CPA 主备备份服务管理' "$TMP/bare-menu"
reject < /dev/null
mkdir "$TMP/minimal"
ln -s "$(command -v bash)" "$TMP/minimal/bash"
PATH="$TMP/minimal" /usr/bin/bash "$ROOT/start.sh" status --output "$TMP/missing" > "$TMP/no-jq"
grep -q '未知' "$TMP/no-jq"
[[ ! -e $TMP/missing ]]
printf 'PASS: PTY menu invalid-input, unavailable action, return and exit without writes\n'

: > "$FIXTURE_LOG"
printf 'running\n' > "$FIXTURE_CURRENT"
run stop --output "$TMP/config" --yes > "$TMP/stop"
grep -q '^docker stop ' "$FIXTURE_LOG"
run restart --output "$TMP/config" --yes > "$TMP/restart"
grep -q '^docker start ' "$FIXTURE_LOG"
printf 'stopped\n' > "$FIXTURE_CURRENT"
run start --output "$TMP/config" --yes > "$TMP/start"
grep -q '^docker start ' "$FIXTURE_LOG"
jq '.job.running=true' "$FIXTURE_STATE/runtime.json" > "$TMP/busy"
cp "$TMP/busy" "$FIXTURE_STATE/runtime.json"
: > "$FIXTURE_LOG"
reject stop --output "$TMP/config" --yes
if grep -q '^docker stop ' "$FIXTURE_LOG"; then exit 1; fi
pty=$(printf '%q ' bash "$ROOT/start.sh" menu --output "$TMP/config")
printf '5\n2\ny\n0\n' | script -q -e -c "$pty" /dev/null > "$TMP/failed-menu" 2>&1
grep -q '返回菜单' "$TMP/failed-menu"
if grep -q '^docker stop ' "$FIXTURE_LOG"; then exit 1; fi
reject uninstall --output "$TMP/config" --yes
grep -q '正在运行备份/恢复任务' "$TMP/failure"
if grep -q ' down ' "$FIXTURE_LOG"; then exit 1; fi
jq '.job.running=false' "$FIXTURE_STATE/runtime.json" > "$TMP/idle"
cp "$TMP/idle" "$FIXTURE_STATE/runtime.json"
FIXTURE_FAIL=stop reject stop --output "$TMP/config" --yes
exec {busy_fd}> "$FIXTURE_STATE/operation.lock"
flock -n "$busy_fd"
: > "$FIXTURE_LOG"
reject stop --output "$TMP/config" --yes
if grep -q '^docker stop ' "$FIXTURE_LOG"; then exit 1; fi
exec {busy_fd}>&-
rm "$FIXTURE_STATE/operation.lock"
: > "$FIXTURE_LOG"
FIXTURE_MOUNT_STATE="$TMP/unrelated-state" run status --output "$TMP/config" > "$TMP/wrong-mount"
grep -q '挂载与安装记录不符' "$TMP/wrong-mount"
FIXTURE_MOUNT_STATE="$TMP/unrelated-state" reject uninstall --output "$TMP/config" --yes
grep -q '容器归属未知' "$TMP/failure"
if grep -q ' down ' "$FIXTURE_LOG"; then exit 1; fi
FIXTURE_SERVICE=unrelated reject uninstall --output "$TMP/config" --yes
grep -q '容器归属未知' "$TMP/failure"
if grep -q ' down ' "$FIXTURE_LOG"; then exit 1; fi
FIXTURE_QUERY_FAIL='ps' reject uninstall --output "$TMP/config" --yes
grep -q '容器归属未知' "$TMP/failure"
FIXTURE_MODE=multiple FIXTURE_CURRENT="$TMP/no-current" reject uninstall --output "$TMP/config" --yes
grep -q '容器归属未知' "$TMP/failure"
if grep -q ' down ' "$FIXTURE_LOG"; then exit 1; fi
printf 'PASS: readable host runtime does not bypass Docker uninstall mount/label ownership\n'
cp "$TMP/config/.env.docker.json" "$TMP/original-record"
mv "$FIXTURE_STATE/runtime.json" "$TMP/idle-runtime"
printf 'absent\n' > "$FIXTURE_CURRENT"
for record_status in pending ready uninstalled; do
  jq --arg status "$record_status" '.status=$status' "$TMP/original-record" > "$TMP/config/.env.docker.json"
  run uninstall --output "$TMP/config" --yes > "$TMP/absent-uninstall"
  jq -e '.status=="uninstalled"' "$TMP/config/.env.docker.json" >/dev/null
done
cp "$TMP/original-record" "$TMP/config/.env.docker.json"
mv "$TMP/idle-runtime" "$FIXTURE_STATE/runtime.json"
printf 'running\n' > "$FIXTURE_CURRENT"
printf 'PASS: pending/ready/uninstalled records without containers or runtime can still be cleaned up\n'
printf 'preserve secret fixture\n' > "$TMP/protected"
ln -s "$TMP/protected" "$FIXTURE_STATE/operation.lock"
reject stop --output "$TMP/config" --yes
grep -qx 'preserve secret fixture' "$TMP/protected"
printf 'PASS: existing-container controls require confirmation, reject busy jobs and propagate stop failure\n'
