#!/usr/bin/env bash
# shellcheck disable=SC2015
# Trusted program library. JSON configuration is data; it is never sourced.

cpa_fail() { printf '%s\n' "$*" >&2; return 1; }
cpa_id_valid() { [[ ${1-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$ ]]; }
cpa_now() { date -u +'%Y-%m-%dT%H:%M:%S.%NZ'; }
cpa_uuid() { cat /proc/sys/kernel/random/uuid; }

# Validate lexical paths before resolving them, including missing targets.
cpa_path_validate() {
    local path=${1-} cursor
    [[ $path == /* && $path != *\\* && ! $path =~ [[:cntrl:]] ]] || { cpa_fail '路径须为不含控制字符或反斜线的绝对路径。'; return 1; }
    [[ $(realpath -ms -- "$path") == "$path" || $path == / ]] || { cpa_fail '路径须规范化，不含 .、.. 或重复斜线。'; return 1; }
    cursor=$path
    while [[ $cursor != / ]]; do
        [[ ! -L $cursor ]] || { cpa_fail '路径或祖先为符号链接。'; return 1; }
        cursor=$(dirname -- "$cursor") || return 1
    done
}

cpa_paths_intersect() {
    local first=${1%/} second=${2%/}
    [[ $first == "$second" || $first == "$second"/* || $second == "$first"/* || -z $first || -z $second ]]
}

# Durable atomic replacement. Every caller checks the returned failure status.
cpa_atomic() {
    local destination=$1 parent temporary
    cpa_path_validate "$destination" || return 1
    parent=$(dirname -- "$destination") || return 1
    [[ -d $parent ]] || { cpa_fail '原子写入的父目录不存在。'; return 1; }
    temporary=$(mktemp "$parent/.atomic.XXXXXXXX") || return 1
    # FILE operands without -f fsync only these inodes. -f means syncfs and
    # would flush the entire backing filesystem for every frequent state write.
    if ! chmod 600 "$temporary" || ! cat > "$temporary" || ! sync -- "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -fT -- "$temporary" "$destination"; then rm -f -- "$temporary"; return 1; fi
    sync -- "$parent" || return 1
}

cpa_config_get() { cat -- "$CPA_STATE_DIR/config.json"; }
cpa_config_public() { jq 'del(.admin_token,.peer.token,.peer.password)' "$CPA_STATE_DIR/config.json"; }

cpa_init() {
    local root state uuid token
    state=${CPA_STATE_DIR:?CPA_STATE_DIR required}
    root=${CPA_ALLOWED_ROOT:-/data}
    cpa_path_validate "$state" && cpa_path_validate "$root" || return 1
    cpa_paths_intersect "$state" "$root" && { cpa_fail '状态目录与数据根须独立。'; return 1; }
    umask 077
    mkdir -p -- "$state" "$state/snapshots" "$state/tmp" || return 1
    chmod 700 -- "$state" "$state/snapshots" "$state/tmp" || return 1
    if [[ ! -e $state/admin.token ]]; then
        token=${CPA_ADMIN_TOKEN:-}
        if [[ -z $token ]]; then token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n') || return 1; fi
        [[ $token =~ ^[A-Za-z0-9_-]{32,256}$ ]] || { cpa_fail '管理员令牌须为至少32位安全随机字符。'; return 1; }
        printf '%s\n' "$token" | cpa_atomic "$state/admin.token" || return 1
    fi
    [[ ! -L $state/admin.token && -f $state/admin.token ]] || return 1
    chmod 600 -- "$state/admin.token" || return 1
    token=$(cat -- "$state/admin.token") || return 1
    [[ $token =~ ^[A-Za-z0-9_-]{32,256}$ ]] || { cpa_fail '已有管理员令牌格式或强度无效，保留原文件并停止初始化。'; return 1; }
    if [[ ! -e $state/config.json ]]; then
        uuid=$(cpa_uuid) || return 1
        jq -n --arg node "$uuid" --arg root "$root" --arg state "$state" '{node_id:$node,node_role:"primary",enabled:false,interval_seconds:60,secondary_interval_seconds:3600,retention_count:120,max_snapshot_bytes:1073741824,allowed_root:$root,sources:[],peer:{host:"",port:22,user:"root",identity_file:($state+"/ssh/id_ed25519"),known_hosts_file:($state+"/ssh/known_hosts"),node_id:""},service:{driver:"none",name:"",timeout_seconds:60}}' | cpa_atomic "$state/config.json" || return 1
    fi
    cpa_path_validate "$state/config.json" && cpa_config_validate "$state/config.json" || return 1
}

cpa_config_validate() {
    local file=$1 root node state path name kind other host user key known driver service
    jq -e '
      type=="object" and (.node_id|type=="string") and (.node_role=="primary" or .node_role=="backup") and
      (.enabled|type=="boolean") and (.allowed_root|type=="string") and (.sources|type=="array" and length<=128) and
      ([.sources[].name]|length == (unique|length)) and
      ([.interval_seconds,.secondary_interval_seconds]|all(type=="number" and floor==. and .>=1 and .<=604800)) and
      (.retention_count|type=="number" and floor==. and .>=1 and .<=100000) and
      (.max_snapshot_bytes|type=="number" and floor==. and .>=1 and .<=1099511627776) and
      (.peer|type=="object") and (.peer.port|type=="number" and floor==. and .>=1 and .<=65535) and
      ([.peer.host,.peer.user,.peer.identity_file,.peer.known_hosts_file,.peer.node_id]|all(type=="string")) and
      (.service.driver=="none" or .service.driver=="docker" or .service.driver=="systemd") and
      (.service.name|type=="string") and (.service.timeout_seconds|type=="number" and floor==. and .>=1 and .<=600) and
      all(.sources[]; (.name|type=="string") and (.path|type=="string") and (.kind=="auto" or .kind=="file" or .kind=="directory" or .kind=="sqlite"))
    ' "$file" >/dev/null || { cpa_fail '配置格式或数值无效。'; return 1; }
    root=$(jq -r .allowed_root "$file") && node=$(jq -r .node_id "$file") || return 1
    cpa_id_valid "$node" && cpa_path_validate "$root" || return 1
    state=${CPA_STATE_DIR:?}
    cpa_paths_intersect "$root" "$state" && { cpa_fail '数据根不可包含备份状态目录。'; return 1; }
    host=$(jq -r .peer.host "$file") && user=$(jq -r .peer.user "$file") || return 1
    [[ -z $host || $host =~ ^[A-Za-z0-9:][A-Za-z0-9_.:-]{0,252}$ ]] || { cpa_fail 'SSH主机名格式无效。'; return 1; }
    [[ $user =~ ^[A-Za-z_][A-Za-z0-9_-]{0,63}$ ]] || { cpa_fail 'SSH用户名格式无效。'; return 1; }
    node=$(jq -r .peer.node_id "$file") || return 1
    [[ -z $node ]] || cpa_id_valid "$node" || return 1
    key=$(jq -r .peer.identity_file "$file") && known=$(jq -r .peer.known_hosts_file "$file") || return 1
    [[ -z $key ]] || cpa_path_validate "$key" || return 1
    [[ -z $known ]] || cpa_path_validate "$known" || return 1
    driver=$(jq -r .service.driver "$file") && service=$(jq -r .service.name "$file") || return 1
    [[ $driver == none || $service =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,127}$ ]] || { cpa_fail 'CPA管理目标名称无效。'; return 1; }
    local -a paths=()
    while IFS= read -r row; do
        name=$(jq -r .name <<< "$row") && path=$(jq -r .path <<< "$row") && kind=$(jq -r .kind <<< "$row") || return 1
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || { cpa_fail '数据标签格式无效。'; return 1; }
        cpa_path_validate "$path" || return 1
        [[ $root == / || $path == "$root" || $path == "$root"/* ]] || { cpa_fail '来源超出允许数据根。'; return 1; }
        cpa_paths_intersect "$path" "$state" && { cpa_fail '来源不得包含状态目录。'; return 1; }
        for other in "${paths[@]}"; do cpa_paths_intersect "$path" "$other" && { cpa_fail '来源目录/文件相互重叠。'; return 1; }; done
        paths+=("$path")
        [[ ! -e $path || $kind == auto || ( $kind == directory && -d $path ) || ( $kind != directory && -f $path ) ]] || { cpa_fail '来源实际类型不匹配。'; return 1; }
    done < <(jq -c '.sources[]' "$file")
}

cpa_config_set() {
    local supplied=$1 merged old_root old_node new_root new_node
    [[ -f $supplied ]] && jq -e 'type=="object"' "$supplied" >/dev/null || { cpa_fail '配置须为JSON对象。'; return 1; }
    old_root=$(jq -r .allowed_root "$CPA_STATE_DIR/config.json") && old_node=$(jq -r .node_id "$CPA_STATE_DIR/config.json") || return 1
    merged=$(mktemp "$CPA_STATE_DIR/tmp/config.XXXXXXXX") || return 1
    if ! jq --slurpfile incoming "$supplied" '. as $old | .+$incoming[0] | .peer=($old.peer+($incoming[0].peer//{})) | .service=($old.service+($incoming[0].service//{}))' "$CPA_STATE_DIR/config.json" > "$merged"; then rm -f -- "$merged"; return 1; fi
    new_root=$(jq -r .allowed_root "$merged") && new_node=$(jq -r .node_id "$merged") || { rm -f -- "$merged"; return 1; }
    if [[ $new_root != "$old_root" || $new_node != "$old_node" ]] || ! cpa_config_validate "$merged"; then rm -f -- "$merged"; cpa_fail '节点ID及允许数据根不可修改，或配置无效。'; return 1; fi
    if ! cpa_atomic "$CPA_STATE_DIR/config.json" < "$merged"; then rm -f -- "$merged"; return 1; fi
    rm -f -- "$merged"
    cpa_config_get
}
