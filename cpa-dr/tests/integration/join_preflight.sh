#!/usr/bin/env bash
# Real discovery failures and file/config preflight, plus selected service states.
# shellcheck disable=SC2034,SC1090
set -Eeuo pipefail
SERVICE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
cleanup() {
  local rc=$?
  [[ -z ${DOCKER_MARKER_FIXTURE:-} ]] || docker rm -f "$DOCKER_MARKER_FIXTURE" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
ROOT=$SERVICE
source "$SERVICE/scripts/install/start-lifecycle.sh"
source "${CPA_JOIN_IMPLEMENTATION:-$SERVICE/scripts/install/join.sh}"
fail() { printf '%s\n' "$*" >&2; exit 1; }
jq() {
  if [[ ${MARKER_READ_AS_UNPRIVILEGED:-0} == 1 && ${*: -1} == "$TMP/state/enrollment/join.json" ]]; then
    setpriv --reuid=65534 --regid=65534 --clear-groups /usr/bin/jq "$@"
  else command jq "$@"; fi
}
mkdir -p "$TMP/source" "$TMP/state/enrollment" "$TMP/output"
mkdir -p "$TMP/state/ssh"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/current-hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/previous-hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/state/ssh/id_ed25519"
host_key=$(awk '{print $1 " " $2}' "$TMP/current-hostkey.pub")
previous_host_key=$(awk '{print $1 " " $2}' "$TMP/previous-hostkey.pub")
cat > "$TMP/source/start.sh" <<'INSTALL'
#!/usr/bin/env bash
printf 'installer called\n' >> "$MUTATION_LOG"
exit "${FIXTURE_INSTALL_EXIT:-91}"
INSTALL
chmod +x "$TMP/source/start.sh"
export MUTATION_LOG="$TMP/mutations"
ROOT="$TMP/source"
jq -n --arg data "$TMP/data" --arg host_key "$host_key" '{version:1,invite_id:"fixture-invite",auto_enable:true,primary:{node_id:"fixture-primary",host:"HOST",port:22,public_key:"fixture-public",host_key:$host_key},backup:{host:"BACKUP",port:2222,bind_host:"0.0.0.0",deployment:"native",data_dir:$data},sources:[{name:"auths",kind:"directory",relative_path:"auths"}],policy:{interval_seconds:900,secondary_interval_seconds:3600,retention_count:30,max_snapshot_bytes:1048576}}' > "$TMP/invite.json"
jq '.primary.host="::1" | .backup.host="::1"' "$TMP/invite.json" > "$TMP/ipv6.json"
cpa_join_validate "$TMP/ipv6.json"
for host in '-option' 'host/path' 'host;command' "$(printf 'x%.0s' {1..254})"; do
  jq --arg host "$host" '.primary.host=$host' "$TMP/invite.json" > "$TMP/bad-host.json"
  if (cpa_join_validate "$TMP/bad-host.json") >/dev/null 2>&1; then echo 'invalid endpoint accepted' >&2; exit 1; fi
done
jq -n --arg data "$TMP/data" '{data_dir:$data,deployment:"native"}' > "$TMP/record.json"
jq -n --arg data "$TMP/data" --arg state "$TMP/state" '{node_role:"backup",allowed_root:$data,enabled:false,peer:{node_id:"fixture-primary",identity_file:($state+"/ssh/id_ed25519"),known_hosts_file:($state+"/ssh/known_hosts")},sources:[{name:"auths",kind:"directory",path:($data+"/auths")}]} ' > "$TMP/state/config.json"
printf '%s\n' '{"job":{"running":false},"phase":"backup_standby"}' > "$TMP/state/runtime.json"
invoke_discovery() {
  local -a driver=(/bin/bash -c '
    ROOT=$1; TMP=$2
    source "$ROOT/scripts/install/start-lifecycle.sh"
    source "$ROOT/scripts/install/start-manager.sh"
    source "$3"
    fail() { printf "%s\n" "$*" >&2; exit 1; }
    ROOT="$TMP/source"
    invite_payload="" invite_file=$5 output="$TMP/output" deployment="" data="" assume_yes=1
    if [[ $4 == snapshot ]]; then
      deployment=$(jq -r .backup.deployment "$invite_file")
      cpa_manager_snapshot
      jq -cn --arg record "$record" --arg install "$manager_install" --arg service "$manager_service" --arg reason "$manager_reason" "{record:\$record,install:\$install,service:\$service,reason:\$reason}"
    else cpa_join_main; fi
  ' -- "$SERVICE" "$TMP" "${CPA_JOIN_IMPLEMENTATION:-$SERVICE/scripts/install/join.sh}" "$1" "${2:-$TMP/invite.json}")
  if [[ ${DISCOVERY_DROP_DAC:-0} == 1 ]]; then driver=(setpriv '--bounding-set=-dac_override,-dac_read_search' "${driver[@]}"); fi
  PATH=${DISCOVERY_TOOL_PATH:-$PATH} "${driver[@]}"
}
discovery_hashes() {
  { find "$TMP/output" "$TMP/state" "$TMP/source" -type f -exec sha256sum -- {} +
    find "$TMP/output" "$TMP/state" "$TMP/source" -type l -printf '%p -> %l\n'; } | sort
}
reject_discovery() {
  local label=$1 expected=$2 snapshot preserved
  snapshot=$(invoke_discovery snapshot)
  jq -e --arg expected "$expected" '.record=="" and .install==$expected and .service=="未知" and (.reason|length>0)' <<< "$snapshot" >/dev/null
  preserved=$(discovery_hashes)
  if invoke_discovery join > "$TMP/result" 2>&1; then echo "untrusted discovery accepted: $label" >&2; exit 1; fi
  [[ ! -e $MUTATION_LOG && ! -e $TMP/data ]] || { printf 'discovery %s mutated before rejection: %s\n' "$label" "$(cat "$MUTATION_LOG" 2>/dev/null || true)" >&2; exit 1; }
  [[ $(discovery_hashes) == "$preserved" ]]
  grep -q '已有安装状态未确认' "$TMP/result" || { cat "$TMP/result" >&2; exit 1; }
  printf 'PASS: actual discovery %s rejects empty/untrusted record before data/install writes\n' "$label"
}
printf '{broken-json\n' > "$TMP/output/.env.native.json"
reject_discovery malformed-json 记录异常
rm -- "$TMP/output/.env.native.json"
ln -s "$TMP/record.json" "$TMP/output/.env.native.json"
reject_discovery linked-manifest 记录异常
[[ -L $TMP/output/.env.native.json ]]
rm -- "$TMP/output/.env.native.json"
if ((EUID == 0)) && command -v setpriv >/dev/null; then
  printf '{}\n' > "$TMP/output/.env.native.json"
  chmod 000 "$TMP/output/.env.native.json"
  DISCOVERY_DROP_DAC=1 reject_discovery unreadable-manifest 状态未知
  chmod 600 "$TMP/output/.env.native.json"
  rm -- "$TMP/output/.env.native.json"
fi
jq '.backup.deployment="docker"' "$TMP/invite.json" > "$TMP/docker-invite.json"
cp "$TMP/invite.json" "$TMP/native-invite.json"
cp "$TMP/docker-invite.json" "$TMP/invite.json"
printf 'FIXTURE_LEGACY_CONFIG=preserve\n' > "$TMP/output/.env"
reject_discovery legacy-env 旧部署待确认
rm -- "$TMP/output/.env"
cp "$TMP/native-invite.json" "$TMP/invite.json"
mkdir "$TMP/query-tools"
for tool in bash jq realpath dirname stat cat mkdir chmod sha256sum ssh-keygen awk; do ln -s "$(type -P "$tool")" "$TMP/query-tools/$tool"; done
DISCOVERY_TOOL_PATH="$TMP/query-tools" reject_discovery missing-query-timeout 状态未知
invoke_discovery snapshot | jq -e '.record=="" and .install=="未安装" and .service=="未安装" and .reason==""' >/dev/null
if invoke_discovery join > "$TMP/result" 2>&1; then echo 'fixture installer failure unexpectedly succeeded' >&2; exit 1; fi
[[ -d $TMP/data && $(cat "$MUTATION_LOG") == 'installer called' ]]
grep -q '备机安装未完成' "$TMP/result"
rm -- "$MUTATION_LOG"
rmdir -- "$TMP/data"
printf 'PASS: actual discovery explicitly uninstalled reaches first installation; absent query tools are not treated as absence\n'
if [[ -n ${CPA_JOIN_DOCKER_IMAGE:-} ]]; then
  suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  DOCKER_MARKER_FIXTURE="cpa-join-discovery-ack-$suffix"
  mkdir "$TMP/ack-data"
  printf 'fixture-original-data\n' > "$TMP/ack-data/keep.txt"
  docker run -d --name "$DOCKER_MARKER_FIXTURE" --read-only --entrypoint sleep \
    --label "com.docker.compose.project=$DOCKER_MARKER_FIXTURE" --label com.docker.compose.service=cpa-dr \
    -v "$TMP/state:/state:ro" -v "$TMP/ack-data:/data:ro" "$CPA_JOIN_DOCKER_IMAGE" 300 >/dev/null
  docker stop "$DOCKER_MARKER_FIXTURE" >/dev/null
  jq -n --arg output "$TMP/output" --arg state "$TMP/state" --arg data "$TMP/ack-data" --arg source "$ROOT" --arg project "$DOCKER_MARKER_FIXTURE" \
    '{version:1,managed_by:"cpa-dr-start",deployment:"docker",status:"ready",install_id:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",data_dir:$data,state_dir:$state,source_root:$source,install_root:"",config_dir:$output,run_dir:"",project_name:$project,port:8787,ssh_port:2222,bind_host:"127.0.0.1",read_only:false,initial_config:null,unit_hashes:{}}' > "$TMP/output/.env.docker.json"
  jq --arg data "$TMP/ack-data" '.backup.deployment="docker"|.backup.data_dir=$data' "$TMP/invite.json" > "$TMP/ack-invite.json"
  printf '%s\n' '{"invite_id":"fixture-invite","primary_node_id":"fixture-primary","status":"completed","snapshot_id":"fixture-first-snapshot","completion_acknowledged":true}' > "$TMP/state/enrollment/join.json"
  preserved=$(discovery_hashes)
  data_before=$(sha256sum "$TMP/ack-data/keep.txt")
  invoke_discovery join "$TMP/ack-invite.json" > "$TMP/result"
  [[ ! -e $MUTATION_LOG && $(discovery_hashes) == "$preserved" && $(sha256sum "$TMP/ack-data/keep.txt") == "$data_before" ]]
  [[ $(docker inspect "$DOCKER_MARKER_FIXTURE" | jq -r '.[0].State.Running') == false ]]
  grep -q '本邀请已完成' "$TMP/result"
  docker rm -f "$DOCKER_MARKER_FIXTURE" >/dev/null
  DOCKER_MARKER_FIXTURE=''
  rm -- "$TMP/output/.env.docker.json"
  printf 'PASS: actual stopped Docker discovery validates acknowledged history without writes or helper startup\n'
fi
cpa_manager_snapshot() {
  record=$(cat "$TMP/record.json")
  manager_install=已安装
  manager_backend=${FIXTURE_BACKEND:-native} manager_service=${FIXTURE_SERVICE:-已停止} manager_reason=''
  manager_container=${DOCKER_MARKER_FIXTURE:-}
  state="$TMP/state" native_root="$TMP/installed"
  if [[ -n ${FIXTURE_POST_INSTALL_REASON:-} && -e $MUTATION_LOG ]]; then
    manager_service=未知 manager_reason=$FIXTURE_POST_INSTALL_REASON
  fi
}
invoke() (
  invite_payload='' invite_file="$TMP/invite.json" output="$TMP/output" deployment='' data='' assume_yes=1
  cpa_join_main
)
assert_unchanged() {
  [[ ! -e $MUTATION_LOG && ! -e $TMP/data ]] || { printf 'preflight mutated installation/data: %s\n' "$(cat "$MUTATION_LOG" 2>/dev/null || true)" >&2; return 1; }
  [[ $(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json") == "$before" ]]
}
printf '%s\n' '{"invite_id":"different-invite","status":"registered"}' > "$TMP/state/enrollment/join.json"
before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
if invoke > "$TMP/result" 2>&1; then echo 'stopped different invitation accepted' >&2; exit 1; fi
assert_unchanged
grep -q '已有安装邀请与本次邀请冲突' "$TMP/result"
printf '%s\n' '{"invite_id":"fixture-invite","status":"registered"}' > "$TMP/state/enrollment/join.json"
printf '%s\n' '{"job":{"running":false},"phase":"paused"}' > "$TMP/state/runtime.json"
before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
if invoke > "$TMP/result" 2>&1; then echo 'protected deployment accepted' >&2; exit 1; fi
assert_unchanged
grep -q '容灾保护状态' "$TMP/result"
# A completed invite does not authorize changing later administrator settings.
printf '%s\n' '{"invite_id":"fixture-invite","primary_node_id":"fixture-primary","status":"completed","snapshot_id":"fixture-first-snapshot","completion_acknowledged":true}' > "$TMP/state/enrollment/join.json"
jq '.sources=[{name:"later-setting",kind:"directory",path:(.allowed_root+"/later-setting")}]' "$TMP/state/config.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/config.json"
before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
for service in 已停止 运行中; do FIXTURE_SERVICE=$service invoke > "$TMP/result"; assert_unchanged; done
grep -q '本邀请已完成' "$TMP/result"
printf 'PASS: stopped/foreign and protected preflight rejects before writes; completed receipt preserves paused/data settings\n'

# Activation alone is not a primary commit receipt. Recover only through the
# permanent completion RPC, never through installation or configuration writes.
jq 'del(.completion_acknowledged)' "$TMP/state/enrollment/join.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/enrollment/join.json"
cpa_join_ssh() {
  [[ $1 == permanent && $2 == 'enroll-complete fixture-invite' && $3 == "$TMP/invite.json" ]] || exit 92
  printf '%s\n' "$1 $2" >> "$TMP/completion-rpc.log"
  case ${COMPLETION_RPC_MODE:-success} in
    failed) return 42;;
    wrong-snapshot) printf '%s\n' '{"completed":true,"invite_id":"fixture-invite","snapshot_id":"other-snapshot","enabled":false}';;
    wrong-invite) printf '%s\n' '{"completed":true,"invite_id":"other-invite","snapshot_id":"fixture-first-snapshot","enabled":false}';;
    pending) printf '%s\n' '{"completed":false,"invite_id":"fixture-invite","snapshot_id":"fixture-first-snapshot","enabled":false}';;
    *) printf '%s\n' '{"completed":true,"invite_id":"fixture-invite","snapshot_id":"fixture-first-snapshot","enabled":false}';;
  esac
}
for mode in failed wrong-snapshot wrong-invite pending; do
  before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
  if COMPLETION_RPC_MODE=$mode invoke > "$TMP/result" 2>&1; then echo 'unconfirmed activation falsely completed' >&2; exit 1; fi
  assert_unchanged
  [[ -s $TMP/completion-rpc.log ]]
  ! grep -q '本邀请已完成' "$TMP/result"
