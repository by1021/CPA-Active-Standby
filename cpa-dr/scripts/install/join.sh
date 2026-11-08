#!/usr/bin/env bash
# Invite-driven backup installation, resumable with the backup's permanent identity.
# shellcheck disable=SC2154,SC2016
cpa_join_validate() {
  local file=$1 path name kind relative host port
  [[ -f $file && ! -L $file && $(stat -c %s "$file") -le 65536 ]] || fail '邀请文件异常'
  jq -e '.version==1 and (.invite_id|type=="string" and test("^[A-Za-z0-9_-]{1,96}$")) and (.auto_enable|type=="boolean") and (.primary.node_id|type=="string") and (.primary.public_key|type=="string") and (.primary.host_key|type=="string") and (.sources|type=="array" and length>0 and length<=128) and (.backup.deployment=="native" or .backup.deployment=="docker") and (.backup.data_dir|type=="string") and (.policy|type=="object")' "$file" >/dev/null || fail '邀请格式不完整'
  for side in primary backup; do
    host=$(jq -r --arg side "$side" '.[$side].host' "$file"); port=$(jq -r --arg side "$side" '.[$side].port' "$file")
    [[ $host =~ ^[A-Za-z0-9:][A-Za-z0-9_.:-]{0,252}$ && $port =~ ^[0-9]{1,5}$ ]] && ((10#$port > 0 && 10#$port <= 65535)) || fail '邀请连接地址或端口异常'
  done
  path=$(jq -r .backup.data_dir "$file"); cpa_path_validate "$path" || fail '备机数据目录异常'
  [[ $path != / && $path != *[\'\"\\\$:]* ]] || fail '备机数据目录不支持特殊字符或根目录'
  while IFS=$'\t' read -r name kind relative; do
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ && $kind =~ ^(directory|file|sqlite)$ ]] || fail '邀请数据标签或类型异常'
    [[ $relative == . || ( -n $relative && $relative != /* && $relative != ../* && $relative != *'/../'* && $relative != */.. && $relative != *'/./'* && $relative != *[\'\"\\\$:]* && ! $relative =~ [[:cntrl:]] ) ]] || fail '邀请相对数据路径异常'
  done < <(jq -r '.sources[]|[.name,.kind,.relative_path]|@tsv' "$file")
}
cpa_join_read() {
  local path=$1
  if [[ $deployment == docker ]]; then
    if [[ $manager_service == 运行中 ]]; then docker exec "$manager_container" cat "/state/$path"
    elif [[ -n $manager_container ]]; then docker cp "$manager_container:/state/$path" - | tar -xOf -
    else cpa_start_no_links "$state/$path"; cat "$state/$path"; fi
  else cpa_start_no_links "$state/$path"; cat "$state/$path"; fi
}
# An optional marker is absent only after every ancestor has been inspected.
# Do not turn inaccessible paths, links, special files or invalid JSON into {}.
cpa_join_marker_local() {
  local path="$1/enrollment/join.json" cursor="$1/enrollment" size
  cpa_path_validate "$path" || return 1
  while [[ $cursor != / ]]; do
    if [[ -e $cursor ]]; then [[ -d $cursor && -x $cursor ]] || return 1; fi
    cursor=${cursor%/*}; cursor=${cursor:-/}
  done
  if [[ ! -e $path ]]; then printf '{}\n'; return 0; fi
  [[ -f $path && -r $path ]] || return 1
  size=$(stat -c %s -- "$path") || return 1
  ((size <= 65536)) || return 1
  jq -se 'if length==1 and (.[0]|type=="object") then .[0] else error("invalid invitation marker") end' "$path"
}
cpa_join_marker() {
  if [[ $deployment == docker && $manager_service == 运行中 ]]; then
    local script
    script=$(printf '%s\n' 'set -Eeuo pipefail' 'source /opt/cpa-dr/lib/common.sh'; declare -f cpa_join_marker_local; printf '%s\n' 'cpa_join_marker_local "$1"')
    docker exec "$manager_container" bash -c "$script" -- /state
  else
    # Never start a stopped service/helper merely to inspect private state.
    # If its host mount cannot be inspected, reject before any install mutation.
    cpa_join_marker_local "$state"
  fi
}
cpa_join_store() {
  local path=$1
  if [[ $deployment == docker ]]; then
    docker exec -i "$manager_container" bash -c 'set -Eeuo pipefail; umask 077; export CPA_STATE_DIR=/state; source /opt/cpa-dr/lib/common.sh; mkdir -p /state/enrollment; chmod 700 /state/enrollment; cpa_atomic "/state/$1"' -- "$path"
  else mkdir -p "$state/enrollment"; chmod 700 "$state/enrollment"; cpa_atomic "$state/$path"; fi
}
cpa_join_acknowledge_completion() {
  local file=$1 response=$2 id marker snapshot
  id=$(jq -r .invite_id "$file")
  jq -e --arg id "$id" '.completed==true and .invite_id==$id and (.snapshot_id|type=="string")' <<< "$response" >/dev/null || fail '主机最终完成收据异常，保持未确认状态'
  snapshot=$(jq -r .snapshot_id <<< "$response")
  marker=$(cpa_join_marker) || fail '安装邀请记录读取失败，未记录主机确认'
  jq -e --arg id "$id" --arg node "$(jq -r .primary.node_id "$file")" --arg snapshot "$snapshot" '.invite_id==$id and .primary_node_id==$node and .status=="completed" and .snapshot_id==$snapshot' <<< "$marker" >/dev/null || fail '主机最终完成收据与本机首次快照不一致，保持未确认状态'
  jq '.completion_acknowledged=true' <<< "$marker" | cpa_join_store enrollment/join.json || fail '主机最终完成确认记录未保存，可重跑同一邀请'
}
# ssh-keygen -F resolves hashed names, aliases and OpenSSH host patterns. A
# matching endpoint is immutable: every candidate must be the invited key.
cpa_join_pin_local() {
  local file=$1 endpoint=$2 key=$3 mode=$4 cursor algorithm expected matches names stored rest found=0 rc content=''
  [[ $mode == check || $mode == write ]] || return 1
  # OpenSSH lowercases host names before hashing; queries must do the same.
  endpoint=${endpoint,,}
  [[ ! $key =~ [[:cntrl:]] ]] || return 1
  read -r algorithm expected rest <<< "$key"
  [[ $algorithm == ssh-ed25519 && $expected =~ ^[A-Za-z0-9+/=]{1,256}$ ]] || return 1
  key="$algorithm $expected"
  ssh-keygen -l -f <(printf '%s\n' "$key") >/dev/null 2>&1 || return 1
  cpa_path_validate "$file" || return 1
  cursor=${file%/*}
  while [[ $cursor != / ]]; do
    if [[ -e $cursor ]]; then [[ -d $cursor && -x $cursor ]] || return 1; fi
    cursor=${cursor%/*}; cursor=${cursor:-/}
  done
  if [[ -e $file ]]; then
    [[ -f $file && -r $file ]] || return 1
    if matches=$(ssh-keygen -F "$endpoint" -f "$file" 2>&1); then
      while read -r names algorithm stored rest; do
        [[ -n $names && $names != \#* ]] || continue
        [[ $names != @* && $algorithm == ssh-ed25519 && $stored == "$expected" ]] || { cpa_fail '主机指纹与已有记录冲突，拒绝替换'; return 1; }
        ((found+=1))
      done <<< "$matches"
      ((found > 0)) || return 1
      return 0
    else
      rc=$?
      [[ $rc == 1 && -z $matches ]] || return 1
    fi
  fi
  [[ $mode == write ]] || return 0
  if [[ -e $file ]]; then
    content=$(cat -- "$file" && printf '.') || return 1
    content=${content%.}
  fi
  { printf '%s' "$content"; [[ -z $content || $content == *$'\n' ]] || printf '\n'; printf '%s %s\n' "$endpoint" "$key"; } | cpa_atomic "$file"
}
cpa_join_transport() {
  local config
  config=$(cpa_join_read config.json) || return 1
  jq -ce '.peer | select(type=="object" and .identity_file!=.known_hosts_file and ([.identity_file,.known_hosts_file]|all(type=="string" and startswith("/") and length>1))) | {identity_file,known_hosts_file}' <<< "$config"
}
cpa_join_transport_local_path() {
  local path=$1
  if [[ $deployment == docker ]]; then
    # Discovery verified the /state bind. No stopped-container helper or
    # arbitrary external mount is used to inspect configured private paths.
    [[ $path == /state/* ]] || return 1
    path="$state/${path#/state/}"
  fi
  cpa_path_validate "$path" || return 1
  printf '%s\n' "$path"
}
cpa_join_public_key_local() {
  local file=$1 key sidecar
  cpa_path_validate "$file" || return 1
  [[ -f $file && -r $file ]] || return 1
  key=$(ssh-keygen -y -P '' -f "$file" </dev/null) || return 1
  [[ $key =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || return 1
  key=$(awk '{print $1 " " $2}' <<< "$key")
  if [[ -e $file.pub || -L $file.pub ]]; then
    cpa_path_validate "$file.pub" || return 1
    [[ -f $file.pub && -r $file.pub ]] || return 1
    sidecar=$(awk '{print $1 " " $2}' "$file.pub") || return 1
    [[ $sidecar == "$key" ]] || return 1
  fi
  printf '%s\n' "$key"
}
cpa_join_public_key() {
  local transport file script
  transport=$(cpa_join_transport) || return 1
  file=$(jq -r .identity_file <<< "$transport")
  if [[ $deployment == docker && $manager_service == 运行中 ]]; then
    script=$(printf '%s\n' 'set -Eeuo pipefail' 'source /opt/cpa-dr/lib/common.sh'; declare -f cpa_join_public_key_local; printf '%s\n' 'cpa_join_public_key_local "$1"')
    docker exec "$manager_container" bash -c "$script" -- "$file"
  else
    file=$(cpa_join_transport_local_path "$file") || return 1
    cpa_join_public_key_local "$file"
  fi
}
cpa_join_known_host() {
  local host=$1 port=$2 key=$3 mode=${4:-write} endpoint script transport file
  endpoint=$host; [[ $port == 22 ]] || endpoint="[$host]:$port"
  transport=$(cpa_join_transport) || return 1
  file=$(jq -r .known_hosts_file <<< "$transport")
  if [[ $deployment == docker && $manager_service == 运行中 ]]; then
    script=$(printf '%s\n' 'set -Eeuo pipefail; umask 077' 'source /opt/cpa-dr/lib/common.sh'; declare -f cpa_join_pin_local; printf '%s\n' 'cpa_join_pin_local "$1" "$2" "$3" "$4"')
    docker exec "$manager_container" bash -c "$script" -- "$file" "$endpoint" "$key" "$mode"
  else
    file=$(cpa_join_transport_local_path "$file") || return 1
    cpa_join_pin_local "$file" "$endpoint" "$key" "$mode"
  fi
}
cpa_join_ssh() {
  local identity=$1 command=$2 file=$3 host port private transport key known
  host=$(jq -r .primary.host "$file"); port=$(jq -r .primary.port "$file")
  if [[ $identity == permanent ]]; then
    [[ $deployment != docker || $manager_service == 运行中 ]] || return 1
    transport=$(cpa_join_transport) || return 1
    key=$(jq -r .identity_file <<< "$transport"); known=$(jq -r .known_hosts_file <<< "$transport")
    cpa_join_public_key >/dev/null || return 1
    if [[ $deployment == docker ]]; then
      docker exec -i "$manager_container" timeout 300 ssh -T -oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes -oConnectTimeout=10 -o "UserKnownHostsFile=$known" -i "$key" -p "$port" "root@$host" "$command"
    else
      timeout 300 ssh -T -oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes -oConnectTimeout=10 -o "UserKnownHostsFile=$known" -i "$key" -p "$port" "root@$host" "$command"
    fi
  else
    private=$(mktemp -d); chmod 700 "$private"
    jq -r .temporary_private_key "$file" > "$private/key"
    local endpoint=$host; [[ $port == 22 ]] || endpoint="[$host]:$port"
    printf '%s %s\n' "$endpoint" "$(jq -r .primary.host_key "$file")" > "$private/known_hosts"; chmod 600 "$private/key" "$private/known_hosts"
    local rc=0
    timeout 300 ssh -T -oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes -oConnectTimeout=10 -o "UserKnownHostsFile=$private/known_hosts" -i "$private/key" -p "$port" "root@$host" "$command" || rc=$?
    rm -rf -- "$private"; return "$rc"
  fi
}
cpa_join_main() {
  local temporary='' requested_output=$output requested_deployment=$deployment requested_data=$data file id host_key public_key node desired marker prior response
  local -a source_args=()
  if [[ -n $invite_payload ]]; then
    [[ -z $invite_file && $invite_payload =~ ^[A-Za-z0-9+/=]+$ ]] || fail '邀请参数冲突或编码异常'
    temporary=$(mktemp); chmod 600 "$temporary"; printf '%s' "$invite_payload" | base64 -d > "$temporary" || fail '邀请编码异常'
    invite_file=$temporary
  fi
  [[ -n $invite_file ]] || fail 'join 需要 --invite-file FILE'
  file=$(realpath -e -- "$invite_file")
  cpa_join_validate "$file"
  id=$(jq -r .invite_id "$file"); data=$(jq -r .backup.data_dir "$file"); deployment=$(jq -r .backup.deployment "$file")
  [[ -z $requested_data || $requested_data == "$data" ]] || fail '--data-dir 与邀请冲突'
  [[ -z $requested_deployment || $requested_deployment == "$deployment" ]] || fail '--deployment 与邀请冲突'
  output=$(jq -r '.backup.output//empty' "$file")
  if [[ -z $output ]]; then output=${requested_output:-}; fi
  [[ -n $output ]] || { [[ $deployment != native ]] || output=/etc/cpa-dr-native; output=${output:-$HOME/.local/share/cpa-dr/deployments/$id}; }
  [[ -z $requested_output || $requested_output == "$output" ]] || fail '--output 与邀请冲突'
  cpa_path_validate "$output" || fail '备机部署目录异常'
  cpa_paths_intersect "$ROOT" "$output" && fail '备机源码与部署目录须独立'
  cpa_paths_intersect "$data" "$output" && fail '备机数据与部署目录须独立'
  cpa_paths_intersect "$data" "$ROOT" && fail '备机数据与源码目录须独立'
  if [[ $deployment == native && $EUID != 0 ]]; then
    [[ -t 0 || $assume_yes == 1 ]] || fail '非交互加入需 --yes，未提权'
  fi
  # Invite output is resolved first: different targets retain their priority,
  # while this fixed release's own target keeps its stable identity across sudo.
  if [[ $ROOT == */releases/*/cpa-dr ]]; then cpa_manager_find_association; fi
  if [[ $deployment == native && $EUID != 0 ]]; then
    command -v sudo >/dev/null || fail 'Linux 本地安装需要 root/sudo'
    local -a elevated=(join --invite-file "$file" --output "$output")
    ((assume_yes == 0)) || elevated+=(--yes)
    exec sudo -- bash "$ROOT/start.sh" "${elevated[@]}"
  fi
  printf '\n邀请备机安装计划：\n部署：%s\n数据：%s\n安装配置：%s\nSSH监听：%s:%s\n主机：%s:%s\n首备校验通过后才启用调度，不恢复CPA运行数据。\n' "$deployment" "$data" "$output" "$(jq -r .backup.bind_host "$file")" "$(jq -r .backup.port "$file")" "$(jq -r .primary.host "$file")" "$(jq -r .primary.port "$file")"
  local answer
  if ((assume_yes == 0)); then [[ -t 0 ]] || fail '非交互加入需 --yes'; prompt '确认按邀请安装并配对？[y/N] ' answer; yes_answer "$answer" || fail '已取消加入'; fi
  # Before creating or starting anything, reject an existing unrelated deployment.
  cpa_manager_snapshot
  # An empty record is absence only when discovery positively reports absence.
  # Malformed/legacy/inaccessible records must not become an install attempt.
  [[ -z $manager_reason ]] || fail '已有安装状态未确认，未启动或修改服务'
  if [[ -z $record ]]; then
    [[ $manager_install == 未安装 && $manager_service == 未安装 ]] || fail '已有安装状态未确认，未启动或修改服务'
  else
    [[ $manager_backend == "$deployment" && $(jq -r .data_dir <<< "$record") == "$data" ]] || fail '已有安装与邀请目录/方式冲突'
    prior=$(cpa_join_read config.json) || fail '已有数据配置读取失败，未启动或修改服务'
    jq -e --arg node "$(jq -r .primary.node_id "$file")" '.node_role=="backup" and (.peer.node_id=="" or .peer.node_id==$node)' <<< "$prior" >/dev/null || fail '已有角色或主备关系与邀请冲突'
    marker=$(cpa_join_marker) || fail '已有安装邀请记录读取失败，未启动或修改服务'
    jq -e --arg id "$id" '.invite_id==null or .invite_id==$id' <<< "$marker" >/dev/null || fail '已有安装邀请与本次邀请冲突，未启动或修改服务'
    if [[ $(jq -r '.status//empty' <<< "$marker") == completed ]]; then
      jq -e --arg node "$(jq -r .primary.node_id "$file")" '.primary_node_id==$node and (.snapshot_id|type=="string")' <<< "$marker" >/dev/null || fail '原已完成邀请记录异常，未修改服务'
      # Backup activation precedes the primary's final commit. Only an explicit
      # observed primary receipt makes subsequent replay entirely read-only.
      if ! jq -e '.completion_acknowledged==true' <<< "$marker" >/dev/null; then
        cpa_join_known_host "$(jq -r .primary.host "$file")" "$(jq -r .primary.port "$file")" "$(jq -r .primary.host_key "$file")" check || fail '主机指纹与已有记录冲突或不可核验，未启动或修改服务'
        cpa_join_public_key >/dev/null || fail '已有SSH身份不可核验，未启动或修改服务'
        response=$(cpa_join_ssh permanent "enroll-complete $id" "$file") || fail '主机最终完成确认失败；未重新安装或修改本机配置，可重跑同一邀请'
        cpa_join_acknowledge_completion "$file" "$response"
        printf '\n本邀请已完成主机最终提交；首备快照：%s\n自动备份：%s（按邀请策略完成提交）；未重新安装服务。\n' "$(jq -r .snapshot_id <<< "$response")" "$(jq -r '.enabled' <<< "$response")"
      else
        printf '\n本邀请已完成；首备快照：%s\n保留当前服务状态、暂停设置和数据配置；未重新安装或启用调度。\n' "$(jq -r .snapshot_id <<< "$marker")"
      fi
      [[ -z $temporary ]] || rm -f "$temporary"
      return 0
    fi
    cpa_join_known_host "$(jq -r .primary.host "$file")" "$(jq -r .primary.port "$file")" "$(jq -r .primary.host_key "$file")" check || fail '主机指纹与已有记录冲突或不可核验，未启动或修改服务'
    cpa_join_public_key >/dev/null || fail '已有SSH身份不可核验，未启动或修改服务'
    local current_runtime
    current_runtime=$(cpa_join_read runtime.json) || fail '已有任务状态读取失败，未启动或修改服务'
    jq -e '.job.running==false and (.phase=="unconfigured" or .phase=="backup_standby")' <<< "$current_runtime" >/dev/null || fail '已有服务处于任务或容灾保护状态，未启动或修改服务'
    jq -e --slurpfile invite "$file" '$invite[0] as $i | .allowed_root as $root | (.sources|length==0) or (.sources|sort_by(.name))==([$i.sources[]|{name,kind,path:(if .relative_path=="." then $root else $root+"/"+.relative_path end)}]|sort_by(.name))' <<< "$prior" >/dev/null || fail '已有数据项目与邀请冲突，未启动或修改服务'
  fi
  mkdir -p -- "$data"
  while IFS=$'\t' read -r name kind relative; do source_args+=(--source "$name:$kind:$relative"); done < <(jq -r '.sources[]|[.name,.kind,.relative_path]|@tsv' "$file")
  local -a install_args=(install --role backup --deployment "$deployment" --data-dir "$data" --output "$output" --ssh-port "$(jq -r .backup.port "$file")" --ssh-bind-host "$(jq -r .backup.bind_host "$file")" --yes)
  bash "$ROOT/start.sh" "${install_args[@]}" "${source_args[@]}" || fail '备机安装未完成；配置和身份保留，可重跑邀请'
  cpa_manager_snapshot
  [[ -n $record && -z $manager_reason && $manager_service == 运行中 ]] || fail "备机服务未就绪（服务：${manager_service:-未知}；原因：${manager_reason:-未提供}）"
  prior=$(cpa_installed_cli config get)
  jq -e --arg node "$(jq -r .primary.node_id "$file")" '.node_role=="backup" and (.peer.node_id=="" or .peer.node_id==$node)' <<< "$prior" >/dev/null || fail '已有主备关系与邀请冲突'
  cpa_join_known_host "$(jq -r .primary.host "$file")" "$(jq -r .primary.port "$file")" "$(jq -r .primary.host_key "$file")" check || fail '主机指纹与已有记录冲突或不可核验，未继续修改配对'
  public_key=$(cpa_join_public_key) || fail '已有SSH身份不可核验，未继续修改配对'
  marker=$(cpa_join_marker) || fail '已有安装邀请记录读取失败，未继续修改配对'
  jq -e --arg id "$id" '.invite_id==null or .invite_id==$id' <<< "$marker" >/dev/null || fail '已有安装邀请与本次邀请冲突'
  if [[ $(jq -r '.status//empty' <<< "$marker") != completed ]]; then
    desired=$(jq --slurpfile invite "$file" --arg data "$(jq -r .allowed_root <<< "$prior")" '
      $invite[0] as $i | .node_role="backup"|.enabled=false|
      .interval_seconds=$i.policy.interval_seconds|.secondary_interval_seconds=$i.policy.secondary_interval_seconds|
      .retention_count=$i.policy.retention_count|.max_snapshot_bytes=$i.policy.max_snapshot_bytes|
      .sources=[$i.sources[]|{name,kind,path:(if .relative_path=="." then $data else $data+"/"+.relative_path end)}]|
      .peer.host=$i.primary.host|.peer.port=$i.primary.port|.peer.user="root"|.peer.node_id=$i.primary.node_id' <<< "$prior")
    printf '%s\n' "$desired" | cpa_installed_json config set >/dev/null
    jq -r .primary.public_key "$file" | cpa_installed_json trust-key >/dev/null
    cpa_join_known_host "$(jq -r .primary.host "$file")" "$(jq -r .primary.port "$file")" "$(jq -r .primary.host_key "$file")" || fail '主机指纹与已有记录冲突或不可核验，未继续修改配对'
    local context epoch configured
    configured=$(cpa_installed_cli config get)
    context=$(jq -Sc '{node_id,allowed_root,sources,interval_seconds,secondary_interval_seconds,retention_count,max_snapshot_bytes,transport:(.peer|{identity_file,known_hosts_file,user})}' <<< "$configured" | sha256sum | cut -d ' ' -f1)
    epoch=$(cpa_installed_cli status | jq -r .epoch)
    jq --arg context "$context" --argjson epoch "$epoch" '{invite_id,primary_node_id:.primary.node_id,primary_public_key:.primary.public_key,auto_enable,status:"registered",backup_context:$context,backup_epoch:$epoch}' "$file" | cpa_join_store enrollment/join.json
  fi
  node=$(jq -r .node_id <<< "$prior")
  host_key=$(cpa_join_read ssh/ssh_host_ed25519_key.pub)
  # Try the permanent key first: registration may have succeeded before the
  # previous process/response disappeared, or the invitation already completed.
  if ! response=$(cpa_join_ssh permanent "enroll-complete $id" "$file" 2>/dev/null); then
    [[ $(jq -r '.status//empty' <<< "$marker") != completed ]] || fail '已完成配对的主机连接异常；未修改原调度'
    desired=$(jq -n --arg node_id "$node" --arg public_key "$public_key" --arg host_key "$host_key" --arg host "$(jq -r .backup.host "$file")" --argjson port "$(jq -r .backup.port "$file")" '{node_id:$node_id,public_key:$public_key,host_key:$host_key,host:$host,port:$port}')
    printf '%s\n' "$desired" | cpa_join_ssh temporary "enroll $id register" "$file" >/dev/null || fail '主机认领失败；本机身份和配置保留'
    response=$(cpa_join_ssh permanent "enroll-complete $id" "$file") || fail '双向连接或首备失败；调度未启用，可重跑同一命令'
  fi
  cpa_join_acknowledge_completion "$file" "$response"
  printf '\n备机安装和双向配对完成；首备快照：%s\n自动备份：%s\n' "$(jq -r .snapshot_id <<< "$response")" "$(jq -r '.enabled' <<< "$response")"
  [[ -z $temporary ]] || rm -f "$temporary"
}
