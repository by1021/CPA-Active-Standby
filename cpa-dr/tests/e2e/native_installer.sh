#!/usr/bin/env bash
# Real native processes and installer in a disposable container, not host systemd.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
cat > "$TMP/run.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -Eeuo pipefail
export MOCK_ROOT=/opt/cpa-native-fixture MOCK_STATE=/var/lib/cpa-native-fixture MOCK_CFG=/etc/cpa-native-fixture
trap 'rc=$?; printf "native fixture failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2; for out in /tmp/status.out /tmp/sshd.log /tmp/stopped-status.out /tmp/stop-control.out /tmp/start-control.out /tmp/restart-control.out; do [[ ! -f $out ]] || tail -30 "$out" >&2; done; grep -E "^(Port|ListenAddress) " "$MOCK_CFG/sshd.conf" >&2 || true; exit "$rc"' ERR
export MOCK_PORT=18878 MOCK_SYSTEMCTL_LOG=/tmp/systemctl.log
mkdir -p /fixture/data/auths /etc/systemd/system /usr/local/bin
printf '{"fixture":true}\n' > /fixture/data/settings.json
sqlite3 /fixture/data/usage.sqlite 'CREATE TABLE sample(value TEXT);'
: > "$MOCK_SYSTEMCTL_LOG"
cat > /usr/local/bin/systemctl <<'MANAGER'
#!/usr/bin/env bash
# Only the manager is simulated. Nginx, CGI, SSH and state/CLI are real.
set -Eeuo pipefail
printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
[[ ${1:-} != "${MOCK_SYSTEMCTL_FAIL:-}" ]] || { echo 'fixture systemctl failure' >&2; exit 17; }
case ${1:-} in
  show)
    if [[ $* == *--property=LoadState* ]]; then
      [[ ${MOCK_SYSTEMCTL_QUERY_FAIL:-} != load ]] || exit "${MOCK_SYSTEMCTL_QUERY_RC:-124}"
      echo loaded
    else
      [[ ${MOCK_SYSTEMCTL_QUERY_FAIL:-} != active ]] || exit "${MOCK_SYSTEMCTL_QUERY_RC:-124}"
      if [[ -n ${MOCK_SYSTEMCTL_ACTIVE_STATE:-} ]]; then echo "$MOCK_SYSTEMCTL_ACTIVE_STATE"
      elif [[ -f /tmp/native-running && ${2:-} != "${MOCK_SYSTEMCTL_INACTIVE:-}" ]]; then echo active
      else echo inactive; fi
    fi;;
  daemon-reload|disable) ;;
  is-active)
    [[ ${MOCK_SYSTEMCTL_QUERY_FAIL:-} != active ]] || exit "${MOCK_SYSTEMCTL_QUERY_RC:-124}"
    [[ -f /tmp/native-running && ${@: -1} != "${MOCK_SYSTEMCTL_INACTIVE:-}" ]];;
  is-failed)
    [[ ${MOCK_SYSTEMCTL_QUERY_FAIL:-} != active ]] || exit "${MOCK_SYSTEMCTL_QUERY_RC:-124}"
    exit 1;;
  enable|start)
    [[ ! -f /tmp/native-running ]] || exit 0
    mkdir -p /run/cpa-dr-native /run/sshd
    # Execute marker-related ExecStartPre commands from the generated units;
    # do not manufacture the expected marker in the manager fixture itself.
    for unit in cpa-dr-native-fcgi.service cpa-dr-native-ssh.service; do
      while IFS= read -r pre_start; do
        if [[ $pre_start == 'ExecStartPre=/usr/bin/install -m 0600 '* ]]; then
          read -r -a pre_args <<< "${pre_start#ExecStartPre=}"
          "${pre_args[@]}"
        fi
      done < "/etc/systemd/system/$unit"
    done
    install -d -o www-data -g www-data -m 0700 /run/cpa-dr-native/{body,fastcgi,proxy,uwsgi,scgi}
    export CPA_ROOT="$MOCK_ROOT" CPA_STATE_DIR="$MOCK_STATE"
    spawn-fcgi -n -s /run/cpa-dr-native/fcgi.sock -M 0660 -g www-data -- /usr/sbin/fcgiwrap -f > /tmp/fcgi.log 2>&1 &
    printf '%s\n' "$!" > /tmp/native-pids
    nginx -c "$MOCK_CFG/nginx.conf" -g 'daemon off;' > /tmp/nginx.log 2>&1 &
    printf '%s\n' "$!" >> /tmp/native-pids
    /usr/sbin/sshd -D -e -f "$MOCK_CFG/sshd.conf" > /tmp/sshd.log 2>&1 &
    printf '%s\n' "$!" >> /tmp/native-pids
    for _ in {1..100}; do
      if [[ -S /run/cpa-dr-native/fcgi.sock ]] && curl -fsS "http://127.0.0.1:$MOCK_PORT/healthz" >/dev/null 2>&1; then touch /tmp/native-running; exit 0; fi
      sleep .05
    done
    cat /tmp/nginx.log /tmp/fcgi.log /tmp/sshd.log >&2
    exit 18;;
  stop)
    if [[ -f /tmp/native-pids ]]; then while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done < /tmp/native-pids; fi
    rm -f /tmp/native-running
    sleep .2;;
  *) echo "unexpected manager operation: $*" >&2; exit 19;;
