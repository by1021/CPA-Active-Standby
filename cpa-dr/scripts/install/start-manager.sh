#!/usr/bin/env bash
# Trusted management UI. Read-only paths never initialize, elevate or build.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2154,SC2016,SC2030,SC2031

cpa_manager_select() {
  local answer native_candidate=0 docker_candidate=0
  if [[ -z $output ]]; then
    if [[ -e /etc/cpa-dr-native/.env.native.json || -L /etc/cpa-dr-native/.env.native.json || ( -d /etc/cpa-dr-native && ! -x /etc/cpa-dr-native ) ]]; then native_candidate=1; fi
    if [[ -e $ROOT/.env || -e $ROOT/.env.docker.json || -L $ROOT/.env ]]; then docker_candidate=1; fi
    if [[ $deployment == native ]]; then output=/etc/cpa-dr-native
    elif [[ $deployment == docker ]]; then output=$ROOT
    elif ((native_candidate && docker_candidate)); then
      [[ -t 0 ]] || fail '检测到多份部署，请指定 --deployment 或 --output'
      printf '检测到多份部署：\n  1) Linux 本地\n  2) Docker\n  0) 退出\n'
      while :; do
        prompt '请选择目标 [0-2]：' answer
        case $answer in 1) output=/etc/cpa-dr-native; manager_target_fixed=1; break;; 2) output=$ROOT; manager_target_fixed=1; break;; 0) exit 0;; *) printf '请输入 0、1 或 2。\n';; esac
      done
    elif ((native_candidate)); then output=/etc/cpa-dr-native
    else output=$ROOT; fi
  fi
  command -v realpath >/dev/null || return 0
  output=$(realpath -ms -- "$output")
}

cpa_manager_command() { timeout 8 "$@"; }

