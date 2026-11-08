#!/usr/bin/env bash
# Fixed, pinned native SSH transport used by replication and enrollment.
cpa_ssh() {
    local operation=$1; shift
    local host user port identity known command arg
    host=$(jq -r '.peer.host' "$CPA_STATE_DIR/config.json")
    user=$(jq -r '.peer.user' "$CPA_STATE_DIR/config.json")
    port=$(jq -r '.peer.port' "$CPA_STATE_DIR/config.json")
    identity=$(jq -r '.peer.identity_file' "$CPA_STATE_DIR/config.json")
    known=$(jq -r '.peer.known_hosts_file' "$CPA_STATE_DIR/config.json")
    [[ $host =~ ^[A-Za-z0-9:][A-Za-z0-9_.:-]*$ && $user =~ ^[A-Za-z_][A-Za-z0-9_-]*\$?$ && $port =~ ^[0-9]+$ ]] || { cpa_fail '对端 SSH 地址配置不完整'; return 1; }
    [[ -f $identity && -f $known ]] || { cpa_fail 'SSH 私钥或 known_hosts 尚未配置'; return 1; }
    [[ $operation =~ ^(status|receive|archive|handover|baseline|commit)$ ]] || { cpa_fail 'SSH 操作未登记'; return 1; }
    command=$operation
    for arg in "$@"; do
        [[ $arg =~ ^[A-Za-z0-9_-]+$ ]] || { cpa_fail 'SSH 参数非法'; return 1; }
        command+=" $arg"
    done
    timeout 300 ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o "UserKnownHostsFile=$known" -i "$identity" -p "$port" "$user@$host" "$command"
}
