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
mkdir -p "$TMP/bin" "$TMP/repo/CPA-Active-Standby-$COMMIT" "$TMP/home" "$TMP/work" "$TMP/backup-work" "$TMP/elsewhere" "$TMP/data with spaces"
cp -a "$ROOT" "$TMP/repo/CPA-Active-Standby-$COMMIT/cpa-dr"
cat > "$TMP/repo/CPA-Active-Standby-$COMMIT/cpa-dr/start.sh" <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" > "$FIXTURE/arguments"
root=$(cd -- "$(dirname -- "$0")" && pwd -P)
output=""; action=$1
for ((i=1;i<=$#;i++)); do
  if [[ ${!i} == --output ]]; then ((i+=1)); output=${!i}; fi
done
if [[ $action == install || $action == join ]]; then
  mkdir -p "$output/state-native"
  jq -n --arg root "$root" --arg config "$output" --arg data "$FIXTURE/data with spaces" --arg state "$output/state-native" '{version:1,managed_by:"cpa-dr-start",deployment:"docker",status:"ready",install_id:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",data_dir:$data,state_dir:$state,source_root:$root,install_root:"",config_dir:$config,run_dir:"",project_name:"location-fixture",port:8787,ssh_port:2222,bind_host:"127.0.0.1",ssh_bind_host:"0.0.0.0",read_only:false,initial_config:null,unit_hashes:{}}' > "$output/.env.docker.json"
  printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' > "$output/state-native/.cpa-dr-install-id"
fi
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
  "https://raw.githubusercontent.com/by1021/CPA-Active-Standby/$COMMIT/cpa-dr/scripts/packaging/location.sh") cp "$LOCATION_HELPER" "$output";;
  "https://codeload.github.com/by1021/CPA-Active-Standby/tar.gz/$COMMIT") cp "$FIXTURE/source.tar.gz" "$output";;
  *) echo "unexpected URL: $url" >&2; exit 1;;
