#!/usr/bin/env bash
# Guarded native source/SSH upgrade. No state, identity or snapshot migration.
# shellcheck disable=SC2154,SC2034
cpa_native_upgrade() {
  local desired=$1 stage backup name original_record=$record failed=0 address scan
  local -a backed_up_items=() installed_items=()
  [[ $desired =~ ^[A-Za-z0-9:][A-Za-z0-9_.:-]{0,252}$ ]] || fail 'SSH监听地址非法'
  cpa_start_native_paths; cpa_start_native_units_check
  cpa_start_owned_directory "$state" "$(jq -r .install_id <<< "$record")"
  cpa_start_owned_directory "$native_root" "$(jq -r .install_id <<< "$record")"
  stage=$(mktemp -d "$native_root/.env.upgrade-new.XXXXXXXX")
  backup=$(mktemp -d "$native_root/.env.upgrade-old.XXXXXXXX")
  local -a items=(bin lib cgi www scripts start.sh deploy Dockerfile compose.yaml .env.example .dockerignore)
  for name in "${items[@]}"; do
    [[ -e $ROOT/$name || -L $ROOT/$name ]] || continue
    if [[ -L $ROOT/$name ]]; then
      case $name in
        Dockerfile|compose.yaml|.env.example) [[ $(realpath -e -- "$ROOT/$name") == "$ROOT/deploy/$name" && ! -L $ROOT/deploy/$name ]] || fail '兼容部署文件链接异常'; cp -pL -- "$ROOT/$name" "$stage/$name";;
        *) fail '升级源码含不受信链接';;
      esac
    else cp -a -- "$ROOT/$name" "$stage/"; fi
  done
  "$ROOT/scripts/render-sshd.sh" "$state" /run/cpa-dr-native "$desired" "$ssh_port" "$native_root" > "$stage/sshd.conf"
  if ! /usr/sbin/sshd -t -f "$stage/sshd.conf"; then rm -rf -- "$stage" "$backup"; fail '新 SSH 配置检查失败，原安装未改'; fi
  cp -- "$output/sshd.conf" "$backup/sshd.conf"
  manager_backend=native
  cpa_manager_guard
  if ! systemctl stop "${CPA_START_UNITS[@]}"; then cpa_manager_release_guard; rm -rf -- "$stage" "$backup"; fail '停止本服务失败，原代码和配置保留'; fi
  for name in "${items[@]}"; do
    if [[ -e $native_root/$name || -L $native_root/$name ]]; then
      mv -- "$native_root/$name" "$backup/$name" || { failed=1; break; }
      backed_up_items+=("$name")
    fi
    if [[ -e $stage/$name || -L $stage/$name ]]; then
      mv -- "$stage/$name" "$native_root/$name" || { failed=1; break; }
      installed_items+=("$name")
    fi
  done
  if ((failed == 0)); then
    install -m 600 -- "$stage/sshd.conf" "$output/sshd.conf" || failed=1
    record=$(jq --arg host "$desired" --arg hash "$(sha256sum "$output/sshd.conf" | cut -d ' ' -f1)" '.ssh_bind_host=$host|.unit_hashes["sshd.conf"]=$hash' <<< "$record")
    printf '%s\n' "$record" | cpa_atomic "$manifest" || failed=1
  fi
  cpa_manager_release_guard
  if ((failed == 0)); then
    # Ordinary uninstall removed installed units but kept verified templates.
    # Reinstall must publish those templates before starting upgraded code.
    for name in "${CPA_START_UNITS[@]}"; do install -m 644 -- "$output/$name" /etc/systemd/system/ || failed=1; done
    systemctl daemon-reload || failed=1
    systemctl enable --now cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-ssh.service || failed=1
    for name in cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-fcgi.service cpa-dr-native-ssh.service; do systemctl is-active --quiet "$name" || failed=1; done
    address=$(jq -r .bind_host <<< "$record")
    [[ $address != 0.0.0.0 && $address != :: ]] || address=127.0.0.1
    [[ $address != *:* ]] || address="[$address]"
    curl -fsS --max-time 5 "http://$address:$(jq -r .port <<< "$record")/healthz" | jq -e '.ok==true' >/dev/null || failed=1
    address=$desired
    [[ $address != 0.0.0.0 && $address != :: ]] || address=127.0.0.1
    scan=$(timeout 5 ssh-keyscan -t ed25519 -p "$ssh_port" "$address" 2>/dev/null) || failed=1
    [[ $(awk '!/^#/ {print $3; exit}' <<< "$scan") == "$(awk '{print $2}' "$state/ssh/ssh_host_ed25519_key.pub")" ]] || failed=1
  fi
  if ((failed)); then
    systemctl stop "${CPA_START_UNITS[@]}" >/dev/null 2>&1 || true
    for name in "${installed_items[@]}"; do
      [[ ! -e $native_root/$name && ! -L $native_root/$name ]] || rm -rf -- "${native_root:?}/$name"
    done
    for name in "${backed_up_items[@]}"; do
      mv -- "$backup/$name" "$native_root/$name" || fail "原代码恢复失败；保留备份目录：$backup"
    done
    install -m 600 -- "$backup/sshd.conf" "$output/sshd.conf"
    record=$original_record; cpa_start_save_record
    systemctl enable --now cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-ssh.service >/dev/null 2>&1 || true
    rm -rf -- "$stage" "$backup"; fail '本地升级失败，原代码和监听已恢复，数据与身份保留'
  fi
  rm -rf -- "$stage" "$backup"
}
