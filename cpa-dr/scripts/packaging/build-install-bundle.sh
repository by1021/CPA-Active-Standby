#!/usr/bin/env bash
# Produce an immutable source-only installation archive. Never include state.
set -Eeuo pipefail
umask 077
SOURCE=${1:?service source directory required}
DEST=${2:?archive destination required}
SOURCE=$(realpath -e -- "$SOURCE")
[[ -d $SOURCE && ! -L $DEST && ! -e $DEST ]] || { echo '安装包来源或目标无效' >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir "$TMP/cpa-dr"
for directory in bin lib cgi www scripts deploy; do
  [[ -d $SOURCE/$directory && ! -L $SOURCE/$directory ]] || { [[ $directory == deploy ]] && continue; echo "安装包缺少源码目录：$directory" >&2; exit 1; }
  while IFS= read -r -d '' path; do
    relative=${path#"$SOURCE/"}
    [[ ! $relative =~ [[:cntrl:]] && $relative != *\\* && ! -L $path && ( -d $path || -f $path ) ]] || { echo '安装包源码含链接或特殊文件' >&2; exit 1; }
    case ${relative##*/} in .env|.env.*|*.pem|*.key|*.log|id_ed25519|id_rsa) [[ ${relative##*/} == .env.example ]] || { echo '安装包源码含秘密或运行数据' >&2; exit 1; };; esac
    if [[ -f $path ]]; then
      case $relative in
        bin/cpa-dr|bin/cpa-dr-rpc|bin/cpa-dr-enroll-rpc|bin/cpa-dr-ssh-dispatch|lib/*.sh|cgi/*.cgi|scripts/*.sh|scripts/packaging/github-source.json|www/*.html|www/*.css|www/*.js|www/*.svg|www/*.png|www/*.jpg|www/*.woff2|deploy/Dockerfile|deploy/compose.yaml|deploy/.env.example) ;;
        *) echo "安装包白名单之外的文件：$relative" >&2; exit 1;;
      esac
    fi
    if [[ -d $path ]]; then mkdir -p -- "$TMP/cpa-dr/$relative"
    else
      # GitHub, Docker chmod and native installation must produce identical bytes.
      mode=644
      case $relative in bin/*|cgi/*.cgi|scripts/*.sh) mode=755;; esac
      install -m "$mode" -- "$path" "$TMP/cpa-dr/$relative"
    fi
  done < <(find -P "$SOURCE/$directory" -print0)
done
for name in start.sh Dockerfile compose.yaml .env.example .dockerignore; do
  [[ -f $SOURCE/$name ]] || { echo "安装包缺少源码文件：$name" >&2; exit 1; }
  if [[ -L $SOURCE/$name ]]; then
    case $name in Dockerfile|compose.yaml|.env.example) [[ $(realpath -e -- "$SOURCE/$name") == "$SOURCE/deploy/$name" && ! -L $SOURCE/deploy/$name ]] || { echo '安装包兼容链接目标非法' >&2; exit 1; };; *) echo '安装包来源含不受信链接' >&2; exit 1;; esac
  fi
  mode=644; [[ $name != start.sh ]] || mode=755
  install -m "$mode" -- "$SOURCE/$name" "$TMP/cpa-dr/$name"
done
while IFS= read -r path; do
  jq -cn --arg path "$path" --arg sha "$(sha256sum "$TMP/cpa-dr/$path" | cut -d ' ' -f1)" '{path:$path,sha256:$sha}'
done < <(cd "$TMP/cpa-dr" && find -P . -type f -printf '%P\n' | LC_ALL=C sort) > "$TMP/files.jsonl"
version=$(sha256sum "$TMP/files.jsonl" | cut -d ' ' -f1)
jq -s --arg version "$version" '{format_version:1,protocol_version:1,version:$version,files:.}' "$TMP/files.jsonl" > "$TMP/cpa-dr/install-manifest.json"
find "$TMP/cpa-dr" -type d -exec chmod 755 {} +
chmod 644 "$TMP/cpa-dr/install-manifest.json"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -C "$TMP" -cf "$DEST" cpa-dr
chmod 600 "$DEST"
origin='null'
if [[ -f $SOURCE/scripts/packaging/github-source.json ]]; then
  jq -e '.format_version==1 and .repository=="by1021/CPA-Active-Standby" and (.commit==null or (.commit|type=="string" and test("^[a-f0-9]{40}$")))' "$SOURCE/scripts/packaging/github-source.json" >/dev/null || { echo 'GitHub 安装来源无效' >&2; exit 1; }
  origin=$(jq -c 'if .commit==null then null else {format_version,repository,commit} end' "$SOURCE/scripts/packaging/github-source.json")
fi
jq -cn --arg version "$version" --arg sha "$(sha256sum "$DEST" | cut -d ' ' -f1)" --argjson origin "$origin" '{version:$version,sha256:$sha} + (if $origin==null then {} else {source:$origin} end)'