esac
MANAGER
chmod +x /usr/local/bin/systemctl
# Docker does not exist in the fixture: the native branch must not require it.
! command -v docker
export MOCK_SYSTEMCTL_FAIL=enable
command=$(printf '%q ' bash /fixture/source/start.sh --output "$MOCK_CFG" --state-dir "$MOCK_STATE" --install-root "$MOCK_ROOT" --port "$MOCK_PORT" --ssh-port 22228 --read-only-data --no-install-deps)
if printf '2\n/fixture/data\nauths\nauths\n1\ny\nsettings.json\nconfig\n2\ny\nusage.sqlite\nusage\n3\nn\n1\nn\ny\n' | script -q -e -c "$command" /dev/null > /tmp/first.out 2>&1; then echo 'failed manager startup was accepted' >&2; exit 1; fi
jq -e '.status=="pending" and .deployment=="native"' "$MOCK_CFG/.env.native.json" >/dev/null
jq -e '.node_role=="backup" and .enabled==false and .allowed_root=="/fixture/data" and .sources==[{name:"auths",kind:"directory",path:"/fixture/data/auths"},{name:"config",kind:"file",path:"/fixture/data/settings.json"},{name:"usage",kind:"sqlite",path:"/fixture/data/usage.sqlite"}]' "$MOCK_STATE/config.json" >/dev/null
! grep -q '服务已启动\|管理员令牌' /tmp/first.out
identity=$(sha256sum "$MOCK_STATE/admin.token" "$MOCK_STATE/ssh/id_ed25519" "$MOCK_STATE/ssh/ssh_host_ed25519_key")
node=$(jq -r .node_id "$MOCK_STATE/config.json")
unset MOCK_SYSTEMCTL_FAIL
bash /fixture/source/start.sh --output "$MOCK_CFG" --no-install-deps > /tmp/retry.out
[[ $(sha256sum "$MOCK_STATE/admin.token" "$MOCK_STATE/ssh/id_ed25519" "$MOCK_STATE/ssh/ssh_host_ed25519_key") == "$identity" && $(jq -r .node_id "$MOCK_STATE/config.json") == "$node" ]]
grep -q '部署方式：Linux 本地' /tmp/retry.out
jq -e '.status=="ready" and .read_only==true' "$MOCK_CFG/.env.native.json" >/dev/null
for file in tick fcgi ssh; do grep -Fq 'ReadOnlyPaths="/fixture/data"' "$MOCK_CFG/cpa-dr-native-$file.service"; done
[[ $(stat -c %a "$MOCK_STATE/admin.token") == 600 && $(stat -c %a "$MOCK_STATE/ssh/id_ed25519") == 600 && $(stat -c %a "$MOCK_CFG/.env.native.json") == 600 ]]
TOKEN=$(< "$MOCK_STATE/admin.token")
BASE="http://127.0.0.1:$MOCK_PORT"
curl -fsS -H "Authorization: Bearer $TOKEN" -H "Origin: $BASE" "$BASE/api/status" | jq -e '.node_role=="backup" and .phase=="backup_standby" and .enabled==false' >/dev/null
curl -fsS -H "Authorization: Bearer $TOKEN" -H "Origin: $BASE" "$BASE/api/config" | jq -e '(.sources|length)==3 and .peer.identity_file=="/var/lib/cpa-native-fixture/ssh/id_ed25519"' >/dev/null
jq '.interval_seconds=777' "$MOCK_STATE/config.json" > /tmp/updated.json
"$MOCK_ROOT/bin/cpa-dr" --state-dir "$MOCK_STATE" config set /tmp/updated.json > /dev/null
config_before=$(sha256sum "$MOCK_STATE/config.json")
export MOCK_SYSTEMCTL_INACTIVE=cpa-dr-native-ssh.service
if bash /fixture/source/start.sh --output "$MOCK_CFG" --no-install-deps > /tmp/inactive-unit.out 2>&1; then echo 'inactive SSH accepted while web was healthy' >&2; exit 1; fi
! grep -q '服务已启动\|管理员令牌' /tmp/inactive-unit.out
unset MOCK_SYSTEMCTL_INACTIVE
bash /fixture/source/start.sh --output "$MOCK_CFG" --no-install-deps > /tmp/repeat.out
[[ $(sha256sum "$MOCK_STATE/config.json") == "$config_before" ]]
if bash /fixture/source/start.sh --output "$MOCK_CFG" --role primary --no-install-deps > /tmp/conflict.out 2>&1; then exit 1; fi
printf 'PASS: native menu dispatch without Docker, real JSON/CGI/health, failed-start retry, private identity, source mapping and UI settings preserved\n'

