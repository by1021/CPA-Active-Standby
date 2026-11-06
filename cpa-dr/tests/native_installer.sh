#!/usr/bin/env bash
# Real native processes and installer in a disposable container, not host systemd.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
cat > "$TMP/run.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -Eeuo pipefail
export MOCK_ROOT=/opt/cpa-native-fixture MOCK_STATE=/var/lib/cpa-native-fixture MOCK_CFG=/etc/cpa-native-fixture
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
  show) echo fixture;;
  daemon-reload|disable) ;;
  is-active) [[ -f /tmp/native-running && ${@: -1} != "${MOCK_SYSTEMCTL_INACTIVE:-}" ]];;
  enable)
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
    sshd -D -e -f "$MOCK_CFG/sshd.conf" > /tmp/sshd.log 2>&1 &
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
if printf '2\n/fixture/data\nauths\nauths\n1\ny\nsettings.json\nconfig\n2\ny\nusage.sqlite\nusage\n3\nn\ny\n1\n' | script -q -e -c "$command" /dev/null > /tmp/first.out 2>&1; then echo 'failed manager startup was accepted' >&2; exit 1; fi
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
FIXTURE
# The container has no host sockets, host ports, systemd or writable source mount.
docker run --rm --entrypoint bash \
  --mount "type=bind,source=$ROOT,target=/fixture/source,readonly" \
  --mount "type=bind,source=$TMP,target=/fixture/test,readonly" \
  "${CPA_NATIVE_TEST_IMAGE:-cpa-dr:native-verify}" /fixture/test/run.sh
