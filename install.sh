#!/usr/bin/env bash
# Public HTTPS bootstrap; a registered project owns its pinned source.
set -Eeuo pipefail
umask 077
install_cwd=$(pwd -P)
install_dir="$install_cwd/cpa-dr"
install_output=''
arguments=()
while (($#)); do
  case $1 in
    --install-dir)
      [[ $# -ge 2 && -n $2 ]] || { echo '--install-dir 缺少值' >&2; exit 1; }
      install_dir=$2; shift 2;;
    --output)
      [[ $# -ge 2 && -n $2 ]] || { echo '--output 缺少值' >&2; exit 1; }
      install_output=$2; arguments+=("$1" "$2"); shift 2;;
    --data-dir|--port|--ssh-port|--role|--deployment|--source|--state-dir|--install-root|--bind-host|--ssh-bind-host|--invite-file|--invite|--primary-host|--primary-port|--backup-host|--backup-port|--backup-data-dir|--backup-deployment|--backup-output|--backup-bind-host|--ttl|--tail)
      [[ $# -ge 2 && -n $2 ]] || { printf '参数缺少值：%s\n' "$1" >&2; exit 1; }
      arguments+=("$1" "$2"); shift 2;;
    *) arguments+=("$1"); shift;;
  esac
done
[[ $install_dir == /* ]] || install_dir="$install_cwd/$install_dir"
set -- "${arguments[@]}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '%s\n' '用法：bash install.sh [安装参数 ...]' \
    '默认主机角色；项目位于执行目录/cpa-dr，配置位于项目/config。' \
    '--install-dir DIR 指定项目；--output DIR 指定配置；--generate-backup 显式生成备机邀请。' \
    '版本：CPA_GITHUB_REF=main|提交SHA|标签；须预装 Bash、curl 和系统 CA 证书。' \
    '非交互示例：bash install.sh --deployment docker --data-dir TARGET --yes'
  exit 0
fi
# No jq/helper/package dependency is available yet. A denied ancestor must
# not masquerade as a missing old deployment and trigger any HTTPS request.
probe=("$install_dir")
if [[ -n $install_output ]]; then
  [[ $install_output == /* ]] || install_output="$install_cwd/$install_output"
fi
# A registered project's trusted launcher retains Native's controlled sudo
# re-entry. Only unassociated candidates must be classified before downloads.
if [[ ! -e $install_dir/install.json && ! -L $install_dir/install.json ]]; then
  if [[ -n $install_output ]]; then probe+=("$install_output")
  else probe+=("$HOME/.local/share/cpa-dr/deployments/primary" /etc/cpa-dr-native); fi
fi
for candidate in "${probe[@]}"; do
  [[ $candidate == /* && $candidate != / && ! $candidate =~ [[:cntrl:]] ]] || { echo '候选路径异常，状态未知' >&2; exit 1; }
  cursor=$candidate
  while :; do
    [[ ! -L $cursor ]] || { printf '已知部署路径含链接，状态未知：%s\n' "$cursor" >&2; exit 1; }
    if [[ -d $cursor && ! -x $cursor ]]; then
      printf '已知部署路径祖先目录权限不足，状态未知：%s\n' "$cursor" >&2; exit 1
    fi
    [[ ! -e $cursor || -d $cursor ]] || { printf '已知部署路径不是目录，状态未知：%s\n' "$cursor" >&2; exit 1; }
    [[ $cursor != / ]] || break
    cursor=${cursor%/*}; cursor=${cursor:-/}
  done
done
if [[ -e $install_dir/install.json || -L $install_dir/install.json ]]; then
  # Before running even our launcher, reject links and writable/foreign owners.
  cursor="$install_dir/start.sh"
  caller=$EUID
  if ((EUID == 0)) && [[ ${SUDO_UID:-} =~ ^[0-9]+$ ]]; then caller=$SUDO_UID; fi
  while [[ $cursor != / ]]; do
    [[ ! -L $cursor ]] || { echo '安装入口路径含链接，未执行' >&2; exit 1; }
    if [[ -d $cursor ]]; then
      owner=$(stat -c %u "$cursor"); mode=$(stat -c %a "$cursor")
      [[ $owner == "$EUID" || $owner == "$caller" || $owner == 0 ]] && (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || { echo '安装入口祖先目录权限不安全，未执行' >&2; exit 1; }
    fi
    cursor=${cursor%/*}; cursor=${cursor:-/}
  done
  [[ -f $install_dir/start.sh && -r $install_dir/start.sh && -f $install_dir/install.json && ! -L $install_dir/install.json ]] || { echo '安装入口或记录异常，未执行' >&2; exit 1; }
  owner=$(stat -c %u "$install_dir/start.sh"); mode=$(stat -c %a "$install_dir/start.sh")
  [[ $owner == "$EUID" || $owner == "$caller" || $owner == 0 ]] && (( (8#$mode & 0022) == 0 )) && grep -qx '# cpa-dr stable project launcher v1' "$install_dir/start.sh" || { echo '不是可信项目入口，未执行' >&2; exit 1; }
  exec bash "$install_dir/start.sh" --bootstrap-existing "$@"
fi
repository=by1021/CPA-Active-Standby
ref=${CPA_GITHUB_REF:-main}
[[ $ref =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { echo 'GitHub 版本参数异常' >&2; exit 1; }
command -v curl >/dev/null || { echo '请先安装 curl 和系统 CA 证书' >&2; exit 1; }
commit=$ref
if [[ ! $commit =~ ^[a-f0-9]{40}$ ]]; then
  commit=$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --retry 2 \
    -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$repository/commits/$ref")
fi
[[ $commit =~ ^[a-f0-9]{40}$ ]] || { echo 'GitHub 未返回有效提交 SHA，请检查版本、网络或 API 限速' >&2; exit 1; }
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
for helper in github location; do
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --retry 2 \
    "https://raw.githubusercontent.com/$repository/$commit/cpa-dr/scripts/packaging/$helper.sh" -o "$temp/$helper.sh" || {
      printf '选定提交 %s 的安装辅助文件 %s 下载失败；检查该版本是否包含新版入口及网络，未开始服务安装。\n' "$commit" "$helper" >&2
      exit 1
    }
done
bash "$temp/github.sh" "$repository" "$commit" --install-dir "$install_dir" "$@"
