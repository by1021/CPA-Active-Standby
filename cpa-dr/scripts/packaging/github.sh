#!/usr/bin/env bash
# Shared HTTPS source fetcher, also embedded into the standby invitation command.
cpa_github_fail() { printf 'GitHub 安装失败：%s\n' "$*" >&2; return 1; }
cpa_github_identity() {
  [[ $1 == by1021/CPA-Active-Standby && $2 =~ ^[a-f0-9]{40}$ ]] || { cpa_github_fail '仓库或固定提交无效'; return 1; }
}
cpa_github_dependencies() {
  local tool missing=0 answer allow=${1:-0} no_install=${2:-0}
  for tool in jq curl tar gzip sha256sum realpath flock find install; do command -v "$tool" >/dev/null || missing=1; done
  ((missing)) || return 0
  printf '安装下载/校验依赖：curl、CA 证书、jq、tar、gzip、coreutils、util-linux、findutils（现有系统软件源）。\n' >&2
  ((no_install == 0)) || { cpa_github_fail '已禁用依赖安装，请预装下载/校验工具'; return 1; }
  if ((allow == 0)); then
    [[ -t 0 ]] || { cpa_github_fail '非交互补齐引导依赖需指定 --yes'; return 1; }
    read -r -p '确认安装下载/校验依赖？[y/N] ' answer || return 1
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || { cpa_github_fail '已取消依赖安装'; return 1; }
  fi
  local -a privilege=()
  if ((EUID != 0)); then command -v sudo >/dev/null || { cpa_github_fail '依赖安装需要 root/sudo'; return 1; }; privilege=(sudo --); fi
  if command -v apt-get >/dev/null; then
    "${privilege[@]}" apt-get update && "${privilege[@]}" apt-get install -y --no-install-recommends curl ca-certificates jq tar gzip coreutils util-linux findutils || return 1
  elif command -v dnf >/dev/null; then "${privilege[@]}" dnf install -y curl ca-certificates jq tar gzip coreutils util-linux findutils || return 1
  elif command -v yum >/dev/null; then "${privilege[@]}" yum install -y curl ca-certificates jq tar gzip coreutils util-linux findutils || return 1
  else cpa_github_fail '未找到 apt-get/dnf/yum'; return 1; fi
  for tool in jq curl tar gzip sha256sum realpath flock find install; do command -v "$tool" >/dev/null || return 1; done
}
cpa_github_bundle() (
  set -Eeuo pipefail
  umask 077
  local repository=$1 commit=$2 dest=$3 temp prefix name normalized kind count=0
  local -A seen=()
  cpa_github_identity "$repository" "$commit" || return 1
  [[ ! -e $dest && ! -L $dest ]] || { cpa_github_fail '安装包目标已存在'; return 1; }
  temp=$(mktemp -d)
  trap 'rm -rf -- "$temp"' EXIT
  prefix="${repository#*/}-$commit"
  printf '从 GitHub 下载固定提交：%s\n' "$commit" >&2
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 300 --retry 2 --max-filesize 209715200 \
    "https://codeload.github.com/$repository/tar.gz/$commit" -o "$temp/source.tar.gz" || { cpa_github_fail '源码下载失败'; return 1; }
  [[ $(stat -c %s "$temp/source.tar.gz") -le 209715200 ]] || return 1
  # Select exact members before extraction: do not recurse into unchecked dirs.
  tar -tzf "$temp/source.tar.gz" > "$temp/members" || return 1
  : > "$temp/selected"
  while IFS= read -r name; do
    case $name in
      "$prefix/cpa-dr/bin"*|"$prefix/cpa-dr/lib"*|"$prefix/cpa-dr/cgi"*|"$prefix/cpa-dr/www"*|"$prefix/cpa-dr/scripts"*|"$prefix/cpa-dr/deploy"*|"$prefix/cpa-dr/start.sh"|"$prefix/cpa-dr/.dockerignore") ;;
      *) continue;;
    esac
    normalized=${name%/}
    [[ $normalized =~ ^$prefix/cpa-dr/((bin|lib|cgi|www|scripts|deploy)(/[A-Za-z0-9_.+-]+)*|start\.sh|\.dockerignore)$ && ! /$normalized/ =~ /(\.|\.\.)/ ]] || { cpa_github_fail '源码归档路径异常'; return 1; }
    [[ -z ${seen[$normalized]:-} ]] || { cpa_github_fail '源码归档包含重复路径'; return 1; }
    seen[$normalized]=1; ((count+=1))
    printf '%s\n' "$name" >> "$temp/selected"
  done < "$temp/members"
  ((count > 1 && count <= 4096)) || { cpa_github_fail '源码归档成员数量异常'; return 1; }
  tar --no-recursion --numeric-owner -tvzf "$temp/source.tar.gz" -T "$temp/selected" > "$temp/types" || return 1
  while IFS= read -r kind; do
    [[ ${kind:0:1} == - || ${kind:0:1} == d ]] || { cpa_github_fail '源码归档包含链接或特殊文件'; return 1; }
  done < "$temp/types"
  mkdir "$temp/source"
  tar --no-recursion --no-same-owner --no-same-permissions --strip-components=1 -xzf "$temp/source.tar.gz" -C "$temp/source" -T "$temp/selected" || return 1
  local service="$temp/source/cpa-dr" file
  # GitHub compatibility symlinks are not extracted; materialize known templates.
  for file in Dockerfile compose.yaml .env.example; do cp -p -- "$service/deploy/$file" "$service/$file" || return 1; done
  jq -cn --arg repository "$repository" --arg commit "$commit" '{format_version:1,repository:$repository,commit:$commit}' > "$service/scripts/packaging/github-source.json"
  bash "$service/scripts/packaging/build-install-bundle.sh" "$service" "$dest"
)
cpa_github_main() (
  set -Eeuo pipefail
  umask 077
  local repository=${1:?repository required} commit=${2:?commit required}
  shift 2
  cpa_github_identity "$repository" "$commit" || return 1
  local yes=0 no_install=0 argument
  for argument in "$@"; do
    case $argument in --yes) yes=1;; --no-install-deps) no_install=1;; esac
  done
  cpa_github_dependencies "$yes" "$no_install" || return 1
  local base="$HOME/.local/share/cpa-dr" source_dir temp version output=0 item
  # Reuse the proven archive/manifest and private-path checks from this commit.
  temp=$(mktemp -d)
  trap 'rm -rf -- "$temp"' EXIT
  cpa_github_bundle "$repository" "$commit" "$temp/bundle.tar" > "$temp/metadata.json"
  mkdir "$temp/check"
  tar --no-same-owner -xf "$temp/bundle.tar" -C "$temp/check"
  source "$temp/check/cpa-dr/scripts/packaging/bootstrap.sh"
  version=$(jq -r .version "$temp/metadata.json")
  cpa_bootstrap_check_archive "$temp/bundle.tar" && cpa_bootstrap_manifest "$temp/check/cpa-dr" "$version" || return 1
  cpa_bootstrap_private_path "$base" || { cpa_github_fail '本机源码路径异常'; return 1; }
  mkdir -p "$base/github" "$base/deployments"
  source_dir="$base/github/$commit"
  cpa_bootstrap_private_path "$source_dir" || return 1
  exec {github_lock}>"$base/github/$commit.lock"
  flock -n "$github_lock" || { cpa_github_fail '同一版本安装正在执行'; return 1; }
  if [[ -e $source_dir ]]; then
    cpa_bootstrap_manifest "$source_dir/cpa-dr" "$version" || { cpa_github_fail '持久源码校验失败，原配置与数据保留'; return 1; }
  else
    local stage
    stage=$(mktemp -d "$base/github/.stage.XXXXXXXX")
    cp -a "$temp/check/cpa-dr" "$stage/"
    mv -T "$stage" "$source_dir"
  fi
  for item in "$@"; do [[ $item != --output ]] || output=1; done
  local -a args=(install --role primary)
  ((output)) || args+=(--output "$base/deployments/primary")
  printf 'GitHub 提交：\n%s\n持久源码：%s/cpa-dr\n' "$commit" "$source_dir"
  # Long-lived native services must not retain the installer lock descriptor.
  (exec {github_lock}>&-; bash "$source_dir/cpa-dr/start.sh" "${args[@]}" "$@")
)
if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then cpa_github_main "$@"; fi
