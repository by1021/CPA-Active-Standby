#!/usr/bin/env bash
# One-time SSH installation invitations. Records are durable JSON, never code.
# shellcheck disable=SC2016
cpa_enrollment_dir() {
    cpa_id_valid "${1:-}" || { cpa_fail '邀请ID无效'; return 1; }
    printf '%s/enrollment/invites/%s\n' "$CPA_STATE_DIR" "$1"
}
cpa_enrollment_key() {
    local value=$1 file algorithm key _extra
    [[ $value != *$'\n'* && $value != *$'\r'* && ${#value} -le 512 ]] || { cpa_fail '公钥格式无效'; return 1; }
    read -r algorithm key _extra <<< "$value"
    [[ $algorithm == ssh-ed25519 && $key =~ ^[A-Za-z0-9+/=]+$ ]] || { cpa_fail '配对只接受Ed25519公钥'; return 1; }
    file=$(mktemp "$CPA_STATE_DIR/.enroll-key.XXXXXX") || return
    printf '%s %s\n' "$algorithm" "$key" > "$file"
    if ! ssh-keygen -l -f "$file" >/dev/null 2>&1; then rm -f -- "$file"; cpa_fail '配对公钥无效'; return 1; fi
    rm -f -- "$file"
    printf '%s %s\n' "$algorithm" "$key"
}
cpa_enrollment_host() {
    [[ ${1:-} =~ ^[A-Za-z0-9:][A-Za-z0-9_.:-]{0,252}$ ]] || { cpa_fail '配对地址无效'; return 1; }
}
cpa_enrollment_primary() {
    jq -e '.node_role=="primary" and .enabled==false and .peer.user=="root" and (.sources|length)>0' "$CPA_STATE_DIR/config.json" >/dev/null &&
      jq -e '.phase=="primary_active" and .job.running==false' "$CPA_STATE_DIR/runtime.json" >/dev/null || { cpa_fail '请先配置正常主机和备份内容，并停用定时任务'; return 1; }
}
cpa_enrollment_context() {
    jq -Sc '{node_id,allowed_root,sources,interval_seconds,secondary_interval_seconds,retention_count,max_snapshot_bytes,transport:(.peer|{identity_file,known_hosts_file,user})}' "$CPA_STATE_DIR/config.json" | sha256sum | cut -d ' ' -f1
}
cpa_enrollment_known_hosts_file() {
    local file identity
    file=$(jq -r '.peer.known_hosts_file' "$CPA_STATE_DIR/config.json")
    identity=$(jq -r '.peer.identity_file' "$CPA_STATE_DIR/config.json")
    cpa_path_validate "$file" || return
    [[ $file != "$identity" && -f $file && -r $file && -w $file && -w $(dirname -- "$file") ]] || { cpa_fail '配置的 known_hosts 须为可读写的独立普通文件'; return 1; }
    printf '%s\n' "$file"
}
cpa_enrollment_transport_public_key() {
    local identity public sidecar
    cpa_enrollment_known_hosts_file >/dev/null || return
    identity=$(jq -r '.peer.identity_file' "$CPA_STATE_DIR/config.json")
    cpa_path_validate "$identity" || return
    [[ -f $identity && -r $identity ]] || { cpa_fail '配置的永久 SSH 私钥须为可读的普通文件'; return 1; }
    public=$(ssh-keygen -y -P '' -f "$identity" </dev/null 2>/dev/null) || { cpa_fail '配置的永久 SSH 私钥无效、权限不安全或需要口令'; return 1; }
    public=$(cpa_enrollment_key "$public") || { cpa_fail '配置的永久 SSH 私钥须使用Ed25519'; return 1; }
    # OpenSSH may offer the .pub sidecar before loading the private identity.
    # Reject stale sidecars rather than rewriting a user's key configuration.
    if [[ -e $identity.pub || -L $identity.pub ]]; then
        cpa_path_validate "$identity.pub" || return
        [[ -f $identity.pub && -r $identity.pub && $(stat -c %s "$identity.pub") -le 512 ]] || { cpa_fail '永久 SSH 公钥文件无效'; return 1; }
        sidecar=$(cpa_enrollment_key "$(cat "$identity.pub")") || { cpa_fail '永久 SSH 公钥文件无效'; return 1; }
        [[ $sidecar == "$public" ]] || { cpa_fail '永久 SSH 公钥文件与配置的私钥不匹配'; return 1; }
    fi
    printf '%s\n' "$public"
}
cpa_enrollment_create() {
    local options=$1 id dir ttl expires hostkey public_key body bundle source row relative kind command encoded count
    cpa_enrollment_primary || return
    [[ -f $CPA_ROOT/scripts/packaging/generate-command.sh && ! -L $CPA_ROOT/scripts/packaging/generate-command.sh ]] || { cpa_fail '安装命令生成器缺失，请先更新主机备份服务'; return 1; }
    jq -e 'type=="object" and ([.primary_host,.backup_host,.data_dir,.deployment]|all(type=="string")) and
      ([.primary_port,.backup_port,.ttl_seconds]|all(.==null or type=="number")) and
      ([.output,.backup_bind_host]|all(.==null or type=="string")) and
      (.auto_enable==null or (.auto_enable|type)=="boolean") and
      (.deployment=="docker" or .deployment=="native") and
      ([.primary_port//2222,.backup_port//2222]|all(type=="number" and floor==. and .>=1 and .<=65535)) and
      (.ttl_seconds//1800|type=="number" and floor==. and .>=60 and .<=86400) and
      (.auto_enable//true|type=="boolean") and (.output//""|type=="string") and (.backup_bind_host//.backup_host|type=="string")' "$options" >/dev/null || { cpa_fail '邀请参数格式或范围无效'; return 1; }
    for value in primary_host backup_host; do cpa_enrollment_host "$(jq -r --arg key "$value" '.[$key]' "$options")" || return; done
    cpa_enrollment_host "$(jq -r '.backup_bind_host//.backup_host' "$options")" || return
    local data output
    data=$(jq -r .data_dir "$options")
    output=$(jq -r '.output//""' "$options")
    if [[ -z $output && $(jq -r .deployment "$options") == native ]]; then output=/etc/cpa-dr-native; fi
    cpa_path_validate "$data" || return
    [[ $data != / && $data != *[\'\"\\\$:]* ]] || { cpa_fail '备机数据目录无效'; return 1; }
    if [[ -n $output ]]; then
        cpa_path_validate "$output" || return
        [[ $output != / && $output != *[\'\"\\\$:]* ]] || { cpa_fail '备机安装目录无效'; return 1; }
        cpa_paths_intersect "$data" "$output" && { cpa_fail '备机数据和安装目录须独立'; return 1; }
    fi
    [[ $(jq -r '.primary_host+":"+((.primary_port//2222)|tostring)' "$options") != "$(jq -r '.backup_host+":"+((.backup_port//2222)|tostring)' "$options")" ]] || { cpa_fail '主备端点不可相同'; return 1; }
    hostkey=$(cpa_enrollment_key "$(cat "$CPA_STATE_DIR/ssh/ssh_host_ed25519_key.pub")") || { cpa_fail '主机SSH服务器密钥尚未生成'; return 1; }
    public_key=$(cpa_enrollment_transport_public_key) || return
    mkdir -p -- "$CPA_STATE_DIR/enrollment/invites" || return
    chmod 700 "$CPA_STATE_DIR/enrollment" "$CPA_STATE_DIR/enrollment/invites"
    count=$(find "$CPA_STATE_DIR/enrollment/invites" -mindepth 1 -maxdepth 1 -type d | wc -l)
    ((count < 1024)) || { cpa_fail '邀请记录达到上限，请先清理历史记录'; return 1; }
    id=$(cpa_uuid); dir=$(cpa_enrollment_dir "$id") || return
    cpa_path_validate "$dir" || return
    mkdir -- "$dir"; chmod 700 "$dir"
    ssh-keygen -q -t ed25519 -N '' -C cpa-dr-install-invitation -f "$dir/invitation-key" </dev/null || return
    bundle=$(bash "$CPA_ROOT/scripts/packaging/build-install-bundle.sh" "$CPA_ROOT" "$dir/install-bundle.tar") || return
    ttl=$(jq -r '.ttl_seconds//1800' "$options"); expires=$(( $(date +%s)+ttl ))
    source=$(mktemp "$CPA_STATE_DIR/.enroll-sources.XXXXXX") || return
    local root
    root=$(jq -r .allowed_root "$CPA_STATE_DIR/config.json")
    while IFS= read -r row; do
        relative=$(jq -r .path <<< "$row"); kind=$(jq -r .kind <<< "$row")
        if [[ $kind == auto ]]; then [[ -d $relative ]] && kind=directory || kind='file'; fi
        [[ $relative == "$root" ]] && relative=. || relative=${relative#"${root%/}/"}
        jq -cn --arg name "$(jq -r .name <<< "$row")" --arg kind "$kind" --arg path "$relative" '{name:$name,kind:$kind,relative_path:$path}'
    done < <(jq -c '.sources[]' "$CPA_STATE_DIR/config.json") > "$source"
    body=$(jq -n --slurpfile options "$options" --slurpfile sources "$source" --slurpfile config "$CPA_STATE_DIR/config.json" \
      --arg id "$id" --arg at "$(date -u -d "@$expires" +'%Y-%m-%dT%H:%M:%SZ')" --arg hostkey "$hostkey" --arg key "$public_key" --arg output "$output" --arg private "$(cat "$dir/invitation-key")" --argjson bundle "$bundle" '
      $options[0] as $o|$config[0] as $c|{version:1,invite_id:$id,expires_at:$at,
       primary:{node_id:$c.node_id,host:$o.primary_host,port:($o.primary_port//2222),user:"root",public_key:$key,host_key:$hostkey},
       backup:{host:$o.backup_host,port:($o.backup_port//2222),bind_host:($o.backup_bind_host//$o.backup_host),data_dir:$o.data_dir,deployment:$o.deployment,output:$output},
       sources:$sources,policy:($c|{interval_seconds,secondary_interval_seconds,retention_count,max_snapshot_bytes}),
       auto_enable:(if $o.auto_enable==null then true else $o.auto_enable end),bundle:$bundle,temporary_private_key:$private}') || { rm -f -- "$source"; return 1; }
    rm -f -- "$source"
    if (( $(printf '%s' "$body" | wc -c) > 65536 )); then
        rm -rf -- "$dir"
        cpa_fail '安装邀请超过64KiB，请减少备份项目或缩短路径'
        return 1
    fi
    printf '%s\n' "$body" | cpa_atomic "$dir/invite.json" || return
    jq -n --arg id "$id" --arg at "$(cpa_now)" --argjson expires "$expires" --arg key "$(cpa_enrollment_key "$(cat "$dir/invitation-key.pub")")" --arg context "$(cpa_enrollment_context)" --argjson epoch "$(jq -r .epoch "$CPA_STATE_DIR/runtime.json")" --argjson invite "$body" \
      '{invite_id:$id,status:"issued",created_at:$at,expires_at:$invite.expires_at,expires_unix:$expires,invitation_public_key:$key,primary_context:$context,primary_epoch:$epoch,invite:($invite|del(.temporary_private_key)),claim:null,first_snapshot:null}' | cpa_atomic "$dir/record.json" || return
    command=$(bash "$CPA_ROOT/scripts/packaging/generate-command.sh" "$dir/invite.json") || { rm -rf -- "$dir"; return 1; }
    if [[ -z $command ]] || (( $(printf '%s' "$command" | wc -c) > 131000 )); then
        rm -rf -- "$dir"
        cpa_fail '安装命令为空或超过执行参数限制，请减少备份项目'
        return 1
    fi
    # All keys still enter the global dispatcher; this per-key restriction also
    # keeps invitations constrained on explicitly reviewed fallback configs.
    { cat "$CPA_STATE_DIR/ssh/authorized_keys"; printf 'restrict,command="%s/bin/cpa-dr-enroll-rpc --state-dir %s --invite-id %s" %s\n' "$CPA_ROOT" "$CPA_STATE_DIR" "$id" "$(cpa_enrollment_key "$(cat "$dir/invitation-key.pub")")"; } | cpa_atomic "$CPA_STATE_DIR/ssh/authorized_keys" || return
    encoded=$(printf '%s' "$body" | base64 -w0)
    jq -n --arg id "$id" --arg at "$(jq -r .expires_at <<< "$body")" --arg command "$command" --arg encoded "$encoded" --argjson invite "$body" '{invite_id:$id,expires_at:$at,command:$command,invite:$invite,invite_base64:$encoded}'
}
cpa_enrollment_list() {
    local file
    for file in "$CPA_STATE_DIR"/enrollment/invites/*/record.json; do
        [[ -f $file && ! -L $file ]] || continue
        jq --argjson now "$(date +%s)" '{invite_id,status:(if (.status=="issued" or .status=="registered") and .expires_unix<=$now then "expired" else .status end),created_at,expires_at,backup_host:.invite.backup.host,backup_port:.invite.backup.port,deployment:.invite.backup.deployment,node_id:.claim.node_id,snapshot_id:.first_snapshot}' "$file"
    done | jq -s '{invites:.}'
}
cpa_enrollment_record() {
    local dir
    dir=$(cpa_enrollment_dir "$1") || return
    cpa_path_validate "$dir/record.json" || return
    [[ -f $dir/record.json ]] || { cpa_fail '邀请不存在'; return 1; }
    cat "$dir/record.json"
}
cpa_enrollment_active() {
    local record=$1
    jq -e --argjson now "$(date +%s)" '(.status=="issued" or .status=="registered") and .expires_unix>$now' <<< "$record" >/dev/null || { cpa_fail '邀请已过期、撤销或完成'; return 1; }
    [[ $(jq -r .invite.primary.node_id <<< "$record") == "$(jq -r .node_id "$CPA_STATE_DIR/config.json")" && $(cpa_enrollment_context) == "$(jq -r .primary_context <<< "$record")" ]] || { cpa_fail '主机身份或备份配置已变化，请重新生成邀请'; return 1; }
    jq -e --argjson epoch "$(jq -r .primary_epoch <<< "$record")" '.phase=="primary_active" and .epoch==$epoch' "$CPA_STATE_DIR/runtime.json" >/dev/null && jq -e '.enabled==false' "$CPA_STATE_DIR/config.json" >/dev/null || { cpa_fail '主机角色、代次或调度状态已变化'; return 1; }
}
cpa_enrollment_remove_key() {
    local key=$1 file
    file=$(mktemp "$CPA_STATE_DIR/.enroll-authorized.XXXXXX") || return
    awk -v key="$key" 'index($0," " key)==0' "$CPA_STATE_DIR/ssh/authorized_keys" > "$file"
    cat "$file" | cpa_atomic "$CPA_STATE_DIR/ssh/authorized_keys"
    rm -f -- "$file"
}
cpa_enrollment_revoke() {
    local dir record guard
    dir=$(cpa_enrollment_dir "$1") || return; record=$(cpa_enrollment_record "$1") || return
    exec {guard}>"$dir/completion.lock"
    flock -n "$guard" || { cpa_fail '邀请正在完成配对，请等待当前任务'; return 75; }
    [[ $(jq -r .status <<< "$record") != completed && $(jq -r .status <<< "$record") != committing ]] || { cpa_fail '配对已经进入最终确认，撤销邀请不解除永久配对'; return 1; }
    jq '.status="revoked"' <<< "$record" | cpa_atomic "$dir/record.json" || return
    cpa_enrollment_remove_key "$(jq -r .invitation_public_key <<< "$record")" || return
    rm -f -- "$dir/invitation-key" "$dir/invite.json"
    jq -cn --arg id "$1" '{invite_id:$id,revoked:true}'
}
cpa_enrollment_known_host_pending() {
    local host=$1 port=$2 key=$3 line file matches endpoint names algorithm stored rest expected_algorithm expected found=0 rc
    endpoint="[$host]:$port"; [[ $port != 22 ]] || endpoint=$host
    endpoint=${endpoint,,}
    read -r expected_algorithm expected rest <<< "$key"
    line="$endpoint $expected_algorithm $expected"
    file=$(cpa_enrollment_known_hosts_file) || return
    if matches=$(ssh-keygen -F "$endpoint" -f "$file" 2>&1); then
        while read -r names algorithm stored rest; do
            [[ -n $names && $names != \#* ]] || continue
            [[ $names != @* && $algorithm == "$expected_algorithm" && $stored == "$expected" ]] || { cpa_fail '对端服务器指纹与已有记录冲突'; return 1; }
            found=1
        done <<< "$matches"
        [[ $found == 1 ]] || { cpa_fail '对端服务器指纹记录不可核验'; return 1; }
    else
        rc=$?
        [[ $rc == 1 && -z $matches ]] || { cpa_fail '对端服务器指纹记录不可核验'; return 1; }
        printf '%s\n' "$line"
    fi
}
cpa_enrollment_known_host() {
    local line file
    file=$(cpa_enrollment_known_hosts_file) || return
    line=$(cpa_enrollment_known_host_pending "$@") || return
    if [[ -n $line ]]; then { cat "$file"; printf '%s\n' "$line"; } | cpa_atomic "$file" || return; fi
}
cpa_enrollment_claim_available() {
    local node=$1 key=$2 hostkey=$3 file
    # Claims survive incomplete trust/config writes and invitation revocation.
    # Endpoint maintenance remains bound to each invite, not historical claims.
    for file in "$CPA_STATE_DIR"/enrollment/invites/*/record.json; do
        [[ -f $file && ! -L $file ]] || continue
        jq -e --arg node "$node" --arg key "$key" --arg hostkey "$hostkey" \
          '.claim==null or (.claim.node_id==$node and .claim.public_key==$key and .claim.host_key==$hostkey)' "$file" >/dev/null || { cpa_fail '主机已经由另一永久备机身份认领'; return 1; }
    done
}
cpa_enrollment_register() {
    local id=$1 request=$2 dir record key hostkey node claimed config temp
    dir=$(cpa_enrollment_dir "$id") || return; record=$(cpa_enrollment_record "$id") || return
    cpa_enrollment_active "$record" || return
    [[ ${CPA_ENROLL_AUTH_KEY:-} == "$(jq -r .invitation_public_key <<< "$record")" ]] || { cpa_fail '邀请认证身份不符'; return 1; }
    jq -e 'type=="object" and ([.node_id,.public_key,.host_key,.host]|all(type=="string")) and (.port|type=="number" and floor==. and .>=1 and .<=65535)' "$request" >/dev/null || { cpa_fail '备机注册数据无效'; return 1; }
    node=$(jq -r .node_id "$request"); cpa_id_valid "$node" || return
    key=$(cpa_enrollment_key "$(jq -r .public_key "$request")") || return
    hostkey=$(cpa_enrollment_key "$(jq -r .host_key "$request")") || return
    [[ $node != "$(jq -r .node_id "$CPA_STATE_DIR/config.json")" && $key != "$(jq -r .invite.primary.public_key <<< "$record")" && $hostkey != "$(jq -r .invite.primary.host_key <<< "$record")" && $key != "$(jq -r .invitation_public_key <<< "$record")" ]] || { cpa_fail '主备必须拥有独立身份'; return 1; }
    [[ $(jq -r .host "$request") == "$(jq -r .invite.backup.host <<< "$record")" && $(jq -r .port "$request") == "$(jq -r .invite.backup.port <<< "$record")" ]] || { cpa_fail '备机地址不符合邀请'; return 1; }
    claimed=$(jq -r '.claim.node_id//empty' <<< "$record")
    if [[ -n $claimed ]]; then
        [[ $claimed == "$node" && $(jq -r .claim.public_key <<< "$record") == "$key" && $(jq -r .claim.host_key <<< "$record") == "$hostkey" ]] || { cpa_fail '邀请已由另一备机身份认领'; return 1; }
    fi
    config=$(cat "$CPA_STATE_DIR/config.json")
    [[ $(jq -r '.peer.node_id//empty' <<< "$config") == '' || $(jq -r .peer.node_id <<< "$config") == "$node" ]] || { cpa_fail '主机已经与另一节点配对'; return 1; }
    cpa_enrollment_claim_available "$node" "$key" "$hostkey" || return
    cpa_enrollment_known_host_pending "$(jq -r .host "$request")" "$(jq -r .port "$request")" "$hostkey" >/dev/null || return
    # Publish the claim before touching trust/config; a retry repairs interrupted
    # writes using exactly the same public identity, never a different claimant.
    jq --arg node "$node" --arg key "$key" --arg hostkey "$hostkey" '.status="registered"|.claim={node_id:$node,public_key:$key,host_key:$hostkey}' <<< "$record" | cpa_atomic "$dir/record.json" || return
    temp=$(mktemp "$CPA_STATE_DIR/.enroll-register.XXXXXX") || return
    cpa_enrollment_known_host "$(jq -r .host "$request")" "$(jq -r .port "$request")" "$hostkey" || { rm -f -- "$temp"; return 1; }
    jq --arg node "$node" --arg host "$(jq -r .host "$request")" --argjson port "$(jq -r .port "$request")" '.enabled=false|.peer.node_id=$node|.peer.host=$host|.peer.port=$port|.peer.user="root"' <<< "$config" > "$temp"
    cpa_save_config "$temp" >/dev/null || { rm -f -- "$temp"; return 1; }
    # Only grant ordinary RPC after the durable identity, pinned host and config
    # are all bound. Same-identity registration can repair a failed final write.
    printf '%s\n' "$key" > "$temp"
    cpa_trust_key "$temp" >/dev/null || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
    jq -cn --arg id "$id" --argjson primary "$(jq .invite.primary <<< "$record")" '{registered:true,invite_id:$id,primary:$primary}'
}
cpa_enrollment_join_auth() {
    local id=$1 file="$CPA_STATE_DIR/enrollment/join.json" key
    cpa_path_validate "$file" || return
    [[ -f $file ]] || { cpa_fail '备机加入记录不存在'; return 1; }
    key=$(cpa_enrollment_key "$(jq -r .primary_public_key "$file")") || return
    [[ $(jq -r .invite_id "$file") == "$id" && ${CPA_ENROLL_AUTH_KEY:-} == "$key" ]] || { cpa_fail '加入记录或主机认证不符'; return 1; }
    jq -e --slurpfile joined "$file" '.node_role=="backup" and .peer.node_id==$joined[0].primary_node_id' "$CPA_STATE_DIR/config.json" >/dev/null && jq -e '.phase=="backup_standby"' "$CPA_STATE_DIR/runtime.json" >/dev/null || { cpa_fail '备机配对或角色状态不符'; return 1; }
    if jq -e '.backup_context!=null and .backup_epoch!=null' "$file" >/dev/null; then
        [[ $(jq -r .backup_context "$file") == "$(cpa_enrollment_context)" && $(jq -r .backup_epoch "$file") == "$(jq -r .epoch "$CPA_STATE_DIR/runtime.json")" ]] || { cpa_fail '备机数据配置或角色代次已变化'; return 1; }
    fi
}
cpa_enrollment_probe() {
    cpa_enrollment_join_auth "$1" || return
    # No primary operation lock is held by the caller. Peer status is read-only.
    (
      cpa_lock || return; cpa_enrollment_join_auth "$1" || return
      if ! jq -e '.backup_context!=null and .backup_epoch!=null' "$CPA_STATE_DIR/enrollment/join.json" >/dev/null; then
          jq --arg context "$(cpa_enrollment_context)" --argjson epoch "$(jq -r .epoch "$CPA_STATE_DIR/runtime.json")" '.backup_context=$context|.backup_epoch=$epoch' "$CPA_STATE_DIR/enrollment/join.json" | cpa_atomic "$CPA_STATE_DIR/enrollment/join.json" || return
      fi
      cpa_check_peer >/dev/null
    ) || return
    jq -n --slurpfile config "$CPA_STATE_DIR/config.json" --slurpfile runtime "$CPA_STATE_DIR/runtime.json" --slurpfile joined "$CPA_STATE_DIR/enrollment/join.json" '{node_id:$config[0].node_id,node_role:$config[0].node_role,phase:$runtime[0].phase,latest_received:$runtime[0].latest_received,reverse_verified:true,join_status:$joined[0].status,join_snapshot_id:$joined[0].snapshot_id}'
}
cpa_enrollment_activate() {
    local id=$1 snapshot=$2 file="$CPA_STATE_DIR/enrollment/join.json" temp enable
    cpa_id_valid "$snapshot" || return
    cpa_enrollment_join_auth "$id" || return
    if [[ $(jq -r '.status//empty' "$file") == completed ]]; then
        [[ $(jq -r '.snapshot_id//empty' "$file") == "$snapshot" ]] || { cpa_fail '首次启用恢复点不符'; return 1; }
        if [[ $(jq -r '.activation_compensated//false' "$file") != true ]]; then
            jq -cn --arg id "$id" --arg snapshot "$snapshot" --argjson enable "$(jq -r .enabled "$CPA_STATE_DIR/config.json")" '{activated:true,invite_id:$id,snapshot_id:$snapshot,enabled:$enable}'
            return
        fi
    else
        [[ $(jq -r '.latest_received.id//empty' "$CPA_STATE_DIR/runtime.json") == "$snapshot" ]] || { cpa_fail '备机最新恢复点与首次备份不符'; return 1; }
        cpa_snapshot_verify "$snapshot" >/dev/null || return
    fi
    enable=$(jq -r '.auto_enable//false' "$file")
    temp=$(mktemp "$CPA_STATE_DIR/.enroll-activate.XXXXXX") || return
    cpa_state_update '.last_secondary_attempt_unix=$now' --argjson now "$(date +%s)" || { rm -f -- "$temp"; return 1; }
    jq --argjson enable "$enable" '.enabled=$enable' "$CPA_STATE_DIR/config.json" > "$temp"
    cpa_save_config "$temp" >/dev/null || { rm -f -- "$temp"; return 1; }; rm -f -- "$temp"
    jq --arg snapshot "$snapshot" '.status="completed"|.snapshot_id=$snapshot|.activation_compensated=false' "$file" | cpa_atomic "$file" || return
    jq -cn --arg id "$id" --arg snapshot "$snapshot" --argjson enable "$enable" '{activated:true,invite_id:$id,snapshot_id:$snapshot,enabled:$enable}'
}
cpa_enrollment_deactivate() {
    local id=$1 snapshot=$2 file="$CPA_STATE_DIR/enrollment/join.json" temp
    cpa_id_valid "$snapshot" && cpa_enrollment_join_auth "$id" || return
    [[ $(jq -r '.snapshot_id//empty' "$file") == "$snapshot" ]] || { cpa_fail '补偿请求恢复点不符'; return 1; }
    temp=$(mktemp "$CPA_STATE_DIR/.enroll-deactivate.XXXXXX") || return
    jq '.enabled=false' "$CPA_STATE_DIR/config.json" > "$temp"
    cpa_save_config "$temp" >/dev/null || { rm -f -- "$temp"; return 1; }; rm -f -- "$temp"
    jq '.activation_compensated=true' "$file" | cpa_atomic "$file" || return
    printf '{"deactivated":true}\n'
}
cpa_enrollment_remote() {
    local command=$1; shift
    local host port identity known
    if [[ -n ${CPA_ENROLL_REMOTE_RECORD:-} ]]; then
        host=$(jq -r .invite.backup.host <<< "$CPA_ENROLL_REMOTE_RECORD"); port=$(jq -r .invite.backup.port <<< "$CPA_ENROLL_REMOTE_RECORD")
    else
        host=$(jq -r .peer.host "$CPA_STATE_DIR/config.json"); port=$(jq -r .peer.port "$CPA_STATE_DIR/config.json")
    fi
    identity=$(jq -r .peer.identity_file "$CPA_STATE_DIR/config.json"); known=$(jq -r .peer.known_hosts_file "$CPA_STATE_DIR/config.json")
    [[ $command =~ ^enroll-(probe|activate|deactivate)$ ]] || return 1
    local arg
    for arg in "$@"; do cpa_id_valid "$arg" || return; command+=" $arg"; done
    timeout 300 ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o "UserKnownHostsFile=$known" -i "$identity" -p "$port" "root@$host" "$command"
}
cpa_enrollment_finish_context() {
    local record=$1
    [[ $(jq -r .status <<< "$record") == committing ]] || { cpa_enrollment_active "$record"; return; }
    # A commit decision made before expiration is recoverable with the permanent
    # claimant identity. This never reopens an expired temporary credential.
    [[ $(cpa_enrollment_context) == "$(jq -r .primary_context <<< "$record")" && $(jq -r .invite.primary.node_id <<< "$record") == "$(jq -r .node_id "$CPA_STATE_DIR/config.json")" ]] || { cpa_fail '最终确认的主机身份或数据配置已变化'; return 1; }
    jq -e --argjson epoch "$(jq -r .primary_epoch <<< "$record")" '.phase=="primary_active" and .epoch==$epoch' "$CPA_STATE_DIR/runtime.json" >/dev/null || { cpa_fail '主机不处于原正常服务代次，保持保护状态'; return 1; }
}
cpa_enrollment_bound_peer() {
    local record=$1
    jq -e --arg node "$(jq -r .claim.node_id <<< "$record")" --arg host "$(jq -r .invite.backup.host <<< "$record")" --argjson port "$(jq -r .invite.backup.port <<< "$record")" '.node_role=="primary" and .peer.node_id==$node and .peer.host==$host and .peer.port==$port and .peer.user=="root"' "$CPA_STATE_DIR/config.json" >/dev/null || { cpa_fail '当前主备端点与邀请绑定不符'; return 1; }
}
cpa_enrollment_compensate_primary() {
    local id=$1 record temp
    cpa_lock || return
    record=$(cpa_enrollment_record "$id") || return
    [[ $(jq -r .status <<< "$record") == committing ]] || return 0
    cpa_enrollment_finish_context "$record" && cpa_enrollment_bound_peer "$record" || return
    temp=$(mktemp "$CPA_STATE_DIR/.enroll-compensate.XXXXXX") || return
    jq '.enabled=false' "$CPA_STATE_DIR/config.json" > "$temp"
    cpa_save_config "$temp" >/dev/null || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
}
cpa_enrollment_complete() {
    local id=$1 dir record node snapshot manifest remote temp enabled guard
    dir=$(cpa_enrollment_dir "$id") || return
    cpa_path_validate "$dir/completion.lock" || return
    exec {guard}>"$dir/completion.lock"
    flock -n "$guard" || { cpa_fail '本次邀请正在完成配对'; return 75; }
    record=$(cpa_enrollment_record "$id") || return
    [[ $(jq -r '.claim.public_key//empty' <<< "$record") == "${CPA_ENROLL_AUTH_KEY:-}" && -n ${CPA_ENROLL_AUTH_KEY:-} ]] || { cpa_fail '完成配对须使用已登记的备机永久身份'; return 1; }
    if [[ $(jq -r .status <<< "$record") == completed ]]; then
        (cpa_lock || return; cpa_enrollment_remove_key "$(jq -r .invitation_public_key <<< "$record")" || return; rm -f -- "$dir/invitation-key" "$dir/invite.json") || return
        jq --argjson enabled "$(jq -n --slurpfile config "$CPA_STATE_DIR/config.json" --slurpfile runtime "$CPA_STATE_DIR/runtime.json" '$config[0].enabled and $runtime[0].phase=="primary_active"')" '{completed:true,invite_id,snapshot_id:.first_snapshot,enabled:$enabled}' <<< "$record"; return
    fi
    cpa_enrollment_finish_context "$record" || return
    cpa_enrollment_bound_peer "$record" || return
    local CPA_ENROLL_REMOTE_RECORD=$record
    node=$(jq -r .claim.node_id <<< "$record")
    [[ $(jq -r .peer.node_id "$CPA_STATE_DIR/config.json") == "$node" ]] || { cpa_fail '当前配对节点与邀请不符'; return 1; }
    (cpa_lock || return; cpa_check_peer >/dev/null) || return
    remote=$(cpa_enrollment_remote enroll-probe "$id") || return
    [[ $(jq -r .node_id <<< "$remote") == "$node" && $(jq -r .reverse_verified <<< "$remote") == true ]] || { cpa_fail '双向配对尚未通过'; return 1; }
    snapshot=$(jq -r '.first_snapshot//empty' <<< "$record")
    if [[ -z $snapshot ]]; then
        # Same lock discipline as ordinary backup; release it before probing or
        # activating the peer, so a reverse callback cannot deadlock this node.
        manifest=$(
          cpa_lock || return
          cpa_enrollment_active "$(cpa_enrollment_record "$id")" || return
          temp=$(mktemp "$CPA_STATE_DIR/.enroll-first-body.XXXXXX") || return
          printf '{}\n' > "$temp"
          if manifest=$(cpa_backup "$temp"); then rm -f -- "$temp"; printf '%s\n' "$manifest"; else rm -f -- "$temp"; return 1; fi
        ) || return
        snapshot=$(jq -er .id <<< "$manifest") || return
        (cpa_lock || return; record=$(cpa_enrollment_record "$id") || return; cpa_enrollment_active "$record" || return; jq --arg snapshot "$snapshot" '.first_snapshot=$snapshot' <<< "$record" | cpa_atomic "$dir/record.json") || return
    fi
    remote=$(cpa_enrollment_remote enroll-probe "$id") || return
    if [[ $(jq -r '.latest_received.id//empty' <<< "$remote") != "$snapshot" ]]; then
        [[ $(jq -r .status <<< "$record") == committing && $(jq -r '.join_status//empty' <<< "$remote") == completed && $(jq -r '.join_snapshot_id//empty' <<< "$remote") == "$snapshot" ]] || { cpa_fail '备机未确认同一首次恢复点'; return 1; }
    fi
    (
      cpa_lock || return
      record=$(cpa_enrollment_record "$id") || return
      cpa_enrollment_finish_context "$record" || return
      cpa_enrollment_bound_peer "$record" || return
      jq '.status="committing"' <<< "$record" | cpa_atomic "$dir/record.json"
    ) || return
    remote=$(cpa_enrollment_remote enroll-activate "$id" "$snapshot") || { cpa_enrollment_remote enroll-deactivate "$id" "$snapshot" >/dev/null 2>&1 || true; return 1; }
    [[ $(jq -r .activated <<< "$remote") == true && $(jq -r .snapshot_id <<< "$remote") == "$snapshot" ]] || { cpa_enrollment_remote enroll-deactivate "$id" "$snapshot" >/dev/null 2>&1 || true; cpa_fail '备机未确认启用状态'; return 1; }
    enabled=$(jq -r .invite.auto_enable <<< "$record")
    if (
      cpa_lock || return; record=$(cpa_enrollment_record "$id") || return; cpa_enrollment_finish_context "$record" || return; cpa_enrollment_bound_peer "$record" || return
      temp=$(mktemp "$CPA_STATE_DIR/.enroll-complete.XXXXXX") || return
      cpa_state_update '.last_attempt_unix=$now' --argjson now "$(date +%s)" || { rm -f -- "$temp"; return 1; }
      jq --argjson enabled "$enabled" '.enabled=$enabled' "$CPA_STATE_DIR/config.json" > "$temp"
      cpa_save_config "$temp" >/dev/null || { rm -f -- "$temp"; return 1; }; rm -f -- "$temp"
      jq --arg snapshot "$snapshot" '.status="completed"|.first_snapshot=$snapshot' <<< "$record" | cpa_atomic "$dir/record.json" || return
      cpa_enrollment_remove_key "$(jq -r .invitation_public_key <<< "$record")" || return
      rm -f -- "$dir/invitation-key" "$dir/invite.json"
    ); then :; else
        (cpa_enrollment_compensate_primary "$id") >/dev/null 2>&1 || true
        cpa_enrollment_remote enroll-deactivate "$id" "$snapshot" >/dev/null 2>&1 || true
        return 1
    fi
    jq -cn --arg id "$id" --arg snapshot "$snapshot" --argjson enabled "$enabled" '{completed:true,invite_id:$id,snapshot_id:$snapshot,enabled:$enabled}'
}
cpa_enrollment_rpc() {
    local id=$1 operation=$2 request=$3 snapshot=${4:-} record dir
    case $operation in
      complete) cpa_enrollment_complete "$id"; return;;
      probe) cpa_enrollment_probe "$id"; return;;
      activate) cpa_lock; cpa_enrollment_activate "$id" "$snapshot"; return;;
      deactivate) cpa_lock; cpa_enrollment_deactivate "$id" "$snapshot"; return;;
    esac
    cpa_lock
    dir=$(cpa_enrollment_dir "$id") || return; record=$(cpa_enrollment_record "$id") || return
    cpa_enrollment_active "$record" || return
    [[ ${CPA_ENROLL_AUTH_KEY:-} == "$(jq -r .invitation_public_key <<< "$record")" ]] || { cpa_fail '邀请认证身份不符'; return 1; }
    case $operation in
      bundle) [[ -f $dir/install-bundle.tar && ! -L $dir/install-bundle.tar ]] || return 1; cat "$dir/install-bundle.tar";;
      register) cpa_enrollment_register "$id" "$request";;
      status) jq '{invite_id,status,expires_at,node_id:.claim.node_id,snapshot_id:.first_snapshot}' <<< "$record";;
      *) cpa_fail '邀请操作无效'; return 1;;
    esac
}
cpa_enrollment_cli() {
    case ${1:-} in
      create) [[ $# == 2 ]] || return 1; cpa_lock; cpa_enrollment_create "$2";;
      list) [[ $# == 1 ]] || return 1; cpa_enrollment_list;;
      revoke) [[ $# == 2 ]] || return 1; cpa_lock; cpa_enrollment_revoke "$2";;
      _rpc) [[ $# == 5 ]] || return 1; shift; cpa_enrollment_rpc "$@";;
      *) cpa_fail 'enrollment create JSONFILE | list | revoke ID'; return 1;;
    esac
}
