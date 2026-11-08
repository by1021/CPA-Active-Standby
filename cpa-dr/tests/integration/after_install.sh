#!/usr/bin/env bash
# PTY continuation and explicit noninteractive invitation, without services.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
successor=''
trap '[[ -z $successor ]] || { kill "$successor" 2>/dev/null || true; wait "$successor" 2>/dev/null || true; }; rm -rf -- "$TMP"' EXIT
if bash "$ROOT/start.sh" install --role backup --generate-backup --primary-host HOST --backup-host HOST --yes --output "$TMP/rejected" > "$TMP/role-error" 2>&1; then exit 1; fi
[[ ! -e $TMP/rejected ]]
grep -q '仅用于主机' "$TMP/role-error"
mkdir -p "$TMP/service" "$TMP/state"
export TEST_INVITE_LOG="$TMP/invite" TEST_SERVICE="$TMP/service" TEST_ROOT="$ROOT" TEST_STATE="$TMP/state"
cat > "$TMP/service/start.sh" <<'START'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TEST_INVITE_LOG"
exit "${TEST_INVITE_FAIL:-0}"
START
cat > "$TMP/run.sh" <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$TEST_ROOT
source "$ROOT/scripts/install/invitation.sh"
ROOT=$TEST_SERVICE; output=$TEST_SERVICE; state=$TEST_STATE
existing=${TEST_EXISTING:-0}; role=${TEST_ROLE:-primary}; generate_backup=${TEST_GENERATE:-0}
primary_host=primary-fixture; backup_host=backup-fixture; primary_port=2222; backup_port=2222
backup_data=/fixture/data; backup_deployment=docker; backup_output=''; backup_bind=0.0.0.0
invite_ttl=1800; invite_auto=0; assume_yes=1; start_lock=''; lock_file=''
cpa_install_finish
RUN
bash "$TMP/run.sh" > "$TMP/noninteractive" 2>&1
[[ ! -e $TEST_INVITE_LOG ]]
printf 'n\n' | script -q -e -c "bash $TMP/run.sh" /dev/null > "$TMP/decline" 2>&1
grep -q '现在生成备机安装命令' "$TMP/decline"
[[ ! -e $TEST_INVITE_LOG ]]
printf '\n' | script -q -e -c "bash $TMP/run.sh" /dev/null > "$TMP/accept" 2>&1
grep -qx generate-backup-command "$TEST_INVITE_LOG"
rm "$TEST_INVITE_LOG"
TEST_EXISTING=1 bash "$TMP/run.sh" > "$TMP/repeat"
[[ ! -e $TEST_INVITE_LOG ]]
TEST_GENERATE=1 bash "$TMP/run.sh" > "$TMP/explicit"
grep -qx generate-backup-command "$TEST_INVITE_LOG"; grep -qx -- --no-auto-enable "$TEST_INVITE_LOG"
rm "$TEST_INVITE_LOG"
if TEST_GENERATE=1 TEST_INVITE_FAIL=2 bash "$TMP/run.sh" > "$TMP/failure" 2>&1; then exit 1; fi
grep -q '安装已成功' "$TMP/failure"
printf 'PASS: default/decline/accept/repeat/noninteractive continuation and invitation failure separation\n'

