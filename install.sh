#!/usr/bin/env bash
# Public HTTPS bootstrap. Resolve once, then fetch only immutable commit URLs.
set -Eeuo pipefail
umask 077
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '%s\n' '用法：bash install.sh [start.sh 安装参数 ...]' \
    '默认主机角色；从 GitHub 下载固定提交，配置默认位于 ~/.local/share/cpa-dr/deployments/primary。' \
    '版本：CPA_GITHUB_REF=main|提交SHA|标签；须预装 Bash、curl 和系统 CA 证书。' \
    '非交互示例：bash install.sh --deployment docker --data-dir TARGET --yes'
  exit 0
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
file=$(mktemp)
trap 'rm -f -- "$file"' EXIT
curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --retry 2 \
  "https://raw.githubusercontent.com/$repository/$commit/cpa-dr/scripts/packaging/github.sh" -o "$file"
bash "$file" "$repository" "$commit" "$@"