done
jq '.completion_acknowledged="true"' "$TMP/state/enrollment/join.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/enrollment/join.json"
before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
if COMPLETION_RPC_MODE=failed invoke > "$TMP/result" 2>&1; then echo 'string acknowledgement falsely completed' >&2; exit 1; fi
assert_unchanged
configuration_before=$(sha256sum "$TMP/state/config.json" "$TMP/state/runtime.json")
invoke > "$TMP/result"
[[ ! -e $MUTATION_LOG && ! -e $TMP/data ]]
[[ $(sha256sum "$TMP/state/config.json" "$TMP/state/runtime.json") == "$configuration_before" ]]
jq -e '.completion_acknowledged==true and .snapshot_id=="fixture-first-snapshot"' "$TMP/state/enrollment/join.json" >/dev/null
grep -q '已完成主机最终提交' "$TMP/result"
! grep -q '未重新安装或启用调度' "$TMP/result"
before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
rpc_before=$(sha256sum "$TMP/completion-rpc.log")
for service in 已停止 运行中; do FIXTURE_SERVICE=$service invoke > "$TMP/result"; assert_unchanged; done
[[ $(sha256sum "$TMP/completion-rpc.log") == "$rpc_before" ]]
unset -f cpa_join_ssh
printf 'PASS: unacknowledged activation retries permanent completion only; failures stay pending; acknowledged replay is entirely read-only\n'
printf '%s\n' '{"job":{"running":false},"phase":"backup_standby"}' > "$TMP/state/runtime.json"
jq --arg data "$TMP/data" '.sources=[{name:"auths",kind:"directory",path:($data+"/auths")}]' "$TMP/state/config.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/config.json"
reject_pin() {
  local pins=${1:-$TMP/state/ssh/known_hosts}
  before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
  pin_before=$(sha256sum "$pins" "$TMP/state/ssh/id_ed25519")
  if invoke > "$TMP/result" 2>&1; then echo 'existing installation accepted replaced primary pin' >&2; exit 1; fi
  assert_unchanged
  [[ $(sha256sum "$pins" "$TMP/state/ssh/id_ed25519") == "$pin_before" ]]
  grep -q '主机指纹与已有记录冲突' "$TMP/result"
}
printf '%s\n' '{"invite_id":"fixture-invite","status":"registered"}' > "$TMP/state/enrollment/join.json"
printf 'HOST %s\n' "$previous_host_key" > "$TMP/state/ssh/known_hosts"
reject_pin
rm -- "$TMP/state/ssh/known_hosts"
printf 'PASS: existing native primary pin conflict rejects before install/configuration changes\n'
printf 'HOST %s\n' "$host_key" > "$TMP/state/ssh/known_hosts"
printf 'HOST %s\n' "$previous_host_key" > "$TMP/state/ssh/custom_hosts"
jq --arg known "$TMP/state/ssh/custom_hosts" '.peer.known_hosts_file=$known' "$TMP/state/config.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/config.json"
default_pin_before=$(sha256sum "$TMP/state/ssh/known_hosts")
reject_pin "$TMP/state/ssh/custom_hosts"
[[ $(sha256sum "$TMP/state/ssh/known_hosts") == "$default_pin_before" ]]
jq --arg known "$TMP/state/ssh/known_hosts" '.peer.known_hosts_file=$known' "$TMP/state/config.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/config.json"
printf 'PASS: custom native primary pin rejects before installer/configuration mutation; default trust untouched\n'
reject_identity() {
  before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
  identity_before=$(sha256sum "$TMP/state/ssh/id_ed25519" "$TMP/state/ssh/id_ed25519.pub" "$TMP/state/ssh/known_hosts")
  if invoke > "$TMP/result" 2>&1; then echo 'invalid configured identity accepted before install' >&2; exit 1; fi
  assert_unchanged
  [[ $(sha256sum "$TMP/state/ssh/id_ed25519" "$TMP/state/ssh/id_ed25519.pub" "$TMP/state/ssh/known_hosts") == "$identity_before" ]]
  grep -q '已有SSH身份不可核验' "$TMP/result"
}
cp "$TMP/state/ssh/id_ed25519.pub" "$TMP/valid-identity.pub"
cp "$TMP/previous-hostkey.pub" "$TMP/state/ssh/id_ed25519.pub"
reject_identity
cp "$TMP/valid-identity.pub" "$TMP/state/ssh/id_ed25519.pub"
mv "$TMP/state/ssh/id_ed25519.pub" "$TMP/linked-identity.pub"
ln -s "$TMP/linked-identity.pub" "$TMP/state/ssh/id_ed25519.pub"
reject_identity
rm -- "$TMP/state/ssh/id_ed25519.pub"
cp "$TMP/valid-identity.pub" "$TMP/state/ssh/id_ed25519.pub"
jq --arg key "$TMP/state/ssh/missing_identity" '.peer.identity_file=$key' "$TMP/state/config.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/config.json"
reject_identity
jq --arg key "$TMP/state/ssh/id_ed25519" '.peer.identity_file=$key' "$TMP/state/config.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/config.json"
printf 'PASS: native missing identity and mismatched/linked sidecars reject before install without rewriting keys\n'
native_config=$(cat "$TMP/state/config.json")
native_invite=$(cat "$TMP/invite.json")
if [[ -n ${CPA_JOIN_DOCKER_IMAGE:-} ]]; then
  DOCKER_MARKER_FIXTURE="cpa-join-same-path-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  docker run -d --name "$DOCKER_MARKER_FIXTURE" --read-only --entrypoint sleep \
    -v "$TMP/state:/state:ro" "$CPA_JOIN_DOCKER_IMAGE" 300 >/dev/null
  jq '.backup.deployment="docker"' <<< "$native_invite" > "$TMP/invite.json"
  jq '.peer.identity_file="/state/ssh/id_ed25519"|.peer.known_hosts_file=.peer.identity_file' <<< "$native_config" > "$TMP/state/config.json"
  FIXTURE_BACKEND=docker FIXTURE_SERVICE=运行中 reject_pin "$TMP/state/ssh/id_ed25519"
  docker rm -f "$DOCKER_MARKER_FIXTURE" >/dev/null
  DOCKER_MARKER_FIXTURE=''
  printf 'PASS: real Docker identical trust/identity paths reject before installer/data mutation; private key unchanged\n'
