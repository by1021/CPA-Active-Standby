#!/usr/bin/env bash
# One-command Compose deployment; configuration is data, never Shell code.
set -Eeuo pipefail
umask 077
script_directory=.
[[ ${BASH_SOURCE[0]} != */* ]] || script_directory=${BASH_SOURCE[0]%/*}/
ROOT=$(cd -- "$script_directory" && pwd)
data='' output="$ROOT" port='' ssh_port='' read_only=0 install_deps=1 assume_yes=0
usage() {
  local line
  while IFS= read -r line; do printf '%s\n' "$line"; done <<'HELP'
用法：bash start.sh [--data-dir TARGET] [--output DIR] [--port 8787]
                     [--ssh-port 2222] [--read-only-data] [--yes | --no-install-deps]
首次运行提供已有 CPA 数据父目录；终端运行未指定时交互输入。
已有 .env 可直接重跑；重复传入的参数须与原配置一致，不覆盖配置和密钥。
需要 Bash、Docker Engine、支持 --wait/--wait-timeout 的 Compose v2、
coreutils、OpenSSL、OpenSSH 客户端、util-linux 和 jq。
缺失依赖时提示确认后用 apt-get/dnf/yum 安装；普通用户通过 sudo 安装。
--yes 明确允许非交互安装；--no-install-deps 只检查，不安装。
只使用现有软件源；Docker daemon 及访问权限仍须就绪。
HELP
}
fail() { printf '启动失败：%s\n' "$*" >&2; exit 1; }
within() { [[ $1 == "$2" || $1 == "${2%/}/"* ]]; }
while (($#)); do
  case $1 in
    --data-dir|--output|--port|--ssh-port)
      (($# >= 2)) && [[ -n $2 ]] || fail "参数缺少值：$1"
      case $1 in
        --data-dir) data=$2;; --output) output=$2;;
        --port) port=$2;; --ssh-port) ssh_port=$2;;
      esac
      shift 2;;
    --read-only-data) read_only=1; shift;;
    --yes) assume_yes=1; shift;;
    --no-install-deps) install_deps=0; shift;;
    --help|-h) usage; exit 0;;
    *) fail "未知参数：$1（使用 --help 查看用法）";;
  esac
done
((assume_yes == 0 || install_deps == 1)) || fail '--yes 与 --no-install-deps 不可同时使用'
for value in "$port" "$ssh_port"; do
  [[ -n $value ]] || continue
  [[ $value =~ ^[0-9]+$ && ${#value} -le 5 ]] || fail '端口须在1到65535之间'
  ((10#$value >= 1 && 10#$value <= 65535)) || fail '端口须在1到65535之间'
done
# Do not let unrelated shell exports override the private deployment file.
unset ADMIN_TOKEN CPA_DATA_PATH STATE_PATH PORT SSH_PORT BIND_HOST SSH_BIND_HOST DATA_ACCESS
# shellcheck source=scripts/start-dependencies.sh
source "$ROOT/scripts/start-dependencies.sh"
cpa_start_ensure_dependencies "$install_deps" "$assume_yes"
docker compose version >/dev/null || fail '请安装 Docker Compose v2 插件'
up_help=$(docker compose up --help) || fail '读取 Compose 启动选项失败'
[[ $up_help == *--wait-timeout* && $up_help == *--wait* ]] || fail '请升级 Compose v2，须支持 up --wait --wait-timeout'
docker info >/dev/null || fail 'Docker daemon 未就绪或当前用户没有访问权限'
output=$(realpath -m -- "$output")
[[ $output != *[\'\"\\\$:]* && ! $output =~ [[:cntrl:]] ]] || fail '部署路径含不支持的字符，参见 README'
envfile="$output/.env"
if [[ -e $envfile || -L $envfile ]]; then
  [[ -f $envfile ]] || fail '.env 必须是已有的普通配置文件'
  printf '使用已有配置：%s（保留密钥和状态）\n' "$envfile"
else
  if [[ -z $data ]]; then
    [[ -t 0 ]] || fail '首次非交互运行请提供 --data-dir TARGET'
    read -r -p '请输入已存在的 CPA 数据父目录：' data || fail '未读取到数据目录'
  fi
  [[ -d $data ]] || fail '--data-dir 必须指向已存在的数据父目录'
  data=$(realpath -e -- "$data")
  if within "$data" "$ROOT" || within "$ROOT" "$data" || within "$data" "$output" || within "$output" "$data"; then
    fail '数据目录与服务源码、部署/状态目录必须独立'
  fi
  setup_args=(--data-dir "$data" --output "$output")
  [[ -z $port ]] || setup_args+=(--port "$port")
  [[ -z $ssh_port ]] || setup_args+=(--ssh-port "$ssh_port")
  ((read_only == 0)) || setup_args+=(--read-only-data)
  # Display credentials only after management health succeeds.
  bash "$ROOT/scripts/setup.sh" "${setup_args[@]}" >/dev/null
fi
compose=(docker compose --project-directory "$ROOT" --file "$ROOT/compose.yaml" --env-file "$envfile")
"${compose[@]}" config --quiet || fail 'Compose 配置检查失败；已保留 .env 和状态'
model=$("${compose[@]}" config --format json) || fail '读取 Compose 有效配置失败'
config_value() {
  local query
  case $1 in
    CPA_DATA_PATH) query='.services["cpa-dr"].volumes[] | select(.target == "/data" and .type == "bind") | .source';;
    STATE_PATH) query='.services["cpa-dr"].volumes[] | select(.target == "/state" and .type == "bind") | .source';;
    PORT) query='.services["cpa-dr"].ports[] | select(.target == 8787) | .published';;
    SSH_PORT) query='.services["cpa-dr"].ports[] | select(.target == 22) | .published';;
    DATA_ACCESS) query='.services["cpa-dr"].volumes[] | select(.target == "/data") | if .read_only == true then "ro" else "rw" end';;
    ADMIN_TOKEN) query='.services["cpa-dr"].environment.CPA_ADMIN_TOKEN';;
    *) return 1;;
  esac
  jq -er "$query" <<< "$model"
}
effective_data=$(config_value CPA_DATA_PATH) || fail '.env 缺少 CPA_DATA_PATH'
state=$(config_value STATE_PATH) || fail '.env 缺少 STATE_PATH'
[[ $effective_data == /* ]] || effective_data="$ROOT/$effective_data"
[[ $state == /* ]] || state="$ROOT/$state"
[[ -d $effective_data && -d $state ]] || fail '配置中的数据或状态目录不存在；请核对挂载，不自动创建空目录'
effective_data=$(realpath -e -- "$effective_data")
state=$(realpath -e -- "$state")
for value in "$effective_data" "$state"; do
  [[ $value != *[\'\"\\\$:]* && ! $value =~ [[:cntrl:]] ]] || fail '挂载路径含不支持的字符，参见 README'
done
if within "$effective_data" "$ROOT" || within "$ROOT" "$effective_data" || within "$effective_data" "$state" || within "$state" "$effective_data" || within "$effective_data" "$output" || within "$output" "$effective_data"; then
  fail '数据目录与服务源码、部署/状态目录必须独立'
fi
if [[ -n $data ]]; then
  [[ -d $data ]] || fail '--data-dir 必须指向已存在的数据父目录'
  [[ $(realpath -e -- "$data") == "$effective_data" ]] || fail '--data-dir 与已有 .env 冲突；请核对配置，不覆盖原挂载'
fi
for key in PORT SSH_PORT; do
  configured=$(config_value "$key") || fail ".env 缺少 $key"
  [[ $configured =~ ^[0-9]+$ && ${#configured} -le 5 ]] || fail ".env 的 $key 格式异常"
  ((10#$configured >= 1 && 10#$configured <= 65535)) || fail ".env 的 $key 超出端口范围"
  requested=$port; [[ $key != SSH_PORT ]] || requested=$ssh_port
  if [[ -n $requested ]] && ((10#$requested != 10#$configured)); then
    fail "$key 与已有 .env 冲突；修改监听请明确编辑 .env 后重跑"
  fi
done
access=$(config_value DATA_ACCESS) || fail '.env 缺少 DATA_ACCESS'
[[ $access == rw || $access == ro ]] || fail 'DATA_ACCESS 须为 rw 或 ro'
if ((read_only == 1)) && [[ $access != ro ]]; then fail '--read-only-data 与已有 .env 冲突；请明确编辑 DATA_ACCESS 后重跑'; fi
[[ -f $state/admin.token && -f $state/ssh/id_ed25519.pub ]] || fail '状态目录缺少管理员令牌或 SSH 公钥；保留已有配置，请核对状态目录'
token=$(< "$state/admin.token")
[[ $token =~ ^[a-zA-Z0-9_-]{32,}$ ]] || fail '状态目录的管理员令牌格式异常'
[[ $(config_value ADMIN_TOKEN) == "$token" ]] || fail '.env 管理员令牌与状态目录不一致；请核对原配置'
unset model
printf '正在构建并启动，管理健康检查最多等待120秒……\n'
if ! "${compose[@]}" up -d --build --wait --wait-timeout 120; then
  printf '启动失败：构建或管理健康检查未通过，已保留配置、密钥和数据。\n排错命令：' >&2
  printf '%q ' "${compose[@]}" logs --tail 50 >&2
  printf '\n' >&2
  exit 1
fi
"${compose[@]}" ps
address=$("${compose[@]}" port cpa-dr 8787) || fail '读取实际管理端口失败'
[[ -n $address ]] || fail '未找到管理端口映射'
printf '\n服务已启动（仅管理服务健康，不代表 CPA 业务就绪）。\n管理地址：http://%s\n配置文件：%s\n管理员令牌：%s\n本机 SSH 公钥：\n' "$address" "$envfile" "$token"
cat -- "$state/ssh/id_ed25519.pub"
printf '%s\n' '默认管理与备份 SSH 仅绑定本机；远程访问、对端指纹核对和角色/备份设置见 README。'
