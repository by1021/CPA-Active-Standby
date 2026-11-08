#!/usr/bin/env bash
# Offline GitHub transport fixture; real archive/bundler/manifest, no host install.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROJECT=$(dirname "$ROOT")
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
[[ -f $PROJECT/install.sh && -f $ROOT/scripts/packaging/github.sh ]] || { echo 'FAIL: GitHub installation entrypoint missing' >&2; exit 1; }
COMMIT=1111111111111111111111111111111111111111
export COMMIT FIXTURE="$TMP" REAL_CURL
REAL_CURL=$(command -v curl)
mkdir -p "$TMP/bin" "$TMP/repo/CPA-Active-Standby-$COMMIT" "$TMP/home"
cp -a "$ROOT" "$TMP/repo/CPA-Active-Standby-$COMMIT/cpa-dr"
cat > "$TMP/repo/CPA-Active-Standby-$COMMIT/cpa-dr/start.sh" <<'START'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FIXTURE/arguments"
START
tar -czf "$TMP/source.tar.gz" -C "$TMP/repo" "CPA-Active-Standby-$COMMIT"
cp "$TMP/source.tar.gz" "$TMP/good.tar.gz"
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url='' output=''
while (($#)); do
  case $1 in -o|--output) output=$2; shift 2;; -H|--header|--connect-timeout|--max-time|--retry|--max-filesize|--proto|--proto-redir) shift 2;; https://*) url=$1; shift;; *) shift;; esac
done
printf '%s\n' "$url" >> "$FIXTURE/requests"
[[ ${FAIL_DOWNLOAD:-0} == 0 ]] || exit 22
case $url in
  https://api.github.com/repos/by1021/CPA-Active-Standby/commits/main) printf '%s\n' "$COMMIT";;
  "https://raw.githubusercontent.com/by1021/CPA-Active-Standby/$COMMIT/cpa-dr/scripts/packaging/github.sh") cp "$GITHUB_HELPER" "$output";;
  "https://codeload.github.com/by1021/CPA-Active-Standby/tar.gz/$COMMIT") cp "$FIXTURE/source.tar.gz" "$output";;
  *) echo "unexpected URL: $url" >&2; exit 1;;
esac
CURL
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" GITHUB_HELPER="$ROOT/scripts/packaging/github.sh"
bash "$PROJECT/install.sh" --deployment docker --data-dir '/fixture/data with spaces' --yes > "$TMP/install.out"
grep -Fxq "$COMMIT" "$TMP/install.out"
mapfile -t args < "$TMP/arguments"
[[ ${args[0]} == install && ${args[1]} == --role && ${args[2]} == primary ]]
[[ ${args[*]} == *'/fixture/data with spaces'* && ${args[*]} == *"$HOME/.local/share/cpa-dr/deployments/primary"* ]]
grep -Fxq "https://codeload.github.com/by1021/CPA-Active-Standby/tar.gz/$COMMIT" "$TMP/requests"
source "$ROOT/scripts/packaging/github.sh"
source "$ROOT/scripts/packaging/bootstrap.sh"
source_dir="$HOME/.local/share/cpa-dr/github/$COMMIT/cpa-dr"
jq -e --arg sha "$COMMIT" '.commit==$sha and .repository=="by1021/CPA-Active-Standby"' "$source_dir/scripts/packaging/github-source.json" >/dev/null
metadata=$(cpa_github_bundle by1021/CPA-Active-Standby "$COMMIT" "$TMP/bundle.tar")
cpa_bootstrap_check_archive "$TMP/bundle.tar"
cpa_bootstrap_manifest "$source_dir" "$(jq -r .version <<< "$metadata")"
rm "$TMP/arguments"
FAIL_DOWNLOAD=1 bash "$PROJECT/install.sh" --yes > "$TMP/fail.out" 2>&1 && exit 1
[[ ! -f $TMP/arguments ]]
printf '\nchanged\n' >> "$source_dir/start.sh"
CPA_GITHUB_REF="$COMMIT" bash "$PROJECT/install.sh" --yes > "$TMP/corrupt.out" 2>&1 && exit 1
[[ ! -f $TMP/arguments ]]
grep -q '持久源码校验失败' "$TMP/corrupt.out"
for invalid in traversal duplicate symlink; do
  case $invalid in
    traversal) tar -czf "$TMP/source.tar.gz" --transform="s,cpa-dr/start.sh,cpa-dr/../start.sh," -C "$TMP/repo" "CPA-Active-Standby-$COMMIT/cpa-dr/start.sh";;
    duplicate) tar -czf "$TMP/source.tar.gz" -C "$TMP/repo" "CPA-Active-Standby-$COMMIT/cpa-dr/start.sh" "CPA-Active-Standby-$COMMIT/cpa-dr/start.sh";;
    symlink) ln -s /etc/passwd "$TMP/repo/CPA-Active-Standby-$COMMIT/cpa-dr/bin/link"; tar -czf "$TMP/source.tar.gz" -C "$TMP/repo" "CPA-Active-Standby-$COMMIT";;
  esac
  if (cpa_github_bundle by1021/CPA-Active-Standby "$COMMIT" "$TMP/invalid-$invalid.tar") > "$TMP/$invalid.out" 2>&1; then echo "FAIL: accepted $invalid" >&2; exit 1; fi
done
cp "$TMP/good.tar.gz" "$TMP/source.tar.gz"
# Standby obtains public source via GitHub, not the primary's private SSH bundle.
HOME="$TMP/backup-home"; export HOME
mkdir -p "$HOME"
jq -n --arg version "$(jq -r .version <<< "$metadata")" --arg sha "$(jq -r .sha256 <<< "$metadata")" --arg commit "$COMMIT" '{version:1,invite_id:"github-fixture",bundle:{version:$version,sha256:$sha,source:{format_version:1,repository:"by1021/CPA-Active-Standby",commit:$commit}},backup:{deployment:"docker",output:""}}' > "$TMP/invite.json"
(cpa_bootstrap_main "$(base64 -w0 "$TMP/invite.json")") > "$TMP/join.out"
mapfile -t args < "$TMP/arguments"
[[ ${args[0]} == join && ${args[1]} == --invite-file ]]
before=$(wc -l < "$TMP/requests")
(cpa_bootstrap_main "$(base64 -w0 "$TMP/invite.json")") > "$TMP/repeat.out"
[[ $(wc -l < "$TMP/requests") == "$before" ]]
rm "$TMP/arguments"
jq '.invite_id="bad-digest"|.bundle.sha256=("0"*64)' "$TMP/invite.json" > "$TMP/bad.json"
if (cpa_bootstrap_main "$(base64 -w0 "$TMP/bad.json")") > "$TMP/bad.out" 2>&1; then echo 'FAIL: accepted wrong digest' >&2; exit 1; fi
[[ ! -f $TMP/arguments ]]
printf 'PASS: GitHub pinned primary/standby source, forwarded arguments, archive/digest rejection and download-free resume\n'