esac
CURL
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" GITHUB_HELPER="$ROOT/scripts/packaging/github.sh" LOCATION_HELPER="$ROOT/scripts/packaging/location.sh"
: > "$TMP/requests"
# Full public entrypoint with an actual non-root caller and valid old record.
# Keep its transport/state separate from the remaining root-owned fixtures.
if ((EUID == 0)) && command -v setpriv >/dev/null; then
  nf="$TMP/nonroot"
  old_config="$nf/home/.local/share/cpa-dr/deployments/primary"
  mkdir -p "$nf/helpers" "$nf/old-source" "$old_config/state" "$nf/data with spaces" "$nf/control" "$nf/denied" "$nf/explicit" "$nf/missing" "$nf/new-home" "$nf/explicit-denied" "$nf/no-jq"
  chmod 755 "$TMP" "$TMP/bin"
  cp "$GITHUB_HELPER" "$LOCATION_HELPER" "$nf/helpers/"
  cp "$PROJECT/install.sh" "$nf/install.sh"
  cp "$TMP/source.tar.gz" "$nf/source.tar.gz"
  cp "$TMP/repo/CPA-Active-Standby-$COMMIT/cpa-dr/start.sh" "$nf/old-source/start.sh"
  jq -n --arg source "$nf/old-source" --arg config "$old_config" --arg state "$old_config/state" --arg data "$nf/data with spaces" '{version:1,managed_by:"cpa-dr-start",deployment:"docker",status:"ready",install_id:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",data_dir:$data,state_dir:$state,source_root:$source,install_root:"",config_dir:$config,run_dir:"",project_name:"old-fixture",port:8787,ssh_port:2222,bind_host:"127.0.0.1",read_only:false,initial_config:null,unit_hashes:{}}' > "$old_config/.env.docker.json"
  printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' > "$old_config/state/.cpa-dr-install-id"
  printf 'fixture original data\n' > "$nf/data with spaces/preserve"
  : > "$nf/requests"
  chmod 644 "$nf/source.tar.gz" "$nf/install.sh" "$nf/helpers/"*
  chown -R 65534:65534 "$nf"
  public_nonroot() (
    directory=$1; shift
    cd "$directory"
    export HOME="${NONROOT_HOME:-$nf/home}" FIXTURE="$nf" GITHUB_HELPER="$nf/helpers/github.sh" LOCATION_HELPER="$nf/helpers/location.sh" PATH="${NONROOT_PATH:-$PATH}"
    exec setpriv --reuid 65534 --regid 65534 --clear-groups bash "$nf/install.sh" "$@"
  )
  old_snapshot() { find "$nf/old-source" "$old_config" "$nf/data with spaces" -type f -exec sha256sum {} + | sort; }
  reject_nonroot() {
    local directory=$1; shift
    : > "$nf/requests"; rm -f "$nf/arguments" "$nf/dependency-commands"
    result=0
    public_nonroot "$directory" "$@" > "$nf/rejected.out" 2>&1 || result=$?
    if [[ $result == 0 ]] || ! grep -Eq '权限不足|含链接|状态未知' "$nf/rejected.out"; then
      cat "$nf/rejected.out" >&2
      printf 'FAIL: public unknown old candidate accepted (CLI exit=%s, bootstrap=%s, codeload=%s, new_record=%s)\n' "$result" "$(grep -Ec 'api.github.com|raw.githubusercontent.com' "$nf/requests" || true)" "$(grep -c 'codeload.github.com' "$nf/requests" || true)" "$([[ -e $directory/cpa-dr/config/.env.docker.json ]] && printf yes || printf no)" >&2
      exit 1
    fi
    [[ ! -s $nf/requests && ! -e $nf/dependency-commands && ! -e $nf/arguments && ! -e $directory/cpa-dr && ! -e $directory/start.sh ]] || { cat "$nf/rejected.out" >&2; cat "$nf/requests" >&2; echo 'FAIL: public rejection occurred after download/dependency/project/source mutation' >&2; exit 1; }
    [[ $(old_snapshot) == "$old_before" ]]
  }
  old_before=$(old_snapshot)
  if ! public_nonroot "$nf/control" --deployment docker --data-dir "$nf/data with spaces" --yes > "$nf/control.out" 2>&1; then cat "$nf/control.out" >&2; echo 'FAIL: readable valid old record did not adopt' >&2; exit 1; fi
  jq -e --arg config "$old_config" --arg source "$nf/old-source" '.config_dir==$config and .source_root==$source' "$nf/control/cpa-dr/install.json" >/dev/null
  [[ $(old_snapshot) == "$old_before" ]] && ! grep -q 'codeload.github.com' "$nf/requests"
  chown root:root "$nf/home/.local"; chmod 700 "$nf/home/.local"
  reject_nonroot "$nf/denied" --deployment docker --data-dir "$nf/data with spaces" --yes
  # The downloaded helper is also a standalone entry. Spy only on the
  # dependency phase; keep its real parser, candidate paths and non-root UID.
  cat > "$nf/direct.sh" <<'DIRECT'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$GITHUB_HELPER"
