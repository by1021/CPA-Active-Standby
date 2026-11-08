#!/usr/bin/env bash
# Shared HTTPS source fetcher, also embedded into the standby invitation command.
# The public loader fetches this helper from the same fixed commit.
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]%/*}/location.sh ]]; then
  # shellcheck source=location.sh
  source "${BASH_SOURCE[0]%/*}/location.sh"
fi
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
  local cwd
  cwd=$(pwd -P) || return 1
  local repository=${1:?repository required} commit=${2:?commit required}
  shift 2
  cpa_github_identity "$repository" "$commit" || return 1
  local yes=0 no_install=0 project="$cwd/cpa-dr" config='' argument mode='' source_dir temp version generate=0
  local -a forwarded=()
  while (($#)); do
    case $1 in
      --install-dir) [[ $# -ge 2 && -n $2 ]] || { cpa_github_fail '--install-dir 缺少值'; return 1; }; project=$2; shift 2;;
      --output) [[ $# -ge 2 && -n $2 ]] || return 1; config=$2; forwarded+=("$1" "$2"); shift 2;;
      --deployment) [[ $# -ge 2 && -n $2 ]] || return 1; mode=$2; forwarded+=("$1" "$2"); shift 2;;
      --yes) yes=1; forwarded+=("$1"); shift;;
      --no-install-deps) no_install=1; forwarded+=("$1"); shift;;
      --generate-backup) generate=1; forwarded+=("$1"); shift;;
      *) forwarded+=("$1"); shift;;
    esac
  done
  [[ $project == /* ]] || project="$cwd/$project"
  [[ -z $config || $config == /* ]] || config="$cwd/$config"
  # Independently protect direct/embedded helper callers before dependency
  # installation. Explicit config and a stable association outrank HOME scans.
  local candidate cursor
  local -a probe=("$project")
  if [[ ! -e $project/install.json && ! -L $project/install.json ]]; then
    if [[ -n $config ]]; then probe+=("$config")
    else probe+=("$HOME/.local/share/cpa-dr/deployments/primary" /etc/cpa-dr-native); fi
  fi
  for candidate in "${probe[@]}"; do
    cpa_location_path "$candidate" || { cpa_github_fail "候选路径含链接或异常，状态未知：$candidate"; return 1; }
    cursor=$candidate
    while :; do
      if [[ -d $cursor && ! -x $cursor ]]; then
        cpa_github_fail "已知部署路径祖先目录权限不足，状态未知：$cursor"; return 1
      fi
      [[ ! -e $cursor || -d $cursor ]] || { cpa_github_fail "已知部署路径不是目录，状态未知：$cursor"; return 1; }
      [[ $cursor != / ]] || break
      cursor=${cursor%/*}; cursor=${cursor:-/}
    done
  done
  cpa_github_dependencies "$yes" "$no_install" || return 1
  project=$(realpath -m -- "$project")
  [[ -z $config ]] || config=$(realpath -m -- "$config")
  cpa_location_path "$project" || { cpa_github_fail '项目路径含链接或异常'; return 1; }
  if [[ -e $project/install.json || -L $project/install.json ]]; then
    cpa_location_launch "$project" --bootstrap-existing "${forwarded[@]}"
    return
  fi
  local record old_source candidates=0
  local -a found=()
  if [[ -n $config ]]; then found=("$config")
  else found=("$HOME/.local/share/cpa-dr/deployments/primary" /etc/cpa-dr-native); fi
  for candidate in "${found[@]}"; do
    if [[ -e $candidate/.env.docker.json || -L $candidate/.env.docker.json || -e $candidate/.env.native.json || -L $candidate/.env.native.json ]]; then
      record=$(cpa_location_deployment "$candidate") || { cpa_github_fail "已有部署记录异常：$candidate"; return 1; }
      [[ -z $mode || $(jq -r .deployment "$record") == "$mode" ]] || continue
      old_source=$(jq -r .source_root "$record")
      cpa_location_trusted "$old_source/start.sh" && cpa_location_manifest "$old_source" || { cpa_github_fail '已有源码校验失败'; return 1; }
      ((candidates+=1)); config=$candidate; source_dir=$old_source
    fi
  done
  ((candidates <= 1)) || { cpa_github_fail '检测到多份已有部署，请指定 --output'; return 1; }
  if ((candidates)); then
    cpa_location_register "$project" "$source_dir" "$config" "$cwd" || return 1
    if ((generate)); then cpa_location_launch "$project" --bootstrap-existing "${forwarded[@]}"; return; fi
    cpa_location_launch "$project" status
    return
  fi
  if [[ -d $project && ! -f $project/.cpa-dr-project ]]; then
    [[ -z $(find "$project" -mindepth 1 -maxdepth 1 -print -quit) ]] || { cpa_github_fail '项目目录已有其他文件，未覆盖'; return 1; }
  fi
  cpa_location_project_file "$project/.cpa-dr-project" && cpa_location_project_file "$project/.install.lock" || return 1
  mkdir -p "$project/releases"; chmod 700 "$project"
  cpa_location_project_marker "$project" || return 1
  exec {github_lock}>>"$project/.install.lock"
  flock -n "$github_lock" || { cpa_github_fail '该项目安装正在执行'; return 1; }
  temp=$(mktemp -d)
  trap 'rm -rf -- "$temp"' EXIT
  cpa_github_bundle "$repository" "$commit" "$temp/bundle.tar" > "$temp/metadata.json"
  mkdir "$temp/check"
  tar --no-same-owner -xf "$temp/bundle.tar" -C "$temp/check"
  # shellcheck source=bootstrap.sh
  source "$temp/check/cpa-dr/scripts/packaging/bootstrap.sh"
  version=$(jq -r .version "$temp/metadata.json")
  cpa_bootstrap_check_archive "$temp/bundle.tar" && cpa_bootstrap_manifest "$temp/check/cpa-dr" "$version" || return 1
  source_dir="$project/releases/$commit"
  cpa_location_path "$source_dir" || return 1
  if [[ -e $source_dir ]]; then
    cpa_bootstrap_manifest "$source_dir/cpa-dr" "$version" || { cpa_github_fail '持久源码校验失败，原配置与数据保留'; return 1; }
  else
    local stage
    stage=$(mktemp -d "$project/releases/.stage.XXXXXXXX")
    cp -a "$temp/check/cpa-dr" "$stage/"
    mv -T "$stage" "$source_dir"
  fi
  config=${config:-$project/config}
  local -a args=(install --role primary --output "$config")
  local skip=0
  for argument in "${forwarded[@]}"; do
    if ((skip)); then skip=0; continue; fi
    if [[ $argument == --output ]]; then skip=1; continue; fi
    args+=("$argument")
  done
  printf 'GitHub 提交：\n%s\n持久源码：%s/cpa-dr\n' "$commit" "$source_dir"
  (exec {github_lock}>&-; bash "$source_dir/cpa-dr/start.sh" "${args[@]}")
  if [[ -e $project/install.json ]]; then cpa_location_read "$project" >/dev/null; return; fi
  cpa_location_register "$project" "$source_dir/cpa-dr" "$config" "$cwd"
)
if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then cpa_github_main "$@"; fi