# Inject one partial source move failure: bin was already replaced, but lib's
# original move fails. Rollback must not delete the unmoved original library.
cat > /usr/local/bin/mv <<'MOVE'
#!/usr/bin/env bash
if [[ ${MOCK_SOURCE_MOVE_FAIL:-0} == 1 && ${1:-} == -- && ${2:-} == "$MOCK_ROOT/lib" && ${3:-} == "$MOCK_ROOT/".env.upgrade-old.*/lib ]]; then
  printf 'fixture original source move failure\n' >&2
  exit 92
fi
exec /bin/mv "$@"
MOVE
chmod +x /usr/local/bin/mv
program_before=$(find "$MOCK_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum)
record_before=$(sha256sum "$MOCK_CFG/.env.native.json" "$MOCK_CFG/sshd.conf")
export MOCK_SOURCE_MOVE_FAIL=1
if bash /fixture/source/start.sh --output "$MOCK_CFG" --no-install-deps > /tmp/move-failure.out 2>&1; then echo 'source move failure accepted' >&2; exit 1; fi
unset MOCK_SOURCE_MOVE_FAIL
[[ $(find "$MOCK_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum) == "$program_before" ]] || { echo 'rollback deleted or changed unmoved original program files' >&2; exit 1; }
[[ $(sha256sum "$MOCK_CFG/.env.native.json" "$MOCK_CFG/sshd.conf") == "$record_before" ]]
[[ $(sha256sum "$MOCK_STATE/config.json") == "$config_before" && $(sha256sum "$MOCK_STATE/admin.token" "$MOCK_STATE/ssh/id_ed25519" "$MOCK_STATE/ssh/ssh_host_ed25519_key") == "$identity" ]]
printf 'PASS: partial source move failure restores only moved items and preserves unmoved original code/configuration/identity\n'

# /run is volatile even with RuntimeDirectoryPreserve=yes. Model boot starting
# the installed units, then check both rerun and the later uninstall lifecycle.
systemctl stop cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-fcgi.service cpa-dr-native-ssh.service
rm -rf -- /run/cpa-dr-native
systemctl enable --now cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-ssh.service
[[ -f /run/cpa-dr-native/.cpa-dr-install-id ]] || { echo 'runtime ownership marker not restored after simulated reboot' >&2; exit 1; }
[[ $(< /run/cpa-dr-native/.cpa-dr-install-id) == $(< "$MOCK_STATE/.cpa-dr-install-id") ]]
[[ $(stat -c %a /run/cpa-dr-native/.cpa-dr-install-id) == 600 ]]
bash /fixture/source/start.sh --output "$MOCK_CFG" --no-install-deps > /tmp/post-reboot.out
[[ $(sha256sum "$MOCK_STATE/config.json") == "$config_before" && $(sha256sum "$MOCK_STATE/admin.token" "$MOCK_STATE/ssh/id_ed25519" "$MOCK_STATE/ssh/ssh_host_ed25519_key") == "$identity" ]]
printf 'PASS: generated unit startup restores volatile runtime ownership; post-reboot rerun preserves settings and identity\n'

bash /fixture/source/start.sh status --output "$MOCK_CFG" > /tmp/status.out
grep -q '服务状态：运行中' /tmp/status.out
grep -q '管理 API：正常' /tmp/status.out
grep -q '专用 SSH：正常' /tmp/status.out
if grep -Fq "$TOKEN" /tmp/status.out; then echo 'status leaked token' >&2; exit 1; fi
for query_kind in active load; do
for query_rc in 1 124; do
  export MOCK_SYSTEMCTL_QUERY_FAIL=$query_kind MOCK_SYSTEMCTL_QUERY_RC=$query_rc
  bash /fixture/source/start.sh status --output "$MOCK_CFG" > /tmp/query-error.out
  grep -q '服务状态：未知' /tmp/query-error.out || { echo 'native query error reported as stopped, expected unknown' >&2; cat /tmp/query-error.out >&2; exit 1; }
  before_error_stop=$(grep -c '^stop ' "$MOCK_SYSTEMCTL_LOG")
  if bash /fixture/source/start.sh stop --yes --output "$MOCK_CFG" > /tmp/query-error-stop.out 2>&1; then echo 'native stop accepted unknown query state' >&2; exit 1; fi
  [[ $(grep -c '^stop ' "$MOCK_SYSTEMCTL_LOG") == "$before_error_stop" ]]
done
done
unset MOCK_SYSTEMCTL_QUERY_FAIL MOCK_SYSTEMCTL_QUERY_RC
for active_state in activating deactivating maintenance; do
  MOCK_SYSTEMCTL_ACTIVE_STATE=$active_state bash /fixture/source/start.sh status --output "$MOCK_CFG" > /tmp/transition-status.out
  grep -q '服务状态：切换中' /tmp/transition-status.out
done
MOCK_SYSTEMCTL_ACTIVE_STATE=failed bash /fixture/source/start.sh status --output "$MOCK_CFG" > /tmp/failed-status.out
grep -q '异常（单元失败）' /tmp/failed-status.out
MOCK_SYSTEMCTL_ACTIVE_STATE=invalid-state bash /fixture/source/start.sh status --output "$MOCK_CFG" > /tmp/invalid-status.out
grep -q '服务状态：未知' /tmp/invalid-status.out
printf 'PASS: native query errors/timeouts are unknown and block service operations\n'
before_stop=$(grep -c '^stop ' "$MOCK_SYSTEMCTL_LOG")
jq '.job.running=true' "$MOCK_STATE/runtime.json" > /tmp/busy.json
cp /tmp/busy.json "$MOCK_STATE/runtime.json"
if bash /fixture/source/start.sh stop --yes --output "$MOCK_CFG" > /tmp/busy-stop.out 2>&1; then exit 1; fi
if bash /fixture/source/start.sh uninstall --yes --output "$MOCK_CFG" > /tmp/busy-uninstall.out 2>&1; then exit 1; fi
[[ $(grep -c '^stop ' "$MOCK_SYSTEMCTL_LOG") == "$before_stop" ]]
jq '.job.running=false' "$MOCK_STATE/runtime.json" > /tmp/idle.json
cp /tmp/idle.json "$MOCK_STATE/runtime.json"
bash /fixture/source/start.sh stop --yes --output "$MOCK_CFG" > /tmp/stop-control.out
bash /fixture/source/start.sh status --output "$MOCK_CFG" > /tmp/stopped-status.out
grep -q '服务状态：已停止' /tmp/stopped-status.out
bash /fixture/source/start.sh start --yes --output "$MOCK_CFG" > /tmp/start-control.out
bash /fixture/source/start.sh restart --yes --output "$MOCK_CFG" > /tmp/restart-control.out
[[ $(sha256sum "$MOCK_STATE/config.json") == "$config_before" && $(sha256sum "$MOCK_STATE/admin.token" "$MOCK_STATE/ssh/id_ed25519" "$MOCK_STATE/ssh/ssh_host_ed25519_key") == "$identity" ]]
printf 'PASS: native status distinguishes live/stopped units, real API/SSH readiness and guarded start/stop/restart preserve identity\n'

# Non-root dispatch uses sudo rather than trying to read private state or write units.
cat > /usr/local/bin/sudo <<'SUDO'
#!/usr/bin/env bash
printf '%q ' "$@" >> /tmp/sudo.log
exit 99
SUDO
chmod +x /usr/local/bin/sudo
: > /tmp/sudo.log; chmod 666 /tmp/sudo.log
if setpriv --reuid 65534 --regid 65534 --clear-groups bash /fixture/source/start.sh --output "$MOCK_CFG" --no-install-deps > /tmp/user.out 2>&1; then exit 1; fi
grep -Fq '/fixture/source/start.sh' /tmp/sudo.log
grep -Fq -- '--deployment native' /tmp/sudo.log
: > /tmp/sudo.log
setpriv --reuid 65534 --regid 65534 --clear-groups bash /fixture/source/start.sh status --output "$MOCK_CFG" > /tmp/user-status.out
grep -q '未知' /tmp/user-status.out
[[ ! -s /tmp/sudo.log ]]
if setpriv --reuid 65534 --regid 65534 --clear-groups bash /fixture/source/start.sh stop --yes --output "$MOCK_CFG" > /tmp/user-control.out 2>&1; then exit 1; fi
grep -Fq '/fixture/source/start.sh stop' /tmp/sudo.log
grep -Fq -- '--deployment native' /tmp/sudo.log
chmod 700 /fixture/data
: > /tmp/sudo.log
if setpriv --reuid 65534 --regid 65534 --clear-groups bash /fixture/source/start.sh --role backup --deployment native --data-dir /fixture/data --source auths:directory:auths --output /etc/cpa-new-fixture --no-install-deps > /tmp/user-new.out 2>&1; then exit 1; fi
grep -Fq -- '--data-dir /fixture/data' /tmp/sudo.log
chmod 755 /fixture/data
printf 'PASS: native non-root dispatch invokes sudo with the selected deployment/output\n'

stop_count() { grep -c '^stop ' "$MOCK_SYSTEMCTL_LOG" || true; }
stop_before=$(stop_count)
cp /etc/systemd/system/cpa-dr-native-tick.timer /tmp/unit.original
printf '# changed unit\n' >> /etc/systemd/system/cpa-dr-native-tick.timer
if bash /fixture/source/start.sh --purge --yes --output "$MOCK_CFG" > /tmp/foreign-unit.out 2>&1; then exit 1; fi
[[ $(stop_count) == "$stop_before" && -f $MOCK_STATE/config.json ]]
cp /tmp/unit.original /etc/systemd/system/cpa-dr-native-tick.timer
# Simulate a crash after re-enabling units but before updating the old status.
cp "$MOCK_CFG/.env.native.json" /tmp/record.original
jq '.status="uninstalled"' /tmp/record.original > "$MOCK_CFG/.env.native.json"
export MOCK_SYSTEMCTL_FAIL=stop
if bash /fixture/source/start.sh --purge --yes --output "$MOCK_CFG" > /tmp/stop-failed.out 2>&1; then exit 1; fi
[[ -f /etc/systemd/system/cpa-dr-native-tick.timer && -f $MOCK_STATE/config.json ]]
unset MOCK_SYSTEMCTL_FAIL
cp /tmp/record.original "$MOCK_CFG/.env.native.json"
bash /fixture/source/start.sh uninstall --yes --output "$MOCK_CFG" > /tmp/uninstall.out
[[ ! -e /etc/systemd/system/cpa-dr-native-tick.timer && -f $MOCK_ROOT/bin/cpa-dr && -f $MOCK_STATE/config.json ]]
jq -e '.status=="uninstalled"' "$MOCK_CFG/.env.native.json" >/dev/null
rm -rf -- /run/cpa-dr-native
bash /fixture/source/start.sh --output "$MOCK_CFG" --no-install-deps > /tmp/reinstall.out
[[ $(< /run/cpa-dr-native/.cpa-dr-install-id) == $(< "$MOCK_STATE/.cpa-dr-install-id") ]]
[[ -f /etc/systemd/system/cpa-dr-native-tick.timer && $(sha256sum "$MOCK_STATE/config.json") == "$config_before" && $(sha256sum "$MOCK_STATE/admin.token" "$MOCK_STATE/ssh/id_ed25519" "$MOCK_STATE/ssh/ssh_host_ed25519_key") == "$identity" ]]
printf 'unknown config\n' > "$MOCK_CFG/unknown.conf"
data_before=$(find /fixture/data -type f -exec sha256sum {} + | sort)
bash /fixture/source/start.sh --purge --yes --output "$MOCK_CFG" > /tmp/purge.out
[[ ! -e $MOCK_ROOT && ! -e $MOCK_STATE && ! -e /run/cpa-dr-native && ! -e $MOCK_CFG/.env.native.json && -f $MOCK_CFG/unknown.conf && -f /fixture/source/start.sh ]]
[[ $(find /fixture/data -type f -exec sha256sum {} + | sort) == "$data_before" ]]
for file in /etc/systemd/system/cpa-dr-native-*; do [[ ! -e $file ]]; done
printf 'PASS: native unit ownership/failed-stop guards, uninstall/reinstall/purge preserve original data and unknown files\n'

# Default multi-deployment discovery is exercised entirely inside this container.
mkdir -p /etc/cpa-dr-native /fixture/dual
printf '{}\n' > /etc/cpa-dr-native/.env.native.json
cp /fixture/source/start.sh /fixture/dual/
cp -a /fixture/source/scripts /fixture/source/lib /fixture/dual/
printf 'legacy fixture\n' > /fixture/dual/.env
command=$(printf '%q ' bash /fixture/dual/start.sh)
printf '2\n0\n' | script -q -e -c "$command" /dev/null > /tmp/dual-menu.out 2>&1
grep -q '检测到多份部署' /tmp/dual-menu.out
grep -q '旧部署待确认' /tmp/dual-menu.out
if bash /fixture/dual/start.sh status > /tmp/dual-status.out 2>&1; then exit 1; fi
grep -q '多份部署' /tmp/dual-status.out
bash /fixture/dual/start.sh status --deployment docker > /tmp/dual-docker.out
grep -q '旧部署待确认' /tmp/dual-docker.out
printf 'PASS: bare multi-deployment menu selects a target; noninteractive ambiguous status rejects and explicit Docker status stays read-only\n'
chmod 700 /etc/cpa-dr-native
setpriv --reuid 65534 --regid 65534 --clear-groups bash /fixture/source/start.sh status > /tmp/private-default-status.out
grep -q '安装状态：状态未知' /tmp/private-default-status.out
grep -q '配置目录：/etc/cpa-dr-native' /tmp/private-default-status.out
printf 'PASS: default discovery retains an inaccessible native candidate as unknown instead of uninstalled\n'
FIXTURE
# The container has no host sockets, host ports, systemd or writable source mount.
docker run --rm --entrypoint bash \
  --mount "type=bind,source=$ROOT,target=/fixture/source,readonly" \
  --mount "type=bind,source=$TMP,target=/fixture/test,readonly" \
  "${CPA_NATIVE_TEST_IMAGE:-cpa-dr:native-verify}" /fixture/test/run.sh