cpa_github_dependencies() { printf 'dependency-called\n' >> "$FIXTURE/dependency-commands"; return 99; }
cpa_github_main "$@"
DIRECT
  chmod 644 "$nf/direct.sh"
  result=0
  HOME="$nf/home" FIXTURE="$nf" GITHUB_HELPER="$nf/helpers/github.sh" setpriv --reuid 65534 --regid 65534 --clear-groups bash "$nf/direct.sh" by1021/CPA-Active-Standby "$COMMIT" --install-dir "$nf/denied/cpa-dr" --deployment docker --yes > "$nf/direct.out" 2>&1 || result=$?
  [[ $result != 0 && ! -e $nf/dependency-commands && ! -s $nf/requests && ! -e $nf/denied/cpa-dr ]] && grep -q '祖先目录权限不足' "$nf/direct.out" || { cat "$nf/direct.out" >&2; echo 'FAIL: direct GitHub helper reached dependencies or writes before unknown-candidate rejection' >&2; exit 1; }
  chmod 755 "$nf/home/.local"
  chown root:root "$nf/home/.local/share"; chmod 700 "$nf/home/.local/share"
  reject_nonroot "$nf/denied" --deployment docker --data-dir "$nf/data with spaces" --yes
  chmod 755 "$nf/home/.local/share"
  mv "$nf/home/.local" "$nf/home/local-real"; ln -s "$nf/home/local-real" "$nf/home/.local"
  reject_nonroot "$nf/denied" --deployment docker --data-dir "$nf/data with spaces" --yes
  rm "$nf/home/.local"; mv "$nf/home/local-real" "$nf/home/.local"
  chmod 700 "$nf/home/.local"
  # Missing jq makes dependency installation observable, without real packages.
  for tool in bash cp mktemp rm stat grep sha256sum realpath flock find install tar gzip chmod mkdir setpriv dirname cat wc head sort; do ln -s "$(command -v "$tool")" "$nf/no-jq/$tool"; done
  ln -s "$TMP/bin/curl" "$nf/no-jq/curl"
  for tool in sudo apt-get dnf yum; do printf '#!/usr/bin/env bash\nprintf "package %%s\\n" "$*" >> "$FIXTURE/dependency-commands"\nexit 99\n' > "$nf/no-jq/$tool"; chmod 755 "$nf/no-jq/$tool"; done
  NONROOT_PATH="$nf/no-jq" reject_nonroot "$nf/denied" --deployment docker --data-dir "$nf/data with spaces" --yes
  # An explicit accessible record outranks an unrelated inaccessible HOME path.
  explicit_config="$nf/explicit-config"
  mkdir "$explicit_config"
  jq --arg config "$explicit_config" '.config_dir=$config' "$old_config/.env.docker.json" > "$explicit_config/.env.docker.json"
  chown -R 65534:65534 "$explicit_config"
  : > "$nf/requests"
  public_nonroot "$nf/explicit" --output "$explicit_config" --deployment docker --yes > "$nf/explicit.out" 2>&1
  jq -e --arg config "$explicit_config" '.config_dir==$config' "$nf/explicit/cpa-dr/install.json" >/dev/null
  ! grep -q 'codeload.github.com' "$nf/requests"
  : > "$nf/requests"
  stable_before=$(sha256sum "$nf/explicit/cpa-dr/install.json" "$explicit_config/.env.docker.json")
  public_nonroot "$nf/explicit" --yes > "$nf/stable.out" 2>&1
  [[ ! -s $nf/requests && $(sha256sum "$nf/explicit/cpa-dr/install.json" "$explicit_config/.env.docker.json") == "$stable_before" ]]
  reject_nonroot "$nf/explicit-denied" --output "$old_config" --deployment docker --yes
  # A trusted existing Native association retains the original CLI's controlled
  # sudo re-entry, even with an explicit output below a root-private directory.
  (
    # shellcheck source=../../scripts/packaging/location.sh
    source "$LOCATION_HELPER"
    native_source="$nf/native-source"; native_project="$nf/native/cpa-dr"
    native_config="$nf/private-native/config"
    mkdir -p "$native_source" "$native_project" "$native_config" "$nf/native-tools" "$nf/native-unassociated"
    cp -a "$ROOT/." "$native_source/"
    chmod -R go-w,go+rX "$native_source"
    chmod 755 "$nf/private-native" "$native_config" "$nf/native" "$nf/native-tools" "$nf/native-unassociated"
    chown 65534:65534 "$nf/native-unassociated"
    jq --arg source "$native_source" --arg config "$native_config" --arg state "$nf/native-state" --arg root "$nf/native-root" \
      '.deployment="native"|.source_root=$source|.config_dir=$config|.state_dir=$state|.install_root=$root|.run_dir="/run/cpa-dr-native"|.project_name=""' \
      "$old_config/.env.docker.json" > "$native_config/.env.native.json"
    chmod 600 "$native_config/.env.native.json"
    SUDO_UID=65534 SUDO_GID=65534 cpa_location_register "$native_project" "$native_source" "$native_config" "$nf/native" > "$nf/native-register.out"
    chown -R 65534:65534 "$native_project"
    cat > "$nf/native-tools/sudo" <<'SUDO'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FIXTURE/native-sudo"
exit 99
SUDO
    chmod 755 "$nf/native-tools/sudo"
    # Only missing Native dependency-presence checks are stubbed; the real
    # start.sh, argument parser, records, permissions and elevation path run.
    for tool in rsync sqlite3 nginx spawn-fcgi fcgiwrap sshd; do
      if ! PATH="$PATH:/usr/sbin:/sbin" command -v "$tool" >/dev/null; then
        printf '#!/usr/bin/env bash\nexit 97\n' > "$nf/native-tools/$tool"
        chmod 755 "$nf/native-tools/$tool"
      fi
    done
    native_before=$(sha256sum "$native_project/install.json" "$native_config/.env.native.json" "$native_source/start.sh")
    for private in leaf ancestor; do
      chmod 755 "$nf/private-native" "$native_config"
      if [[ $private == leaf ]]; then chmod 700 "$native_config"; else chmod 700 "$nf/private-native"; fi
      for entry in public-explicit public-associated direct; do
        native_cwd="$nf/native"; [[ $entry != direct ]] || native_cwd=$(pwd -P)
        native_forwarded=(install --output "$native_config" --deployment native --role backup --data-dir "$nf/data with spaces" --yes)
        if [[ $entry == public-associated ]]; then
          native_forwarded=(install --deployment native --role backup --data-dir "$nf/data with spaces" --yes --output "$native_config")
        fi
        printf '%s\n' -- bash "$native_project/start.sh" --native-reentry "$native_source" "$native_config" native \
          aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$native_cwd" -- "${native_forwarded[@]}" > "$nf/native-expected"
        : > "$nf/requests"; rm -f "$nf/native-sudo" "$nf/dependency-commands"
        result=0
        if [[ $entry == direct ]]; then
          HOME="$nf/home" FIXTURE="$nf" PATH="$nf/native-tools:$PATH:/usr/sbin:/sbin" \
            setpriv --reuid 65534 --regid 65534 --clear-groups bash "$nf/helpers/github.sh" by1021/CPA-Active-Standby "$COMMIT" \
              --install-dir "$native_project" --output "$native_config" --deployment native --role backup --data-dir "$nf/data with spaces" --yes > "$nf/native.out" 2>&1 || result=$?
        elif [[ $entry == public-explicit ]]; then
          NONROOT_PATH="$nf/native-tools:$PATH:/usr/sbin:/sbin" public_nonroot "$nf/native" \
            --output "$native_config" --deployment native --role backup --data-dir "$nf/data with spaces" --yes > "$nf/native.out" 2>&1 || result=$?
        else
          NONROOT_PATH="$nf/native-tools:$PATH:/usr/sbin:/sbin" public_nonroot "$nf/native" \
            --deployment native --role backup --data-dir "$nf/data with spaces" --yes > "$nf/native.out" 2>&1 || result=$?
        fi
        if [[ $result != 99 || ! -f $nf/native-sudo ]] || ! cmp -s "$nf/native-expected" "$nf/native-sudo"; then
          cat "$nf/native.out" >&2
          printf 'FAIL: trusted Native %s/%s lost controlled sudo re-entry (CLI exit=%s)\n' "$private" "$entry" "$result" >&2
          exit 1
        fi
        [[ ! -s $nf/requests && ! -e $nf/dependency-commands && $(sha256sum "$native_project/install.json" "$native_config/.env.native.json" "$native_source/start.sh") == "$native_before" ]]
      done
      rm -f "$nf/native-sudo"
      reject_nonroot "$nf/native-unassociated" --output "$native_config" --deployment native --role backup --data-dir "$nf/data with spaces" --yes
      [[ ! -e $nf/native-sudo ]]
      result=0
      HOME="$nf/home" FIXTURE="$nf" GITHUB_HELPER="$nf/helpers/github.sh" \
        setpriv --reuid 65534 --regid 65534 --clear-groups bash "$nf/direct.sh" by1021/CPA-Active-Standby "$COMMIT" \
          --install-dir "$nf/native-unassociated/cpa-dr" --output "$native_config" --deployment native --yes > "$nf/native-direct-rejected.out" 2>&1 || result=$?
      [[ $result != 0 && ! -e $nf/dependency-commands && ! -e $nf/native-sudo && ! -s $nf/requests && ! -e $nf/native-unassociated/cpa-dr ]]
      grep -q '祖先目录权限不足' "$nf/native-direct-rejected.out"
    done
    printf 'PASS: trusted public/direct Native private explicit and associated targets retain exact controlled sudo argv without requests or record changes; unassociated private targets reject before dependencies\n'
  )
  # A truly nonexistent HOME candidate still allows a new fixed installation.
  : > "$nf/requests"
  NONROOT_HOME="$nf/new-home" public_nonroot "$nf/missing" --deployment docker --data-dir "$nf/data with spaces" --yes > "$nf/missing.out" 2>&1
  [[ -f $nf/missing/cpa-dr/config/.env.docker.json && ! -e $nf/new-home/.local ]]
  grep -q 'codeload.github.com' "$nf/requests"
  jq -e --arg config "$nf/missing/cpa-dr/config" '.config_dir==$config' "$nf/missing/cpa-dr/install.json" >/dev/null
  [[ $(old_snapshot) == "$old_before" ]]
  printf 'PASS: public non-root old adoption/ancestor-link denial occurs before SHA/helper/bundle/dependency/writes; explicit/stable targets and truly missing paths retain semantics\n'