# Exercise the real native sudo re-entry builder, not a copied option list.
mkdir "$TMP/bin"
export TEST_SUDO_ARGUMENTS="$TMP/sudo-arguments"
cat > "$TMP/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$TEST_SUDO_ARGUMENTS"
SUDO
chmod +x "$TMP/bin/sudo"
cat > "$TMP/elevate.sh" <<'ELEVATE'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$TEST_ROOT
source "$ROOT/scripts/install/start-lifecycle.sh"
output=$TEST_SERVICE; uninstall=0; purge=0; role=primary; data=''; source_specs=()
port=''; ssh_port=''; bind=''; ssh_bind=''; state_arg=''; root_arg=''; read_only=0
assume_yes=1; install_deps=0; generate_backup=1
primary_host=primary-fixture; primary_port=2233; backup_host=backup-fixture; backup_port=2244
backup_data='/fixture/data with spaces'; backup_deployment=docker; backup_output='/fixture/config with spaces'; backup_bind=0.0.0.0
invite_ttl=3600; invite_auto=0
cpa_start_elevate_native
ELEVATE
PATH="$TMP/bin:$PATH" bash "$TMP/elevate.sh" > "$TMP/elevate-output"
mapfile -d '' -t actual < "$TEST_SUDO_ARGUMENTS"
expected=(-- bash "$ROOT/start.sh" --deployment native --output "$TEST_SERVICE" --role primary
  --generate-backup --primary-host primary-fixture --primary-port 2233
  --backup-host backup-fixture --backup-port 2244 --backup-data-dir '/fixture/data with spaces'
  --backup-deployment docker --backup-output '/fixture/config with spaces' --backup-bind-host 0.0.0.0
  --ttl 3600 --no-auto-enable --yes --no-install-deps)
