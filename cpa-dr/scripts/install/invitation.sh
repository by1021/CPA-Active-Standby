#!/usr/bin/env bash
# Sourced by the installer; all service mutations use the service's own CLI.
# shellcheck disable=SC2154,SC2016,SC2034
cpa_invitation_select() {
  cpa_manager_select
  cpa_manager_snapshot
  if [[ $manager_backend == native && $EUID != 0 ]]; then
    command -v sudo >/dev/null || fail '此操作需要 root/sudo'
    exec sudo -- bash "$ROOT/start.sh" "${original_args[@]}"
  fi
  [[ -n $record && -z $manager_reason && $manager_record_state == ready && $manager_service == 运行中 ]] || fail "服务未就绪（配置目录：$output；安装：$manager_install；服务：$manager_service；原因：${manager_reason:-请核对状态}）"
  deployment=$manager_backend
}
cpa_installed_cli() {
  if [[ $deployment == docker ]]; then docker exec -i "$manager_container" /opt/cpa-dr/bin/cpa-dr --state-dir /state "$@"
  else "$native_root/bin/cpa-dr" --state-dir "$state" "$@"; fi
}
cpa_installed_json() {
  if [[ $deployment == docker ]]; then
    docker exec -i "$manager_container" bash -c 'set -Eeuo pipefail; umask 077; file=$(mktemp /state/tmp/install.XXXXXXXX); trap '\''rm -f -- "$file"'\'' EXIT; cat > "$file"; /opt/cpa-dr/bin/cpa-dr --state-dir /state "$@" "$file"' -- "$@"
  else
    local file result rc=0
    file=$(mktemp "$state/tmp/install.XXXXXXXX")
    chmod 600 "$file"; cat > "$file"
    result=$("$native_root/bin/cpa-dr" --state-dir "$state" "$@" "$file") || rc=$?
    rm -f "$file"; printf '%s\n' "$result"; return "$rc"
  fi
}
cpa_generate_invitation() {
  [[ -t 0 || ( -n $primary_host && -n $backup_host ) ]] || fail '生成命令需要 --primary-host 和 --backup-host'
  cpa_invitation_select
  local config request answer result
  config=$(cpa_installed_cli config get)
  [[ $(jq -r .node_role <<< "$config") == primary ]] || fail '只有主机可以生成备机安装命令'
  primary_port=${primary_port:-$manager_ssh_port}; backup_port=${backup_port:-2222}
  backup_deployment=${backup_deployment:-$deployment}; backup_data=${backup_data:-$(jq -r .data_dir <<< "$record")}
  if [[ -t 0 ]]; then
    [[ -n $primary_host ]] || prompt '备机能访问的主机地址：' primary_host
    prompt "备机连接主机的专用 SSH 端口 [$primary_port]：" answer; primary_port=${answer:-$primary_port}
    [[ -n $backup_host ]] || prompt '主机能访问的备机地址：' backup_host
    prompt "主机连接备机的专用 SSH 端口 [$backup_port]：" answer; backup_port=${answer:-$backup_port}
    prompt "备机数据父目录 [$backup_data]：" answer; backup_data=${answer:-$backup_data}
    prompt "备机部署方式 native/docker [$backup_deployment]：" answer; backup_deployment=${answer:-$backup_deployment}
    prompt "备机专用 SSH 监听 [${backup_bind:-0.0.0.0}]：" answer; backup_bind=${answer:-${backup_bind:-0.0.0.0}}
    prompt "邀请有效期（秒）[$invite_ttl]：" answer; invite_ttl=${answer:-$invite_ttl}
    if ((invite_auto)); then
      prompt '首备成功后启用定时备份？[Y/n] ' answer
      [[ -z $answer ]] || { if yes_answer "$answer"; then invite_auto=1; else invite_auto=0; fi; }
    else
      prompt '首备成功后启用定时备份？[y/N] ' answer
      if yes_answer "$answer"; then invite_auto=1; else invite_auto=0; fi
    fi
  fi
  [[ -n $primary_host && -n $backup_host ]] || fail '生成命令需要 --primary-host 和 --backup-host'
  backup_bind=${backup_bind:-0.0.0.0}
  request=$(jq -n --arg primary_host "$primary_host" --arg primary_port "$primary_port" --arg backup_host "$backup_host" --arg backup_port "$backup_port" --arg backup_bind_host "$backup_bind" --arg data_dir "$backup_data" --arg deployment "$backup_deployment" --arg output "$backup_output" --arg ttl "$invite_ttl" --arg auto "$invite_auto" '{primary_host:$primary_host,primary_port:($primary_port|tonumber),backup_host:$backup_host,backup_port:($backup_port|tonumber),backup_bind_host:$backup_bind_host,data_dir:$data_dir,deployment:$deployment,output:$output,ttl_seconds:($ttl|tonumber),auto_enable:($auto=="1")}') || fail '邀请参数格式异常'
  printf '\n备机安装计划：\n主机连接：%s:%s\n备机连接：%s:%s\n备机数据：%s\n部署方式：%s\n有效期：%s 秒\n首备成功后启用调度：%s\n' "$primary_host" "$primary_port" "$backup_host" "$backup_port" "$backup_data" "$backup_deployment" "$invite_ttl" "$invite_auto"
  printf '只安装备份服务，不启动/恢复 CPA，不修改 Cloudflare。请保证两机 SSH 端口互通。\n'
  if [[ ${manager_ssh_address:-} == 127.* || ${manager_ssh_address:-} == ::1 ]]; then
    if [[ -t 0 ]]; then
      printf '主机专用 SSH 仅监听回环地址，备机将无法连接；管理页面监听保持不变。\n'
      prompt '确认把专用 SSH 监听改为 0.0.0.0？[y/N] ' answer
      yes_answer "$answer" || fail '专用 SSH 监听未修改，邀请未生成；请先 configure-ssh'
      bash "$ROOT/start.sh" configure-ssh --output "$output" --ssh-bind-host 0.0.0.0 --yes || fail '专用 SSH 监听更新失败'
      cpa_invitation_select
    else
      fail '专用 SSH 仅监听回环；先执行 configure-ssh --ssh-bind-host HOST，或安装时指定 --ssh-bind-host HOST'
    fi
  fi
  if ((assume_yes == 0)); then [[ -t 0 ]] || fail '非交互生成需显式 --yes'; prompt '确认生成一次性安装邀请？[y/N] ' answer; yes_answer "$answer" || fail '已取消生成'; fi
  result=$(printf '%s\n' "$request" | cpa_installed_json enrollment create) || fail '邀请生成失败'
  printf '邀请 ID：%s\n有效至：%s\n复制以下完整命令到备机执行（命令含短期凭据，请勿公开）：\n' "$(jq -r .invite_id <<< "$result")" "$(jq -r .expires_at <<< "$result")"
  jq -er .command <<< "$result"
}
cpa_install_finish() {
  local answer='' project=$ROOT rc=0 argument cwd
  cwd=$(pwd -P) || return 1
  if [[ $ROOT == */releases/*/cpa-dr ]]; then
    project=${ROOT%/releases/*}
    if [[ ! -e $project/install.json ]] || [[ $(jq -r .config_dir "$project/install.json") == "$output" ]]; then
      cpa_location_register "$project" "$ROOT" "$output" "$cwd" || return 1
    else
      printf '显式目标配置：%s；项目默认关联保持不变。\n管理命令：' "$output"
      printf 'bash %q menu --output %q\n' "$ROOT/start.sh" "$output"
      printf '状态目录：%s\n' "${state:-未知}"
    fi
  else
    printf '项目/源码目录：%s\n配置目录：%s\n状态目录：%s\n管理命令：' "$ROOT" "$output" "${state:-未知}"
    printf 'bash %q menu --output %q\n' "$ROOT/start.sh" "$output"
    printf '备机邀请：bash %q generate-backup-command --output %q\n' "$ROOT/start.sh" "$output"
  fi
  printf '安装状态：已安装\n服务状态：运行中\n配对与定时备份：请以 status 显示的实际配置为准。\n'
  [[ $role == primary || ( -z $role && $generate_backup == 1 ) ]] || return 0
  if ((generate_backup == 0)); then
    ((existing == 0)) && [[ -t 0 ]] || return 0
    read -r -p '现在生成备机安装命令？[Y/n] ' answer || { printf '\n已保留安装，备机配置可稍后继续。\n'; return 0; }
    [[ -z $answer ]] || yes_answer "$answer" || return 0
  fi
  # Installation is complete: do not retain its lock while configuring listeners.
  if [[ -n ${start_lock:-} ]]; then
    [[ -z ${lock_file:-} ]] || rm -f -- "$lock_file" || return 1
    # Keep the EXIT trap and its exit-code handling, but disarm this cleanup
    # before releasing ownership: another operation may create a new lock.
    lock_file=''
    exec {start_lock}>&-
    unset start_lock
  fi
  local -a args=(generate-backup-command --output "$output")
  for argument in primary_host primary_port backup_host backup_port backup_data backup_deployment backup_output backup_bind; do
    [[ -n ${!argument} ]] || continue
    case $argument in
      primary_host) args+=(--primary-host "$primary_host");; primary_port) args+=(--primary-port "$primary_port");;
      backup_host) args+=(--backup-host "$backup_host");; backup_port) args+=(--backup-port "$backup_port");;
      backup_data) args+=(--backup-data-dir "$backup_data");; backup_deployment) args+=(--backup-deployment "$backup_deployment");;
      backup_output) args+=(--backup-output "$backup_output");; backup_bind) args+=(--backup-bind-host "$backup_bind");;
    esac
  done
  args+=(--ttl "$invite_ttl")
  ((invite_auto)) || args+=(--no-auto-enable)
  ((assume_yes == 0)) || args+=(--yes)
  bash "$ROOT/start.sh" "${args[@]}" || rc=$?
  if ((rc)); then printf '安装已成功；备机邀请未完成（退出码 %s），原配置保留。可用上方邀请命令继续。\n' "$rc" >&2; fi
  return "$rc"
}
cpa_configure_ssh() {
  [[ -n $ssh_bind ]] || fail '请明确提供 --ssh-bind-host HOST'
  cpa_invitation_select
  local answer saved=$ssh_bind
  printf '将专用 SSH 监听改为 %s，管理页面、节点身份与历史保持不变；会重启备份服务，不操作 CPA。\n' "$saved"
  if ((assume_yes == 0)); then [[ -t 0 ]] || fail '非交互监听修改需 --yes'; prompt '确认修改？[y/N] ' answer; yes_answer "$answer" || fail '已取消'; fi
  cpa_start_lock
  if [[ $deployment == native ]]; then
    bind=$(jq -r .bind_host <<< "$record"); ssh_port=$(jq -r .ssh_port <<< "$record"); data=$(jq -r .data_dir <<< "$record")
    cpa_native_upgrade "$saved"
  else
    local envfile="$output/.env" old new project
    [[ -f $envfile && ! -L $envfile ]] || fail '.env 归属异常'
    cpa_manager_guard
    old=$(mktemp "$output/.env.listener-old.XXXXXXXX"); new=$(mktemp "$output/.env.listener-new.XXXXXXXX")
    cp -- "$envfile" "$old"
    awk -v value="$saved" 'BEGIN{found=0} /^SSH_BIND_HOST=/{print "SSH_BIND_HOST=" value;found=1;next} {print} END{if(!found)print "SSH_BIND_HOST=" value}' "$envfile" > "$new"
    chmod 600 "$old" "$new"
    project=$(jq -r .project_name <<< "$record")
    local -a command=(docker compose --project-directory "$ROOT" --file "$ROOT/compose.yaml" --env-file "$envfile" --project-name "$project")
    if ! "${command[@]}" stop --timeout 60; then cpa_manager_release_guard; rm -f "$old" "$new"; fail '停止失败，监听未修改'; fi
    mv -fT "$new" "$envfile"
    cpa_manager_release_guard
    if ! "${command[@]}" up -d --build --wait --wait-timeout 120; then
      cp -- "$old" "$envfile"; chmod 600 "$envfile"
      "${command[@]}" up -d --wait --wait-timeout 120 >/dev/null 2>&1 || true
      rm -f "$old"; fail '新监听启动失败，已恢复原配置'
    fi
    record=$(jq --arg host "$saved" '.ssh_bind_host=$host' <<< "$record"); cpa_start_save_record
    rm -f "$old"
  fi
  printf '专用 SSH 监听已更新；防火墙未修改，请限制对端来源。\n'
}

# shellcheck source=native-upgrade.sh
source "$ROOT/scripts/install/native-upgrade.sh"