fi
printf '%s\n' "$native_invite" > "$TMP/invite.json"
jq '.peer.known_hosts_file=.peer.identity_file' <<< "$native_config" > "$TMP/state/config.json"
reject_pin "$TMP/state/ssh/id_ed25519"
# Historical acknowledgement remains entirely read-only even for this later
# transport misconfiguration; no transport parser or installer is needed.
printf '%s\n' '{"invite_id":"fixture-invite","primary_node_id":"fixture-primary","status":"completed","snapshot_id":"fixture-first-snapshot","completion_acknowledged":true}' > "$TMP/state/enrollment/join.json"
before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
invoke > "$TMP/result"
assert_unchanged
printf '%s\n' "$native_config" > "$TMP/state/config.json"
printf 'PASS: native identical trust/identity paths reject before mutation; acknowledged historical receipt stays read-only\n'
printf '%s\n' '{"invite_id":"fixture-invite","status":"registered"}' > "$TMP/state/enrollment/join.json"
diagnostic_before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json" "$TMP/state/ssh/id_ed25519")
if FIXTURE_INSTALL_EXIT=0 FIXTURE_POST_INSTALL_REASON=fixture-manager-unconfirmed invoke > "$TMP/result" 2>&1; then
  echo 'unconfirmed manager readiness accepted' >&2; exit 1
