#!/usr/bin/env bash
# Durable association and self-contained launchers; JSON is never code.
# shellcheck disable=SC2154,SC2016
cpa_location_fail() { printf '安装入口异常：%s\n' "$*" >&2; return 1; }
cpa_location_path() {
  local path=$1 cursor
  [[ $path == /* && $path != / && ! $path =~ [[:cntrl:]] ]] || return 1
  cursor=$path
  while [[ $cursor != / ]]; do
    [[ ! -L $cursor ]] || return 1
    cursor=${cursor%/*}; cursor=${cursor:-/}
  done
}
cpa_location_trusted() {
  local file=$1 owner mode cursor caller=$EUID
  if ((EUID == 0)) && [[ ${SUDO_UID:-} =~ ^[0-9]+$ ]]; then caller=$SUDO_UID; fi
  cpa_location_path "$file" && [[ -f $file && -r $file ]] || return 1
  owner=$(stat -c %u -- "$file"); mode=$(stat -c %a -- "$file")
  [[ $owner == "$EUID" || $owner == "$caller" || $owner == 0 ]] && (( (8#$mode & 0022) == 0 )) || return 1
  cursor=${file%/*}
  while :; do
    owner=$(stat -c %u -- "$cursor"); mode=$(stat -c %a -- "$cursor")
    [[ $owner == "$EUID" || $owner == "$caller" || $owner == 0 ]] || return 1
    # Root-owned sticky /tmp protects entries; other writable ancestors do not.
    (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || return 1
    [[ $cursor != / ]] || break
    cursor=${cursor%/*}; cursor=${cursor:-/}
  done
  return 0
}
cpa_location_deployment() {
  local config=$1 expected=${2:-} file mode=''
  cpa_location_path "$config" || return 1
  for file in docker native; do
    if [[ -e $config/.env.$file.json || -L $config/.env.$file.json ]]; then
      [[ -z $mode ]] || return 1
      mode=$file
    fi
  done
  [[ -n $mode ]] || return 1
  file="$config/.env.$mode.json"
  cpa_location_trusted "$file" || return 1
  jq -e --arg config "$config" --arg mode "$mode" --arg source "$expected" '
    .version==1 and .managed_by=="cpa-dr-start" and .config_dir==$config and .deployment==$mode and
    (.status=="ready" or .status=="pending" or .status=="uninstalled") and
    (.install_id|type=="string" and test("^[a-f0-9-]{36}$")) and
    ([.source_root,.state_dir,.data_dir]|all(type=="string" and startswith("/") and length>1)) and
    (.install_root|type=="string") and (.project_name|type=="string") and
    (.port|type=="number" and floor==. and .>=1 and .<=65535) and
    (.ssh_port|type=="number" and floor==. and .>=1 and .<=65535) and
    (.bind_host|type=="string") and (.read_only|type=="boolean") and (.unit_hashes|type=="object") and
    (if $mode=="native" then .run_dir=="/run/cpa-dr-native" else .run_dir=="" end) and
    (.initial_config==null or (.initial_config|type=="object" and (.node_role=="primary" or .node_role=="backup") and .enabled==false and (.sources|type=="array"))) and
    ($source=="" or .source_root==$source)
    ' "$file" >/dev/null || return 1
  printf '%s\n' "$file"
}
cpa_location_manifest_required() {
  local source=$1 origin="$1/scripts/packaging/github-source.json"
  if [[ -e $source/install-manifest.json || -L $source/install-manifest.json ||
    $source =~ /releases/([a-f0-9]{40}|[a-f0-9]{64})/cpa-dr$ ||
    $source =~ /\.local/share/cpa-dr/github/[a-f0-9]{40}/cpa-dr$ ||
    -e ${source%/*}/.bootstrap-id || -L ${source%/*}/.bootstrap-id ]]; then return 0; fi
  [[ -e $origin || -L $origin ]] || return 1
  # The repository ships commit:null as a local-source template. Only that
  # trusted, well-formed template is exempt; invalid provenance fails closed.
  cpa_location_trusted "$origin" && jq -e '.format_version==1 and has("commit") and
    (.repository|type=="string" and length>0) and
    (.commit==null or (.commit|type=="string" and test("^[a-f0-9]{40}$")))' "$origin" >/dev/null 2>&1 || return 0
  jq -e '.commit!=null' "$origin" >/dev/null
}
cpa_location_manifest() {
  local source=$1 manifest="$1/install-manifest.json" required=${2:-false} path hash actual count=0
  if [[ ! -e $manifest && ! -L $manifest ]]; then
    [[ $required != true ]] && ! cpa_location_manifest_required "$source"
    return $?
  fi
  cpa_location_trusted "$manifest" || return 1
  jq -e '.format_version==1 and (.files|type=="array" and length>0 and length<=4096) and ([.files[].path]|length==(unique|length))' "$manifest" >/dev/null || return 1
  while IFS=$'\t' read -r path hash; do
    [[ $path =~ ^[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*$ && ! /$path/ =~ /(\.|\.\.)/ && $hash =~ ^[a-f0-9]{64}$ ]] || return 1
    cpa_location_trusted "$source/$path" || return 1
    actual=$(sha256sum -- "$source/$path"); [[ ${actual:0:64} == "$hash" ]] || return 1
    ((count+=1))
  done < <(jq -r '.files[]|[.path,.sha256]|@tsv' "$manifest")
  [[ $(find "$source" -type f | wc -l) -eq $((count+1)) && -z $(find "$source" -type l -print -quit) ]]
}
cpa_location_project_file() {
  local file=$1
  cpa_location_path "$file" || { cpa_location_fail '项目文件路径含链接或异常'; return 1; }
  if [[ -e $file || -L $file ]]; then
    cpa_location_trusted "$file" && [[ $(stat -c %h -- "$file") == 1 ]] || { cpa_location_fail '项目文件须为单链接、归属与权限可信的普通文件'; return 1; }
  fi
}
cpa_location_project_marker() {
  local file="$1/.cpa-dr-project"
  cpa_location_project_file "$file" || return 1
  if [[ -e $file ]]; then
    [[ $(< "$file") == 'cpa-dr project v1' ]] || { cpa_location_fail '项目标记内容异常，未覆盖'; return 1; }
  else
    printf '%s\n' 'cpa-dr project v1' | cpa_location_write "$file" 600
  fi
}
# Absence is a positive lookup result, never an unreadable-path fallback.
# Use the same caller/ancestor ownership rules as trusted record reads.
cpa_location_records_absent() {
  local config=$1 cursor=$1 record owner mode caller=$EUID
  if ((EUID == 0)) && [[ ${SUDO_UID:-} =~ ^[0-9]+$ ]]; then caller=$SUDO_UID; fi
  while :; do
    if [[ -e $cursor || -L $cursor ]]; then
      [[ -d $cursor && ! -L $cursor && -r $cursor && -x $cursor ]] || return 1
      owner=$(stat -c %u -- "$cursor") || return 1
      mode=$(stat -c %a -- "$cursor") || return 1
      [[ $owner == "$EUID" || $owner == "$caller" || $owner == 0 ]] &&
        (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || return 1
    fi
    [[ $cursor != / ]] || break
    cursor=${cursor%/*}; cursor=${cursor:-/}
  done
  for record in .env.native.json .env.docker.json .env; do
    [[ ! -e $config/$record && ! -L $config/$record ]] || return 1
  done
  return 0
}
cpa_location_read() {
  local project=$1 file="$1/install.json" source config record id path explicit=${2:-0}
  cpa_location_trusted "$file" || { cpa_location_fail '入口记录不可读、权限不安全或含链接'; return 1; }
  jq -e --arg project "$project" '.format_version==1 and .project_dir==$project and
    ([.source_root,.config_dir]|all(type=="string" and startswith("/") and length>1)) and
    (.deployment=="native" or .deployment=="docker") and (.install_id|test("^[a-f0-9-]{36}$")) and
    (if has("manifest_required") then (.manifest_required|type=="boolean") else true end) and
    (.status==null or .status=="purged")' "$file" >/dev/null || { cpa_location_fail '入口记录格式异常'; return 1; }
  source=$(jq -r .source_root "$file"); config=$(jq -r .config_dir "$file"); id=$(jq -r .install_id "$file")
  for path in "$project" "$source" "$config"; do cpa_location_path "$path" || { cpa_location_fail '入口路径含链接或异常'; return 1; }; done
  cpa_location_trusted "$source/start.sh" || { cpa_location_fail '源码入口不可读、权限不安全或含链接'; return 1; }
  cpa_location_manifest "$source" "$(jq -r '.manifest_required//false' "$file")" || { cpa_location_fail '源码清单校验失败，原配置与数据保留'; return 1; }
  # Explicit target selection/internal purge bookkeeping intentionally skips
  # records. A receipt skips identity only after all record forms are absent.
  if ((explicit)); then printf '%s\n' "$file"; return 0; fi
  if jq -e '.status=="purged"' "$file" >/dev/null && cpa_location_records_absent "$config"; then
    printf '%s\n' "$file"; return 0
  fi
  if ((EUID != 0)) && [[ $(jq -r .deployment "$file") == native && ! -r $config/.env.native.json ]]; then
    # Read-only Native queries preserve unknown permissions. Explicit writes
    # return through the stable entry after confirmation for root revalidation.
    printf '%s\n' "$file"; return 0
  fi
  record=$(cpa_location_deployment "$config" "$source") || { cpa_location_fail '入口关联的部署记录异常'; return 1; }
  jq -e --arg id "$id" --arg mode "$(jq -r .deployment "$file")" '.install_id==$id and .deployment==$mode' "$record" >/dev/null || { cpa_location_fail '入口安装身份与部署记录不符'; return 1; }
  printf '%s\n' "$file"
}
cpa_location_native_sudo() {
  local project=$1 source=$2 config=$3 mode=$4 id=$5 confirmed=$6 answer cwd
  shift 6
  [[ -t 0 || $confirmed == 1 ]] || { cpa_location_fail '非交互 Native 操作须显式 --yes，未提权'; return 1; }
  if [[ -t 0 ]] && ((confirmed == 0)); then
    printf '\n提权校验计划：Native 部署 %s\n将通过 sudo 回到稳定入口核验身份；原操作向导与最终确认保持。\n' "$config"
    read -r -p '确认通过 sudo 校验并进入原操作？[y/N] ' answer || return 1
    case $answer in y|Y|yes|YES) ;; *) return 1;; esac
  fi
  command -v sudo >/dev/null || { cpa_location_fail 'Native 操作需要 root/sudo'; return 1; }
  cwd=$(pwd -P) || return 1
  exec sudo -- bash "$project/start.sh" --native-reentry "$source" "$config" "$mode" "$id" "$cwd" -- "$@"
}
# Match the source CLI's action grammar, including options before the action.
# Values are never classified as commands; conflicting actions fail before sudo.
cpa_location_action() {
  local selected='' candidate argument menu_options=0
  while (($#)); do
    argument=$1; candidate=''
    case $argument in
      --help|-h) printf 'help\n'; return 0;;
      --output|--data-dir|--port|--ssh-port|--role|--deployment|--source|--state-dir|--install-root|--bind-host|--ssh-bind-host|--invite-file|--invite|--primary-host|--primary-port|--backup-host|--backup-port|--backup-data-dir|--backup-deployment|--backup-output|--backup-bind-host|--ttl|--tail)
        (($# >= 2)) && [[ -n $2 ]] || { cpa_location_fail "参数缺少值：$argument"; return 1; }
        [[ $argument != --deployment || $2 == native || $2 == docker ]] || { cpa_location_fail '--deployment 须为 native 或 docker'; return 1; }
        case $argument in --output|--deployment) ;; *) menu_options=1;; esac
        shift 2; continue;;
      install|menu|status|doctor|start|stop|restart|logs|generate-backup-command|join|configure-ssh) candidate=$argument;;
      uninstall|--uninstall|--purge) candidate=uninstall;;
      --yes|--no-install-deps|--read-only-data|--generate-backup|--no-auto-enable|--follow) menu_options=1;;
      *) cpa_location_fail "未知参数：$argument（使用 --help 查看用法）"; return 1;;
    esac
    if [[ -n $candidate ]]; then
      [[ -z $selected || $selected == "$candidate" ]] || { cpa_location_fail '每次只能指定一种操作'; return 1; }
      selected=$candidate
    fi
    shift
  done
  [[ $selected != menu || $menu_options == 0 ]] || { cpa_location_fail 'menu 仅接受目标目录/方式选项'; return 1; }
  printf '%s\n' "${selected:-install}"
}
cpa_location_launch() {
  local project=$1 info source config mode id output_given=0 argument generate=0 purge_action=0 uninstall_action=0 skip=0 requested_output='' requested_deployment='' selected_action
  local reentry=0 same_target=1 confirmed=0 help_requested=0 expected_source='' expected_config='' expected_mode='' expected_id='' expected_cwd=''
  shift
  if [[ ${1:-} == --native-reentry ]]; then
    ((EUID == 0 && $# >= 8)) || { cpa_location_fail 'Native 提权重入上下文异常'; return 1; }
    expected_source=$2; expected_config=$3; expected_mode=$4; expected_id=$5; expected_cwd=$6
    shift 6
    [[ $1 == -- && $expected_mode == native ]] && { [[ $expected_cwd == / ]] || cpa_location_path "$expected_cwd"; } || { cpa_location_fail 'Native 提权重入上下文异常'; return 1; }
    shift
    cd -- "$expected_cwd" || return 1
    reentry=1
  fi
  for argument in "$@"; do
    if ((skip)); then
      [[ $skip != 2 ]] || requested_output=$argument
      [[ $skip != 3 ]] || requested_deployment=$argument
      skip=0; continue
    fi
    case $argument in
      --output) output_given=1; skip=2;;
      --deployment) skip=3;;
      --data-dir|--port|--ssh-port|--role|--source|--state-dir|--install-root|--bind-host|--ssh-bind-host|--invite-file|--invite|--primary-host|--primary-port|--backup-host|--backup-port|--backup-data-dir|--backup-deployment|--backup-output|--backup-bind-host|--ttl|--tail) skip=1;;
      --generate-backup) generate=1;;
      --yes) confirmed=1;;
      --help|-h) help_requested=1;;
      --purge) purge_action=1; uninstall_action=1;;
      uninstall|--uninstall) uninstall_action=1;;
    esac
  done
  # This first read validates association/source provenance only. Target
  # selection, not merely the presence of --output, decides record validation.
  info=$(cpa_location_read "$project" 1) || return 1
  source=$(jq -r .source_root "$info"); config=$(jq -r .config_dir "$info")
  mode=$(jq -r .deployment "$info"); id=$(jq -r .install_id "$info")
  if ((output_given)) && [[ $(realpath -ms -- "$requested_output") != "$(realpath -ms -- "$config")" ]]; then same_target=0; fi
  if ((reentry)); then
    ((same_target)) && [[ $source == "$expected_source" && $config == "$expected_config" && $mode == "$expected_mode" && $id == "$expected_id" ]] || {
      cpa_location_fail 'Native 提权上下文与入口关联不符，未执行原操作'; return 1;
    }
  fi
  if ((same_target)); then cpa_location_read "$project" >/dev/null || return 1; fi
  local -a args=("$@")
  if [[ ${args[0]:-} == --bootstrap-existing ]]; then
    args=("${args[@]:1}")
    if ((generate)); then
      local -a filtered=()
      skip=0
      for argument in "${args[@]}"; do
        if ((skip)); then filtered+=("$argument"); skip=0; continue; fi
        case $argument in
          --generate-backup) continue;;
          --output|--data-dir|--port|--ssh-port|--role|--deployment|--source|--state-dir|--install-root|--bind-host|--ssh-bind-host|--invite-file|--invite|--primary-host|--primary-port|--backup-host|--backup-port|--backup-data-dir|--backup-deployment|--backup-output|--backup-bind-host|--ttl|--tail) skip=1;;
        esac
        filtered+=("$argument")
      done
      args=(generate-backup-command "${filtered[@]}")
    elif [[ ${#args[@]} == 0 || ( ${#args[@]} == 1 && ${args[0]} == --yes ) ]]; then
      if [[ -t 0 ]]; then args=(menu); else args=(status); fi
    else args=(install "${args[@]}"); fi
  fi
  ((output_given)) || args+=(--output "$config")
  if [[ $# == 0 ]]; then args=(menu --output "$config"); fi
  selected_action=$(cpa_location_action "${args[@]}") || return 1
  if [[ $selected_action == menu ]]; then
    cpa_location_menu "$project" "$source" "$config" "$requested_output" "$requested_deployment"
    return
  fi
  if ((EUID != 0 && same_target && help_requested == 0)) && [[ $mode == native ]]; then
    case $selected_action in
      status|doctor|logs) ;;
      *) cpa_location_native_sudo "$project" "$source" "$config" "$mode" "$id" "$confirmed" "${args[@]}"; return;;
    esac
  fi
  if ((purge_action && uninstall_action)); then
    bash "$source/start.sh" "${args[@]}" || return $?
    if ((output_given == 0)) || [[ $(realpath -m -- "$requested_output") == "$config" ]]; then
      local receipt
      receipt=$(mktemp "$project/.purge.XXXXXXXX")
      jq '.status="purged"' "$info" > "$receipt"; chmod 600 "$receipt"
      if ((EUID == 0)); then chown --reference="$info" "$receipt"; fi
      mv -fT "$receipt" "$info"
    fi
    return 0
  fi
  if [[ $selected_action == install ]]; then
    bash "$source/start.sh" "${args[@]}" || return $?
    if ((output_given == 0)) || [[ $(realpath -m -- "$requested_output") == "$config" ]]; then
      local refreshed deployed
      deployed=$(cpa_location_deployment "$config" "$source") || return 1
      refreshed=$(mktemp "$project/.refresh.XXXXXXXX")
      jq --arg id "$(jq -r .install_id "$deployed")" --arg mode "$(jq -r .deployment "$deployed")" 'del(.status)|.install_id=$id|.deployment=$mode' "$info" > "$refreshed"
      chmod 600 "$refreshed"
      if ((EUID == 0)); then chown --reference="$info" "$refreshed"; fi
      mv -fT "$refreshed" "$info"
    fi
    return 0
  fi
  exec bash "$source/start.sh" "${args[@]}"
}
cpa_location_menu() {
  local project=$1 source=$2 config=$3 requested=$4 requested_deployment=${5:-} answer kind action
  [[ -t 0 ]] || { cpa_location_fail 'menu 需要终端；请使用 status 等显式命令'; return 1; }
  local -a target=()
  [[ -z $requested ]] || target=(--output "$requested")
  [[ -z $requested_deployment ]] || target+=(--deployment "$requested_deployment")
  while :; do
    printf '\n━━━━━━━━ CPA 主备备份服务管理 ━━━━━━━━\n'
    bash "$source/start.sh" status --output "${requested:-$config}" "${target[@]}" || return 1
    printf '\n  1) 安装 / 恢复已有安装\n  2) 卸载服务\n  3) 查看详细状态\n  4) 环境检查与故障诊断\n  5) 服务管理（启动 / 停止 / 重启）\n  6) 查看日志\n  7) 生成备机安装命令\n  0) 退出\n'
    read -r -p '请选择 [0-7]：' answer || return 0
    local -a args=()
    case $answer in
      0) return 0;; 1) args=(install);;
      2)
        printf '  1) 普通卸载，保留配置/密钥/备份\n  2) 卸载并清理专用状态\n  0) 返回\n'
        read -r -p '请选择 [0-2]：' kind || return 0
        case $kind in 1) args=(uninstall);; 2) args=(uninstall --purge);; *) continue;; esac;;
      3) args=(status);; 4) args=(doctor);;
      5)
        read -r -p '1) 启动 2) 停止 3) 重启 0) 返回：' kind || return 0
        case $kind in 1) action=start;; 2) action=stop;; 3) action=restart;; *) continue;; esac
        args=("$action");;
      6) args=(logs);; 7) args=(generate-backup-command);;
      *) printf '请输入 0 到 7。\n'; continue;;
    esac
    bash "$project/start.sh" "${args[@]}" "${target[@]}" || printf '操作未完成或已取消，原配置保留。\n'
  done
}
cpa_location_mark_purged() {
  local source=$1 config=$2 project info
  [[ $source == */releases/*/cpa-dr ]] || return 0
  project=${source%/releases/*}
  [[ -e $project/install.json ]] || return 0
  info=$(cpa_location_read "$project" 1) || return 1
  [[ $(jq -r .config_dir "$info") == "$config" ]] || return 0
  jq '.status="purged"' "$info" | cpa_location_write "$info" 600
}
cpa_location_write() {
  local file=$1 mode=$2 stage
  cpa_location_path "$file" || return 1
  stage=$(mktemp "${file%/*}/.location.XXXXXXXX") || return 1
  cat > "$stage"; chmod "$mode" "$stage"
  if ((EUID == 0)) && [[ -e $file ]]; then chown --reference="$file" "$stage"; fi
  mv -fT -- "$stage" "$file"
}
cpa_location_register() {
  local project=$1 source=$2 config=$3 shortcut=$4 invite=${5:-} record mode id path required=false
  for path in "$project" "$source" "$config" "$shortcut"; do cpa_location_path "$path" || { cpa_location_fail '安装路径含链接或异常'; return 1; }; done
  record=$(cpa_location_deployment "$config" "$source") || { cpa_location_fail '部署记录未通过核验，未登记入口'; return 1; }
  if cpa_location_manifest_required "$source"; then required=true; fi
  cpa_location_manifest "$source" "$required" || { cpa_location_fail '源码清单校验失败，未登记入口'; return 1; }
  mode=$(jq -r .deployment "$record"); id=$(jq -r .install_id "$record")
  mkdir -p -- "$project"; chmod 700 "$project"
  if [[ -e $project/install.json || -L $project/install.json ]]; then
    # Registration follows successful installation, not an execution preflight:
    # validate the old receipt separately from the new record verified above.
    cpa_location_read "$project" 1 >/dev/null || return 1
    jq -e --arg id "$id" --arg source "$source" --arg config "$config" '(.install_id==$id or .status=="purged") and .source_root==$source and .config_dir==$config' "$project/install.json" >/dev/null || { cpa_location_fail '项目已关联其他部署'; return 1; }
  fi
  if [[ -e $project/start.sh || -L $project/start.sh ]]; then
    cpa_location_trusted "$project/start.sh" && grep -qx '# cpa-dr stable project launcher v1' "$project/start.sh" || { cpa_location_fail '项目 start.sh 属于其他文件，未覆盖'; return 1; }
  fi
  jq -n --arg project "$project" --arg source "$source" --arg config "$config" --arg mode "$mode" --arg id "$id" --arg invite "$invite" --argjson required "$required" \
    '{format_version:1,project_dir:$project,source_root:$source,config_dir:$config,deployment:$mode,install_id:$id,invite_id:$invite,manifest_required:$required}' | cpa_location_write "$project/install.json" 600 || return 1
  {
    printf '#!/usr/bin/env bash\n# cpa-dr stable project launcher v1\nset -Eeuo pipefail\n'
    declare -f cpa_location_fail cpa_location_path cpa_location_trusted cpa_location_deployment cpa_location_manifest_required cpa_location_manifest cpa_location_records_absent cpa_location_read cpa_location_native_sudo cpa_location_action cpa_location_launch cpa_location_menu
    printf '%s\n' 'directory=.' '[[ ${BASH_SOURCE[0]} != */* ]] || directory=${BASH_SOURCE[0]%/*}' 'project=$(cd -- "$directory" && pwd -P)' 'cpa_location_launch "$project" "$@"'
  } | cpa_location_write "$project/start.sh" 700 || return 1
  if ((EUID == 0)) && [[ ${SUDO_UID:-} =~ ^[0-9]+$ && ${SUDO_GID:-} =~ ^[0-9]+$ ]]; then
    chown "$SUDO_UID:$SUDO_GID" "$project/install.json" "$project/start.sh"
  fi
  if [[ ! -e $shortcut/start.sh && ! -L $shortcut/start.sh ]]; then
    { printf '#!/usr/bin/env bash\n# cpa-dr shortcut v1\n# project: %s\nexec bash ' "$project"; printf '%q ' "$project/start.sh"; printf '"$@"\n'; } | cpa_location_write "$shortcut/start.sh" 700 || return 1
  elif cpa_location_trusted "$shortcut/start.sh" && grep -qx '# cpa-dr shortcut v1' "$shortcut/start.sh" && grep -Fxq "# project: $project" "$shortcut/start.sh"; then :
  else printf '已保留其他 start.sh；请使用完整项目入口。\n' >&2; fi
  if ((EUID == 0)) && [[ ${SUDO_UID:-} =~ ^[0-9]+$ && ${SUDO_GID:-} =~ ^[0-9]+$ ]] && grep -Fxq "# project: $project" "$shortcut/start.sh"; then
    chown "$SUDO_UID:$SUDO_GID" "$shortcut/start.sh"
  fi
  printf '项目目录：%s\n配置目录：%s\n源码目录：%s\n状态目录：%s\n管理命令：' "$project" "$config" "$source" "$(jq -r .state_dir "$record")"
  printf 'bash %q menu\n' "$project/start.sh"
  printf '状态命令：bash %q status\n备机邀请：bash %q generate-backup-command\n' "$project/start.sh" "$project/start.sh"
}