if [[ ${#actual[@]} != "${#expected[@]}" ]]; then
  printf 'FAIL: native sudo re-entry lost invitation options: %s\n' "${actual[*]}" >&2; exit 1
fi
for index in "${!expected[@]}"; do [[ ${actual[index]} == "${expected[index]}" ]] || exit 1; done
printf 'PASS: native sudo re-entry preserves explicit invitation, endpoint/backup values and consent exactly\n'

# A real later lock holder starts during the invitation. The installer EXIT
# trap must never unlink that holder's lock after releasing its own descriptor.
cat > "$TMP/finish-lock.sh" <<'FINISH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$TEST_ROOT
source "$ROOT/scripts/install/start-lifecycle.sh"
source "$ROOT/scripts/install/invitation.sh"
ROOT=$TEST_LOCK_DIR/service; output=$TEST_LOCK_DIR/config; state=$TEST_STATE
existing=0; role=primary; generate_backup=1; assume_yes=1
primary_host=primary-fixture; backup_host=backup-fixture; primary_port=2222; backup_port=2222
backup_data=/fixture/data; backup_deployment=docker; backup_output=''; backup_bind=0.0.0.0
invite_ttl=1800; invite_auto=0
cpa_start_lock
trap -p EXIT > "$TEST_LOCK_DIR/trap-before"
result=0
cpa_install_finish || result=$?
trap -p EXIT > "$TEST_LOCK_DIR/trap-after"
exit "$result"
FINISH
cat > "$TMP/successor.sh" <<'SUCCESSOR'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$TEST_ROOT
source "$ROOT/scripts/install/start-lifecycle.sh"
fail() { printf '%s\n' "$*" >&2; exit 1; }
output=$TEST_LOCK_DIR/config
for attempt in {1..500}; do
  [[ ! -e $TEST_LOCK_DIR/invitation-ready ]] || break
  sleep .01
done
[[ -e $TEST_LOCK_DIR/invitation-ready ]]
cpa_start_lock
: > "$TEST_LOCK_DIR/successor-ready"
for attempt in {1..500}; do
  [[ ! -e $TEST_LOCK_DIR/release-successor ]] || exit 0
  sleep .01
done
exit 1
SUCCESSOR
for finish_rc in 0 17; do
  export TEST_LOCK_DIR="$TMP/lock-$finish_rc" TEST_INVITE_RC=$finish_rc
  mkdir -p "$TEST_LOCK_DIR/service" "$TEST_LOCK_DIR/config"
  cat > "$TEST_LOCK_DIR/service/start.sh" <<'INVITE'
#!/usr/bin/env bash
set -Eeuo pipefail
: > "$TEST_LOCK_DIR/invitation-ready"
for attempt in {1..500}; do
  [[ ! -e $TEST_LOCK_DIR/successor-ready ]] || exit "$TEST_INVITE_RC"
  sleep .01
done
exit 99
INVITE
  bash "$TMP/successor.sh" > "$TEST_LOCK_DIR/successor-output" 2>&1 & successor=$!
  result=0
  bash "$TMP/finish-lock.sh" > "$TEST_LOCK_DIR/installer-output" 2>&1 || result=$?
  [[ $result == "$finish_rc" ]]
  cmp "$TEST_LOCK_DIR/trap-before" "$TEST_LOCK_DIR/trap-after"
  [[ -f $TEST_LOCK_DIR/config/.env.start.lock ]] || { printf 'FAIL: completed installer EXIT trap deleted successor lock\n' >&2; exit 1; }
  if bash -c 'set -Eeuo pipefail; ROOT=$TEST_ROOT; source "$ROOT/scripts/install/start-lifecycle.sh"; fail() { printf "%s\n" "$*" >&2; exit 1; }; output=$TEST_LOCK_DIR/config; cpa_start_lock' > "$TEST_LOCK_DIR/contender-output" 2>&1; then
    printf 'FAIL: another operation acquired a split lock while successor still held it\n' >&2; exit 1
  fi
  grep -q '另一项安装/卸载正在执行' "$TEST_LOCK_DIR/contender-output"
  : > "$TEST_LOCK_DIR/release-successor"
  wait "$successor"; successor=''
  [[ ! -e $TEST_LOCK_DIR/config/.env.start.lock ]]
done
printf 'PASS: installer releases only its own lock, preserves EXIT trap/exit code, and never deletes a successor lock\n'

# The release-path summary must report actual state, also from a logical cwd.
export TEST_LAYOUT="$TMP/finish-physical/cpa-dr" TEST_LAYOUT_SOURCE="$TMP/finish-physical/cpa-dr/releases/1111111111111111111111111111111111111111/cpa-dr"
mkdir -p "$TEST_LAYOUT_SOURCE" "$TEST_LAYOUT/config/state-native"
cp "$TEST_SERVICE/start.sh" "$TEST_LAYOUT_SOURCE/start.sh"
jq -n --arg hash "$(sha256sum "$TEST_LAYOUT_SOURCE/start.sh" | cut -d' ' -f1)" '{format_version:1,files:[{path:"start.sh",sha256:$hash}]}' > "$TEST_LAYOUT_SOURCE/install-manifest.json"
jq -n --arg source "$TEST_LAYOUT_SOURCE" --arg config "$TEST_LAYOUT/config" --arg state "$TEST_LAYOUT/config/state-native" --arg data "$TMP/fixture-data" '{version:1,managed_by:"cpa-dr-start",deployment:"docker",status:"ready",install_id:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",data_dir:$data,state_dir:$state,source_root:$source,install_root:"",config_dir:$config,run_dir:"",project_name:"summary-fixture",port:8787,ssh_port:2222,bind_host:"127.0.0.1",read_only:false,initial_config:null,unit_hashes:{}}' > "$TEST_LAYOUT/config/.env.docker.json"
ln -s "$TMP/finish-physical" "$TMP/finish-logical"
(
  cd "$TMP/finish-logical"
  ROOT=$TEST_ROOT
  source "$ROOT/scripts/packaging/location.sh"
  source "$ROOT/scripts/install/invitation.sh"
  # Fields consumed by cpa_install_finish, sourced dynamically above.
  ROOT=$TEST_LAYOUT_SOURCE
  # shellcheck disable=SC2034
  output=$TEST_LAYOUT/config
  # shellcheck disable=SC2034
  state=$TEST_LAYOUT/config/state-native
  # shellcheck disable=SC2034
  role=backup
  # shellcheck disable=SC2034
  generate_backup=0
  cpa_install_finish
) > "$TMP/release-summary"
[[ -f $TMP/finish-physical/start.sh && -f $TEST_LAYOUT/start.sh ]]
grep -Fxq "状态目录：$TEST_LAYOUT/config/state-native" "$TMP/release-summary" || { echo 'FAIL: release installation summary omitted actual state_dir' >&2; exit 1; }
printf 'PASS: logical cwd finish registers physical shortcut and reports actual release state directory\n'