cpa_manager_snapshot() {
  local detected='' details ids status_data unit active=0 failed=0 transitioning=0 load active_state cursor
  manager_install='未安装'; manager_service='未安装'; manager_reason=''
  manager_web='未检测'; manager_api='未检测'; manager_ssh='未检测'
  manager_runtime=''; manager_backend=''; manager_container=''; record=''
  manager_address=''; manager_port=''; manager_ssh_port=''; manager_record_state=''
  state=''; native_root=''; manager_ssh_address=''
  if ! command -v jq >/dev/null || ! command -v realpath >/dev/null || ! command -v timeout >/dev/null; then
    manager_install='状态未知'; manager_service='未知'; manager_reason='缺少 jq/realpath/timeout；仅显示菜单，不安装依赖'; return 0
  fi
  if ! (cpa_start_no_links "$output") 2>/dev/null; then
    manager_install='记录异常'; manager_service='未知'; manager_reason='目标路径含符号链接'; return 0
  fi
  cursor=$output
  while :; do
    if [[ -d $cursor && ! -x $cursor ]]; then
      manager_install='状态未知'; manager_service='未知'; manager_reason='配置目录或祖先目录权限不足'; return 0
    fi
    [[ $cursor != / ]] || break
    cursor=${cursor%/*}; cursor=${cursor:-/}
  done
  if [[ -e $output/.env.native.json || -L $output/.env.native.json ]]; then detected=native; fi
  if [[ -e $output/.env.docker.json || -L $output/.env.docker.json || -e $output/.env || -L $output/.env ]]; then
    if [[ -n $detected ]]; then manager_install='记录异常'; manager_service='未知'; manager_reason='目录含两种部署记录，请核对 --output'; return 0; fi
    detected=docker
  fi
  [[ -n $detected ]] || return 0
  manager_backend=$detected
  if [[ -n $deployment && $deployment != "$detected" ]]; then
    manager_install='记录异常'; manager_service='未知'; manager_reason='指定方式与记录冲突'; return 0
  fi
  manifest="$output/.env.$detected.json"
  if [[ ! -e $manifest && ! -L $manifest ]]; then
    manager_install='旧部署待确认'; manager_service='未知'; manager_reason='仅有旧 .env；请用 install 核对并登记，不自动启动'; return 0
  fi
  if [[ ! -r $manifest ]]; then
    manager_install='状态未知'; manager_service='未知'; manager_reason='安装记录权限不足；只读查询不自动 sudo'; return 0
  fi
  if ! record=$(deployment=$detected; cpa_start_load_record; printf '%s' "$record") 2>/dev/null; then
    record=''; manager_install='记录异常'; manager_service='未知'; manager_reason='安装记录或路径校验失败'; return 0
  fi
  manager_record_state=$(jq -r .status <<< "$record")
  case $manager_record_state in pending) manager_install='安装未完成';; ready) manager_install='已安装';; uninstalled) manager_install='已卸载（保留数据）';; esac
  state=$(jq -r .state_dir <<< "$record")
  manager_address=$(jq -r .bind_host <<< "$record")
  manager_port=$(jq -r .port <<< "$record"); manager_ssh_port=$(jq -r .ssh_port <<< "$record")
  if [[ $detected == docker ]]; then
    if ! command -v docker >/dev/null; then manager_service='未知'; manager_reason='缺少 Docker'; return 0; fi
    project=$(jq -r .project_name <<< "$record")
    if [[ ! $project =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then manager_service='未知'; manager_reason='Compose 项目名异常'; return 0; fi
    if ! ids=$(cpa_manager_command docker ps --all --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.service=cpa-dr' --format '{{.ID}}' 2>/dev/null); then
      manager_service='未知'; manager_reason='Docker daemon/访问权限未就绪或查询超时'; return 0
    fi
    if [[ -z $ids ]]; then manager_service='已停止（无容器）'; return 0; fi
    if [[ $ids == *$'\n'* ]]; then manager_service='未知'; manager_reason='发现多个同项目服务容器，未选择操作目标'; return 0; fi
    if ! details=$(cpa_manager_command docker inspect "$ids" 2>/dev/null) || ! jq -e --arg project "$project" --arg state "$state" --arg data "$(jq -r .data_dir <<< "$record")" '
      length==1 and .[0].Config.Labels["com.docker.compose.project"]==$project and .[0].Config.Labels["com.docker.compose.service"]=="cpa-dr" and
      any(.[0].Mounts[]; .Type=="bind" and .Destination=="/state" and .Source==$state) and
      any(.[0].Mounts[]; .Type=="bind" and .Destination=="/data" and .Source==$data)
      ' <<< "$details" >/dev/null 2>&1; then
      manager_service='未知'; manager_reason='容器标签或数据/状态挂载与安装记录不符'; return 0
    fi
    manager_container=$ids
    if jq -e '.[0].State.Running==true' <<< "$details" >/dev/null; then
      manager_service='运行中'
      status_data=$(cpa_manager_command docker exec "$ids" /opt/cpa-dr/bin/cpa-dr --state-dir /state status 2>/dev/null) || status_data=''
      manager_address=$(jq -r '.[0].NetworkSettings.Ports["8787/tcp"][0].HostIp//empty' <<< "$details")
      manager_port=$(jq -r '.[0].NetworkSettings.Ports["8787/tcp"][0].HostPort//empty' <<< "$details")
      manager_ssh_address=$(jq -r '.[0].NetworkSettings.Ports["22/tcp"][0].HostIp//empty' <<< "$details")
      manager_ssh_port=$(jq -r '.[0].NetworkSettings.Ports["22/tcp"][0].HostPort//empty' <<< "$details")
    else
      manager_service='已停止'
      # Never start a temporary container to read private stopped-service data.
      if [[ -r $state/config.json && -r $state/runtime.json ]]; then
        status_data=$(cpa_manager_read_state "$state") || status_data=''
      fi
    fi
  else
    native_root=$(jq -r .install_root <<< "$record")
    if ! (data=$(jq -r .data_dir <<< "$record"); deployment=native; cpa_start_native_paths; cpa_start_native_units_check) >/dev/null 2>&1; then
      manager_service='未知'; manager_reason='本地目录或单元归属异常/权限不足'; return 0
    fi
    if ! command -v systemctl >/dev/null; then manager_service='未知'; manager_reason='缺少 systemctl'; return 0; fi
    for unit in cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-fcgi.service cpa-dr-native-ssh.service; do
      if ! load=$(cpa_manager_command systemctl show "$unit" --property=LoadState --value 2>/dev/null); then manager_service='未知'; manager_reason='systemd/访问权限未就绪'; return 0; fi
      [[ $load != not-found ]] || continue
      [[ $load == loaded ]] || { manager_service='未知'; manager_reason='systemd 单元加载状态异常'; return 0; }
      # is-active/is-failed nonzero exits conflate inactive with query errors.
      # show is the machine-readable interface; failed queries are unknown.
      if ! active_state=$(cpa_manager_command systemctl show "$unit" --property=ActiveState --value 2>/dev/null); then
        manager_service='未知'; manager_reason='systemd 状态查询失败或超时'; return 0
      fi
      case $active_state in
        active|reloading|refreshing) ((active+=1));;
        inactive) ;;
        failed) ((failed+=1));;
        activating|deactivating|maintenance) ((transitioning+=1));;
        *) manager_service='未知'; manager_reason='systemd 返回未知单元状态'; return 0;;
      esac
    done
    if ((failed)); then manager_service='异常（单元失败）'
    elif ((transitioning)); then manager_service='切换中（单元启动/停止/维护）'
    elif ((active == 4)); then manager_service='运行中'
    elif ((active == 0)); then manager_service='已停止'
    else manager_service='异常（部分单元停止）'; fi
    if [[ -r $state/config.json && -r $state/runtime.json ]]; then status_data=$(cpa_manager_read_state "$state") || status_data=''; fi
    manager_ssh_address=$(jq -r '.ssh_bind_host//.bind_host' <<< "$record")
  fi
  if [[ -n ${status_data:-} ]] && jq -e 'type=="object" and (.job.running|type)=="boolean"' <<< "$status_data" >/dev/null 2>&1; then manager_runtime=$status_data; fi
  [[ $manager_service != '运行中' && $manager_service != '异常（部分单元停止）' ]] || cpa_manager_health
}

cpa_manager_read_state() {
  cpa_start_no_links "$1/config.json"
  cpa_start_no_links "$1/runtime.json"
  jq -n --slurpfile config "$1/config.json" --slurpfile runtime "$1/runtime.json" '$runtime[0]+{node_role:$config[0].node_role,enabled:$config[0].enabled,peer:($runtime[0].peer+{configured:($config[0].peer.host!="" and $config[0].peer.node_id!="")})}'
}

cpa_manager_probe_host() {
  case $1 in ''|0.0.0.0) printf '127.0.0.1';; '::') printf '::1';; *) printf '%s' "$1";; esac
}

cpa_manager_health() {
  local address ssh_address url body token='' curl_host
  address=$(cpa_manager_probe_host "$manager_address")
  ssh_address=$(cpa_manager_probe_host "${manager_ssh_address:-$manager_address}")
  [[ $address =~ ^[A-Za-z0-9.:_-]+$ && $manager_port =~ ^[0-9]{1,5}$ ]] || { manager_web='未知（监听信息异常）'; manager_api='未知'; return 0; }
  curl_host=$address; [[ $address != *:* ]] || curl_host="[$address]"
  url="http://$curl_host:$manager_port"
  manager_web='未知（缺少 curl）'; manager_api='未知（令牌不可读或缺少 curl）'
  if command -v curl >/dev/null; then
    if body=$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 3 "$url/healthz" 2>/dev/null) && jq -e '.ok==true' <<< "$body" >/dev/null 2>&1; then manager_web='正常'; else manager_web='异常'; fi
    if [[ -r $state/admin.token && ! -L $state/admin.token ]]; then token=$(< "$state/admin.token")
    elif [[ $manager_backend == docker && -n $manager_container ]]; then
      token=$(cpa_manager_command docker exec "$manager_container" cat /state/admin.token 2>/dev/null) || token=''
    fi
    if [[ $token =~ ^[A-Za-z0-9_-]{20,256}$ ]]; then
      # Header travels over stdin, not command-line arguments or diagnostic output.
      if body=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl --config - --noproxy '*' -fsS --connect-timeout 2 --max-time 3 "$url/api/status" 2>/dev/null) && jq -e '(.job.running|type)=="boolean"' <<< "$body" >/dev/null 2>&1; then manager_api='正常'; else manager_api='异常'; fi
    fi
  fi
  manager_ssh='未知（监听信息异常）'
  if [[ $ssh_address =~ ^[A-Za-z0-9.:_-]+$ && $manager_ssh_port =~ ^[0-9]{1,5}$ ]]; then
    if timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"; IFS= read -r banner <&3; [[ $banner == SSH-* ]]' bash "$ssh_address" "$manager_ssh_port" 2>/dev/null; then manager_ssh='正常（SSH 握手）'; else manager_ssh='异常（连接或握手失败）'; fi
  fi
}

cpa_manager_show() {
  local role_text='未知（配置不可读或服务未初始化）' enabled_text='未知' value
  if [[ -n $manager_runtime ]]; then
    case $(jq -r '.node_role//empty' <<< "$manager_runtime") in primary) role_text=主机;; backup) role_text=备机;; esac
    case $(jq -r '.enabled' <<< "$manager_runtime") in true) enabled_text=已启用;; false) enabled_text=未启用;; esac
  fi
  printf '\n安装状态：%s\n配置目录：%s\n部署方式：%s\n服务状态：%s\n本机角色：%s\n自动备份：%s\n管理页面：%s\n管理 API：%s\n专用 SSH：%s\n' "$manager_install" "$output" "${manager_backend:-尚未选择}" "$manager_service" "$role_text" "$enabled_text" "$manager_web" "$manager_api" "$manager_ssh"
  [[ -z $manager_reason ]] || printf '说明：%s\n' "$manager_reason"
  if [[ -n $manager_runtime ]]; then
    # Whitelist: no config blob, tokens, private keys or free-form job payloads.
    value=$(jq -c 'def summary: if type=="object" then {id,created_at,node_role,epoch} else null end; {phase,job:{running:.job.running,action:.job.action,finished_at:.job.finished_at},last_backup:(.last_backup|summary),last_replication:(.last_replication|summary),latest_received:(.latest_received|summary),peer:{configured:.peer.configured,reachable:.peer.reachable}}' <<< "$manager_runtime")
    printf '备份状态（对端可达性为历史记录，不代表当前连通）：\n%s\n' "$value"
  fi
  printf '%s\n' '管理健康不代表 CPA 业务就绪；只读查询不自动连接对端。'
}

cpa_manager_doctor() {
  local mode=${manager_backend:-${deployment:-}} location comm
  cpa_manager_show
  printf '\n环境检查（只读，不自动修复）\n'
  if [[ -n $mode ]]; then
    cpa_start_missing_dependencies "$mode"
    if ((${#CPA_START_MISSING[@]})); then printf '缺少依赖：%s\n' "${CPA_START_MISSING[*]}"; else printf '安装依赖：齐全\n'; fi
    if [[ $mode == native ]]; then
      comm=''; [[ ! -r /proc/1/comm ]] || IFS= read -r comm < /proc/1/comm
      printf 'PID 1：%s（实际 systemd 能力以单元查询为准）\n' "${comm:-未知}"
    fi
  else printf '依赖：尚未选择部署方式；可加 --deployment native|docker\n'; fi
  for location in "$output" "${state:-}"; do
    [[ -n $location ]] || continue
    if [[ -d $location ]]; then
      printf '目录：%s；读取=%s 写入=%s 遍历=%s\n' "$location" "$([[ -r $location ]] && printf 是 || printf 否)" "$([[ -w $location ]] && printf 是 || printf 否)" "$([[ -x $location ]] && printf 是 || printf 否)"
    else printf '目录：%s（尚不存在；未创建）\n' "$location"; fi
  done
  if command -v ss >/dev/null; then
    if [[ $manager_port =~ ^[0-9]{1,5}$ && $manager_ssh_port =~ ^[0-9]{1,5}$ ]]; then
      printf '相关监听端口（占用者归属以服务检查为准）：\n'
      ss -H -ltn "( sport = :$manager_port or sport = :$manager_ssh_port )" || printf '端口检查失败\n'
    fi
  else printf '端口占用检查：未知（缺少 ss，未安装）\n'; fi
  return 0
}

cpa_manager_install_plan() {
  local answer path mode=$deployment
  printf '\n4. 完整安装计划\n部署方式：%s\n配置目录：%s\n' "$mode" "$output"
  if ((existing)); then
    printf '已有部署：恢复安装/启动，保留全部页面设置、密钥与备份。\n'
    if command -v jq >/dev/null && [[ -r $output/.env.$mode.json ]]; then
      jq -r '"数据目录：\(.data_dir)\n状态目录：\(.state_dir)\n服务目录：\(.install_root)\n管理监听：\(.bind_host):\(.port)\n专用 SSH 端口：\(.ssh_port)"' "$output/.env.$mode.json" || fail '安装记录异常'
      path=$(jq -r .state_dir "$output/.env.$mode.json")
      if [[ -r $path/config.json ]]; then jq -r '"保留角色：\(.node_role)\n保留备份项目：\(.sources|map(.name)|join(", "))"' "$path/config.json"; else printf '角色及备份项目：保留原配置（当前用户不可读，提权/容器启动后核对）\n'; fi
    else printf '已有目录、角色、监听与项目：保留原记录，依赖/权限就绪后校验；不重置。\n'; fi
  else
    printf '本机角色：%s\n数据目录：%s\n' "$role" "$data"
    for path in "${source_specs[@]}"; do printf '备份项目：%s\n' "$path"; done
    if [[ $mode == native ]]; then
      printf '状态目录：%s\n服务目录：%s\n管理监听：%s:%s\n' "${state_arg:-/var/lib/cpa-dr-native}" "${root_arg:-/opt/cpa-dr-native}" "${bind:-127.0.0.1}" "${port:-8787}"
    else printf '状态目录：%s/state-native\n管理监听：127.0.0.1:%s\n' "$output" "${port:-8787}"; fi
    printf '专用 SSH 端口：%s\n新安装自动备份：保持停用\n' "${ssh_port:-2222}"
  fi
  cpa_start_missing_dependencies "$mode"
  if ((${#CPA_START_MISSING[@]})); then printf '缺少依赖：%s（确认后按现有软件源安装）\n' "${CPA_START_MISSING[*]}"; else printf '依赖：齐全\n'; fi
  printf '权限：%s\n原始 CPA 数据与源码：保留\n' "$([[ $mode == native || ${#CPA_START_MISSING[@]} != 0 ]] && printf '需要 root/sudo；确认后才提权' || printf '需要 Docker daemon 访问权限')"
  if [[ -t 0 ]] && ((assume_yes == 0)); then
    prompt '确认执行上述安装计划？[y/N] ' answer
    yes_answer "$answer" || fail '已取消安装，未生成配置或安装依赖'
  fi
}

cpa_manager_install_options() {
  local answer value
  printf '\n默认配置目录：%s\n管理端口：%s；专用 SSH 端口：%s\n' "$output" "${port:-8787}" "${ssh_port:-2222}"
  prompt '调整安装目录、监听或端口？[y/N] ' answer
  yes_answer "$answer" || return 0
  prompt "配置目录 [默认 $output]：" value; output=${value:-$output}; output_given=1
  if [[ $deployment == native ]]; then
    prompt "状态目录 [默认 ${state_arg:-/var/lib/cpa-dr-native}]：" value; state_arg=${value:-${state_arg:-/var/lib/cpa-dr-native}}
    prompt "服务目录 [默认 ${root_arg:-/opt/cpa-dr-native}]：" value; root_arg=${value:-${root_arg:-/opt/cpa-dr-native}}
    prompt "本机监听地址 [默认 ${bind:-127.0.0.1}]：" value; bind=${value:-${bind:-127.0.0.1}}
  else printf 'Docker 保持本机回环监听；跨机监听请按 README 显式配置 .env。\n'; fi
  prompt "管理端口 [默认 ${port:-8787}]：" value; port=${value:-${port:-8787}}
  prompt "专用 SSH 端口 [默认 ${ssh_port:-2222}]：" value; ssh_port=${value:-${ssh_port:-2222}}
  for value in "$port" "$ssh_port"; do
    if [[ ! $value =~ ^[0-9]{1,5}$ ]] || ((10#$value < 1 || 10#$value > 65535)); then fail '端口须在1到65535之间'; fi
  done
  ((10#$port != 10#$ssh_port)) || fail '管理与专用 SSH 端口必须不同'
}

# Reserve the same two locks as the service without invoking reconciliation.
# Container locks remain held by an exec session until stop finishes.
cpa_manager_guard() {
  local ready guard_script
  if [[ ${manager_backend:-} == docker && ${manager_service:-} == 已停止* && ! -r $state/runtime.json ]]; then
    # Inspect proved this existing container has no running processes. Do not
    # create a helper container merely to read root-private stopped state.
    return 0
  fi
  if [[ ${manager_backend:-$deployment} == docker && ${manager_service:-} == 运行中 && ! -r $state/runtime.json ]]; then
    guard_script='[[ ! -L /state/control.lock && ! -L /state/operation.lock && -f /state/runtime.json && ! -L /state/runtime.json ]] || exit 75; exec 8>>/state/control.lock; flock -n 8 || exit 75; exec 9>>/state/operation.lock; flock -n 9 || exit 75; jq -e ".job.running==false" /state/runtime.json >/dev/null || exit 75; printf "LOCKED\n"; IFS= read -r release'
    coproc CPA_GUARD { docker exec -i "$manager_container" bash -c "$guard_script"; }
    manager_guard_pid=$CPA_GUARD_PID
    manager_guard_read=${CPA_GUARD[0]}; manager_guard_write=${CPA_GUARD[1]}
    if ! IFS= read -r -t 8 ready <&"$manager_guard_read" || [[ $ready != LOCKED ]]; then
      cpa_manager_release_guard
      fail '服务任务忙碌、状态未知或锁被占用；未中断服务'
    fi
  else
    local lock
    # Existing pending installations can be uninstalled before service init.
    if [[ ! -f $state/runtime.json ]]; then
      [[ ${manager_record_state:-} == pending || $(jq -r .status <<< "$record") == pending ]] || fail '任务状态缺失，未中断服务'
      return 0
    fi
    for lock in control.lock operation.lock runtime.json; do cpa_start_no_links "$state/$lock"; done
    exec {manager_control_fd}>>"$state/control.lock"
    flock -n "$manager_control_fd" || fail '服务控制锁被占用，未中断服务'
    exec {manager_operation_fd}>>"$state/operation.lock"
    flock -n "$manager_operation_fd" || fail '服务任务锁被占用，未中断服务'
    jq -e '.job.running==false' "$state/runtime.json" >/dev/null || fail '正在运行备份/恢复任务或状态异常；未中断服务'
  fi
}

cpa_manager_release_guard() {
  local release_fd
  if [[ -n ${manager_operation_fd:-} ]]; then exec {manager_operation_fd}>&-; unset manager_operation_fd; fi
  if [[ -n ${manager_control_fd:-} ]]; then exec {manager_control_fd}>&-; unset manager_control_fd; fi
  if [[ -n ${manager_guard_write:-} ]]; then
    # Copy the coprocess descriptor in the parent: Bash closes the original
    # in subshells. The copy can send RELEASE while containing SIGPIPE when
    # docker stop/down has already terminated the remote lock holder.
    if { exec {release_fd}>&"$manager_guard_write"; } 2>/dev/null; then
      (printf 'RELEASE\n' >&"$release_fd") 2>/dev/null || true
      exec {release_fd}>&-
    fi
    exec {manager_guard_write}>&-; exec {manager_guard_read}<&-
    wait "$manager_guard_pid" 2>/dev/null || true
    unset manager_guard_write manager_guard_read manager_guard_pid
  fi
}

cpa_manager_control() {
  local answer unit id
  if [[ $manager_backend == native && $EUID != 0 && $manager_install == 状态未知 ]]; then
    printf '\n服务操作计划：%s\n目标配置目录：%s\n需要 sudo；提权后重新校验归属，配置/密钥/备份保留。\n' "$action" "$output"
    if ((assume_yes == 0)); then
      [[ -t 0 ]] || fail '非交互服务管理须显式 --yes'
      prompt '确认通过 sudo 操作本服务？[y/N] ' answer; yes_answer "$answer" || fail '已取消服务操作'
    fi
    command -v sudo >/dev/null || fail '本地服务管理需要 root/sudo'
    exec sudo -- bash "$ROOT/start.sh" "$action" --output "$output" --deployment native --yes
  fi
  [[ -n $record && -z $manager_reason ]] || fail '部署记录/运行状态未确认，未执行服务操作'
  [[ $manager_record_state == ready ]] || fail '尚未完成安装或已卸载；请使用 install 恢复已有安装'
  if [[ $manager_backend == docker ]]; then [[ -n $manager_container ]] || fail '没有已有容器；请使用 install 恢复'; fi
  printf '\n服务操作计划：%s\n部署：%s\n目标：%s\n配置、密钥、备份及原始 CPA 数据：保留\n' "$action" "$manager_backend" "${manager_container:-cpa-dr-native-*}"
  if ((assume_yes == 0)); then
    [[ -t 0 ]] || fail '非交互服务管理须显式 --yes'
    prompt '确认操作本服务？[y/N] ' answer; yes_answer "$answer" || fail '已取消服务操作'
  fi
  if [[ $manager_backend == native && $EUID != 0 ]]; then
    command -v sudo >/dev/null || fail '本地服务管理需要 root/sudo'
    exec sudo -- bash "$ROOT/start.sh" "$action" --output "$output" --deployment native --yes
  fi
  deployment=$manager_backend
  cpa_start_lock
  trap 'cpa_manager_release_guard; rm -f -- "$lock_file"' EXIT
  id=$(jq -r .install_id <<< "$record"); data=$(jq -r .data_dir <<< "$record")
  cpa_start_owned_directory "$state" "$id"
  if [[ $deployment == native ]]; then
    cpa_start_native_paths; cpa_start_native_units_check
    cpa_start_owned_directory "$native_root" "$id"
    for unit in "${CPA_START_UNITS[@]}"; do [[ -f /etc/systemd/system/$unit ]] || fail '本地单元缺失，请用 install 恢复'; done
  fi
  cpa_manager_guard
  if [[ $deployment == docker ]]; then
    if [[ $action == stop || $action == restart ]]; then docker stop --time 60 "$manager_container" || fail '停止容器失败，配置及备份保留'; fi
    # restart is deliberately stop then start: no scheduler window before guard release.
    cpa_manager_release_guard
    if [[ $action == start || $action == restart ]]; then docker start "$manager_container" || fail '启动已有容器失败，未构建/创建'; fi
  else
    if [[ $action == stop || $action == restart ]]; then
      systemctl stop "${CPA_START_UNITS[@]}" || fail '停止本地服务失败，配置及备份保留'
    fi
    cpa_manager_release_guard
    if [[ $action == start || $action == restart ]]; then
      systemctl start cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-ssh.service || fail '启动本地服务失败'
    fi
  fi
  if [[ $action == start || $action == restart ]]; then
    cpa_manager_wait_ready
  else
    cpa_manager_snapshot
    [[ $manager_service == 已停止* ]] || fail '停止后状态未确认，请核对服务；配置及备份保留'
  fi
  printf '服务操作已完成：%s（仅本服务，不操作 CPA 业务进程）。\n' "$action"
}

cpa_manager_wait_ready() {
  local attempt
  for ((attempt=0; attempt<20; attempt++)); do
    cpa_manager_snapshot
    if [[ $manager_service == 运行中 && $manager_web == 正常 && $manager_api == 正常 && $manager_ssh == '正常（SSH 握手）' ]]; then return 0; fi
    sleep .25
  done
  cpa_manager_show
  fail '启动/重启后服务或管理/API/SSH检查未就绪；配置及备份保留'
}

cpa_manager_logs() {
  local unit
  local -a flags=()
  [[ -n $record && -z $manager_reason ]] || fail '部署归属未确认，未读取日志'
  printf '%s\n' '日志为服务原文，可能包含业务信息；请勿公开上传。'
  ((log_follow == 0)) || flags+=(--follow)
  trap 'exit 0' INT
  if [[ $manager_backend == docker ]]; then
    [[ -n $manager_container ]] || fail '没有已有服务容器日志'
    docker logs --tail "$log_tail" "${flags[@]}" "$manager_container"
  else
    command -v journalctl >/dev/null || fail '缺少 journalctl；未安装依赖'
    for unit in "${CPA_START_UNITS[@]}"; do flags+=(-u "$unit"); done
    journalctl --no-pager -n "$log_tail" "${flags[@]}"
  fi
}

cpa_manager_menu() {
  local answer mode child_rc
  [[ -t 0 ]] || fail 'menu 需要终端；非交互请使用显式命令'
  while :; do
    if ((output_given == 0)) && [[ ${manager_target_fixed:-0} == 0 ]]; then output=''; cpa_manager_select; fi
    cpa_manager_snapshot
    printf '\n━━━━━━━━ CPA 主备备份服务管理 ━━━━━━━━\n'
    cpa_manager_show
    printf '\n  1) 安装 / 恢复已有安装\n  2) 卸载服务\n  3) 查看详细状态\n  4) 环境检查与故障诊断\n  5) 服务管理（启动 / 停止 / 重启）%s\n  6) 查看日志%s\n  0) 退出\n' "$(cpa_manager_available || printf ' [未安装或未就绪]')" "$([[ -n $record ]] || printf ' [未安装或当前用户不可读]')"
    printf '  7) 生成备机安装命令\n'
    if ! read -r -p '请选择 [0-7]：' answer; then printf '\n输入结束，已退出；未确认的操作未执行。\n'; return 0; fi
    child_rc=0
    case $answer in
      0) return 0;;
      1)
        local -a args=(install)
        # For a fresh default native install, allow the original default directory.
        if [[ -n $record || $output_given == 1 ]]; then args+=(--output "$output"); fi
        [[ -z $deployment ]] || args+=(--deployment "$deployment")
        bash "$ROOT/start.sh" "${args[@]}" || child_rc=$?;;
      2)
        if [[ -z $record ]] && ! cpa_manager_available; then printf '未找到有效安装记录；未执行卸载。\n'; continue; fi
        printf '  1) 普通卸载，保留配置/密钥/备份\n  2) 卸载并清理专用状态\n  0) 返回\n'
        prompt '请选择 [0-2]：' mode
        case $mode in 1) bash "$ROOT/start.sh" uninstall --output "$output" || child_rc=$?;; 2) bash "$ROOT/start.sh" uninstall --purge --output "$output" || child_rc=$?;; 0) continue;; *) printf '输入无效，返回主菜单。\n';; esac;;
      3) cpa_manager_show;;
      4) cpa_manager_doctor;;
      5)
        cpa_manager_available || { printf '未安装或未就绪；请先安装/恢复。\n'; continue; }
        printf '  1) 启动\n  2) 停止\n  3) 重启\n  0) 返回\n'
        prompt '请选择 [0-3]：' mode
        case $mode in 1) mode=start;; 2) mode=stop;; 3) mode=restart;; 0) continue;; *) printf '输入无效，返回主菜单。\n'; continue;; esac
        bash "$ROOT/start.sh" "$mode" --output "$output" || child_rc=$?;;
      6) bash "$ROOT/start.sh" logs --output "$output" || child_rc=$?;;
      7) bash "$ROOT/start.sh" generate-backup-command --output "$output" || child_rc=$?;;
      *) printf '请输入 0 到 7。\n';;
    esac
    ((child_rc == 0)) || printf '操作未完成或已取消（退出码 %s），返回菜单，原配置保留。\n' "$child_rc"
  done
}

cpa_manager_available() {
  [[ -n $record && $manager_record_state == ready ]] || [[ $manager_backend == native && $manager_install == 状态未知 && $EUID != 0 ]]
}

cpa_manager_dispatch() {
  cpa_manager_select
  if [[ $action == menu ]]; then cpa_manager_menu; return; fi
  cpa_manager_snapshot
  case $action in
    status) cpa_manager_show;;
    doctor) cpa_manager_doctor;;
    logs) cpa_manager_logs;;
    start|stop|restart) cpa_manager_control;;
  esac
}
