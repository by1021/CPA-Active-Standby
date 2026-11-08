#!/usr/bin/env bash
# Sourced by start.sh: private installation records and bounded lifecycle operations.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2154
# The entrypoint supplies validated option variables and the Compose command array.
# shellcheck source=../../lib/common.sh
source "$ROOT/lib/common.sh"
CPA_START_UNITS=(cpa-dr-native-tick.timer cpa-dr-native-tick.service cpa-dr-native-web.service cpa-dr-native-fcgi.service cpa-dr-native-ssh.service)

cpa_start_no_links() {
  local cursor=$1
  [[ $cursor == /* ]] || cursor="$PWD/$cursor"
  while [[ $cursor != / && -n $cursor ]]; do
    [[ ! -L $cursor ]] || fail "路径或其祖先是符号链接：$cursor"
    cursor=${cursor%/*}
  done
}
cpa_start_validate_data() {
  local location=$1
  cpa_paths_intersect "$location" "$ROOT" && fail '数据目录与服务源码必须独立'
  cpa_paths_intersect "$location" "$output" && fail '数据目录与部署/状态目录必须独立'
  return 0
}
cpa_start_lock() {
  mkdir -p -- "$output"
  lock_file="$output/.env.start.lock"
  cpa_start_no_links "$lock_file"
  exec {start_lock}> "$lock_file"
  flock -n "$start_lock" || fail '另一项安装/卸载正在执行，未开始本次操作'
  # All contenders use a nonblocking lock: unlink only after the last mutation.
  trap 'rc=$?; rm -f -- "$lock_file"; exit "$rc"' EXIT
}
cpa_start_save_record() {
  printf '%s\n' "$record" | cpa_atomic "$manifest" || fail '保存安装记录失败，已保留原配置'
}
cpa_start_load_record() {
  cpa_start_no_links "$manifest"
  [[ -f $manifest ]] || fail '安装记录须为普通 JSON 文件'
  record=$(< "$manifest")
  jq -e --arg mode "$deployment" --arg output "$output" '
    .version==1 and .managed_by=="cpa-dr-start" and .deployment==$mode and .config_dir==$output and
    (.status=="pending" or .status=="ready" or .status=="uninstalled") and
    (.install_id|type=="string" and test("^[a-f0-9-]{36}$")) and
    ([.data_dir,.state_dir,.source_root]|all(type=="string" and startswith("/") and length>1)) and
    (.install_root|type=="string") and (.project_name|type=="string") and
    (.port|type=="number" and floor==. and .>=1 and .<=65535) and
    (.ssh_port|type=="number" and floor==. and .>=1 and .<=65535) and
    (.bind_host|type=="string") and (.read_only|type=="boolean") and (.unit_hashes|type=="object") and
    (if $mode=="native" then .run_dir=="/run/cpa-dr-native" else .run_dir=="" end) and
    (.initial_config==null or (.initial_config|type=="object" and (.node_role=="primary" or .node_role=="backup") and .enabled==false and (.sources|type=="array")))
  ' <<< "$record" >/dev/null || fail '安装记录格式异常，未执行部署/删除'
  local path
  for path in data_dir state_dir source_root; do
    path=$(jq -r --arg key "$path" '.[$key]' <<< "$record")
    cpa_path_validate "$path" || fail '安装记录路径异常，未执行删除'
  done
}
cpa_start_create_record() {
  local mode=$1 location=$2 installed_root=$3 project_name=$4 id initial=null prefix=''
  if [[ $mode == docker ]]; then
    prefix=/data
    cpa_start_no_links "$location/.cpa-dr-install-id"
    if [[ -f $location/.cpa-dr-install-id ]]; then id=$(< "$location/.cpa-dr-install-id")
    else id=$(< /proc/sys/kernel/random/uuid); printf '%s\n' "$id" | cpa_atomic "$location/.cpa-dr-install-id"; fi
  else id=$(< /proc/sys/kernel/random/uuid); fi
  [[ $id =~ ^[a-f0-9-]{36}$ ]] || fail '已有目录所有权标记异常'
  if [[ -n $role ]] || ((${#source_names[@]} > 0)); then
    initial=$(jq -n --arg role "${role:-primary}" --argjson sources "$(sources_json "$prefix")" '{node_role:$role,enabled:false,sources:$sources}')
  fi
  record=$(jq -n --arg mode "$mode" --arg id "$id" --arg data "$data" --arg state "$location" --arg root "$installed_root" --arg source "$ROOT" --arg output "$output" --arg project "$project_name" --arg bind "${bind:-127.0.0.1}" --arg ssh_bind "${ssh_bind:-${bind:-127.0.0.1}}" --argjson port "$((10#${port:-8787}))" --argjson ssh_port "$((10#${ssh_port:-2222}))" --argjson ro "$read_only" --argjson initial "$initial" \
    '{version:1,managed_by:"cpa-dr-start",deployment:$mode,status:"pending",install_id:$id,data_dir:$data,state_dir:$state,install_root:$root,source_root:$source,config_dir:$output,run_dir:(if $mode=="native" then "/run/cpa-dr-native" else "" end),project_name:$project,port:$port,ssh_port:$ssh_port,bind_host:$bind,ssh_bind_host:$ssh_bind,read_only:($ro==1),initial_config:$initial,unit_hashes:{}}')
  cpa_start_save_record
}
cpa_start_record_status() {
  local updated
  updated=$(jq --arg status "$1" '.status=$status' <<< "$record")
  if [[ $updated != "$record" ]]; then record=$updated; cpa_start_save_record; fi
}
cpa_start_bootstrap_path() {
  if [[ $deployment == docker ]]; then printf '%s/.env.bootstrap.json\n' "$state"
  else printf '%s/.env.bootstrap.json\n' "$output"; fi
}
cpa_start_write_bootstrap() {
  local file
  file=$(cpa_start_bootstrap_path)
  jq -e '.initial_config!=null' <<< "$record" >/dev/null || return 0
  cpa_start_no_links "$file"
  jq '.initial_config' <<< "$record" | cpa_atomic "$file" || fail '保存待应用的角色/数据配置失败'
}
cpa_start_check_requested() {
  local file=$1 prefix=$2 expected requested
  [[ -n $role || ${#source_specs[@]} != 0 ]] || return 0
  if [[ $(jq -r .status <<< "$record") == pending ]] && jq -e '.initial_config!=null' <<< "$record" >/dev/null; then
    expected=$(jq '.initial_config' <<< "$record")
  elif [[ -f $file ]]; then
    if [[ $deployment == docker && ! -r $file ]]; then
      local running
      running=$("${compose[@]}" ps --status running --quiet cpa-dr) || fail '读取容器状态失败，保留原配置'
      if [[ -n $running ]]; then
        expected=$("${compose[@]}" exec -T cpa-dr /opt/cpa-dr/bin/cpa-dr --state-dir /state config get) || fail '读取已有容器配置失败'
      else
        # Read-only CLI: no entrypoint, scheduler, dependent services or published ports.
        "${compose[@]}" build >/dev/null || fail '构建只读配置检查镜像失败，保留原状态'
        expected=$("${compose[@]}" run --rm --no-deps -T --entrypoint /opt/cpa-dr/bin/cpa-dr cpa-dr --state-dir /state config get) || fail '读取已有部署配置失败，保留原状态'
      fi
    else expected=$(< "$file"); fi
  else return 0; fi
  if [[ -n $role ]]; then
    [[ $(jq -r .node_role <<< "$expected") == "$role" ]] || fail '--role 与已有配置冲突；保留原角色'
  fi
  if ((${#source_specs[@]} > 0)); then
    normalize_sources "$(jq -r .node_role <<< "$expected")"
    requested=$(sources_json "$prefix")
    jq -e --argjson requested "$requested" '(.sources|sort_by(.name))==($requested|sort_by(.name))' <<< "$expected" >/dev/null || fail '--source 与已有配置冲突；保留页面设置'
  fi
}
cpa_start_apply_docker_bootstrap() {
  [[ $(jq -r .status <<< "$record") == pending ]] || return 0
  jq -e '.initial_config!=null' <<< "$record" >/dev/null || return 0
  local file full expected service_state row path kind
  file=$(cpa_start_bootstrap_path); full="$state/.env.bootstrap.full.json"
  cpa_start_write_bootstrap /data
  expected=$(jq '.initial_config' <<< "$record")
  if [[ $(jq -r .node_role <<< "$expected") == primary ]]; then
    while IFS= read -r row; do
      path=$(jq -r .path <<< "$row"); kind=$(jq -r .kind <<< "$row")
      flag=-f; [[ $kind != directory ]] || flag=-d
      "${compose[@]}" exec -T cpa-dr test "$flag" "$path" || fail "主机来源不存在或类型不匹配：$path"
    done < <(jq -c '.sources[]' <<< "$expected")
  fi
  # Config/runtime are normally 0600 owned by container root, even for a non-root
  # Docker client. Read and merge inside the container, not from the host.
  service_state=$("${compose[@]}" exec -T cpa-dr jq -n --slurpfile config /state/config.json --slurpfile runtime /state/runtime.json --slurpfile incoming /state/.env.bootstrap.json \
    '{configured:$runtime[0].configured,matches:($config[0].node_role==$incoming[0].node_role and ($config[0].sources|sort_by(.name))==($incoming[0].sources|sort_by(.name))),merged:($config[0]+$incoming[0])}') || fail '读取容器引导配置失败，状态保留'
  if jq -e '.configured==true' <<< "$service_state" >/dev/null; then
    # A crash after config set must not reset scheduling or later UI changes.
    jq -e '.matches==true' <<< "$service_state" >/dev/null || fail '未完成安装与现有页面配置冲突，保留原配置'
  else
    jq '.merged' <<< "$service_state" | cpa_atomic "$full" || fail '生成服务引导配置失败'
    "${compose[@]}" exec -T cpa-dr /opt/cpa-dr/bin/cpa-dr --state-dir /state config set /state/.env.bootstrap.full.json >/dev/null || fail '应用角色/数据配置失败；保留状态，可重跑'
  fi
  rm -f -- "$file" "$full"
}
cpa_start_elevate_native() {
  local spec
  local -a args=(--deployment native --output "$(realpath -ms -- "$output")")
  command -v sudo >/dev/null || fail 'Linux本地安装/卸载需要 root 或 sudo'
  if ((uninstall)); then args+=(--uninstall); ((purge == 0)) || args+=(--purge)
  else
    [[ -z $role ]] || args+=(--role "$role")
    [[ -z $data ]] || args+=(--data-dir "$(realpath -ms -- "$data")")
    for spec in "${source_specs[@]}"; do args+=(--source "$spec"); done
    [[ -z $port ]] || args+=(--port "$port")
    [[ -z $ssh_port ]] || args+=(--ssh-port "$ssh_port")
    [[ -z $bind ]] || args+=(--bind-host "$bind")
    [[ -z $ssh_bind ]] || args+=(--ssh-bind-host "$ssh_bind")
    [[ -z $state_arg ]] || args+=(--state-dir "$state_arg")
    [[ -z $root_arg ]] || args+=(--install-root "$root_arg")
    ((read_only == 0)) || args+=(--read-only-data)
    ((generate_backup == 0)) || args+=(--generate-backup)
    for spec in primary_host primary_port backup_host backup_port backup_data backup_deployment backup_output backup_bind; do
      [[ -n ${!spec} ]] || continue
      case $spec in
        primary_host) args+=(--primary-host "$primary_host");; primary_port) args+=(--primary-port "$primary_port");;
        backup_host) args+=(--backup-host "$backup_host");; backup_port) args+=(--backup-port "$backup_port");;
        backup_data) args+=(--backup-data-dir "$backup_data");; backup_deployment) args+=(--backup-deployment "$backup_deployment");;
        backup_output) args+=(--backup-output "$backup_output");; backup_bind) args+=(--backup-bind-host "$backup_bind");;
      esac
    done
    args+=(--ttl "$invite_ttl")
    ((invite_auto)) || args+=(--no-auto-enable)
  fi
  ((assume_yes == 0)) || args+=(--yes)
  ((install_deps == 1)) || args+=(--no-install-deps)
  printf '正在通过 sudo 执行Linux本地%s……\n' "$([[ $uninstall == 1 ]] && printf 卸载 || printf 安装)"
  exec sudo -- bash "$ROOT/start.sh" "${args[@]}"
}
cpa_start_owned_directory() {
  local directory=$1 id=$2 source_root
  cpa_start_no_links "$directory"
  cpa_path_validate "$directory" || fail '清除目标路径异常'
  case $directory in /|/etc|/opt|/usr|/var|/var/lib|/home|/root|/tmp|/run|/srv) fail "清除目标是公共目录：$directory";; esac
  cpa_paths_intersect "$directory" "$data" && fail '清除目标与原始数据交集，未执行删除'
  source_root=$(jq -r .source_root <<< "$record")
  if within "$ROOT" "$directory" || within "$source_root" "$directory"; then fail '清除目标包含源码，未执行删除'; fi
  if [[ -e $directory ]]; then
    [[ -d $directory && -f $directory/.cpa-dr-install-id && ! -L $directory/.cpa-dr-install-id ]] || fail "目录缺少本服务所有权标记：$directory"
    [[ $(< "$directory/.cpa-dr-install-id") == "$id" ]] || fail "目录所有权与安装记录不一致：$directory"
  fi
}
cpa_start_confirm_uninstall() {
  local answer
  printf '\n即将%s本服务：%s\n专用状态：%s\n原始数据始终保留：%s\n' "$([[ $purge == 1 ]] && printf '卸载并清除' || printf 卸载)" "$deployment" "$state" "$data"
  if [[ $deployment == docker ]]; then
    printf '停止/移除对象：Compose 项目 %s 的本服务容器和网络\n' "$project"
    ((purge == 0)) || printf '删除路径：%s\n  %s\n  %s\n' "$state" "$envfile" "$manifest"
  else
    printf '停止/删除单元：%s\n' "${CPA_START_UNITS[*]}"
    ((purge == 0)) || printf '删除专用目录：%s\n  %s\n  /run/cpa-dr-native\n删除本服务配置：%s（未知文件保留）\n' "$state" "$native_root" "$output"
  fi
  printf '保留：原始 CPA 数据、源码、共用依赖、无关服务和未知配置。\n'
  ((purge == 0)) || printf '清除会删除本服务的备份历史、回滚副本、令牌和SSH密钥。\n'
  ((assume_yes == 0)) || return 0
  [[ -t 0 ]] || fail '非交互卸载/清除须明确传 --yes'
  if ((purge)); then prompt '请输入 PURGE 确认清除：' answer; [[ $answer == PURGE ]] || fail '已取消清除'
  else prompt '确认卸载并保留备份？[y/N] ' answer; yes_answer "$answer" || fail '已取消卸载'; fi
}
cpa_start_uninstall_docker() {
  local id
  local -a privilege=()
  id=$(jq -r .install_id <<< "$record")
  cpa_start_owned_directory "$state" "$id"
  cpa_start_confirm_uninstall
  # Host-readable idle state is not proof that the running Compose container
  # belongs to this installation. Check labels/mounts for every caller/status;
  # an absent container remains valid for pending/uninstalled cleanup.
  cpa_manager_snapshot
  [[ -n $record && -z $manager_reason ]] || fail '任务状态或容器归属未知，未执行卸载'
  cpa_manager_guard
  trap 'cpa_manager_release_guard; rm -f -- "$lock_file"' EXIT
  if ((purge && EUID != 0)); then
    command -v sudo >/dev/null || fail '清除容器创建的私有备份需要root或sudo；服务和数据尚未删除'
    privilege=(sudo --)
    "${privilege[@]}" true || fail '清除权限检查失败，服务和备份尚未删除'
  fi
  "${compose[@]}" down --timeout 60 || fail '停止/移除容器失败，未清除配置或备份'
  cpa_manager_release_guard
  cpa_start_record_status uninstalled
  if ((purge)); then
    cpa_start_owned_directory "$state" "$id"
    "${privilege[@]}" rm -rf --one-file-system -- "$state" || fail '清除专用状态失败，保留安装记录'
    rm -f -- "$envfile" "$manifest" || fail '清除部署配置失败'
    cpa_location_mark_purged "$ROOT" "$output"
    printf '已卸载并清除Docker部署；原始数据和源码保留。\n'
  else printf '已卸载Docker部署；配置、密钥和备份保留，运行 start.sh install 可恢复。\n'; fi
}
cpa_start_native_paths() {
  local a b
  for a in "$state" "$native_root" "$output" /run/cpa-dr-native; do
    [[ $a =~ ^/[A-Za-z0-9_./-]+$ ]] || fail '本地服务/状态/配置目录须为无空格和特殊字符的绝对路径'
    cpa_start_no_links "$a"
    cpa_paths_intersect "$a" "$data" && fail '本地数据/状态/服务/配置目录必须独立'
    cpa_paths_intersect "$a" "$ROOT" && fail '本地安装目录与源码必须独立'
    for b in "$state" "$native_root" "$output" /run/cpa-dr-native; do
      if [[ $a != "$b" ]] && cpa_paths_intersect "$a" "$b"; then fail '本地服务/状态/配置目录相互重叠'; fi
    done
  done
  [[ $state != "$native_root" && $state != "$output" && $native_root != "$output" ]] || fail '本地服务/状态/配置目录必须不同'
}
cpa_start_native_units_check() {
  local unit expected actual file
  for unit in "${CPA_START_UNITS[@]}" nginx.conf sshd.conf; do
    file="$output/$unit"
    expected=$(jq -r --arg unit "$unit" '.unit_hashes[$unit]//empty' <<< "$record")
    if [[ -e $file || -L $file ]]; then
      [[ -f $file && ! -L $file && $expected =~ ^[a-f0-9]{64}$ ]] || fail "单元来源记录异常：$unit"
      actual=$(sha256sum -- "$file"); [[ ${actual:0:64} == "$expected" ]] || fail "单元配置已改变，保留原文件：$unit"
    fi
    [[ $unit != nginx.conf && $unit != sshd.conf ]] || continue
    for file in "/etc/systemd/system/$unit" "/usr/lib/systemd/system/$unit" "/lib/systemd/system/$unit"; do
      if [[ -e $file || -L $file ]]; then
        [[ -f $file && ! -L $file && $expected =~ ^[a-f0-9]{64}$ ]] || fail "发现非本服务单元：$file"
        actual=$(sha256sum -- "$file"); [[ ${actual:0:64} == "$expected" ]] || fail "已有同名单元不属于本次安装：$file"
      fi
      [[ ! -e $file.d && ! -L $file.d ]] || fail "单元含额外覆盖配置，请核对：$file.d"
    done
  done
}
cpa_start_install_native() {
  local id file config_port config_ssh config_bind config_ssh_bind requested install_status
  if [[ -n $record ]]; then
    state=$(jq -r .state_dir <<< "$record"); native_root=$(jq -r .install_root <<< "$record")
    data_record=$(jq -r .data_dir <<< "$record")
    if [[ -n $data ]]; then [[ -d $data && $(realpath -e -- "$data") == "$data_record" ]] || fail '--data-dir 与已有本地安装冲突'; fi
    data=$data_record
    [[ -z $state_arg || $(realpath -m -- "$state_arg") == "$state" ]] || fail '--state-dir 与已有安装冲突'
    [[ -z $root_arg || $(realpath -m -- "$root_arg") == "$native_root" ]] || fail '--install-root 与已有安装冲突'
    config_port=$(jq -r .port <<< "$record"); config_ssh=$(jq -r .ssh_port <<< "$record"); config_bind=$(jq -r .bind_host <<< "$record")
    config_ssh_bind=$(jq -r '.ssh_bind_host//.bind_host' <<< "$record")
    for file in port ssh_port; do
      requested=${!file}; config_value=$config_port; [[ $file != ssh_port ]] || config_value=$config_ssh
      [[ -z $requested ]] || ((10#$requested == 10#$config_value)) || fail '端口与已有本地安装冲突'
    done
    [[ -z $bind || $bind == "$config_bind" ]] || fail '--bind-host 与已有安装冲突'
    [[ -z $ssh_bind || $ssh_bind == "$config_ssh_bind" ]] || fail '--ssh-bind-host 与已有安装冲突；使用 configure-ssh 修改'
    ((read_only == 0)) || [[ $(jq -r .read_only <<< "$record") == true ]] || fail '--read-only-data 与已有安装冲突'
    port=$config_port; ssh_port=$config_ssh; bind=$config_bind; ssh_bind=$config_ssh_bind
    [[ $(jq -r .read_only <<< "$record") != true ]] || read_only=1
  else
    cpa_start_no_links "${state_arg:-/var/lib/cpa-dr-native}"
    cpa_start_no_links "${root_arg:-/opt/cpa-dr-native}"
    state=$(realpath -m -- "${state_arg:-/var/lib/cpa-dr-native}")
    native_root=$(realpath -m -- "${root_arg:-/opt/cpa-dr-native}")
    [[ ! -e $state && ! -L $state && ! -e $native_root && ! -L $native_root ]] || fail '本地服务或状态目录已存在，未覆盖旧安装'
    [[ ! -e /run/cpa-dr-native && ! -L /run/cpa-dr-native ]] || fail '已有本服务运行目录，保留原安装'
    for file in "${CPA_START_UNITS[@]}" nginx.conf sshd.conf; do
      [[ ! -e $output/$file && ! -L $output/$file ]] || fail "部署目录已有同名配置，保留原文件：$file"
    done
  fi
  [[ -d $data ]] || fail '本地数据父目录不存在，未创建空目录'
  cpa_start_validate_data "$data"
  cpa_start_native_paths
  [[ -z $record ]] || cpa_start_native_units_check
  if [[ -z $record ]]; then
    normalize_sources
    cpa_start_create_record native "$state" "$native_root" ''
  fi
  id=$(jq -r .install_id <<< "$record")
  cpa_start_owned_directory "$state" "$id"; cpa_start_owned_directory "$native_root" "$id"
  cpa_start_owned_directory /run/cpa-dr-native "$id"
  cpa_start_check_requested "$state/config.json" ''
  install_status=$(jq -r .status <<< "$record")
  if [[ $install_status == pending ]]; then
    cpa_start_write_bootstrap ''
    local -a args=(--data-dir "$data" --state-dir "$state" --install-root "$native_root" --config-dir "$output" --port "${port:-8787}" --ssh-port "${ssh_port:-2222}" --bind-host "${bind:-127.0.0.1}" --ssh-bind-host "${ssh_bind:-${bind:-127.0.0.1}}" --install-id "$id" --resume)
    [[ ! -f $output/.env.bootstrap.json ]] || args+=(--config-file "$output/.env.bootstrap.json")
    ((read_only == 0)) || args+=(--read-only-data)
    bash "$ROOT/scripts/install-systemd.sh" "${args[@]}" >/dev/null || fail '本地安装失败，保留配置和状态，可重跑或卸载'
    cpa_start_load_record
  else
    [[ -d $native_root && -d $state && -f $state/config.json ]] || fail '已有本地代码/状态缺失，保留原安装记录'
    for file in nginx.conf sshd.conf; do cpa_start_no_links "$output/$file"; [[ -f $output/$file ]] || fail "缺少本地配置：$file"; done
    # nginx -t also opens its pid path, before systemd can recreate volatile /run.
    # The ownership/path checks above permit creation only when it is absent.
    if [[ ! -d /run/cpa-dr-native ]]; then
      install -d -m 755 -- /run/cpa-dr-native
      install -m 600 -- "$state/.cpa-dr-install-id" /run/cpa-dr-native/.cpa-dr-install-id
    fi
    cpa_native_upgrade "${ssh_bind:-${bind:-127.0.0.1}}"
    nginx -t -c "$output/nginx.conf"
    sshd -t -f "$output/sshd.conf"
    for file in "${CPA_START_UNITS[@]}"; do install -m 644 -- "$output/$file" /etc/systemd/system/; done
    systemctl daemon-reload
    systemctl enable --now cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-ssh.service || fail '重新启动本地服务失败，状态保留'
  fi
  # is-active with several names succeeds when ANY unit is active, not all.
  for file in cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-fcgi.service cpa-dr-native-ssh.service; do
    systemctl is-active --quiet "$file" || fail "本地单元未就绪，状态保留：$file"
  done
  local address=${bind:-127.0.0.1}
  [[ $address != 0.0.0.0 && $address != :: ]] || address=127.0.0.1
  [[ $address != *:* ]] || address="[$address]"
  curl -fsS --max-time 5 "http://$address:${port:-8787}/healthz" | jq -e '.ok==true' >/dev/null || fail '本地管理健康检查失败，配置和备份保留'
  cpa_start_record_status ready
  rm -f -- "$output/.env.bootstrap.json"
  printf '\n服务已启动（仅管理服务健康，不代表 CPA 业务就绪）。\n部署方式：Linux 本地\n管理地址：http://%s:%s\n配置目录：%s\n管理员令牌：' "$address" "${port:-8787}" "$output"
  cat -- "$state/admin.token"
  printf '本机 SSH 公钥：\n'; cat -- "$state/ssh/id_ed25519.pub"
  printf '%s\n' '已保留/初始化角色与数据设置；新安装备份未启用，双端配对后在页面启用。'
  cpa_install_finish
}
cpa_start_uninstall_native() {
  [[ -n $record ]] || fail '缺少本地安装记录，请核对 --output'
  local id file
  data=$(jq -r .data_dir <<< "$record"); state=$(jq -r .state_dir <<< "$record"); native_root=$(jq -r .install_root <<< "$record"); id=$(jq -r .install_id <<< "$record")
  cpa_start_native_paths
  cpa_start_owned_directory "$state" "$id"; cpa_start_owned_directory "$native_root" "$id"
  cpa_start_owned_directory /run/cpa-dr-native "$id"
  cpa_start_native_units_check
  for file in nginx.conf sshd.conf .env.bootstrap.json; do cpa_start_no_links "$output/$file"; done
  cpa_start_confirm_uninstall
  cpa_manager_guard
  # Stop the timer and all writers before removing any units or private files.
  local -a loaded=() enabled=()
  for file in "${CPA_START_UNITS[@]}"; do
    if [[ -f /etc/systemd/system/$file ]]; then
      loaded+=("$file")
      case $file in *-tick.timer|*-web.service|*-ssh.service|*-fcgi.service) enabled+=("$file");; esac
    fi
  done
  if ((${#loaded[@]})); then systemctl stop "${loaded[@]}" || fail '停止本地服务失败，未删除单元/备份'; fi
  if ((${#enabled[@]})); then systemctl disable "${enabled[@]}" || fail '禁用本地服务失败，未删除单元/备份'; fi
  for file in "${CPA_START_UNITS[@]}"; do rm -f -- "/etc/systemd/system/$file"; done
  systemctl daemon-reload || fail '重新加载systemd失败，保留专用状态'
  cpa_start_record_status uninstalled
  if ((purge)); then
    cpa_start_owned_directory "$state" "$id"; cpa_start_owned_directory "$native_root" "$id"
    cpa_start_owned_directory /run/cpa-dr-native "$id"
    rm -rf --one-file-system -- "$state" "$native_root" /run/cpa-dr-native || fail '清除本地专用目录失败，保留安装记录'
    for file in "${CPA_START_UNITS[@]}" nginx.conf sshd.conf .env.bootstrap.json; do rm -f -- "$output/$file"; done
    rm -f -- "$manifest"
    cpa_location_mark_purged "$ROOT" "$output"
    printf '已卸载并清除Linux本地部署；原始数据、源码及未知配置文件保留。\n'
  else printf '已卸载Linux本地单元；代码、配置和备份保留，运行 start.sh install 可恢复。\n'; fi
}
