#!/usr/bin/env bash
# Prepare Docker mounts and SSH identity without interpreting configuration as code.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
data='' output="$ROOT" port=8787 ssh_port=2222 access=rw
usage() { printf '%s\n' '用法：bash scripts/setup.sh --data-dir TARGET [--output DIR] [--port 8787] [--ssh-port 2222] [--read-only-data]'; }
fail() { printf '配置失败：%s\n' "$*" >&2; exit 1; }
while (($#)); do
  case $1 in
    --data-dir|--output|--port|--ssh-port) (($# >= 2)) || fail '参数缺少值'; case $1 in --data-dir) data=$2;; --output) output=$2;; --port) port=$2;; --ssh-port) ssh_port=$2;; esac; shift 2;;
    --read-only-data) access=ro; shift;;
    --help|-h) usage; exit 0;;
    *) fail "未知参数：$1";;
  esac
done
[[ -n $data && -d $data ]] || fail '--data-dir 必须指向已存在的数据父目录'
for value in "$port" "$ssh_port"; do
  if [[ ! $value =~ ^[0-9]+$ || ${#value} -gt 5 ]]; then fail '端口须在1到65535之间'; fi
  if ((10#$value < 1 || 10#$value > 65535)); then fail '端口须在1到65535之间'; fi
done
for command in realpath openssl ssh-keygen stat flock; do command -v "$command" >/dev/null || fail "缺少 Linux 命令：$command"; done
data=$(realpath -e -- "$data")
output=$(realpath -m -- "$output")
# Colon/control/backslash/quote/dollar in mount values create ambiguous dotenv or volumes.
for value in "$data" "$output"; do [[ $value != *[\'\"\\\$:]* && ! $value =~ [[:cntrl:]] ]] || fail '路径请使用不含引号、反斜线、美元符、冒号和控制字符的普通 Linux 目录'; done
[[ $data != "$output" && $data != "$output/"* && $output != "$data/"* ]] || fail '数据目录与部署/状态目录必须独立'
[[ $data != "$ROOT" && $data != "$ROOT/"* && $ROOT != "$data/"* ]] || fail '数据目录与服务源码目录必须独立'
[[ ! -e $output/.env ]] || fail '.env 已存在，保留原密钥；修改配置请编辑该文件'
mkdir -p -- "$output/state-native/ssh"
chmod 700 -- "$output/state-native" "$output/state-native/ssh"
state="$output/state-native"
exec {setup_fd}> "$state/setup.lock"
flock "$setup_fd"
[[ ! -e $output/.env ]] || fail ".env 已被另一进程创建，保留原配置"
if [[ -f $state/admin.token ]]; then
  token=$(<"$state/admin.token")
  [[ $token =~ ^[a-zA-Z0-9_-]{32,}$ ]] || fail '已有管理员令牌格式异常，请核对原状态目录'
else
  token=$(openssl rand -hex 32)
  printf '%s\n' "$token" > "$state/admin.token"
fi
chmod 600 -- "$state/admin.token"
if [[ ! -e $state/ssh/id_ed25519 ]]; then ssh-keygen -q -t ed25519 -N '' -C cpa-dr -f "$state/ssh/id_ed25519"; fi
if [[ ! -e $state/ssh/id_ed25519.pub ]]; then ssh-keygen -y -f "$state/ssh/id_ed25519" > "$state/ssh/id_ed25519.pub"; fi
ssh-keygen -l -f "$state/ssh/id_ed25519.pub" >/dev/null || fail '已有 SSH 公钥异常'
chmod 600 -- "$state/ssh/id_ed25519"
touch -- "$state/ssh/known_hosts" "$state/ssh/authorized_keys"
chmod 600 -- "$state/ssh/known_hosts" "$state/ssh/authorized_keys"
# Noclobber is the final guard against concurrent initialization of an existing .env.
(set -o noclobber; printf "ADMIN_TOKEN=%s\nCPA_DATA_PATH='%s'\nSTATE_PATH='%s'\nPORT=%s\nSSH_PORT=%s\nBIND_HOST=127.0.0.1\nSSH_BIND_HOST=127.0.0.1\nDATA_ACCESS=%s\n" "$token" "$data" "$state" "$port" "$ssh_port" "$access" > "$output/.env") || fail '.env 已被另一初始化进程创建，保留已有文件'
chmod 600 -- "$output/.env"
printf '配置已生成：%s/.env\n管理员令牌：%s\n本机 SSH 公钥：\n' "$output" "$token"
cat -- "$state/ssh/id_ed25519.pub"
printf '%s\n' '部署命令：docker compose up -d --build' '默认管理和 SSH 端口仅发布到本机。跨机需配置内网地址、来源防火墙并登记对端主机指纹。'
