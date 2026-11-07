#!/usr/bin/env bash
# Install/uninstall only this service; configuration is data, never Shell code.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077
script_directory=.
[[ ${BASH_SOURCE[0]} != */* ]] || script_directory=${BASH_SOURCE[0]%/*}/
ROOT=$(cd -- "$script_directory" && pwd -P)
original_args=("$@")
action='' log_tail=50 log_follow=0 log_options=0
data='' output='' output_given=0 port='' ssh_port='' role='' deployment='' bind=''
state_arg='' root_arg='' read_only=0 install_deps=1 assume_yes=0 uninstall=0 purge=0
existing=0 wizard=0 record='' manifest='' lock_file=''
source_specs=() source_names=() source_kinds=() source_paths=()
usage() {
  local line
  while IFS= read -r line; do printf '%s\n' "$line"; done <<'HELP'
用法：bash start.sh                         # 中文管理菜单（终端）
      bash start.sh menu [--output DIR] [--deployment native|docker]
      bash start.sh install [安装参数 ...]
      bash start.sh --role primary|backup --data-dir TARGET --deployment native|docker
                    [--source 标签:directory|file|sqlite:路径 ...]
                    [--output DIR] [--port 8787] [--ssh-port 2222]
                    [--read-only-data] [--yes | --no-install-deps]
      bash start.sh uninstall [--output DIR] [--deployment native|docker] [--yes]
      bash start.sh uninstall --purge [--output DIR] [--yes]
      bash start.sh status|doctor [--output DIR] [--deployment native|docker]
      bash start.sh start|stop|restart [--output DIR] [--yes]
      bash start.sh logs [--output DIR] [--tail 50] [--follow]

向导顺序：选择安装 → 主机/备机 → 数据与项目 → 部署方式 → 完整计划确认。
路径可相对数据父目录；不指定 --source 时，非交互选择整个父目录。
备机可指定尚未存在的恢复目标。两端应使用相同标签与类型。
首次非交互必须明确指定 --role、--data-dir、--deployment。
无参数重跑进入菜单；install 恢复已有部署，保留页面设置、密钥和备份。
旧带参数安装命令兼容；非交互无参数报错，不等待输入。
status/doctor 只读，不自动提权、安装依赖或创建容器；未知不等于未安装。
服务管理只控制本服务；停止/重启/卸载拒绝中断正在运行的任务。
Linux 本地额外支持 --install-root DIR、--state-dir DIR、--bind-host HOST；
默认配置目录 /etc/cpa-dr-native，服务 /opt/cpa-dr-native，状态 /var/lib/cpa-dr-native。
Docker 默认配置目录为脚本目录；自定义 --output 后，重跑/卸载也须指定该目录。
缺失依赖经确认后从现有 apt-get/dnf/yum 软件源安装；本地安装需要 root/sudo。
--yes 确认安装/卸载；--no-install-deps 只检查依赖，二者互斥。
卸载只移除本服务容器/systemd单元，保留配置、代码、备份和密钥。
--purge 额外清除专用状态与本地安装文件，需输入 PURGE 或显式 --yes；
始终保留原始数据、源码及共用依赖，不执行全局 Docker prune。
HELP
}
fail() { printf '操作失败：%s\n' "$*" >&2; exit 1; }
within() { [[ $1 == "$2" || $1 == "${2%/}/"* ]]; }
yes_answer() { [[ $1 == y || $1 == Y || $1 == yes || $1 == YES ]]; }
prompt() { read -r -p "$1" "$2" || fail '输入已结束，操作未确认'; }
set_action() { [[ -z $action || $action == "$1" ]] || fail '每次只能指定一种操作'; action=$1; }
choose_role() {
  local answer
  printf '\n1. 选择本机角色\n  1) 主机（主服务器）\n  2) 备机（备服务器）\n'
  while :; do
    prompt '请选择 [1/2]：' answer
    case $answer in 1|primary) role=primary; break;; 2|backup) role=backup; break;; *) printf '请输入 1 或 2。\n';; esac
  done
}
choose_sources() {
  local path name kind answer default_name default_kind probe_path index=0
  printf '\n2. 选择需要备份的数据（备机填写对应恢复目标）\n'
  [[ -n $data ]] || prompt '请输入已存在的 CPA 数据父目录：' data
  [[ -d $data ]] || fail '--data-dir 必须指向已存在的数据父目录'
  printf '数据父目录：%s\n可逐项输入目录、文件或 SQLite；不要选择节点专属凭据和本服务状态。\n' "$data"
  while :; do
    ((index+=1))
    prompt '备份路径（相对父目录或绝对路径；回车=整个父目录）：' path
    path=${path:-.}
    default_name=${path%/}; default_name=${default_name##*/}
    [[ $path != . && $path != "$data" ]] || default_name=data
    [[ $default_name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || default_name="data$index"
    prompt "数据标签（两端一致，默认 $default_name）：" name
    name=${name:-$default_name}
    default_kind=1
    probe_path=$path; [[ $probe_path == /* ]] || probe_path="$data/$probe_path"
    case $path in *.sqlite|*.sqlite3|*.db) default_kind=3;; *)
      if [[ -f $probe_path ]]; then default_kind=2; fi;; esac
    prompt "类型：1)目录 2)普通文件 3)SQLite [默认 $default_kind]：" kind
    case ${kind:-$default_kind} in 1|directory) kind=directory;; 2|file) kind='file';; 3|sqlite) kind=sqlite;; *) fail '数据类型须选择 1、2 或 3';; esac
    source_specs+=("$name:$kind:$path")
    prompt '继续添加数据？[y/N] ' answer
    yes_answer "$answer" || break
  done
}
parse_sources() {
  local spec name rest kind path
  source_names=(); source_kinds=(); source_paths=()
  for spec in "${source_specs[@]}"; do
    [[ $spec == *:*:* ]] || fail '--source 格式为 标签:directory|file|sqlite:路径'
    name=${spec%%:*}; rest=${spec#*:}; kind=${rest%%:*}; path=${rest#*:}
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || fail "数据标签格式异常：$name"
    [[ $kind == directory || $kind == file || $kind == sqlite ]] || fail "数据类型异常：$kind"
    [[ -n $path && $path != *[\'\"\\\$:]* && ! $path =~ [[:cntrl:]] ]] || fail '数据路径含不支持的字符'
    [[ " ${source_names[*]} " != *" $name "* ]] || fail "数据标签重复：$name"
    source_names+=("$name"); source_kinds+=("$kind"); source_paths+=("$path")
  done
  ((${#source_names[@]} <= 128)) || fail '最多选择128项数据'
}
normalize_sources() {
  local i j path kind cursor host_check effective_role=${1:-${role:-primary}}
  if [[ $# == 0 && -z $role && -r ${state:-}/config.json ]]; then effective_role=$(jq -r .node_role "$state/config.json"); fi
  for ((i=0; i<${#source_paths[@]}; i++)); do
    path=${source_paths[i]}; [[ $path == /* ]] || path="$data/$path"
    # Reject links before canonicalization rather than silently following them.
    cpa_start_no_links "$path"
    path=$(realpath -m -- "$path")
    within "$path" "$data" || fail "备份项目超出数据父目录：$path"
    for ((j=0; j<i; j++)); do
      cpa_paths_intersect "$path" "${source_paths[j]}" && fail '备份项目相互重叠，请分别选择不重叠的目录/文件'
    done
    kind=${source_kinds[i]}
    host_check=1
    if [[ $deployment == docker ]]; then
      cursor=${path%/*}
      while within "$cursor" "$data"; do
        if [[ -d $cursor && ! -x $cursor ]]; then host_check=0; break; fi
        [[ $cursor != "$data" ]] || break
        cursor=${cursor%/*}
      done
    fi
    # Container root may read CPA directories the Docker client user cannot traverse.
    # Deferred primary existence/type checks run inside the container before config set.
    if ((host_check)) && [[ $effective_role == primary || -e $path ]]; then
      if [[ $kind == directory ]]; then [[ -d $path ]] || fail "目录不存在或类型不匹配：$path"
      else [[ -f $path ]] || fail "文件不存在或类型不匹配：$path"; fi
    fi
    source_paths[i]=$path
  done
}
sources_json() {
  local prefix=$1 result='[]' path i
  for ((i=0; i<${#source_paths[@]}; i++)); do
    path=${source_paths[i]}
    [[ $prefix != /data ]] || path="/data${path#"$data"}"
    result=$(jq -c --arg name "${source_names[i]}" --arg kind "${source_kinds[i]}" --arg path "$path" '.+[{name:$name,kind:$kind,path:$path}]' <<< "$result")
  done
  printf '%s\n' "$result"
}
while (($#)); do
  case $1 in
    --data-dir|--output|--port|--ssh-port|--role|--deployment|--source|--state-dir|--install-root|--bind-host)
      if (($# < 2)) || [[ -z $2 ]]; then fail "参数缺少值：$1"; fi
      case $1 in
        --data-dir) data=$2;; --output) output=$2; output_given=1;; --port) port=$2;; --ssh-port) ssh_port=$2;;
        --role) role=$2;; --deployment) deployment=$2;; --source) source_specs+=("$2");;
        --state-dir) state_arg=$2;; --install-root) root_arg=$2;; --bind-host) bind=$2;;
      esac; shift 2;;
    --read-only-data) read_only=1; shift;;
    --yes) assume_yes=1; shift;;
    --no-install-deps) install_deps=0; shift;;
    install|menu|status|doctor|start|stop|restart|logs) set_action "$1"; shift;;
    uninstall|--uninstall) set_action uninstall; uninstall=1; shift;;
    --purge) set_action uninstall; uninstall=1; purge=1; shift;;
    --tail) (($# >= 2)) || fail '--tail 缺少值'; log_tail=$2; log_options=1; shift 2;;
    --follow) log_follow=1; log_options=1; shift;;
    --help|-h) usage; exit 0;;
    *) fail "未知参数：$1（使用 --help 查看用法）";;
  esac
 done
if [[ -z $action ]]; then
  if ((${#original_args[@]})); then action=install
  elif [[ -t 0 ]]; then action=menu
  else usage >&2; fail '非交互运行请明确指定操作及参数'; fi
fi
if [[ ! $log_tail =~ ^[0-9]{1,4}$ ]] || ((10#$log_tail < 1 || 10#$log_tail > 1000)); then fail '--tail 须为1到1000'; fi
if [[ $action != logs ]]; then
  ((log_options == 0)) || fail '--tail/--follow 仅用于 logs'
fi
((assume_yes == 0 || install_deps == 1)) || fail '--yes 与 --no-install-deps 不可同时使用'
[[ -z $role || $role == primary || $role == backup ]] || fail '--role 须为 primary 或 backup'
[[ -z $deployment || $deployment == native || $deployment == docker ]] || fail '--deployment 须为 native 或 docker'
for value in "$port" "$ssh_port"; do
  [[ -n $value ]] || continue
  [[ $value =~ ^[0-9]+$ && ${#value} -le 5 ]] || fail '端口须在1到65535之间'
  ((10#$value >= 1 && 10#$value <= 65535)) || fail '端口须在1到65535之间'
done
if ((uninstall)); then
  [[ -z $role && -z $data && -z $port && -z $ssh_port && -z $bind && -z $state_arg && -z $root_arg && $read_only == 0 && ${#source_specs[@]} == 0 ]] || fail '卸载仅接受 --output、--deployment、--purge 和确认/依赖检查选项'
fi
# Load trusted functions before any backend-specific dependency or mutation.
# shellcheck source=scripts/start-dependencies.sh
source "$ROOT/scripts/start-dependencies.sh"
# shellcheck source=scripts/start-lifecycle.sh
source "$ROOT/scripts/start-lifecycle.sh"
# shellcheck source=scripts/start-manager.sh
source "$ROOT/scripts/start-manager.sh"
if [[ $action != install && $action != uninstall ]]; then
  [[ -z $role && -z $data && -z $port && -z $ssh_port && -z $bind && -z $state_arg && -z $root_arg && $read_only == 0 && ${#source_specs[@]} == 0 ]] || fail '管理操作仅接受目标目录/方式及对应确认或日志选项'
  [[ $action != menu || ( $assume_yes == 0 && $install_deps == 1 ) ]] || fail 'menu 不接受自动确认或依赖安装选项'
  cpa_manager_dispatch
  exit 0
fi

# Filenames identify the backend even when jq/coreutils have not been installed yet.
if [[ -z $output ]]; then
  if [[ $deployment == native ]]; then output=/etc/cpa-dr-native
  elif [[ $deployment == docker ]]; then output=$ROOT
  elif [[ -e /etc/cpa-dr-native/.env.native.json && ( -e $ROOT/.env || -e $ROOT/.env.docker.json ) ]]; then
    fail '检测到本地与Docker两份部署，请明确 --deployment 或 --output'
  elif [[ -e /etc/cpa-dr-native/.env.native.json ]]; then output=/etc/cpa-dr-native
  else output=$ROOT; fi
fi
detected=''
if [[ -e $output/.env.native.json || -L $output/.env.native.json ]]; then detected=native; fi
if [[ -e $output/.env.docker.json || -L $output/.env.docker.json || -e $output/.env || -L $output/.env ]]; then
  [[ -z $detected ]] || fail '部署目录含两种安装记录，请核对 --output'
  detected=docker
fi
if [[ -n $detected ]]; then
  [[ -z $deployment || $deployment == "$detected" ]] || fail '部署方式与已有安装冲突；保留原部署'
  deployment=$detected; existing=1
elif ((uninstall)); then fail '未找到安装记录，请核对 --output DIR'
else
  if [[ -t 0 && ( -z $role || -z $data || ${#source_specs[@]} == 0 || -z $deployment ) ]]; then wizard=1; fi
  if [[ -z $role ]]; then [[ -t 0 ]] || fail '首次非交互运行请提供 --role primary|backup'; choose_role; fi
  if ((${#source_specs[@]} == 0)) && [[ -t 0 ]]; then choose_sources
  else
    if [[ -z $data ]]; then [[ -t 0 ]] || fail '首次非交互运行请提供 --data-dir TARGET'; prompt '请输入已存在的 CPA 数据父目录：' data; fi
    [[ -d $data ]] || fail '--data-dir 必须指向已存在的数据父目录'
    ((${#source_specs[@]} > 0)) || source_specs+=(data:directory:.)
  fi
  parse_sources
  if [[ -z $deployment ]]; then
    [[ -t 0 ]] || fail '首次非交互运行请提供 --deployment native|docker'
    printf '\n3. 选择部署方式\n  1) Linux 本地直接部署（systemd）\n  2) Docker 部署（Compose）\n'
    while :; do
      prompt '请选择 [1/2]：' answer
      case $answer in 1|native) deployment=native; break;; 2|docker) deployment=docker; break;; *) printf '请输入 1 或 2。\n';; esac
    done
    ((output_given)) || { [[ $deployment != native ]] || output=/etc/cpa-dr-native; }
  fi
fi
parse_sources
if ((wizard)); then cpa_manager_install_options; fi
if [[ $deployment == docker ]]; then
  [[ -z $state_arg && -z $root_arg && -z $bind ]] || fail '--state-dir、--install-root、--bind-host 仅用于Linux本地部署'
fi
# Do not let unrelated exports override either the private file or native initializer.
unset ADMIN_TOKEN CPA_DATA_PATH STATE_PATH PORT SSH_PORT BIND_HOST SSH_BIND_HOST DATA_ACCESS
unset CPA_ADMIN_TOKEN CPA_ALLOWED_ROOT CPA_STATE_DIR CPA_ROOT
dependency_mode=$deployment
((uninstall == 0)) || dependency_mode="uninstall-$deployment"
if ((uninstall)); then cpa_start_ensure_dependencies 0 0 "$dependency_mode"
else cpa_manager_install_plan; cpa_start_ensure_dependencies "$install_deps" "$assume_yes" "$dependency_mode"; fi
if [[ $deployment == native && $EUID != 0 ]]; then cpa_start_elevate_native; fi
cpa_start_no_links "$output"
output=$(realpath -m -- "$output")
[[ $output != *[\'\"\\\$:]* && ! $output =~ [[:cntrl:]] ]] || fail '部署路径含不支持的字符，参见 README'
if ((uninstall == 0)) && [[ -n $data ]]; then
  [[ -d $data ]] || fail '数据父目录不存在'
  data=$(realpath -e -- "$data")
fi
manifest="$output/.env.$deployment.json"
cpa_start_lock
if [[ -e $manifest || -L $manifest ]]; then cpa_start_load_record; fi
if [[ $deployment == native ]]; then
  if ((uninstall)); then cpa_start_uninstall_native; else cpa_start_install_native; fi
  exit 0
fi

# Docker keeps the original setup/Compose validation and health-wait workflow.
docker compose version >/dev/null || fail '请安装 Docker Compose v2 插件'
if ((uninstall == 0)); then
  up_help=$(docker compose up --help) || fail '读取 Compose 启动选项失败'
  [[ $up_help =~ (^|[[:space:]])--wait([[:space:]]|$) && $up_help =~ (^|[[:space:]])--wait-timeout([[:space:]]|$) ]] || fail 'Compose v2 须支持 up --wait --wait-timeout'
fi
docker info >/dev/null || fail 'Docker daemon 未就绪或当前用户没有访问权限'
envfile="$output/.env"
fresh=0
if [[ -e $envfile || -L $envfile ]]; then
  [[ -f $envfile && ! -L $envfile ]] || fail '.env 须为普通配置文件，不接受符号链接'
  printf '使用已有配置：%s（保留密钥和状态）\n' "$envfile"
else
  ((uninstall == 0 && existing == 0)) || fail '已有安装缺少 .env，保留状态，请核对原配置'
  cpa_start_validate_data "$data"
  normalize_sources
  setup_args=(--data-dir "$data" --output "$output")
  [[ -z $port ]] || setup_args+=(--port "$port")
  [[ -z $ssh_port ]] || setup_args+=(--ssh-port "$ssh_port")
  ((read_only == 0)) || setup_args+=(--read-only-data)
  bash "$ROOT/scripts/setup.sh" "${setup_args[@]}" >/dev/null
  fresh=1
fi
if [[ -n $record ]]; then
  project=$(jq -r .project_name <<< "$record")
  [[ -z ${COMPOSE_PROJECT_NAME:-} || $COMPOSE_PROJECT_NAME == "$project" ]] || fail 'COMPOSE_PROJECT_NAME 与已有安装记录冲突'
elif [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then project=$COMPOSE_PROJECT_NAME
elif ((fresh)) && [[ $output != "$ROOT" ]]; then
  project=$(printf '%s' "$output" | sha256sum); project="cpa-dr-${project:0:12}"
else project=${ROOT##*/}; fi
[[ $project =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail 'Compose 项目名须使用小写字母、数字、下划线或连字符'
compose=(docker compose --project-directory "$ROOT" --file "$ROOT/compose.yaml" --env-file "$envfile" --project-name "$project")
if ((fresh)); then
  state="$output/state-native"
  cpa_start_create_record docker "$state" '' "$project"
  cpa_start_write_bootstrap /data
fi
"${compose[@]}" config --quiet || fail 'Compose 配置检查失败；已保留 .env 和状态'
model=$("${compose[@]}" config --format json) || fail '读取 Compose 有效配置失败'
config_value() {
  local query
  case $1 in
    CPA_DATA_PATH) query='.services["cpa-dr"].volumes[] | select(.target == "/data" and .type == "bind") | .source';;
    STATE_PATH) query='.services["cpa-dr"].volumes[] | select(.target == "/state" and .type == "bind") | .source';;
    PORT) query='.services["cpa-dr"].ports[] | select(.target == 8787) | .published';;
    SSH_PORT) query='.services["cpa-dr"].ports[] | select(.target == 22) | .published';;
    DATA_ACCESS) query='.services["cpa-dr"].volumes[] | select(.target == "/data") | if .read_only == true then "ro" else "rw" end';;
    ADMIN_TOKEN) query='.services["cpa-dr"].environment.CPA_ADMIN_TOKEN';;
    *) return 1;;
  esac
  jq -er "$query" <<< "$model"
}
effective_data=$(config_value CPA_DATA_PATH) || fail '.env 缺少 CPA_DATA_PATH'
state=$(config_value STATE_PATH) || fail '.env 缺少 STATE_PATH'
[[ $effective_data == /* ]] || effective_data="$ROOT/$effective_data"
[[ $state == /* ]] || state="$ROOT/$state"
cpa_start_no_links "$state"
# An uninstall may proceed after the original data has been moved, but never recreate it.
if ((uninstall == 0)); then [[ -d $effective_data && -d $state ]] || fail '数据或状态目录不存在；不自动创建空目录'; fi
effective_data=$(realpath -m -- "$effective_data"); state=$(realpath -m -- "$state")
for value in "$effective_data" "$state"; do
  [[ $value != *[\'\"\\\$:]* && ! $value =~ [[:cntrl:]] ]] || fail '挂载路径含不支持的字符'
done
cpa_start_validate_data "$effective_data"
cpa_paths_intersect "$effective_data" "$state" && fail '数据目录与状态目录必须独立'
if [[ -n $record ]]; then
  [[ $(jq -r .state_dir <<< "$record") == "$state" && $(jq -r .data_dir <<< "$record") == "$effective_data" ]] || fail '挂载路径与安装记录冲突，未修改/删除原状态'
fi
if [[ -n $data ]]; then
  [[ -d $data && $(realpath -e -- "$data") == "$effective_data" ]] || fail '--data-dir 与已有 .env 冲突'
fi
data=$effective_data
for key in PORT SSH_PORT; do
  configured=$(config_value "$key") || fail ".env 缺少 $key"
  [[ $configured =~ ^[0-9]+$ && ${#configured} -le 5 ]] || fail ".env 的 $key 格式异常"
  ((10#$configured >= 1 && 10#$configured <= 65535)) || fail ".env 的 $key 超出端口范围"
  requested=$port; [[ $key != SSH_PORT ]] || requested=$ssh_port
  if [[ -n $requested ]] && ((10#$requested != 10#$configured)); then fail "$key 与已有 .env 冲突；修改监听请明确编辑 .env 后重跑"; fi
done
access=$(config_value DATA_ACCESS) || fail '.env 缺少 DATA_ACCESS'
[[ $access == rw || $access == ro ]] || fail 'DATA_ACCESS 须为 rw 或 ro'
if ((read_only)) && [[ $access != ro ]]; then fail '--read-only-data 与已有 .env 冲突'; fi
if [[ -z $record ]]; then
  [[ -d $state ]] || fail '缺少原状态目录，请核对原安装'
  cpa_start_create_record docker "$state" '' "$project"
  if [[ -f $state/config.json ]]; then cpa_start_record_status ready
  elif ((${#source_specs[@]} > 0)) || [[ -n $role ]]; then normalize_sources; cpa_start_write_bootstrap /data
  else cpa_start_record_status ready; fi
fi
if ((uninstall)); then unset model; cpa_start_uninstall_docker; exit 0; fi
[[ -f $state/admin.token && -f $state/ssh/id_ed25519.pub ]] || fail '状态目录缺少管理员令牌或 SSH 公钥'
token=$(< "$state/admin.token")
[[ $token =~ ^[a-zA-Z0-9_-]{32,256}$ ]] || fail '管理员令牌格式异常'
[[ $(config_value ADMIN_TOKEN) == "$token" ]] || fail '.env 管理员令牌与状态目录不一致'
unset model
cpa_start_check_requested "$state/config.json" /data
printf '正在构建并启动，管理健康检查最多等待120秒……\n'
if ! "${compose[@]}" up -d --build --wait --wait-timeout 120; then
  printf '启动失败：构建或管理健康检查未通过，已保留配置、密钥和数据。\n排错命令：' >&2
  printf '%q ' "${compose[@]}" logs --tail 50 >&2; printf '\n' >&2; exit 1
fi
cpa_start_apply_docker_bootstrap
cpa_start_record_status ready
"${compose[@]}" ps
address=$("${compose[@]}" port cpa-dr 8787) || fail '读取实际管理端口失败'
[[ -n $address ]] || fail '未找到管理端口映射'
printf '\n服务已启动（仅管理服务健康，不代表 CPA 业务就绪）。\n部署方式：Docker\n管理地址：http://%s\n配置文件：%s\n管理员令牌：%s\n本机 SSH 公钥：\n' "$address" "$envfile" "$token"
cat -- "$state/ssh/id_ed25519.pub"
printf '%s\n' '已保留/初始化角色与数据设置；新安装备份未启用。交换公钥并核对指纹后在页面启用。'