fi
for slot in .install.lock .cpa-dr-project; do
  for kind in hardlink fifo directory writable wrong-content; do
    [[ $slot != .install.lock || $kind != wrong-content ]] || continue
    target="$TMP/project-${slot//./}-$kind"
    protected="$TMP/protected-${slot//./}-$kind"
    mkdir "$target"
    printf 'cpa-dr project v1\n' > "$target/.cpa-dr-project"
    printf 'fixture original data: preserve\n' > "$protected"
    rm -f "$target/$slot"
    case $kind in
      hardlink) ln "$protected" "$target/$slot";;
      fifo) mkfifo "$target/$slot";;
      directory) mkdir "$target/$slot";;
      writable) printf 'cpa-dr project v1\n' > "$target/$slot"; chmod 666 "$target/$slot";;
      wrong-content) printf 'fixture foreign marker\n' > "$target/$slot";;
    esac
    protected_hash=$(sha256sum "$protected")
    marker_hash=''; [[ ! -f $target/.cpa-dr-project ]] || marker_hash=$(sha256sum "$target/.cpa-dr-project")
    before=$(wc -l < "$TMP/requests" 2>/dev/null || printf 0)
    result=0
    FAIL_DOWNLOAD=1 timeout 5 bash "$GITHUB_HELPER" by1021/CPA-Active-Standby "$COMMIT" --install-dir "$target" --yes > "$TMP/project-file.out" 2>&1 || result=$?
    [[ $result != 0 && $result != 124 ]] || { echo "FAIL: unsafe project $slot/$kind accepted or blocked" >&2; exit 1; }
    [[ $(sha256sum "$protected") == "$protected_hash" ]] || { echo "FAIL: project $slot/$kind changed original hardlinked data" >&2; exit 1; }
    [[ -z $marker_hash || $(sha256sum "$target/.cpa-dr-project") == "$marker_hash" ]] || { echo "FAIL: project $slot/$kind rewrote existing marker" >&2; exit 1; }
    [[ $(wc -l < "$TMP/requests" 2>/dev/null || printf 0) == "$before" ]] || { echo "FAIL: unsafe project $slot/$kind reached download" >&2; exit 1; }
  done
