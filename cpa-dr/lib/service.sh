#!/usr/bin/env bash
# Native command orchestration. Callers hold operation.lock for every mutation.
# shellcheck disable=SC2016
# jq programs are single-quoted intentionally; variables are supplied via --arg.
cpa_state_update() {
    local filter=$1; shift
    jq "$@" "$filter" "$CPA_STATE_DIR/runtime.json" | cpa_atomic "$CPA_STATE_DIR/runtime.json"
}
cpa_lock() {
    local seconds=${1:-5}
    # A waiting administrator owns this short gate. Future nonblocking timer
    # ticks must yield until the already-running operation drains.
    exec 8>"$CPA_STATE_DIR/control.lock"
    if ! flock -w "$seconds" 8; then
        exec 8>&-
        cpa_fail '另一个备份/恢复/配置任务正在运行' || true
        return 75
    fi
    exec 9>"$CPA_STATE_DIR/operation.lock"
    if ! flock -w "$seconds" 9; then
        exec 8>&- 9>&-
        # cpa_fail returns 1: handle it so errexit cannot preempt return 75.
        cpa_fail '另一个备份/恢复/配置任务正在运行' || true
        return 75
    fi
    # Only the data lock is inherited by async writers; the gate remains free
    # for the next administrator to reserve priority while waiting.
    exec 8>&-
    cpa_reconcile_interrupted
}
cpa_reconcile_interrupted() {
    # Acquiring the operation lock proves no live writer owns the cached job.
    [[ -f $CPA_STATE_DIR/runtime.json ]] || return 0
    jq -e '.job.running==true' "$CPA_STATE_DIR/runtime.json" >/dev/null || return 0
    local id action
    id=$(jq -r '.job.id' "$CPA_STATE_DIR/runtime.json")
    action=$(jq -r '.job.action' "$CPA_STATE_DIR/runtime.json")
    if [[ $action =~ ^(restore|promote|prepare-recovery|failback)$ ]]; then
        cpa_state_update '.phase="paused"|.interrupted_action=$action|del(.pause_from)' --arg action "$action" || return
    fi
    cpa_job_finish "$id" '上个写者已退出但任务未完成；写入/交接操作保持保护态' '{}'
}
cpa_service_init() {
    cpa_init >/dev/null || return
    mkdir -p -- "$CPA_STATE_DIR/jobs" "$CPA_STATE_DIR/ssh" || return
    chmod 700 "$CPA_STATE_DIR/jobs" "$CPA_STATE_DIR/ssh" || return
    if [[ ! -f $CPA_STATE_DIR/ssh/id_ed25519 ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$CPA_STATE_DIR/ssh/id_ed25519" </dev/null || return
    fi
    chmod 600 "$CPA_STATE_DIR/ssh/id_ed25519" || return
    [[ -f $CPA_STATE_DIR/ssh/known_hosts ]] || : > "$CPA_STATE_DIR/ssh/known_hosts"
    [[ -f $CPA_STATE_DIR/ssh/authorized_keys ]] || : > "$CPA_STATE_DIR/ssh/authorized_keys"
    chmod 600 "$CPA_STATE_DIR/ssh/known_hosts" "$CPA_STATE_DIR/ssh/authorized_keys" || return
    if [[ ! -f $CPA_STATE_DIR/runtime.json ]]; then
        jq -n '{phase:"unconfigured",epoch:0,configured:false,job:{running:false,id:null,action:null,error:null,finished_at:null},last_backup:null,last_replication:null,latest_received:null,peer:{reachable:false,last_error:null},last_attempt_unix:0,last_secondary_attempt_unix:0}' | cpa_atomic "$CPA_STATE_DIR/runtime.json" || return
    fi
    if [[ $(jq -r '.peer.identity_file' "$CPA_STATE_DIR/config.json") == '' ]]; then
        local temp
        temp=$(mktemp "$CPA_STATE_DIR/.config.XXXXXX") || return
        jq --arg key "$CPA_STATE_DIR/ssh/id_ed25519" --arg hosts "$CPA_STATE_DIR/ssh/known_hosts" '.peer.identity_file=$key|.peer.known_hosts_file=$hosts' "$CPA_STATE_DIR/config.json" > "$temp" || { rm -f -- "$temp"; return 1; }
        cpa_config_set "$temp" >/dev/null || { rm -f -- "$temp"; return 1; }
        rm -f -- "$temp"
    fi
}
cpa_pairing() {
    jq -n --arg id "$(jq -r .node_id "$CPA_STATE_DIR/config.json")" --arg key "$(cat "$CPA_STATE_DIR/ssh/id_ed25519.pub")" '{node_id:$id,public_key:$key}'
}
cpa_trust_key() {
    local file=$1 algorithm key _extra temp line
    [[ $CPA_ROOT =~ ^/[A-Za-z0-9._/-]+$ && $CPA_STATE_DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || { cpa_fail 'SSH forced-command 安装路径仅允许字母数字及 /._-'; return 1; }
    [[ -f $file ]] || { cpa_fail '公钥文件不存在'; return 1; }
    read -r algorithm key _extra < "$file" || true
    [[ $algorithm == ssh-ed25519 && $key =~ ^[A-Za-z0-9+/=]+$ && ${#key} -le 256 ]] || { cpa_fail '仅接受有效的 Ed25519 SSH 公钥'; return 1; }
    temp=$(mktemp "$CPA_STATE_DIR/.key.XXXXXX") || return
    printf '%s %s\n' "$algorithm" "$key" > "$temp"
    ssh-keygen -l -f "$temp" >/dev/null 2>&1 || { rm -f -- "$temp"; cpa_fail 'SSH 公钥验证失败'; return 1; }
    line="restrict,command=\"$CPA_ROOT/bin/cpa-dr-rpc --state-dir $CPA_STATE_DIR\" $algorithm $key"
    if ! grep -Fq -- " $algorithm $key" "$CPA_STATE_DIR/ssh/authorized_keys"; then
        { cat "$CPA_STATE_DIR/ssh/authorized_keys"; printf '%s\n' "$line"; } | cpa_atomic "$CPA_STATE_DIR/ssh/authorized_keys" || { rm -f -- "$temp"; return 1; }
    fi
    rm -f -- "$temp"
    printf '{"trusted":true}\n'
}
cpa_status() {
    jq -n --slurpfile config "$CPA_STATE_DIR/config.json" --slurpfile state "$CPA_STATE_DIR/runtime.json" '$state[0]+{node_id:$config[0].node_id,node_role:$config[0].node_role,enabled:$config[0].enabled,peer:($state[0].peer+{configured:($config[0].peer.host!="" and $config[0].peer.node_id!="")})}'
}
cpa_peer_status() {
    cpa_status | jq '{node_id,node_role,phase,epoch,latest_received,handover:(.handover//null)}'
}
# shellcheck source=transport.sh
source "$CPA_ROOT/lib/transport.sh"
cpa_check_peer() {
    local remote id role other
    remote=$(cpa_ssh status) || { cpa_state_update '.peer.reachable=false|.peer.last_error="SSH连接失败：检查公钥、端口、known_hosts与对端服务"' || true; cpa_fail 'SSH 连接失败；核对对端公钥、端口与主机指纹'; return 1; }
    jq -e 'type=="object" and (.epoch|type=="number")' <<< "$remote" >/dev/null || { cpa_fail '对端返回无效状态'; return 1; }
    id=$(jq -r .node_id <<< "$remote")
    cpa_id_valid "$id" || { cpa_fail '对端节点 ID 非法'; return 1; }
    [[ $id != "$(jq -r .node_id "$CPA_STATE_DIR/config.json")" ]] || { cpa_fail '不允许配对本机'; return 1; }
    role=$(jq -r .node_role "$CPA_STATE_DIR/config.json")
    other=$(jq -r .node_role <<< "$remote")
    [[ $role != "$other" && $other =~ ^(primary|backup)$ ]] || { cpa_fail '主备两端必须选择不同角色'; return 1; }
    local expected temp
    expected=$(jq -r .peer.node_id "$CPA_STATE_DIR/config.json")
    [[ -z $expected || $expected == "$id" ]] || { cpa_fail '对端身份与已配对节点不符'; return 1; }
    if [[ -z $expected ]]; then
        temp=$(mktemp "$CPA_STATE_DIR/.config.XXXXXX") || return
        jq --arg id "$id" '.peer.node_id=$id' "$CPA_STATE_DIR/config.json" > "$temp" || { rm -f -- "$temp"; return 1; }
        cpa_config_set "$temp" >/dev/null || { rm -f -- "$temp"; return 1; }
        rm -f -- "$temp"
    fi
    cpa_state_update '.peer.reachable=true|.peer.last_error=null' || return
    printf '%s\n' "$remote"
}
cpa_save_config() {
    local file=$1 old_role new_role phase configured
    cpa_config_validate "$file" || return
    old_role=$(jq -r .node_role "$CPA_STATE_DIR/config.json")
    new_role=$(jq -r .node_role "$file")
    phase=$(jq -r .phase "$CPA_STATE_DIR/runtime.json")
    configured=$(jq -r .configured "$CPA_STATE_DIR/runtime.json")
    if [[ $old_role != "$new_role" && $configured == true ]]; then
        [[ $(jq -r .enabled "$CPA_STATE_DIR/config.json") == false && $(jq -r .enabled "$file") == false && $phase =~ ^(primary_active|backup_standby)$ ]] || { cpa_fail '角色变更前须停用定时任务，且节点处于普通主/备状态'; return 1; }
        [[ $(cpa_snapshot_list | jq length) == 0 ]] || { cpa_fail '已有恢复点后禁止直接更换主备身份，请使用受控接管流程'; return 1; }
    fi
    if jq -e .enabled "$file" >/dev/null; then
        jq -e '.peer.host!="" and .peer.node_id!="" and (.node_role=="backup" or (.sources|length)>0)' "$file" >/dev/null || { cpa_fail '启用前须完成数据内容及 SSH 配对'; return 1; }
    fi
    cpa_config_set "$file" >/dev/null || return
    if [[ $configured != true || $old_role != "$new_role" ]]; then
        [[ $new_role == primary ]] && phase=primary_active || phase=backup_standby
        cpa_state_update '.phase=$phase|.configured=true' --arg phase "$phase" || return
    fi
    cpa_config_public | jq '{config:.}'
}
cpa_service_control() {
    local verb=$1 driver name seconds
    driver=$(jq -r .service.driver "$CPA_STATE_DIR/config.json")
    name=$(jq -r .service.name "$CPA_STATE_DIR/config.json")
    seconds=$(jq -r .service.timeout_seconds "$CPA_STATE_DIR/config.json")
    case "$driver" in
        none) return 0 ;;
        docker) [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { cpa_fail 'CPA 容器名非法'; return 1; }; timeout "$seconds" docker "$verb" "$name" >/dev/null ;;
        systemd) [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]] || { cpa_fail 'CPA 单元名非法'; return 1; }; timeout "$seconds" systemctl "$verb" "$name" ;;
        *) cpa_fail 'CPA 管理驱动未知'; return 1 ;;
    esac
}
cpa_job_begin() {
    local action=$1 id=$2 context=null
    if [[ $action == restore ]]; then context=$(cpa_restore_context) || return; fi
    jq -n --arg id "$id" --arg action "$action" --arg at "$(cpa_now)" '{id:$id,action:$action,running:true,started_at:$at,finished_at:null,error:null,result:null}' | cpa_atomic "$CPA_STATE_DIR/jobs/$id.json" || return
    # Context and running job become durable together, before an async writer
    # can stop CPA or touch data. A crash cannot leave a context-free restore.
    cpa_state_update '.job=$job|if $action=="restore" then .restore_context=$context|.phase="paused"|del(.pause_from,.failed_action,.interrupted_action) else . end' --argjson job "$(cat "$CPA_STATE_DIR/jobs/$id.json")" --arg action "$action" --argjson context "$context"
}
cpa_job_finish() {
    local id=$1 error=$2 result=$3
    cpa_id_valid "$id" || return 1
    local file="$CPA_STATE_DIR/jobs/$id.json"
    [[ -f $file ]] || return 1
    jq --arg error "$error" --arg at "$(cpa_now)" --argjson result "$result" '.running=false|.finished_at=$at|.error=(if $error=="" then null else $error end)|.result=$result' "$file" | cpa_atomic "$file" || return
    # Completion and restored scheduling must be published together. Until
    # then even successful data IO remains an interrupted, retryable restore.
    cpa_state_update '
        if .job.id==$job.id then .job=$job|
            if $job.action=="restore" and $job.error==null then
                .restore_context as $context|
                if $context==null then error("恢复上下文缺失") else
                    .phase=$context.phase|
                    if $context.phase=="paused" then .pause_from=$context.pause_from else del(.pause_from) end|
                    del(.restore_context,.failed_action,.interrupted_action)
                end
            else . end
        else . end' --argjson job "$(cat "$file")" || return
    local old
    while IFS= read -r old; do
        [[ -n $old ]] || continue
        cpa_id_valid "$old" || continue
        rm -f -- "$CPA_STATE_DIR/jobs/$old.json" "$CPA_STATE_DIR/jobs/$old.request.json" "$CPA_STATE_DIR/jobs/$old.log"
    done < <(find "$CPA_STATE_DIR/jobs" -maxdepth 1 -type f -name '*.json' ! -name '*.request.json' -exec cat {} + | jq -sr 'sort_by(.started_at)|reverse|.[20:][]|.id')
}
cpa_job_get() {
    cpa_id_valid "$1" && [[ -f $CPA_STATE_DIR/jobs/$1.json ]] || { cpa_fail '作业不存在'; return 1; }
    # The completed file is flushed before runtime.job. Publish completion only
    # once the matching runtime transition is visible as well.
    jq -n --slurpfile job "$CPA_STATE_DIR/jobs/$1.json" --slurpfile state "$CPA_STATE_DIR/runtime.json" '
        if $job[0].id==$state[0].job.id and $state[0].job.running then
            $job[0]|.running=true|.finished_at=null|.error=null
        else $job[0] end'
}
cpa_backup() {
    local body=$1 purpose=${2:-manual} phase epoch manifest id archive result
    phase=$(jq -r .phase "$CPA_STATE_DIR/runtime.json")
    epoch=$(jq -r .epoch "$CPA_STATE_DIR/runtime.json")
    if [[ $phase == backup_standby ]]; then
        id=$(jq -r '.latest_received.id//empty' "$CPA_STATE_DIR/runtime.json")
        [[ -n $id ]] || { cpa_fail '备机尚无有效主机副本'; return 1; }
        manifest=$(cpa_snapshot_clone "$id" secondary) || return
    else
        [[ $phase =~ ^(primary_active|backup_active)$ ]] || { cpa_fail '节点处于保护/交接状态，禁止发布工作数据'; return 1; }
        manifest=$(cpa_snapshot_create "$purpose" "$epoch") || return
    fi
    cpa_state_update '.last_backup=$manifest' --argjson manifest "$manifest" || return
    if [[ $phase == primary_active && $(jq -r 'if has("replicate") then .replicate else true end' "$body") != false ]]; then
        id=$(jq -r .id <<< "$manifest")
        archive=$(mktemp "$CPA_STATE_DIR/.outgoing.XXXXXX") || return
        cpa_snapshot_export "$id" "$archive" >/dev/null || { rm -f -- "$archive"; return 1; }
        if ! result=$(cpa_ssh receive "$(jq -r .node_id "$CPA_STATE_DIR/config.json")" "$epoch" < "$archive"); then
            rm -f -- "$archive"
            cpa_state_update '.peer.reachable=false|.peer.last_error="主机快照已保留，但SSH传输失败"' || true
            cpa_snapshot_prune || true
            cpa_fail '主机快照已保留，备机接收失败；检查 SSH 及对端角色'; return 1
        fi
        rm -f -- "$archive"
        [[ $(jq -r .id <<< "$result") == "$id" ]] || { cpa_fail '对端未确认同一份恢复点'; return 1; }
        cpa_state_update '.last_replication=$manifest|.peer.reachable=true|.peer.last_error=null' --argjson manifest "$manifest" || return
    fi
    cpa_snapshot_prune || return
    printf '%s\n' "$manifest"
}
cpa_require_body() {
    local body=$1 confirm=$2; shift 2
    jq -e --arg confirmation "$confirm" '.confirm==$confirmation' "$body" >/dev/null || { cpa_fail "请输入确认文字 $confirm"; return 1; }
    local flag
    for flag in "$@"; do
        jq -e --arg flag "$flag" '.[$flag]==true' "$body" >/dev/null || { cpa_fail "需要勾选停机/隔离确认：$flag"; return 1; }
    done
}
cpa_restore_context() {
    # Only ordinary states or this independent restore's own failed/interrupted
    # context are eligible. Never infer authority from a legacy failure alone.
    jq -en --slurpfile state "$CPA_STATE_DIR/runtime.json" --slurpfile config "$CPA_STATE_DIR/config.json" '
        $state[0] as $s|$config[0].node_role as $role|
        def ordinary($phase):
            ($role=="primary" and $phase=="primary_active") or
            ($role=="backup" and ($phase=="backup_active" or $phase=="backup_standby"));
        def valid($context):
            $context.node_role==$role and $context.epoch==$s.epoch and
            (ordinary($context.phase) or ($context.phase=="paused" and ordinary($context.pause_from)));
        (if ordinary($s.phase) or ($s.phase=="paused" and ordinary($s.pause_from)) then
            {node_role:$role,phase:$s.phase,epoch:$s.epoch,pause_from:$s.pause_from}
        elif $s.phase=="paused" and $s.pause_from==null and
            ($s.failed_action=="restore" or $s.interrupted_action=="restore") and
            ($s.failed_action==null or $s.failed_action=="restore") and
            ($s.interrupted_action==null or $s.interrupted_action=="restore") and valid($s.restore_context) then
            $s.restore_context
        else empty end)|
        select($s.failback==null)|
        select($s.handover==null or ($s.handover.committed==true and
            (if .phase=="paused" then .pause_from else .phase end)=="backup_standby"))'
}
cpa_restore() {
    local body=$1
    jq -e '.restore_context!=null' "$CPA_STATE_DIR/runtime.json" >/dev/null || return
    # Historical restore is data-only: job completion restores scheduling,
    # never starts CPA, and retains an ordinary pause only after success.
    cpa_service_control stop || return
    cpa_snapshot_restore "$(jq -r .snapshot_id "$body")"
}
cpa_validate_action() {
    local action=$1 body=$2 phase role
    jq -e 'type=="object"' "$body" >/dev/null || { cpa_fail '请求必须是 JSON 对象'; return 1; }
    phase=$(jq -r .phase "$CPA_STATE_DIR/runtime.json")
    role=$(jq -r .node_role "$CPA_STATE_DIR/config.json")
    case "$action" in
        backup) [[ $phase =~ ^(primary_active|backup_active|backup_standby)$ ]] || { cpa_fail '保护态不能备份工作数据'; return 1; } ;;
        verify|restore-plan) cpa_id_valid "$(jq -r '.snapshot_id//empty' "$body")" || { cpa_fail '恢复点 ID 非法'; return 1; } ;;
        restore)
            cpa_require_body "$body" RESTORE quiesced || return
            cpa_restore_context >/dev/null || { cpa_fail '交接/恢复保护状态禁止独立覆盖历史数据，请继续对应恢复流程'; return 1; }
            cpa_id_valid "$(jq -r '.snapshot_id//empty' "$body")" || return 1 ;;
        promote) cpa_require_body "$body" PROMOTE fenced quiesced || return; [[ $role == backup && $phase == backup_standby ]] || { cpa_fail '只有待机备节点可确认接管'; return 1; }; cpa_id_valid "$(jq -r '.snapshot_id//empty' "$body")" || return 1 ;;
        prepare-recovery) cpa_require_body "$body" RECOVER quiesced || return; [[ $role == primary && $phase =~ ^(primary_active|paused|primary_recovering)$ ]] || { cpa_fail '只有原主节点可进入待恢复'; return 1; } ;;
        failback) cpa_require_body "$body" FAILBACK quiesced backup_quiesced || return; [[ $role == primary && $phase =~ ^(primary_recovering|failback_failed)$ ]] || { cpa_fail '主节点需先准备恢复'; return 1; } ;;
        pause) cpa_require_body "$body" PAUSE || return; [[ $phase =~ ^(primary_active|backup_active|backup_standby)$ ]] || { cpa_fail '交接/失败保护态不能被普通暂停覆盖'; return 1; } ;;
        resume)
            cpa_require_body "$body" RESUME authoritative || return
            # Share the role/handover guard with restore, but never borrow a
            # failed restore's retry context in place of an ordinary pause.
            [[ $phase == paused && $(jq -r '.pause_from//empty' "$CPA_STATE_DIR/runtime.json") =~ ^(primary_active|backup_active|backup_standby)$ ]] && cpa_restore_context >/dev/null || { cpa_fail '无可恢复的普通暂停，交接失败需继续恢复流程'; return 1; } ;;
        test-peer) return 0 ;;
        *) cpa_fail '操作不存在'; return 1 ;;
    esac
}
cpa_promote() {
    local body=$1 manifest epoch
    manifest=$(cpa_snapshot_verify "$(jq -r .snapshot_id "$body")") || return
    [[ $(jq -r .node_role <<< "$manifest") == primary && $(jq -r .node_id <<< "$manifest") == "$(jq -r .peer.node_id "$CPA_STATE_DIR/config.json")" ]] || { cpa_fail '接管只能使用已配对主节点副本'; return 1; }
    [[ $(jq -r .epoch <<< "$manifest") -ge $(jq -r .epoch "$CPA_STATE_DIR/runtime.json") ]] || { cpa_fail '副本来自过时代次'; return 1; }
    epoch=$(( $(jq -r .epoch <<< "$manifest") + 1 ))
    cpa_state_update '.phase="promoting"' || return
    cpa_service_control stop || return
    local result
    result=$(cpa_snapshot_restore "$(jq -r .id <<< "$manifest")") || return
    cpa_service_control start || return
    cpa_state_update '.phase="backup_active"|.epoch=$epoch|del(.pause_from,.handover,.failback)' --argjson epoch "$epoch" || return
    printf '%s\n' "$result"
}
cpa_prepare_recovery() {
    local remote epoch
    remote=$(cpa_check_peer) || return
    if [[ $(jq -r .phase <<< "$remote") != backup_active ]]; then
        [[ $(jq -r .phase <<< "$remote") == paused && $(jq -r '.handover.node_id//empty' <<< "$remote") == "$(jq -r .node_id "$CPA_STATE_DIR/config.json")" && $(jq -r '.handover.id//empty' <<< "$remote") != '' ]] || { cpa_fail '备节点尚未接管或并非可继续的交接状态'; return 1; }
    fi
    epoch=$(jq -r .epoch <<< "$remote")
    cpa_state_update '.phase="primary_recovering"|.epoch=$epoch' --argjson epoch "$epoch" || return
    cpa_service_control stop || return
    printf '{"phase":"primary_recovering"}\n'
}
cpa_failback() {
    local body=$1 remote node epoch handover sid hid archive manifest result baseline limit
    node=$(jq -r .node_id "$CPA_STATE_DIR/config.json")
    epoch=$(jq -r .epoch "$CPA_STATE_DIR/runtime.json")
    remote=$(cpa_check_peer) || return
    [[ $(jq -r .epoch <<< "$remote") == "$epoch" ]] || { cpa_fail '交接代次不一致'; return 1; }
    hid=$(jq -r '.failback.handover_id//empty' "$CPA_STATE_DIR/runtime.json")
    if [[ $(jq -r .phase <<< "$remote") == backup_standby && -n $hid && $(jq -r '.handover.id//empty' <<< "$remote") == "$hid" && $(jq -r '.handover.committed//false' <<< "$remote") == true && $(jq -r '.handover.node_id//empty' <<< "$remote") == "$node" && $(jq -r '.handover.epoch//-1' <<< "$remote") == "$epoch" ]] && jq -e --arg node "$node" --argjson epoch "$epoch" '.latest_received.node_role=="primary" and .latest_received.node_id==$node and .latest_received.epoch==$epoch' <<< "$remote" >/dev/null; then
        # A committed nonce proves the role handoff, not current CPA liveness.
        # Start is idempotent; success can still refresh credentials, so send a
        # fresh ordinary receive before publishing primary_active. The peer's
        # latest ID may already be a previous fresh attempt whose ACK was lost.
        if [[ $(jq -r .service.driver "$CPA_STATE_DIR/config.json") != none ]]; then
            cpa_state_update '.failback.primary_start_attempted=true|.failback.primary_started=false' || return
            cpa_service_control start || return
            cpa_state_update '.failback.primary_started=true' || return
        fi
        baseline=$(cpa_snapshot_create handover "$epoch") || return
        archive=$(mktemp "$CPA_STATE_DIR/.reconciled.XXXXXX") || return
        cpa_snapshot_export "$(jq -r .id <<< "$baseline")" "$archive" >/dev/null || { rm -f -- "$archive"; return 1; }
        if ! manifest=$(cpa_ssh receive "$node" "$epoch" < "$archive"); then rm -f -- "$archive"; return 1; fi
        rm -f -- "$archive"
        [[ $(jq -r .id <<< "$manifest") == "$(jq -r .id <<< "$baseline")" ]] || { cpa_fail '备机未确认重试启动后的主基线'; return 1; }
        cpa_state_update '.phase="primary_active"|.last_replication=$baseline|del(.failback,.pause_from)' --argjson baseline "$baseline" || return
        cpa_snapshot_prune || printf '交接已完成，历史清理失败，请核对存储权限\n' >&2
        printf '{"phase":"primary_active","reconciled":true}\n'; return 0
    fi
    handover=$(cpa_ssh handover "$node" "$epoch" true) || return
    sid=$(jq -r .snapshot_id <<< "$handover")
    hid=$(jq -r .handover_id <<< "$handover")
    cpa_id_valid "$sid" && cpa_id_valid "$hid" || { cpa_fail '对端交接数据非法'; return 1; }
    local existing
    existing=$(jq -r '.failback.handover_id//empty' "$CPA_STATE_DIR/runtime.json")
    [[ -z $existing || $existing == "$hid" ]] || { cpa_fail '对端交接已更换，需要核对权威数据'; return 1; }
    cpa_state_update '.phase="primary_recovering"|.failback=(.failback//{})|.failback.handover_id=$hid|.failback.snapshot_id=$sid' --arg hid "$hid" --arg sid "$sid" || return
    # Legacy primary_started was written before start and is therefore only an
    # attempted-start marker. Either marker forbids restoring older final data
    # over credentials the attempted start may already have refreshed.
    if ! jq -e '.failback.primary_start_attempted==true or .failback.primary_started==true' "$CPA_STATE_DIR/runtime.json" >/dev/null; then
        cpa_service_control stop || return
        archive=$(mktemp "$CPA_STATE_DIR/.backfill.XXXXXX") || return
        limit=$(( $(jq -r .max_snapshot_bytes "$CPA_STATE_DIR/config.json") + 134217728 ))
        if ! cpa_ssh archive "$sid" | head -c "$((limit+1))" > "$archive"; then rm -f -- "$archive"; return 1; fi
        if (( $(stat -c %s "$archive") > limit )); then rm -f -- "$archive"; cpa_fail '最终回灌归档超过接收容量'; return 1; fi
        manifest=$(cpa_snapshot_import "$archive" "$(jq -r .peer.node_id "$CPA_STATE_DIR/config.json")" "$epoch" backup) || { rm -f -- "$archive"; return 1; }
        rm -f -- "$archive"
        [[ $(jq -r .node_role <<< "$manifest") == backup ]] || { cpa_fail '最终副本并非备节点来源'; return 1; }
        result=$(cpa_snapshot_restore "$sid") || return
        cpa_state_update '.failback.restored=true' || return
    else
        result='{"reused_restored_data":true}'
    fi
    if [[ $(jq -r .service.driver "$CPA_STATE_DIR/config.json") != none ]]; then
        # Retry a failed/legacy attempted start on the preserved working data;
        # even an earlier success is stale after prepare-recovery stops CPA.
        # Success is recorded only after this attempt's driver returns success.
        cpa_service_control stop || return
        cpa_state_update '.failback.primary_start_attempted=true|.failback.primary_started=false' || return
        cpa_service_control start || return
        cpa_state_update '.failback.primary_started=true' || return
    fi
    baseline=$(cpa_snapshot_create handover "$epoch") || return
    archive=$(mktemp "$CPA_STATE_DIR/.baseline.XXXXXX") || return
    cpa_snapshot_export "$(jq -r .id <<< "$baseline")" "$archive" >/dev/null || { rm -f -- "$archive"; return 1; }
    if ! manifest=$(cpa_ssh baseline "$node" "$epoch" "$hid" < "$archive"); then rm -f -- "$archive"; return 1; fi
    rm -f -- "$archive"
    [[ $(jq -r .id <<< "$manifest") == "$(jq -r .id <<< "$baseline")" ]] || { cpa_fail '备机未确认刷新后的主基线'; return 1; }
    cpa_state_update '.failback.baseline_id=$id' --arg id "$(jq -r .id <<< "$baseline")" || return
    cpa_ssh commit "$hid" >/dev/null || return
    cpa_state_update '.phase="primary_active"|.last_replication=$baseline|del(.failback,.pause_from)' --argjson baseline "$baseline" || return
    # Role commit is authoritative already; housekeeping cannot demote it to
    # a context-free failback_failed state after the peer has committed.
    cpa_snapshot_prune || printf '交接已完成，历史清理失败，请核对存储权限\n' >&2
    printf '%s\n' "$result"
}
cpa_run_action() {
    local action=$1 body=$2
    case "$action" in
        backup) cpa_backup "$body" ;;
        verify) cpa_snapshot_verify "$(jq -r .snapshot_id "$body")" ;;
        restore-plan) cpa_snapshot_plan "$(jq -r .snapshot_id "$body")" ;;
        # Historical restore is data-only. Starting CPA requires the explicit
        # authoritative promote/failback workflow or an administrator's check.
        restore) cpa_restore "$body" ;;
        promote) cpa_promote "$body" ;;
        prepare-recovery) cpa_prepare_recovery ;;
        failback) cpa_failback "$body" ;;
        pause) cpa_state_update '.pause_from=.phase|.phase="paused"' || return; printf '{"phase":"paused"}\n' ;;
        resume)
            local remote old
            old=$(jq -r .pause_from "$CPA_STATE_DIR/runtime.json")
            remote=$(cpa_check_peer) || return
            if [[ $old =~ ^(primary_active|backup_active)$ && $(jq -r .phase <<< "$remote") =~ ^(primary_active|backup_active)$ ]]; then cpa_fail '对端也是权威节点，禁止恢复调度'; return 1; fi
            cpa_state_update '.phase=.pause_from|del(.pause_from)' || return
            printf '{"resumed":true}\n' ;;
        test-peer) cpa_check_peer ;;
    esac
}
cpa_worker_abort() {
    local action=$1 id=$2
    if [[ $action =~ ^(restore|promote|prepare-recovery|failback)$ ]]; then
        cpa_state_update '.phase="paused"|.interrupted_action=$action|del(.pause_from)' --arg action "$action" >/dev/null 2>&1 || true
    fi
    cpa_job_finish "$id" '任务被终止；写入/交接操作保持保护态' '{}' >/dev/null 2>&1 || true
    exit 1
}
cpa_worker() {
    local action=$1 body=$2 id=$3 result error
    local log="$CPA_STATE_DIR/jobs/$id.log"
    trap 'cpa_worker_abort "$action" "$id"' TERM INT HUP
    if result=$(cpa_run_action "$action" "$body" 2> "$log"); then
        jq -e . <<< "$result" >/dev/null 2>&1 || result='{}'
        cpa_job_finish "$id" '' "$result" || return
    else
        error=$(tail -c 2000 "$log")
        [[ -n $error ]] || error='原生命令任务失败，请核对权限、数据与SSH连接'
        if [[ $action =~ ^(restore|promote|prepare-recovery|failback)$ ]]; then
            if [[ $action == failback ]]; then
                cpa_state_update '.phase="failback_failed"|.failed_action=$action|del(.pause_from)' --arg action "$action" || return
            else
                cpa_state_update '.phase="paused"|.failed_action=$action|del(.pause_from)' --arg action "$action" || return
            fi
        fi
        cpa_job_finish "$id" "$error" '{}' || return
    fi
}
cpa_action() {
    local action=$1 body=$2 id request
    cpa_validate_action "$action" "$body" || return
    case "$action" in verify|restore-plan|test-peer) cpa_run_action "$action" "$body"; return ;; esac
    id=$(cpa_uuid)
    request="$CPA_STATE_DIR/jobs/$id.request.json"
    cpa_atomic "$request" < "$body" || return
    cpa_job_begin "$action" "$id" || return
    # FD 9's flock is inherited; the CGI response may exit, the writer remains serialized.
    CPA_LOCK_HELD=1 nohup bash "$CPA_ROOT/bin/cpa-dr" --state-dir "$CPA_STATE_DIR" _run-job "$action" "$request" "$id" </dev/null > /dev/null 2> "$CPA_STATE_DIR/jobs/$id.log" &
    printf '{"job_id":"%s"}\n' "$id"
}
cpa_tick() {
    local phase enabled now previous interval action body id result
    enabled=$(jq -r .enabled "$CPA_STATE_DIR/config.json")
    [[ $enabled == true ]] || return 0
    phase=$(jq -r .phase "$CPA_STATE_DIR/runtime.json")
    now=$(date +%s)
    case "$phase" in
        primary_active|backup_active) previous=$(jq -r '.last_attempt_unix//0' "$CPA_STATE_DIR/runtime.json"); interval=$(jq -r .interval_seconds "$CPA_STATE_DIR/config.json"); action=backup ;;
        backup_standby) previous=$(jq -r '.last_secondary_attempt_unix//0' "$CPA_STATE_DIR/runtime.json"); interval=$(jq -r .secondary_interval_seconds "$CPA_STATE_DIR/config.json"); action=secondary; [[ $(jq -r '.latest_received.id//empty' "$CPA_STATE_DIR/runtime.json") != '' ]] || return 0 ;;
        *) return 0 ;;
    esac
    (( now - previous >= interval )) || return 0
    if [[ $action == backup ]]; then
        cpa_state_update '.last_attempt_unix=$now' --argjson now "$now" || return
    else
        cpa_state_update '.last_secondary_attempt_unix=$now' --argjson now "$now" || return
    fi
    id=$(cpa_uuid)
    body=$(mktemp "$CPA_STATE_DIR/.tick.XXXXXX") || return
    printf '{}' > "$body"
    cpa_job_begin "$action" "$id" || { rm -f -- "$body"; return 1; }
    if result=$(cpa_backup "$body" scheduled 2> "$CPA_STATE_DIR/jobs/$id.log"); then
        cpa_job_finish "$id" '' "$result" || { rm -f -- "$body"; return 1; }
    else
        cpa_job_finish "$id" "$(tail -c 2000 "$CPA_STATE_DIR/jobs/$id.log")" '{}' || { rm -f -- "$body"; return 1; }
    fi
    rm -f -- "$body"
}
cpa_created_at_bounds() {
    local timestamp=$1 canonical lower upper
    [[ $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{9})?Z$ ]] || { cpa_fail '快照时间须为UTC秒或9位纳秒格式'; return 1; }
    canonical=$(date -u -d "$timestamp" +'%Y-%m-%dT%H:%M:%S.%NZ' 2>/dev/null) || { cpa_fail '快照创建时间的日历值无效'; return 1; }
    if [[ $timestamp == *.* ]]; then
        [[ $canonical == "$timestamp" ]] || { cpa_fail '快照创建时间未规范化'; return 1; }
        lower=$canonical upper=$canonical
    else
        lower="${timestamp%Z}.000000000Z"
        upper="${timestamp%Z}.999999999Z"
        [[ $canonical == "$lower" ]] || { cpa_fail '快照创建时间未规范化'; return 1; }
    fi
    printf '%s %s\n' "$lower" "$upper"
}
cpa_receive_order() {
    local incoming=$1 current=$2 incoming_bounds current_bounds lower previous_upper incoming_epoch current_epoch
    local LC_ALL=C
    incoming_bounds=$(cpa_created_at_bounds "$(jq -er .created_at <<< "$incoming")") || return
    [[ $current != null && -n $current ]] || return 0
    current_bounds=$(cpa_created_at_bounds "$(jq -er .created_at <<< "$current")") || return
    # Import already verifies the full archive and exact content for a duplicate
    # ID; reacknowledging the current ID never moves to a different recovery point.
    [[ $(jq -r .id <<< "$incoming") != "$(jq -r .id <<< "$current")" ]] || return 0
    incoming_epoch=$(jq -r .epoch <<< "$incoming")
    current_epoch=$(jq -r .epoch <<< "$current")
    if (( incoming_epoch > current_epoch )); then return 0; fi
    if (( incoming_epoch < current_epoch )); then cpa_fail '拒绝过时代次副本'; return 1; fi
    lower=${incoming_bounds%% *}
    previous_upper=${current_bounds#* }
    # A legacy second denotes an unknown instant within that second. Never use
    # random IDs to invent an order for equal/overlapping time intervals.
    [[ $lower > $previous_upper ]] || { cpa_fail '拒绝旧副本或时间顺序不明的副本；保留当前有效恢复点'; return 1; }
}
cpa_receive() {
    local node=$1 epoch=$2 purpose=${3:-received} nonce=${4:-} phase role expected archive limit manifest
    cpa_id_valid "$node" && [[ $epoch =~ ^[0-9]+$ ]] || { cpa_fail '来源身份或代次非法'; return 1; }
    expected=$(jq -r .peer.node_id "$CPA_STATE_DIR/config.json")
    [[ -n $expected && $expected == "$node" ]] || { cpa_fail '上传节点不是已配对主节点'; return 1; }
    phase=$(jq -r .phase "$CPA_STATE_DIR/runtime.json")
    role=$(jq -r .node_role "$CPA_STATE_DIR/config.json")
    [[ $role == backup && $epoch -ge $(jq -r .epoch "$CPA_STATE_DIR/runtime.json") ]] || { cpa_fail '接收角色或代次不符'; return 1; }
    if [[ $purpose == baseline ]]; then
        [[ $phase == paused && $nonce == "$(jq -r '.handover.id//empty' "$CPA_STATE_DIR/runtime.json")" && $epoch == "$(jq -r '.handover.epoch//-1' "$CPA_STATE_DIR/runtime.json")" ]] || { cpa_fail '交接基线 nonce 不符'; return 1; }
    else
        [[ $phase == backup_standby ]] || { cpa_fail '备机已接管/暂停，拒绝旧主覆盖'; return 1; }
    fi
    archive=$(mktemp "$CPA_STATE_DIR/.incoming.XXXXXX") || return
    limit=$(( $(jq -r .max_snapshot_bytes "$CPA_STATE_DIR/config.json") + 134217728 ))
    head -c "$((limit+1))" > "$archive" || { rm -f -- "$archive"; return 1; }
    if (( $(stat -c %s "$archive") > limit )); then rm -f -- "$archive"; cpa_fail '归档超过接收容量'; return 1; fi
    manifest=$(cpa_snapshot_import "$archive" "$node" "$epoch" primary) || { rm -f -- "$archive"; return 1; }
    rm -f -- "$archive"
    [[ $(jq -r .node_role <<< "$manifest") == primary ]] || { cpa_fail '接收的副本并非主节点来源'; return 1; }
    if [[ $purpose == baseline ]]; then
        cpa_receive_order "$manifest" "$(jq '.handover.baseline//null' "$CPA_STATE_DIR/runtime.json")" || return
        cpa_state_update '.handover.baseline=$manifest' --argjson manifest "$manifest" || return
    else
        cpa_receive_order "$manifest" "$(jq '.latest_received//null' "$CPA_STATE_DIR/runtime.json")" || return
        cpa_state_update '.latest_received=$manifest|.epoch=$epoch' --argjson manifest "$manifest" --argjson epoch "$epoch" || return
    fi
    cpa_snapshot_prune || return
    printf '%s\n' "$manifest"
}
cpa_handover() {
    local node=$1 epoch=$2 quiesced=$3 phase hid manifest sid
    [[ $node == "$(jq -r .peer.node_id "$CPA_STATE_DIR/config.json")" && $epoch == "$(jq -r .epoch "$CPA_STATE_DIR/runtime.json")" && $quiesced == true ]] || { cpa_fail '最终交接身份、代次或停机确认不符'; return 1; }
    [[ $(jq -r .node_role "$CPA_STATE_DIR/config.json") == backup ]] || { cpa_fail '只有备节点可生成最终交接'; return 1; }
    phase=$(jq -r .phase "$CPA_STATE_DIR/runtime.json")
    if [[ $phase == backup_active ]]; then
        hid=$(cpa_uuid)
        cpa_state_update '.phase="paused"|.handover={id:$id,node_id:$node,epoch:$epoch,snapshot_id:null,baseline:null,committed:false}' --arg id "$hid" --arg node "$node" --argjson epoch "$epoch" || return
        cpa_service_control stop || return
    elif [[ $phase == paused && $(jq -r '.handover.node_id//empty' "$CPA_STATE_DIR/runtime.json") == "$node" ]]; then
        hid=$(jq -r .handover.id "$CPA_STATE_DIR/runtime.json")
        cpa_service_control stop || return
    else cpa_fail '备节点并非可交接权威状态'; return 1
    fi
    sid=$(jq -r '.handover.snapshot_id//empty' "$CPA_STATE_DIR/runtime.json")
    if [[ -z $sid ]]; then
        manifest=$(cpa_snapshot_create handover "$epoch") || return
        sid=$(jq -r .id <<< "$manifest")
        cpa_state_update '.handover.snapshot_id=$id' --arg id "$sid" || return
    else cpa_snapshot_verify "$sid" >/dev/null || return
    fi
    jq -n --arg snapshot "$sid" --arg id "$hid" --argjson epoch "$epoch" '{snapshot_id:$snapshot,handover_id:$id,epoch:$epoch}'
}
cpa_commit_handover() {
    local nonce=$1 id node epoch phase committed manifest
    cpa_id_valid "$nonce" || { cpa_fail '交接nonce非法'; return 1; }
    node=$(jq -r .peer.node_id "$CPA_STATE_DIR/config.json")
    epoch=$(jq -r .epoch "$CPA_STATE_DIR/runtime.json")
    phase=$(jq -r .phase "$CPA_STATE_DIR/runtime.json")
    committed=$(jq -r '.handover.committed//false' "$CPA_STATE_DIR/runtime.json")
    [[ $(jq -r .node_role "$CPA_STATE_DIR/config.json") == backup && -n $node && $(jq -r '.handover.node_id//empty' "$CPA_STATE_DIR/runtime.json") == "$node" && $(jq -r '.handover.epoch//-1' "$CPA_STATE_DIR/runtime.json") == "$epoch" ]] || { cpa_fail '交接角色、配对身份或代次不符'; return 1; }
    [[ $nonce == "$(jq -r '.handover.id//empty' "$CPA_STATE_DIR/runtime.json")" && $(jq -r '.handover.baseline.id//empty' "$CPA_STATE_DIR/runtime.json") != '' ]] || { cpa_fail '没有对应的新主基线，拒绝交接'; return 1; }
    if [[ $committed == true ]]; then
        [[ $phase == backup_standby ]] || { cpa_fail '已提交交接不在普通待机状态'; return 1; }
        # The old baseline may be pruned after later receives. An idempotent
        # ACK must not require it or reassign latest_received to that old data.
        printf '{"committed":true,"idempotent":true}\n'
        return 0
    fi
    [[ $phase == paused ]] || { cpa_fail '只有暂停中的有效交接可以提交'; return 1; }
    id=$(jq -r .handover.baseline.id "$CPA_STATE_DIR/runtime.json")
    manifest=$(cpa_snapshot_verify "$id") || return
    jq -e --arg node "$node" --argjson epoch "$epoch" '.node_role=="primary" and .node_id==$node and .epoch==$epoch' <<< "$manifest" >/dev/null || { cpa_fail '交接基线身份或代次不符'; return 1; }
    cpa_state_update '.latest_received=.handover.baseline|.epoch=.handover.epoch|.phase="backup_standby"|.handover.committed=true' || return
    printf '{"committed":true}\n'
}
cpa_peer() {
    local command=${1:-}; shift || true
    case "$command" in
        status) cpa_peer_status ;;
        receive) cpa_receive "$1" "$2" ;;
        baseline) cpa_receive "$1" "$2" baseline "$3" ;;
        archive) local archive rc; archive=$(mktemp "$CPA_STATE_DIR/.export.XXXXXX") || return; cpa_snapshot_export "$1" "$archive" >/dev/null || { rm -f -- "$archive"; return 1; }; if cat "$archive"; then rc=0; else rc=$?; fi; rm -f -- "$archive"; return "$rc" ;;
        handover) cpa_handover "$1" "$2" "$3" ;;
        commit) cpa_commit_handover "$1" ;;
        *) cpa_fail 'SSH RPC 操作未登记'; return 1 ;;
    esac
}
