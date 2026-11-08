#!/usr/bin/env bash
# Self-contained, dependency-bounded installer bootstrap; invitation JSON is data.
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]%/*}/location.sh ]]; then
  # shellcheck source=location.sh
  source "${BASH_SOURCE[0]%/*}/location.sh"
fi
cpa_bootstrap_fail() { printf '安装引导失败：%s\n' "$*" >&2; return 1; }
cpa_bootstrap_private_path() {
  local path=$1 cursor
  [[ $path == /* && $path != / && ! $path =~ [[:cntrl:]] ]] || return 1
  cursor=$path
  while [[ $cursor != / ]]; do [[ ! -L $cursor ]] || return 1; cursor=${cursor%/*}; cursor=${cursor:-/}; done
}
cpa_bootstrap_check_archive() {
  local archive=$1 name normalized kind count=0
  local -A seen=()
  while IFS= read -r name; do
    normalized=${name%/}
    [[ $name =~ ^cpa-dr(/[A-Za-z0-9_.+-]+)*/?$ && ! /$normalized/ =~ /(\.|\.\.)/ ]] || { cpa_bootstrap_fail '安装包路径异常'; return 1; }
    [[ -z ${seen[$normalized]:-} ]] || { cpa_bootstrap_fail '安装包包含重复路径'; return 1; }
    seen[$normalized]=1; ((count+=1))
  done < <(tar -tf "$archive")
  ((count > 1 && count <= 4096)) || { cpa_bootstrap_fail '安装包成员数量异常'; return 1; }
  # GNU tar prints file type first. Reject links, devices, fifos and extensions.
  while IFS= read -r kind; do
    [[ ${kind:0:1} == - || ${kind:0:1} == d ]] || { cpa_bootstrap_fail '安装包包含链接或特殊文件'; return 1; }
  done < <(tar --numeric-owner -tvf "$archive")
  tar -tf "$archive" >/dev/null && tar -tvf "$archive" >/dev/null
}
cpa_bootstrap_manifest() {
  local service=$1 expected=$2 manifest="$1/install-manifest.json" file hash count=0 actual
  [[ -f $manifest && ! -L $manifest ]] || return 1
  jq -e --arg version "$expected" '.format_version==1 and .protocol_version==1 and .version==$version and (.files|type=="array" and length>0 and length<=4096) and ([.files[].path]|length==(unique|length))' "$manifest" >/dev/null || return 1
  while IFS=$'\t' read -r file hash; do
    [[ $file =~ ^[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*$ && $file != ../* && $file != *'/../'* && $file != */.. && $hash =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ -f $service/$file && ! -L $service/$file ]] || return 1
    actual=$(sha256sum -- "$service/$file"); [[ ${actual:0:64} == "$hash" ]] || return 1
    ((count+=1))
  done < <(jq -r '.files[]|[.path,.sha256]|@tsv' "$manifest")
  [[ $(find "$service" -type f | wc -l) -eq $((count+1)) && -z $(find "$service" -type l -print -quit) ]]
}
cpa_bootstrap_dependencies() {
  local tool missing=0
  for tool in jq ssh ssh-keygen tar timeout flock sha256sum curl gzip find; do command -v "$tool" >/dev/null || missing=1; done
  ((missing)) || return 0
  printf '安装引导依赖：jq、OpenSSH 客户端、tar、coreutils、util-linux；使用现有系统软件源。\n'
  local -a privilege=()
  if ((EUID != 0)); then command -v sudo >/dev/null || { cpa_bootstrap_fail '缺少 sudo，请用 root 执行'; return 1; }; privilege=(sudo --); fi
  if command -v apt-get >/dev/null; then
    "${privilege[@]}" apt-get update && "${privilege[@]}" apt-get install -y --no-install-recommends jq openssh-client tar coreutils util-linux curl ca-certificates gzip findutils
  elif command -v dnf >/dev/null; then "${privilege[@]}" dnf install -y jq openssh-clients tar coreutils util-linux curl ca-certificates gzip findutils
  elif command -v yum >/dev/null; then "${privilege[@]}" yum install -y jq openssh-clients tar coreutils util-linux curl ca-certificates gzip findutils
  else cpa_bootstrap_fail '未找到 apt-get/dnf/yum'; return 1; fi
  for tool in jq ssh ssh-keygen tar timeout flock sha256sum curl gzip find; do command -v "$tool" >/dev/null || return 1; done
}
cpa_bootstrap_main() {
  set -Eeuo pipefail
  umask 077
  local cwd
  cwd=$(pwd -P) || return 1
  [[ $# == 1 && $1 =~ ^[A-Za-z0-9+/=]+$ ]] || { cpa_bootstrap_fail '邀请编码异常'; return 1; }
  cpa_bootstrap_dependencies || return 1
  local base="$HOME/.local/share/cpa-dr" incoming id private source_dir invite_file host port key version expected scan output stage endpoint
  cpa_bootstrap_private_path "$base" || { cpa_bootstrap_fail '本机引导路径含链接或异常'; return 1; }
  mkdir -p -- "$base/enrollment" "$base/sources" "$base/deployments"
  chmod 700 "$base" "$base/enrollment" "$base/sources" "$base/deployments"
  incoming=$(mktemp "$base/enrollment/.incoming.XXXXXXXX")
  printf '%s' "$1" | base64 -d > "$incoming" || { rm -f "$incoming"; return 1; }
  jq -e '.version==1 and (.invite_id|type=="string" and test("^[A-Za-z0-9_-]{1,96}$")) and (.bundle.sha256|test("^[a-f0-9]{64}$")) and (.bundle.version|type=="string")' "$incoming" >/dev/null || { rm -f "$incoming"; cpa_bootstrap_fail '邀请结构异常'; return 1; }
  id=$(jq -r .invite_id "$incoming"); private="$base/enrollment/$id"; source_dir="$base/sources/$id"
  cpa_bootstrap_private_path "$private" && cpa_bootstrap_private_path "$source_dir" || { rm -f "$incoming"; return 1; }
  mkdir -p -- "$private"; chmod 700 "$private"
  exec {bootstrap_lock}>"$private/bootstrap.lock"
  flock -n "$bootstrap_lock" || { rm -f "$incoming"; cpa_bootstrap_fail '同一安装邀请正在执行'; return 1; }
  invite_file="$private/invite.json"
  if [[ -f $invite_file ]]; then
    [[ ! -L $invite_file ]] || return 1
    jq -e --slurpfile prior "$invite_file" 'del(.temporary_private_key)==($prior[0]|del(.temporary_private_key))' "$incoming" >/dev/null || { rm -f "$incoming"; cpa_bootstrap_fail '邀请与本机原安装进度冲突'; return 1; }
  fi
  mv -fT "$incoming" "$invite_file"; chmod 600 "$invite_file"
  version=$(jq -r .bundle.version "$invite_file"); expected=$(jq -r .bundle.sha256 "$invite_file")
  local project="$cwd/cpa-dr" config='' location="$private/location.json" release
  release=$(jq -r '.bundle.source.commit//.bundle.version' "$invite_file")
  [[ $release =~ ^[a-f0-9]{40}$ || $release =~ ^[a-f0-9]{64}$ ]] || { cpa_bootstrap_fail '固定版本格式异常'; return 1; }
  if [[ -e $location || -L $location ]]; then
    cpa_location_trusted "$location" || { cpa_bootstrap_fail '安装位置记录异常'; return 1; }
    jq -e --arg id "$id" '.invite_id==$id and ([.project_dir,.source_dir,.config_dir]|all(type=="string" and startswith("/")))' "$location" >/dev/null || return 1
    project=$(jq -r .project_dir "$location"); source_dir=$(jq -r .source_dir "$location"); config=$(jq -r .config_dir "$location")
  elif [[ -d $source_dir ]]; then
    config=$(jq -r '.backup.output//empty' "$invite_file")
    if [[ -z $config ]]; then
      [[ $(jq -r .backup.deployment "$invite_file") != native ]] || config=/etc/cpa-dr-native
      config=${config:-$base/deployments/$id}
    fi
  else
    cpa_location_path "$project" || return 1
    if [[ -e $project/install.json || -L $project/install.json ]]; then
      cpa_location_read "$project" >/dev/null || return 1
      jq -e --arg id "$id" '.invite_id==$id' "$project/install.json" >/dev/null || { cpa_bootstrap_fail '当前目录项目已关联其他安装'; return 1; }
    elif [[ -d $project && ! -f $project/.cpa-dr-project && -n $(find "$project" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
      cpa_bootstrap_fail '当前项目目录已有其他文件，未覆盖'; return 1
    fi
    cpa_location_project_file "$project/.cpa-dr-project" || return 1
    mkdir -p "$project/releases"; chmod 700 "$project"
    cpa_location_project_marker "$project" || return 1
    source_dir="$project/releases/$release"
    config=$(jq -r '.backup.output//empty' "$invite_file")
    if [[ -z $config ]]; then
      [[ $(jq -r .backup.deployment "$invite_file") != native ]] || config=/etc/cpa-dr-native
      config=${config:-$project/config}
    fi
  fi
  cpa_location_path "$project" && cpa_location_path "$source_dir" && cpa_location_path "$config" || return 1
  # Completed invitations have revoked temporary credentials. Resume from the
  # durable verified source BEFORE attempting another temporary SSH connection.
  if [[ -d $source_dir ]]; then
    [[ -f $source_dir/.bootstrap-id && ! -L $source_dir/.bootstrap-id && $(cat "$source_dir/.bootstrap-id") == "$id" ]] || { cpa_bootstrap_fail '源码目录不属于此邀请'; return 1; }
    cpa_bootstrap_manifest "$source_dir/cpa-dr" "$version" || { cpa_bootstrap_fail '持久源码校验失败'; return 1; }
  else
    if jq -e '.bundle.source!=null' "$invite_file" >/dev/null; then
      local repository commit metadata
      repository=$(jq -r .bundle.source.repository "$invite_file"); commit=$(jq -r .bundle.source.commit "$invite_file")
      [[ $(jq -r .bundle.source.format_version "$invite_file") == 1 ]] || return 1
      declare -F cpa_github_bundle >/dev/null || { cpa_bootstrap_fail '缺少 GitHub 下载器'; return 1; }
      rm -f "$private/bundle.tar"
      metadata=$(cpa_github_bundle "$repository" "$commit" "$private/bundle.tar") || { cpa_bootstrap_fail 'GitHub 安装包下载失败；进度保留，不切换来源'; return 1; }
      [[ $(jq -r .version <<< "$metadata") == "$version" && $(jq -r .sha256 <<< "$metadata") == "$expected" ]] || { cpa_bootstrap_fail 'GitHub 安装包版本或摘要与主机不符'; return 1; }
    else
    host=$(jq -r .primary.host "$invite_file"); port=$(jq -r .primary.port "$invite_file")
    [[ $host =~ ^[A-Za-z0-9:][A-Za-z0-9_.:-]{0,252}$ && $port =~ ^[0-9]{1,5}$ ]] && ((10#$port > 0 && 10#$port <= 65535)) || return 1
    key=$(jq -r .primary.host_key "$invite_file"); [[ $key =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || return 1
    scan="$private/known_hosts"; endpoint=$host; [[ $port == 22 ]] || endpoint="[$host]:$port"; printf '%s %s\n' "$endpoint" "$key" > "$scan"
    jq -r .temporary_private_key "$invite_file" > "$private/key"; chmod 600 "$private/key" "$scan"
    ssh-keygen -y -f "$private/key" >/dev/null || return 1
    printf '获取已固定版本的安装包；主机指纹与摘要均来自本次邀请。\n'
    timeout 300 ssh -T -oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes -oConnectTimeout=10 -o "UserKnownHostsFile=$scan" -i "$private/key" -p "$port" "root@$host" "enroll $id bundle" | head -c 209715201 > "$private/bundle.tar" || { cpa_bootstrap_fail '主机连接或邀请验证失败；本机进度已保留'; return 1; }
    fi
    [[ $(stat -c %s "$private/bundle.tar") -le 209715200 ]] || return 1
    output=$(sha256sum "$private/bundle.tar"); [[ ${output:0:64} == "$expected" ]] || { cpa_bootstrap_fail '安装包摘要不符'; return 1; }
    cpa_bootstrap_check_archive "$private/bundle.tar" || return 1
    mkdir -p "${source_dir%/*}"
    stage=$(mktemp -d "${source_dir%/*}/.stage-$id.XXXXXXXX")
    tar --no-same-owner -xf "$private/bundle.tar" -C "$stage" || { rm -rf -- "$stage"; return 1; }
    cpa_bootstrap_manifest "$stage/cpa-dr" "$version" || { rm -rf -- "$stage"; cpa_bootstrap_fail '安装包清单校验失败'; return 1; }
    printf '%s\n' "$id" > "$stage/.bootstrap-id"
    mv -T "$stage" "$source_dir"
    rm -f "$private/bundle.tar" "$private/key"
  fi
  # Keep the lock in this bootstrap only. Native service children must not
  # inherit it, or a finished installation prevents the next resumable run.
  if [[ ! -e $location ]]; then
    jq -n --arg id "$id" --arg project "$project" --arg source "$source_dir" --arg config "$config" '{invite_id:$id,project_dir:$project,source_dir:$source,config_dir:$config}' | cpa_location_write "$location" 600 || return 1
  fi
  (exec {bootstrap_lock}>&-; bash "$source_dir/cpa-dr/start.sh" join --invite-file "$invite_file" --output "$config" --yes)
  if [[ -e $project/install.json ]]; then
    cpa_location_read "$project" >/dev/null || return 1
    if jq -e --arg id "$id" '.invite_id==$id' "$project/install.json" >/dev/null; then
      printf '已有项目入口：bash %q menu；未改动入口或部署配置。\n' "$project/start.sh"
      return 0
    fi
  fi
  cpa_location_register "$project" "$source_dir/cpa-dr" "$config" "$cwd" "$id"
}
if [[ ${CPA_BOOTSTRAP_EMBEDDED:-0} == 1 || ${BASH_SOURCE[0]:-} == "$0" ]]; then cpa_bootstrap_main "$@"; fi
