#!/usr/bin/env bash
# Isolate credentials/data; simulate Docker while exercising the real initializer.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
[[ -f $ROOT/start.sh ]] || { echo 'FAIL: start.sh is missing' >&2; exit 1; }
mkdir -p "$TMP/mock" "$TMP/data dir" "$TMP/other-data" "$TMP/containers"
export MOCK_COMPOSE_LOG=$TMP/docker.log
export MOCK_CPA_ROOT="$ROOT" MOCK_CPA_HOST_PATH="$PATH"
export MOCK_CONTAINER_DIR="$TMP/containers"
export PATH="$TMP/mock:$PATH"
cat > "$TMP/mock/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
for key in ADMIN_TOKEN CPA_DATA_PATH STATE_PATH PORT SSH_PORT BIND_HOST SSH_BIND_HOST DATA_ACCESS; do
  if [[ -v $key ]]; then echo "Inherited Compose override: $key" >&2; exit 9; fi
done
printf '%q ' "$@" >> "$MOCK_COMPOSE_LOG"; printf '\n' >> "$MOCK_COMPOSE_LOG"
failure=${MOCK_DOCKER_FAIL:-}
if [[ ${1:-} == info ]]; then [[ $failure != info ]] || { echo 'fixture daemon unavailable' >&2; exit 7; }; exit 0; fi
case ${1:-} in
  ps)
    project=''
    for arg in "$@"; do [[ $arg != label=com.docker.compose.project=* ]] || project=${arg#label=com.docker.compose.project=}; done
    [[ ! -f $MOCK_CONTAINER_DIR/$project.json ]] || printf 'fixture-%s\n' "$project"
    exit 0;;
  inspect)
    project=${2#fixture-}
    jq '[{Id:("fixture-"+.project),Config:{Labels:{"com.docker.compose.project":.project,"com.docker.compose.service":"cpa-dr"}},Mounts:[{Type:"bind",Source:.state,Destination:"/state"},{Type:"bind",Source:.data,Destination:"/data"}],State:{Running:true},NetworkSettings:{Ports:{}}}]' "$MOCK_CONTAINER_DIR/$project.json"
    exit 0;;
  exec)
    project=${2#fixture-}; shift 2
    state=$(jq -r .state "$MOCK_CONTAINER_DIR/$project.json")
    if [[ $1 == cat ]]; then cat "$state${2#/state}"; exit 0; fi
    [[ $1 == /opt/cpa-dr/bin/cpa-dr ]] || exit 8; shift
    mapped=()
    for arg in "$@"; do [[ $arg != /state && $arg != /state/* ]] || arg="$state${arg#/state}"; mapped+=("$arg"); done
    PATH="$MOCK_CPA_HOST_PATH" "$MOCK_CPA_ROOT/bin/cpa-dr" "${mapped[@]}"
    exit $?;;
esac
[[ ${1:-} == compose ]] || exit 8
shift
envfile='' project=''
while (($#)); do
  case $1 in
    --env-file) envfile=$2; shift 2;;
    --project-name) project=$2; shift 2;;
    --project-directory|--file) shift 2;;
    *) break;;
  esac
done
read_env() {
  data='' state='' port='' ssh_port='' token='' access=''
  while IFS= read -r line; do
    [[ $line == *=* && $line != \#* ]] || continue
    key=${line%%=*}; value=${line#*=}
    if [[ $value == \'*\' || $value == \"*\" ]]; then value=${value:1:${#value}-2}; fi
    case $key in
      CPA_DATA_PATH) data=$value;; STATE_PATH) state=$value;;
      PORT) port=$value;; SSH_PORT) ssh_port=$value;;
      ADMIN_TOKEN) token=$value;; DATA_ACCESS) access=$value;;
    esac
  done < "$envfile"
}
case ${1:-} in
  version) [[ $failure != version ]] || { echo 'fixture Compose missing' >&2; exit 7; };;
  config)
    [[ $failure != config ]] || { echo 'fixture configuration error' >&2; exit 7; }
    if [[ ${2:-} == --format && ${3:-} == json ]]; then
      read_env
      jq -n --arg data "$data" --arg state "$state" --arg port "$port" --arg ssh_port "$ssh_port" --arg token "$token" --arg access "$access" \
        '{services:{"cpa-dr":{environment:{CPA_ADMIN_TOKEN:$token},volumes:[{type:"bind",source:$data,target:"/data",read_only:($access=="ro")},{type:"bind",source:$state,target:"/state"}],ports:[{target:8787,published:$port},{target:22,published:$ssh_port}]}}}'
    fi;;
  up)
    if [[ ${2:-} == --help ]]; then
      [[ $failure == old-compose ]] || echo '--wait --wait-timeout'
    else
      [[ $failure != up ]] || { echo 'fixture build or health timeout' >&2; exit 7; }
      [[ " $* " == *' --build '* && " $* " == *' --wait '* && " $* " == *' --wait-timeout 120 '* ]] || exit 8
      read_env
      jq -n --arg project "$project" --arg data "$data" --arg state "$state" '{project:$project,data:$data,state:$state}' > "$MOCK_CONTAINER_DIR/$project.json"
      PATH="$MOCK_CPA_HOST_PATH" "$MOCK_CPA_ROOT/bin/cpa-dr" --state-dir "$state" init --allowed-root /data >/dev/null
      if [[ ! -f $state/mock-container-initialized ]]; then
        jq '.peer.identity_file="/state/ssh/id_ed25519"|.peer.known_hosts_file="/state/ssh/known_hosts"' "$state/config.json" > "$state/config.new"
        mv "$state/config.new" "$state/config.json"
        touch "$state/mock-container-initialized"
      fi
    fi;;
  exec)
    [[ $failure != bootstrap ]] || { echo 'fixture bootstrap failed' >&2; exit 7; }
    read_env
    shift; [[ ${1:-} != -T ]] || shift
    [[ ${1:-} == cpa-dr ]] || exit 8; shift
    if [[ ${1:-} == test ]]; then
      flag=$2; path="$data${3#/data}"
      if [[ $flag == -d ]]; then [[ -d $path ]]; else [[ -f $path ]]; fi
      exit $?
    fi
    if [[ ${1:-} == jq ]]; then
      shift; mapped=()
      for arg in "$@"; do [[ $arg != /state/* ]] || arg="$state${arg#/state}"; mapped+=("$arg"); done
      jq "${mapped[@]}"; exit $?
    fi
    [[ ${1:-} == /opt/cpa-dr/bin/cpa-dr ]] || exit 8; shift
    mapped=()
    for arg in "$@"; do [[ $arg != /state && $arg != /state/* ]] || arg="$state${arg#/state}"; mapped+=("$arg"); done
    PATH="$MOCK_CPA_HOST_PATH" "$MOCK_CPA_ROOT/bin/cpa-dr" "${mapped[@]}";;
  down)
    [[ $failure != down ]] || { echo 'fixture stop failed' >&2; exit 7; }
    rm -f -- "$MOCK_CONTAINER_DIR/$project.json";;
  ps) echo 'fixture cpa-dr healthy';;
  port)
    port=$(sed -n 's/^PORT=//p' "$envfile")
    printf '127.0.0.1:%s\n' "$port";;
  *) echo "Unexpected Docker command: $*" >&2; exit 8;;
esac
MOCK
chmod +x "$TMP/mock/docker"
expect_failure() {
  if "$@" > "$TMP/failure.out" 2> "$TMP/failure.err"; then
    printf 'Expected failure: %s\n' "$*" >&2; exit 1
  fi
  if grep -q '服务已启动' "$TMP/failure.out"; then echo 'False startup success' >&2; exit 1; fi
}
start() { bash "$ROOT/start.sh" --role primary --deployment docker "$@"; }
up_count() { grep -c ' up -d ' "$MOCK_COMPOSE_LOG" || true; }
fingerprint() { find "$TMP/deployment dir" -type f -exec sha256sum {} + | sort; }

MOCK_DOCKER_FAIL=info start --help > "$TMP/help.out"
grep -q -- '--data-dir' "$TMP/help.out"
expect_failure start --unknown
expect_failure start --port
expect_failure start --output "$TMP/noninteractive" < /dev/null
[[ ! -e $TMP/noninteractive/.env ]]
for failure in info version old-compose; do
  export MOCK_DOCKER_FAIL=$failure
  expect_failure start --data-dir "$TMP/data dir" --output "$TMP/preflight-$failure"
  [[ ! -e $TMP/preflight-$failure/.env ]]
done
unset MOCK_DOCKER_FAIL
expect_failure start --data-dir "$TMP/missing-data" --output "$TMP/missing"
expect_failure start --data-dir "$TMP/data dir" --output "$TMP/bad-port" --port 99999
[[ ! -e $TMP/missing/.env && ! -e $TMP/bad-port/.env ]]
printf 'PASS: help, invalid input, noninteractive initialization and Docker preflight\n'

# Deliberate inherited overrides must not change mounts, credentials or ports.
export ADMIN_TOKEN=wrong CPA_DATA_PATH="$TMP/other-data" STATE_PATH="$TMP/wrong-state" PORT=1 SSH_PORT=2 BIND_HOST=0.0.0.0 SSH_BIND_HOST=0.0.0.0 DATA_ACCESS=rw
(cd /; start --data-dir "$TMP/data dir" --output "$TMP/deployment dir" --port 18877 --ssh-port 22222 --read-only-data) > "$TMP/first.out"
unset ADMIN_TOKEN CPA_DATA_PATH STATE_PATH PORT SSH_PORT BIND_HOST SSH_BIND_HOST DATA_ACCESS
ENVFILE="$TMP/deployment dir/.env"
STATE="$TMP/deployment dir/state-native"
[[ $(stat -c %a "$ENVFILE") == 600 && $(stat -c %a "$STATE/admin.token") == 600 && $(stat -c %a "$STATE/ssh/id_ed25519") == 600 ]]
grep -q '^DATA_ACCESS=ro$' "$ENVFILE"
grep -q '^BIND_HOST=127.0.0.1$' "$ENVFILE"
grep -q 'http://127.0.0.1:18877' "$TMP/first.out"
grep -q "$(cat "$STATE/admin.token")" "$TMP/first.out"
grep -Fq -- "--project-directory $ROOT --file $ROOT/compose.yaml" "$MOCK_COMPOSE_LOG"
[[ $(up_count) == 1 ]]
printf 'preserve state\n' > "$STATE/sentinel"
printf 'preserve known hosts\n' > "$STATE/ssh/known_hosts"
before=$(fingerprint)
start --output "$TMP/deployment dir" > "$TMP/repeat.out"
start --data-dir "$TMP/data dir" --output "$TMP/deployment dir" --port 18877 --ssh-port 22222 --read-only-data > "$TMP/repeat-args.out"
[[ $(fingerprint) == "$before" && $(up_count) == 3 ]]
printf 'PASS: any working directory, private initialization, effective address and identical reruns\n'

expect_failure start --output "$TMP/deployment dir" --data-dir "$TMP/other-data"
expect_failure start --output "$TMP/deployment dir" --port 18878
expect_failure start --output "$TMP/deployment dir" --ssh-port 22223
[[ $(fingerprint) == "$before" && $(up_count) == 3 ]]
mv "$TMP/data dir" "$TMP/data-gone"
expect_failure start --output "$TMP/deployment dir"
[[ ! -e "$TMP/data dir" ]]
mv "$TMP/data-gone" "$TMP/data dir"
mv "$STATE" "$TMP/state-gone"
expect_failure start --output "$TMP/deployment dir"
[[ ! -e $STATE ]]
mv "$TMP/state-gone" "$STATE"
cp "$ENVFILE" "$TMP/original.env"
sed -i "s|^CPA_DATA_PATH=.*|CPA_DATA_PATH='$ROOT'|" "$ENVFILE"
expect_failure start --output "$TMP/deployment dir"
cp "$TMP/original.env" "$ENVFILE"
sed -i "s|^CPA_DATA_PATH=.*|CPA_DATA_PATH='$STATE'|" "$ENVFILE"
expect_failure start --output "$TMP/deployment dir"
cp "$TMP/original.env" "$ENVFILE"
[[ $(up_count) == 3 ]]
printf 'PASS: conflicting parameters, absent mounts and source/state overlap rejected before startup\n'

printf 'FIXTURE_EXEC=$(touch "%s")\n' "$TMP/should-not-exist" >> "$ENVFILE"
start --output "$TMP/deployment dir" > "$TMP/injection.out"
[[ ! -e $TMP/should-not-exist ]]
for failure in config up; do
  export MOCK_DOCKER_FAIL=$failure
  expect_failure start --data-dir "$TMP/data dir" --output "$TMP/failed-$failure"
  [[ -f $TMP/failed-$failure/.env && -f $TMP/failed-$failure/state-native/admin.token ]]
  grep -q "fixture" "$TMP/failure.err"
done
unset MOCK_DOCKER_FAIL
start --data-dir "$TMP/data dir" --output "$TMP/read-write" > /dev/null
expect_failure start --output "$TMP/read-write" --read-only-data
printf 'PASS: dotenv is not executable, configuration/build/health failures preserve state and return nonzero\n'

# Missing host jq is installed in an isolated PATH, then the full startup runs.
mkdir "$TMP/install-mock"
for tool in bash dirname realpath openssl ssh-keygen stat flock cat mkdir chmod touch sed ln sha256sum mktemp sync mv rm timeout curl; do
  ln -s "$(command -v "$tool")" "$TMP/install-mock/$tool"
done
ln -s "$TMP/mock/docker" "$TMP/install-mock/docker"
export MOCK_APT_LOG="$TMP/apt.log" MOCK_INSTALL_BIN="$TMP/install-mock"
MOCK_HOST_JQ=$(command -v jq); export MOCK_HOST_JQ
cat > "$TMP/install-mock/apt-get" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$MOCK_APT_LOG"
case "$*" in
  update) ;;
  'install -y --no-install-recommends jq') ln -s "$MOCK_HOST_JQ" "$MOCK_INSTALL_BIN/jq";;
  *) echo "Unexpected package operation: $*" >&2; exit 8;;
esac
MOCK
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/install-mock/apt-cache"
cat > "$TMP/install-mock/sudo" <<'MOCK'
#!/usr/bin/env bash
[[ ${1:-} != -- ]] || shift
exec "$@"
MOCK
chmod +x "$TMP/install-mock/apt-get" "$TMP/install-mock/apt-cache" "$TMP/install-mock/sudo"
PATH="$TMP/install-mock" start --yes --data-dir "$TMP/data dir" --output "$TMP/installed-deployment" > "$TMP/installed.out"
grep -q '服务已启动' "$TMP/installed.out"
grep -qx 'install -y --no-install-recommends jq' "$MOCK_APT_LOG"
installed_identity=$(sha256sum "$TMP/installed-deployment/.env" "$TMP/installed-deployment/state-native/ssh/id_ed25519")
PATH="$TMP/install-mock" start --yes --output "$TMP/installed-deployment" > "$TMP/installed-repeat.out"
[[ $(wc -l < "$MOCK_APT_LOG") == 2 ]]
[[ $(sha256sum "$TMP/installed-deployment/.env" "$TMP/installed-deployment/state-native/ssh/id_ed25519") == "$installed_identity" ]]
printf 'PASS: missing jq installation continues through full startup; rerun skips installation and preserves secrets\n'

# New wizard and lifecycle regressions use the same real state/CLI and mock Docker.
workflow() { bash "$ROOT/start.sh" "$@"; }
mkdir -p "$TMP/selected/auths"
printf '{"fixture":true}\n' > "$TMP/selected/settings.json"
sqlite3 "$TMP/selected/usage.sqlite" 'CREATE TABLE sample(value TEXT);'
selected=(--role backup --deployment docker --data-dir "$TMP/selected" --source auths:directory:auths --source config:file:settings.json --source usage:sqlite:usage.sqlite)
workflow "${selected[@]}" --output "$TMP/selected-deployment" > "$TMP/selected.out"
SELECTED_STATE="$TMP/selected-deployment/state-native"
jq -e '.node_role=="backup" and .enabled==false and .allowed_root=="/data" and .sources==[{name:"auths",kind:"directory",path:"/data/auths"},{name:"config",kind:"file",path:"/data/settings.json"},{name:"usage",kind:"sqlite",path:"/data/usage.sqlite"}]' "$SELECTED_STATE/config.json" >/dev/null
jq -e '.phase=="backup_standby" and .configured==true' "$SELECTED_STATE/runtime.json" >/dev/null
jq -e '.status=="ready" and .deployment=="docker"' "$TMP/selected-deployment/.env.docker.json" >/dev/null
[[ $(stat -c %a "$TMP/selected-deployment/.env.docker.json") == 600 ]]
[[ $(jq -r .project_name "$TMP/selected-deployment/.env.docker.json") != $(jq -r .project_name "$TMP/deployment dir/.env.docker.json") ]]
identity=$(sha256sum "$SELECTED_STATE/config.json" "$SELECTED_STATE/admin.token" "$SELECTED_STATE/ssh/id_ed25519")
workflow "${selected[@]}" --output "$TMP/selected-deployment" > /dev/null
[[ $(sha256sum "$SELECTED_STATE/config.json" "$SELECTED_STATE/admin.token" "$SELECTED_STATE/ssh/id_ed25519") == "$identity" ]]
expect_failure workflow --output "$TMP/selected-deployment" --role primary
expect_failure workflow --output "$TMP/selected-deployment" --source auths:directory:.
expect_failure env COMPOSE_PROJECT_NAME=wrong-fixture bash "$ROOT/start.sh" --output "$TMP/selected-deployment"
# UI changes become the baseline on subsequent no-argument starts, not install defaults.
jq '.interval_seconds=43200|.sources[0].name="renamed"' "$SELECTED_STATE/config.json" > "$SELECTED_STATE/config.new"
mv "$SELECTED_STATE/config.new" "$SELECTED_STATE/config.json"
config_before=$(sha256sum "$SELECTED_STATE/config.json")
workflow --output "$TMP/selected-deployment" > /dev/null
[[ $(sha256sum "$SELECTED_STATE/config.json") == "$config_before" ]]
expect_failure workflow "${selected[@]}" --output "$TMP/selected-deployment"
workflow --role backup --deployment docker --data-dir "$TMP/selected" --source future:directory:future/auths --output "$TMP/future-backup" > /dev/null
[[ ! -e $TMP/selected/future ]]
expect_failure workflow --role primary --deployment docker --data-dir "$TMP/selected" --source future:directory:future/auths --output "$TMP/future-primary"
[[ ! -e $TMP/future-primary/.env ]]
for spec in 'dup:directory:auths dup:file:settings.json' 'bad:unknown:auths' 'outside:directory:../other-data'; do
  args=()
  for item in $spec; do args+=(--source "$item"); done
  expect_failure workflow --role primary --deployment docker --data-dir "$TMP/selected" --output "$TMP/invalid-sources" "${args[@]}"
done
expect_failure workflow --role primary --deployment docker --data-dir "$TMP/selected" --source all:directory:. --source child:directory:auths --output "$TMP/overlapping-sources"
ln -s "$TMP/other-data" "$TMP/selected/link"
expect_failure workflow --role primary --deployment docker --data-dir "$TMP/selected" --source link:directory:link --output "$TMP/linked-source"
expect_failure workflow --role unknown --deployment docker --data-dir "$TMP/selected" --output "$TMP/bad-role"
expect_failure workflow --role primary --deployment unknown --data-dir "$TMP/selected" --output "$TMP/bad-mode"
expect_failure workflow --role primary --deployment docker --data-dir "$TMP/selected" --install-root "$TMP/native-only" --output "$TMP/docker-native-options"
printf 'PASS: persisted backup role, multiple source kinds/path mapping, missing backup targets, conflict checks, distinct projects and UI changes preserved\n'

export MOCK_DOCKER_FAIL=bootstrap
expect_failure workflow "${selected[@]}" --output "$TMP/bootstrap-retry"
RETRY_STATE="$TMP/bootstrap-retry/state-native"
[[ -f $RETRY_STATE/.env.bootstrap.json ]]
jq -e '.status=="pending"' "$TMP/bootstrap-retry/.env.docker.json" >/dev/null
retry_identity=$(sha256sum "$RETRY_STATE/admin.token" "$RETRY_STATE/ssh/id_ed25519")
retry_node=$(jq -r .node_id "$RETRY_STATE/config.json")
unset MOCK_DOCKER_FAIL
workflow --output "$TMP/bootstrap-retry" > /dev/null
jq -e '.node_role=="backup" and (.sources|length)==3 and .enabled==false' "$RETRY_STATE/config.json" >/dev/null
[[ $(sha256sum "$RETRY_STATE/admin.token" "$RETRY_STATE/ssh/id_ed25519") == "$retry_identity" && $(jq -r .node_id "$RETRY_STATE/config.json") == "$retry_node" ]]
[[ ! -e $RETRY_STATE/.env.bootstrap.json ]]
printf 'PASS: interrupted bootstrap resumes once without changing keys or node ID\n'

pty_command=$(printf '%q ' bash "$ROOT/start.sh" --output "$TMP/wizard")
printf '2\n%s\nauths\nauths\n1\ny\nsettings.json\nconfig\n2\ny\nusage.sqlite\nusage\n3\nn\n2\nn\ny\n' "$TMP/selected" | script -q -e -c "$pty_command" /dev/null > "$TMP/wizard.out" 2>&1
jq -e '.node_role=="backup" and (.sources|length)==3' "$TMP/wizard/state-native/config.json" >/dev/null
role_line=$(grep -n '1. 选择本机角色' "$TMP/wizard.out" | cut -d: -f1)
data_line=$(grep -n '2. 选择需要备份的数据' "$TMP/wizard.out" | cut -d: -f1)
confirm_line=$(grep -n '4. 完整安装计划' "$TMP/wizard.out" | cut -d: -f1)
mode_line=$(grep -n '3. 选择部署方式' "$TMP/wizard.out" | cut -d: -f1)
((role_line < data_line && data_line < mode_line && mode_line < confirm_line))
pty_command=$(printf '%q ' bash "$ROOT/start.sh" --output "$TMP/cancelled-wizard")
mutation_before=$(grep -c ' up -d ' "$MOCK_COMPOSE_LOG")
if printf '1\n%s\nauths\nauths\n1\nn\n2\nn\nn\n' "$TMP/selected" | script -q -e -c "$pty_command" /dev/null > "$TMP/cancelled.out" 2>&1; then echo 'wizard cancellation accepted' >&2; exit 1; fi
[[ ! -e $TMP/cancelled-wizard ]]
# Read-only Compose capability probes are allowed; no mutation occurs before confirmation.
[[ $(grep -c ' up -d ' "$MOCK_COMPOSE_LOG") == "$mutation_before" ]]
grep -q '4. 完整安装计划' "$TMP/cancelled.out"
printf 'PASS: PTY wizard enforces role/data/deployment/final-plan order and cancellation has no deployment/package side effects\n'

pty_command=$(printf '%q ' bash "$ROOT/start.sh" install --output "$TMP/advanced-plan" --data-dir "$TMP/selected")
if printf '1\nauths\nauths\n1\nn\n2\ny\n%s\n18879\n22229\nn\n' "$TMP/custom-plan" | script -q -e -c "$pty_command" /dev/null > "$TMP/advanced-plan.out" 2>&1; then echo 'advanced plan cancellation accepted' >&2; exit 1; fi
grep -Fq "配置目录：$TMP/custom-plan" "$TMP/advanced-plan.out"
grep -q '管理监听：127.0.0.1:18879' "$TMP/advanced-plan.out"
grep -q '专用 SSH 端口：22229' "$TMP/advanced-plan.out"
[[ ! -e $TMP/advanced-plan && ! -e $TMP/custom-plan ]]
printf 'PASS: custom directory and port wizard appear in final plan; cancellation creates neither directory\n'

down_count() { grep -c ' down ' "$MOCK_COMPOSE_LOG" || true; }
down_before=$(down_count)
selected_before=$(find "$TMP/selected-deployment" -type f -exec sha256sum {} + | sort)
expect_failure workflow uninstall --output "$TMP/selected-deployment" < /dev/null
[[ $(down_count) == "$down_before" && $(find "$TMP/selected-deployment" -type f -exec sha256sum {} + | sort) == "$selected_before" ]]
pty_command=$(printf '%q ' bash "$ROOT/start.sh" --purge --output "$TMP/selected-deployment")
if printf 'no\n' | script -q -e -c "$pty_command" /dev/null > "$TMP/cancelled-purge.out" 2>&1; then echo 'purge cancellation accepted' >&2; exit 1; fi
grep -q '请输入 PURGE' "$TMP/cancelled-purge.out"
[[ $(down_count) == "$down_before" && $(find "$TMP/selected-deployment" -type f -exec sha256sum {} + | sort) == "$selected_before" ]]
export MOCK_DOCKER_FAIL=down
expect_failure workflow uninstall --purge --yes --output "$TMP/selected-deployment"
unset MOCK_DOCKER_FAIL
[[ -f $SELECTED_STATE/config.json && -f $TMP/selected-deployment/.env ]]
jq -e '.status=="ready"' "$TMP/selected-deployment/.env.docker.json" >/dev/null
workflow uninstall --yes --output "$TMP/selected-deployment" > "$TMP/uninstall.out"
[[ -f $SELECTED_STATE/config.json && -f $TMP/selected-deployment/.env ]]
jq -e '.status=="uninstalled"' "$TMP/selected-deployment/.env.docker.json" >/dev/null
workflow --output "$TMP/selected-deployment" > /dev/null
[[ $(sha256sum "$SELECTED_STATE/config.json") == "$config_before" ]]
cp "$TMP/selected-deployment/.env.docker.json" "$TMP/record.original"
jq '.version=2' "$TMP/record.original" > "$TMP/selected-deployment/.env.docker.json"
down_before=$(down_count)
expect_failure workflow --purge --yes --output "$TMP/selected-deployment"
[[ $(down_count) == "$down_before" ]]
cp "$TMP/record.original" "$TMP/selected-deployment/.env.docker.json"
cp "$SELECTED_STATE/.cpa-dr-install-id" "$TMP/id.original"
printf '00000000-0000-0000-0000-000000000000\n' > "$SELECTED_STATE/.cpa-dr-install-id"
expect_failure workflow --purge --yes --output "$TMP/selected-deployment"
[[ $(down_count) == "$down_before" && -f $SELECTED_STATE/config.json ]]
cp "$TMP/id.original" "$SELECTED_STATE/.cpa-dr-install-id"
mv "$SELECTED_STATE" "$TMP/state-preserved"
ln -s "$TMP/state-preserved" "$SELECTED_STATE"
expect_failure workflow --purge --yes --output "$TMP/selected-deployment"
[[ $(down_count) == "$down_before" && -f $TMP/state-preserved/config.json ]]
rm "$SELECTED_STATE"
mv "$TMP/state-preserved" "$SELECTED_STATE"
printf 'keep unknown configuration\n' > "$TMP/selected-deployment/unknown.conf"
source_before=$(find "$TMP/selected" -type f -exec sha256sum {} + | sort)
workflow --purge --yes --output "$TMP/selected-deployment" > "$TMP/purge.out"
[[ ! -e $SELECTED_STATE && ! -e $TMP/selected-deployment/.env && ! -e $TMP/selected-deployment/.env.docker.json && -f $TMP/selected-deployment/unknown.conf ]]
[[ $(find "$TMP/selected" -type f -exec sha256sum {} + | sort) == "$source_before" ]]
! grep -Eq 'prune|--rmi|--volumes|--remove-orphans' "$MOCK_COMPOSE_LOG"
printf 'PASS: confirmation, failed stop, bounded uninstall/reinstall/purge, record/ownership/link guards and original/unknown data preservation\n'