done
printf 'PASS: hardlinked/writable/FIFO/directory project locks and markers reject before data writes or download\n'
mkdir "$TMP/physical-work"
ln -s "$TMP/physical-work" "$TMP/logical-work"
if ! (cd "$TMP/logical-work"; [[ $PWD == "$TMP/logical-work" ]]; bash "$PROJECT/install.sh" --deployment docker --data-dir "$TMP/data with spaces" --yes) > "$TMP/logical.out" 2>&1; then
  cat "$TMP/logical.out" >&2; printf 'FAIL: logical cwd failed physical project registration\n' >&2; exit 1
fi
[[ -f $TMP/physical-work/start.sh && -f $TMP/physical-work/cpa-dr/start.sh ]]
jq -e --arg project "$TMP/physical-work/cpa-dr" --arg config "$TMP/physical-work/cpa-dr/config" '.project_dir==$project and .config_dir==$config' "$TMP/physical-work/cpa-dr/install.json" >/dev/null
bash "$TMP/logical-work/start.sh" status
cd "$TMP/work"
bash "$PROJECT/install.sh" --deployment docker --data-dir "$TMP/data with spaces" --yes > "$TMP/install.out"
grep -Fxq "$COMMIT" "$TMP/install.out"
mapfile -t args < "$TMP/arguments"
[[ ${args[0]} == install && ${args[1]} == --role && ${args[2]} == primary ]]
[[ ${args[*]} == *"$TMP/data with spaces"* && ${args[*]} == *"$TMP/work/cpa-dr/config"* ]]
grep -Fxq "https://codeload.github.com/by1021/CPA-Active-Standby/tar.gz/$COMMIT" "$TMP/requests"
source "$ROOT/scripts/packaging/github.sh"
source "$ROOT/scripts/packaging/bootstrap.sh"
source_dir="$TMP/work/cpa-dr/releases/$COMMIT/cpa-dr"
[[ -f $TMP/work/start.sh && -f $TMP/work/cpa-dr/start.sh && -f $TMP/work/cpa-dr/install.json ]]
(cd "$TMP/elsewhere"; bash "$TMP/work/start.sh" status)
mapfile -t args < "$TMP/arguments"
[[ ${args[0]} == status && ${args[*]} == *"$TMP/work/cpa-dr/config"* ]]
(cd "$TMP/work/cpa-dr"; bash start.sh status)
[[ $(stat -c %a "$TMP/work/cpa-dr/install.json") == 600 ]]
before=$(wc -l < "$TMP/requests")
bash "$PROJECT/install.sh" --yes > "$TMP/repeat-primary.out"
[[ $(wc -l < "$TMP/requests") == "$before" ]]

