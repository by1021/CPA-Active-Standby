#!/usr/bin/env bash
# Sourced by start.sh. Use only the host's configured package repositories.
cpa_start_missing_dependencies() {
  local mode=${1:-docker} tool help
  local -a required=(dirname realpath stat cat mkdir chmod flock jq sha256sum mktemp sync mv rm timeout)
  if [[ $mode != uninstall-* ]]; then required+=(touch openssl ssh-keygen); fi
  case $mode in
    docker) required+=(docker curl);;
    uninstall-docker) required+=(docker);;
    native) required+=(od tr date find grep sed awk tar rsync sqlite3 curl nginx spawn-fcgi fcgiwrap sshd systemctl cp install getent);;
    uninstall-native) required+=(systemctl);;
    *) fail "未知依赖检查模式：$mode";;
  esac
  CPA_START_MISSING=()
  for tool in "${required[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || CPA_START_MISSING+=("$tool")
  done
  [[ $mode == docker || $mode == uninstall-docker ]] || return 0
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    CPA_START_MISSING+=(docker-compose-v2)
  elif [[ $mode == docker ]] && { ! help=$(docker compose up --help 2>/dev/null) ||
       [[ ! $help =~ (^|[[:space:]])--wait([[:space:]]|$) || ! $help =~ (^|[[:space:]])--wait-timeout([[:space:]]|$) ]]; }; then
    CPA_START_MISSING+=(docker-compose-v2)
  fi
}

cpa_start_compose_package_version() {
  local version=${1#*:}
  [[ $version =~ ^([0-9]+)\. ]] && ((10#${BASH_REMATCH[1]} >= 2))
}

cpa_start_repository_package() {
  local manager=$1 package policy line listing name version rest
  shift
  for package in "$@"; do
    if [[ $manager == apt-get ]]; then
      policy=$(LC_ALL=C apt-cache policy "$package") || return 1
      while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*Candidate:[[:space:]]+([^[:space:]]+) && ${BASH_REMATCH[1]} != '(none)' ]]; then
          version=${BASH_REMATCH[1]}
          if [[ $package == docker-compose ]]; then cpa_start_compose_package_version "$version" || continue; fi
          printf '%s\n' "$package"; return 0
        fi
      done <<< "$policy"
    elif listing=$("$manager" -q list --available "$package" 2>/dev/null); then
      if [[ $package == docker-compose ]]; then
        while read -r name version rest; do
          if [[ $name == docker-compose.* ]] && cpa_start_compose_package_version "$version"; then
            printf '%s\n' "$package"; return 0
          fi
        done <<< "$listing"
      else
        printf '%s\n' "$package"; return 0
      fi
    fi
  done
  return 1
}

cpa_start_ensure_dependencies() {
  local install_deps=$1 assume_yes=$2 mode=${3:-docker} manager='' answer='' tool package dependencies cli_package
  local -a privilege=() packages=() candidates=()
  cpa_start_missing_dependencies "$mode"
  ((${#CPA_START_MISSING[@]} > 0)) || return 0
  printf '检测到缺少依赖或需要升级：%s\n' "${CPA_START_MISSING[*]}" >&2
  ((install_deps == 1)) || fail '已禁用依赖安装；请先安装上述依赖后重跑'
  for manager in apt-get dnf yum; do
    command -v "$manager" >/dev/null 2>&1 && break
    manager=''
  done
  [[ -n $manager ]] || fail '未找到支持的包管理器（apt-get/dnf/yum）；请按 README 安装缺失依赖'
  if ((assume_yes == 0)); then
    [[ -t 0 ]] || fail '非交互运行不自动安装依赖；确认后使用 --yes，或预装依赖'
    printf '将使用 %s 从现有软件源安装上述缺失依赖（需要 root 或 sudo 权限）。\n' "$manager" >&2
    read -r -p '是否安装并继续启动？[y/N] ' answer || fail '未读取到安装确认，未安装依赖'
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || fail '已取消依赖安装'
  fi
  if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 || fail '安装依赖需要 root 或 sudo；当前用户缺少 sudo，请由管理员安装依赖后重跑'
    privilege=(sudo --)
  fi
  if [[ $manager == apt-get ]]; then
    command -v apt-cache >/dev/null 2>&1 || fail '缺少 apt-cache，请修复宿主 apt 工具后重跑'
    printf '正在刷新软件包索引……\n' >&2
    "${privilege[@]}" apt-get update || fail '刷新软件包索引失败；请检查软件源、网络或安装权限后重跑'
  fi
  for tool in "${CPA_START_MISSING[@]}"; do
    case $tool in
      dirname|realpath|stat|cat|mkdir|chmod|touch|sha256sum|mktemp|sync|mv|rm|timeout|od|tr|date|cp|install) package=coreutils;;
      openssl|jq|grep|sed|tar|rsync|curl|nginx|spawn-fcgi|fcgiwrap) package=$tool;;
      ssh-keygen) package=openssh-client; [[ $manager == apt-get ]] || package=openssh-clients;;
      sshd) package=openssh-server;;
      systemctl) package=systemd;;
      find) package=findutils;;
      awk) package=gawk;;
      sqlite3) package=sqlite3; [[ $manager == apt-get ]] || package=sqlite;;
      getent) package=libc-bin; [[ $manager == apt-get ]] || package=glibc-common;;
      flock) package=util-linux;;
      docker|docker-compose-v2)
        if [[ $tool == docker ]]; then
          candidates=(docker.io docker-ce)
          [[ $manager == apt-get ]] || candidates=(docker-ce moby-engine docker)
        else
          candidates=(docker-compose-v2 docker-compose-plugin docker-compose)
          [[ $manager == apt-get ]] || candidates=(docker-compose-plugin docker-compose)
        fi
        package=$(cpa_start_repository_package "$manager" "${candidates[@]}") || fail "现有软件源没有可安装的 $tool 包；请配置对应发行版的软件源或预装后重跑"
        ;;
      *) fail "缺少依赖的包映射：$tool";;
    esac
    [[ " ${packages[*]} " == *" $package "* ]] || packages+=("$package")
    if [[ $manager == apt-get && $package == docker.io ]]; then
      # Debian splits /usr/bin/docker into a recommended package, not a dependency.
      dependencies=$(LC_ALL=C apt-cache depends docker.io) || fail '读取 docker.io 软件包依赖失败；请检查 apt 软件源后重跑'
      if [[ $dependencies =~ (Depends|Recommends):[[:space:]]+docker-cli([[:space:]]|$) ]]; then
        cli_package=$(cpa_start_repository_package "$manager" docker-cli) || fail 'docker.io 需要独立的 docker-cli 包，但现有软件源没有可安装版本'
        [[ " ${packages[*]} " == *" $cli_package "* ]] || packages+=("$cli_package")
      fi
    fi
  done
  printf '正在安装缺失依赖的软件包：%s\n' "${packages[*]}" >&2
  if [[ $manager == apt-get ]]; then
    "${privilege[@]}" apt-get install -y --no-install-recommends "${packages[@]}" || fail '依赖安装失败；请检查上方包管理器错误后重跑'
  else
    "${privilege[@]}" "$manager" install -y "${packages[@]}" || fail '依赖安装失败；请检查上方包管理器错误后重跑'
  fi
  hash -r
  cpa_start_missing_dependencies "$mode"
  ((${#CPA_START_MISSING[@]} == 0)) || fail "安装后复检仍缺少依赖或 Compose 等待能力：${CPA_START_MISSING[*]}；请检查软件包版本和 PATH 后重跑"
  printf '依赖安装完成，复检通过，继续启动。\n' >&2
}