fi
[[ $(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json" "$TMP/state/ssh/id_ed25519") == "$diagnostic_before" ]]
grep -q '备机服务未就绪.*服务：未知.*原因：fixture-manager-unconfirmed' "$TMP/result" || { cat "$TMP/result" >&2; exit 1; }
rm -- "$MUTATION_LOG"
rmdir -- "$TMP/data"
printf 'PASS: post-install readiness failure retains strict check and reports nonsecret service/reason\n'

# Existing marker errors are not absence. Verify the complete join boundary,
# including native discovery, before any installer/source/data mutation.
printf '%s\n' '{"job":{"running":false},"phase":"backup_standby"}' > "$TMP/state/runtime.json"
jq --arg data "$TMP/data" '.sources=[{name:"auths",kind:"directory",path:($data+"/auths")}]' "$TMP/state/config.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/state/config.json"
printf '%s\n' '{"invite_id":"fixture-invite","status":"registered"}' > "$TMP/valid-marker.json"
reject_marker() {
  before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
  if invoke > "$TMP/result" 2>&1; then echo 'invalid existing marker accepted' >&2; exit 1; fi
  assert_unchanged
  grep -q '安装邀请记录读取失败' "$TMP/result"
}
rm -f -- "$TMP/state/enrollment/join.json"
ln -s "$TMP/valid-marker.json" "$TMP/state/enrollment/join.json"
reject_marker
[[ -L $TMP/state/enrollment/join.json ]]
rm -- "$TMP/state/enrollment/join.json"
for malformed in '{broken-json' '[]' 'null' '{} {}'; do
  printf '%s\n' "$malformed" > "$TMP/state/enrollment/join.json"
  reject_marker
done
# jq really reads this file as an unprivileged uid. All other fixture reads
# remain untouched, modeling an OS read failure without mocking file contents.
cp "$TMP/valid-marker.json" "$TMP/state/enrollment/join.json"
chmod 000 "$TMP/state/enrollment/join.json"
chmod 755 "$TMP" "$TMP/state" "$TMP/state/enrollment"

MARKER_READ_AS_UNPRIVILEGED=1 reject_marker
chmod 600 "$TMP/state/enrollment/join.json"
unset -f jq
mv "$TMP/state/enrollment" "$TMP/marker-parent"
ln -s "$TMP/marker-parent" "$TMP/state/enrollment"
reject_marker
[[ -L $TMP/state/enrollment ]]
rm -- "$TMP/state/enrollment"
mv "$TMP/marker-parent" "$TMP/state/enrollment"
rm -- "$TMP/state/enrollment/join.json"
[[ $(cpa_join_marker_local "$TMP/state") == '{}' ]]
cp "$TMP/valid-marker.json" "$TMP/state/enrollment/join.json"
printf 'PASS: existing marker symlink, malformed/non-object/multiple JSON and real permission errors reject before mutation\n'

# Optional real-container boundary test. Drop DAC_OVERRIDE so mode 000 is an
# actual OS read denial even for the fixture container's root uid.
if [[ -n ${CPA_JOIN_DOCKER_IMAGE:-} ]]; then
  DOCKER_MARKER_FIXTURE="cpa-join-marker-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  docker run -d --name "$DOCKER_MARKER_FIXTURE" --read-only --cap-drop ALL --entrypoint sleep \
    -v "$TMP/state:/state:ro" "$CPA_JOIN_DOCKER_IMAGE" 300 >/dev/null
  jq '.backup.deployment="docker"' "$TMP/invite.json" > "$TMP/new.json"
  mv "$TMP/new.json" "$TMP/invite.json"
  FIXTURE_BACKEND=docker FIXTURE_SERVICE=运行中
  jq '.peer.identity_file="/state/ssh/id_ed25519"|.peer.known_hosts_file="/state/ssh/known_hosts"' "$TMP/state/config.json" > "$TMP/new.json"
  mv "$TMP/new.json" "$TMP/state/config.json"
  for malformed in '{broken-json' '[]' 'null' '{} {}'; do
    printf '%s\n' "$malformed" > "$TMP/state/enrollment/join.json"
    reject_marker
  done
  rm -- "$TMP/state/enrollment/join.json"
  ln -s "$TMP/valid-marker.json" "$TMP/state/enrollment/join.json"
  reject_marker
  rm -- "$TMP/state/enrollment/join.json"
  cp "$TMP/valid-marker.json" "$TMP/state/enrollment/join.json"
  chmod 000 "$TMP/state/enrollment/join.json"
  reject_marker
  chmod 600 "$TMP/state/enrollment/join.json"
  rm -- "$TMP/state/enrollment/join.json"
  [[ $(deployment=docker manager_service=运行中 manager_container="$DOCKER_MARKER_FIXTURE" cpa_join_marker) == '{}' ]]
  printf 'PASS: real Docker marker script rejects links/JSON/read failures; trusted absence alone returns empty object\n'
  cp "$TMP/valid-marker.json" "$TMP/state/enrollment/join.json"
  printf 'HOST %s\n' "$previous_host_key" > "$TMP/state/ssh/known_hosts"
  reject_pin
  printf 'PASS: real Docker existing primary pin conflict rejects before install/configuration changes\n'
  printf 'HOST %s\n' "$host_key" > "$TMP/state/ssh/known_hosts"
  jq '.peer.known_hosts_file="/state/ssh/custom_hosts"' "$TMP/state/config.json" > "$TMP/new.json"
  mv "$TMP/new.json" "$TMP/state/config.json"
  default_pin_before=$(sha256sum "$TMP/state/ssh/known_hosts")
  reject_pin "$TMP/state/ssh/custom_hosts"
  [[ $(sha256sum "$TMP/state/ssh/known_hosts") == "$default_pin_before" ]]
  printf 'HOST %s\n' "$host_key" > "$TMP/state/ssh/custom_hosts"
  cp "$TMP/previous-hostkey.pub" "$TMP/state/ssh/id_ed25519.pub"
  reject_identity
  cp "$TMP/valid-identity.pub" "$TMP/state/ssh/id_ed25519.pub"
  printf 'HOST %s\n' "$previous_host_key" > "$TMP/state/ssh/custom_hosts"
  docker stop "$DOCKER_MARKER_FIXTURE" >/dev/null
  FIXTURE_SERVICE=已停止 reject_pin "$TMP/state/ssh/custom_hosts"
  jq '.peer.known_hosts_file="/external/known_hosts"' "$TMP/state/config.json" > "$TMP/new.json"
  mv "$TMP/new.json" "$TMP/state/config.json"
  FIXTURE_SERVICE=已停止 reject_pin "$TMP/state/ssh/custom_hosts"
  # A historical, fully acknowledged receipt needs no transport, even stopped.
  printf '%s\n' '{"invite_id":"fixture-invite","primary_node_id":"fixture-primary","status":"completed","snapshot_id":"fixture-first-snapshot","completion_acknowledged":true}' > "$TMP/state/enrollment/join.json"
  before=$(sha256sum "$TMP/state/"*.json "$TMP/state/enrollment/join.json")
  FIXTURE_SERVICE=已停止 invoke > "$TMP/result"
  assert_unchanged
  [[ $(docker inspect "$DOCKER_MARKER_FIXTURE" | jq -r '.[0].State.Running') == false ]]
  printf 'PASS: custom running/stopped Docker pin rejects before mutation; stopped external transport rejects except acknowledged read-only receipt\n'
fi