# A fixed release remains packaged even if both its manifest and origin sidecar
# disappear. The stable entry must reject before executing modified source.
cp "$source_dir/install-manifest.json" "$TMP/saved-manifest"
cp "$source_dir/start.sh" "$TMP/saved-start"
cp "$source_dir/scripts/packaging/github-source.json" "$TMP/saved-origin"
rm "$source_dir/install-manifest.json" "$source_dir/scripts/packaging/github-source.json"
jq '.manifest_required=false' "$TMP/work/cpa-dr/install.json" > "$TMP/false-required"
cp "$TMP/work/cpa-dr/install.json" "$TMP/saved-association"
cp "$TMP/false-required" "$TMP/work/cpa-dr/install.json"
printf '#!/usr/bin/env bash\ntouch "$FIXTURE/manifest-deleted-executed"\n' > "$source_dir/start.sh"
result=0
bash "$TMP/work/start.sh" status > "$TMP/manifest-deleted.out" 2>&1 || result=$?
if [[ $result == 0 || -e $TMP/manifest-deleted-executed ]] || ! grep -q '源码清单校验失败' "$TMP/manifest-deleted.out"; then
  cat "$TMP/manifest-deleted.out" >&2
  printf 'FAIL: deleted fixed-release manifest accepted (CLI exit=%s, executed=%s)\n' "$result" "$([[ -e $TMP/manifest-deleted-executed ]] && printf yes || printf no)" >&2
  exit 1
fi
cp "$TMP/saved-manifest" "$source_dir/install-manifest.json"
cp "$TMP/saved-start" "$source_dir/start.sh"
cp "$TMP/saved-origin" "$source_dir/scripts/packaging/github-source.json"
cp "$TMP/saved-association" "$TMP/work/cpa-dr/install.json"
printf 'PASS: fixed release with deleted manifest/origin rejects before source execution\n'

printf '#!/usr/bin/env bash\necho unrelated\n' > "$TMP/elsewhere/start.sh"
shortcut_hash=$(sha256sum "$TMP/elsewhere/start.sh")
(cd "$TMP/elsewhere"; bash "$PROJECT/install.sh" --install-dir "$TMP/custom/project" --output "$TMP/custom/config" --deployment docker --data-dir "$TMP/data with spaces" --yes) > "$TMP/custom.out"
[[ $(sha256sum "$TMP/elsewhere/start.sh") == "$shortcut_hash" ]]
jq -e --arg config "$TMP/custom/config" '.config_dir==$config' "$TMP/custom/project/install.json" >/dev/null
mkdir -p "$TMP/link-target"
ln -s "$TMP/link-target" "$TMP/project-link"
before=$(wc -l < "$TMP/requests")
if bash "$GITHUB_HELPER" by1021/CPA-Active-Standby "$COMMIT" --install-dir "$TMP/project-link" --yes > "$TMP/project-link.out" 2>&1; then exit 1; fi
if bash "$GITHUB_HELPER" by1021/CPA-Active-Standby "$COMMIT" --install-dir "$TMP/new-project" --output "$TMP/project-link" --yes > "$TMP/config-link.out" 2>&1; then exit 1; fi
[[ $(wc -l < "$TMP/requests") == "$before" && ! -e $TMP/link-target/install.json && ! -e $TMP/new-project ]]
mkdir -p "$TMP/foreign-project"
cp "$TMP/work/cpa-dr/install.json" "$TMP/foreign-project/install.json"
printf '#!/usr/bin/env bash\ntouch "$FIXTURE/foreign-executed"\n' > "$TMP/foreign-project/start.sh"
if bash "$PROJECT/install.sh" --install-dir "$TMP/foreign-project" --yes > "$TMP/foreign.out" 2>&1; then exit 1; fi
[[ ! -e $TMP/foreign-executed ]]
jq -e --arg sha "$COMMIT" '.commit==$sha and .repository=="by1021/CPA-Active-Standby"' "$source_dir/scripts/packaging/github-source.json" >/dev/null
metadata=$(cpa_github_bundle by1021/CPA-Active-Standby "$COMMIT" "$TMP/bundle.tar")
cpa_bootstrap_check_archive "$TMP/bundle.tar"
cpa_bootstrap_manifest "$source_dir" "$(jq -r .version <<< "$metadata")"
rm "$TMP/arguments"
FAIL_DOWNLOAD=1 bash "$PROJECT/install.sh" --install-dir "$TMP/failure-project" --yes > "$TMP/fail.out" 2>&1 && exit 1
[[ ! -f $TMP/arguments ]]
printf '\nchanged\n' >> "$source_dir/start.sh"
CPA_GITHUB_REF="$COMMIT" bash "$PROJECT/install.sh" --yes > "$TMP/corrupt.out" 2>&1 && exit 1
[[ ! -f $TMP/arguments ]]
grep -Eq '持久源码校验失败|源码清单校验失败' "$TMP/corrupt.out"
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
ln -s "$TMP/backup-work" "$TMP/backup-logical"
cd "$TMP/backup-logical"
jq -n --arg version "$(jq -r .version <<< "$metadata")" --arg sha "$(jq -r .sha256 <<< "$metadata")" --arg commit "$COMMIT" '{version:1,invite_id:"github-fixture",bundle:{version:$version,sha256:$sha,source:{format_version:1,repository:"by1021/CPA-Active-Standby",commit:$commit}},backup:{deployment:"docker",output:""}}' > "$TMP/invite.json"
for kind in hardlink fifo directory writable wrong-content; do
  target="$TMP/backup-marker-$kind"
  mkdir -p "$target/cpa-dr"
  printf 'fixture original backup marker data\n' > "$target/protected"
  case $kind in
    hardlink) ln "$target/protected" "$target/cpa-dr/.cpa-dr-project";;
    fifo) mkfifo "$target/cpa-dr/.cpa-dr-project";;
    directory) mkdir "$target/cpa-dr/.cpa-dr-project";;
    writable) printf 'cpa-dr project v1\n' > "$target/cpa-dr/.cpa-dr-project"; chmod 666 "$target/cpa-dr/.cpa-dr-project";;
    wrong-content) printf 'fixture foreign backup marker\n' > "$target/cpa-dr/.cpa-dr-project";;
  esac
  protected_hash=$(sha256sum "$target/protected")
  marker_hash=''; [[ ! -f $target/cpa-dr/.cpa-dr-project ]] || marker_hash=$(sha256sum "$target/cpa-dr/.cpa-dr-project")
  before=$(wc -l < "$TMP/requests")
  if (cd "$target"; HOME="$target/home"; cpa_bootstrap_main "$(base64 -w0 "$TMP/invite.json")") > "$TMP/backup-marker.out" 2>&1; then echo "FAIL: unsafe backup marker $kind accepted" >&2; exit 1; fi
  [[ $(sha256sum "$target/protected") == "$protected_hash" && $(wc -l < "$TMP/requests") == "$before" ]]
  [[ -z $marker_hash || $(sha256sum "$target/cpa-dr/.cpa-dr-project") == "$marker_hash" ]]
done
(cpa_bootstrap_main "$(base64 -w0 "$TMP/invite.json")") > "$TMP/join.out"
mapfile -t args < "$TMP/arguments"
[[ ${args[0]} == join && ${args[1]} == --invite-file ]]
[[ -f $TMP/backup-work/start.sh && -f $TMP/backup-work/cpa-dr/install.json ]]
before=$(wc -l < "$TMP/requests")
cd "$TMP/elsewhere"
(cpa_bootstrap_main "$(base64 -w0 "$TMP/invite.json")") > "$TMP/repeat.out"
[[ $(wc -l < "$TMP/requests") == "$before" ]]
rm "$TMP/arguments"
jq '.invite_id="bad-digest"|.bundle.sha256=("0"*64)' "$TMP/invite.json" > "$TMP/bad.json"
if (cpa_bootstrap_main "$(base64 -w0 "$TMP/bad.json")") > "$TMP/bad.out" 2>&1; then echo 'FAIL: accepted wrong digest' >&2; exit 1; fi
[[ ! -f $TMP/arguments ]]
printf 'PASS: GitHub pinned primary/standby source, forwarded arguments, archive/digest rejection and download-free resume\n'
