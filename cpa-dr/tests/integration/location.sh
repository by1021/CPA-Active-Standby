#!/usr/bin/env bash
# Stable launchers validate real durable records; no service mutation.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
[[ -f $ROOT/scripts/packaging/location.sh ]] || { echo 'FAIL: stable location implementation missing' >&2; exit 1; }
source "$ROOT/scripts/packaging/location.sh"
mkdir -p "$TMP/source" "$TMP/config/state" "$TMP/work" "$TMP/other"
cat > "$TMP/source/start.sh" <<'START'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_ARGUMENTS"
if [[ ${1:-} == uninstall && $* == *--purge* ]]; then rm -f "$TEST_CONFIG/.env.docker.json"; fi
START
chmod 755 "$TMP/source/start.sh"
export TEST_ARGUMENTS="$TMP/arguments" TEST_CONFIG="$TMP/config"
jq -n --arg source "$TMP/source" --arg config "$TMP/config" --arg state "$TMP/config/state" --arg data "$TMP/data" '{version:1,managed_by:"cpa-dr-start",deployment:"docker",status:"ready",install_id:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",data_dir:$data,state_dir:$state,source_root:$source,install_root:"",config_dir:$config,run_dir:"",project_name:"location-fixture",port:8787,ssh_port:2222,bind_host:"127.0.0.1",read_only:false,initial_config:null,unit_hashes:{}}' > "$TMP/config/.env.docker.json"
printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' > "$TMP/config/state/.cpa-dr-install-id"
# Intentionally no location/manage implementation in the OLD source.
cpa_location_register "$TMP/work/cpa-dr" "$TMP/source" "$TMP/config" "$TMP/work" > "$TMP/registration-summary"
grep -Fxq "状态目录：$TMP/config/state" "$TMP/registration-summary" || { echo 'FAIL: central registration summary omitted verified state_dir' >&2; exit 1; }
(cd "$TMP/other"; bash "$TMP/work/start.sh" status)
mapfile -t args < "$TEST_ARGUMENTS"
[[ ${args[0]} == status && ${args[*]} == *"$TMP/config"* ]]
(cd "$TMP/work/cpa-dr"; bash start.sh logs --tail 2)
mapfile -t args < "$TEST_ARGUMENTS"
[[ ${args[0]} == logs && ${args[*]} == *"$TMP/config"* ]]
bash "$TMP/work/cpa-dr/start.sh" status --output "$TMP/explicit"
mapfile -t args < "$TEST_ARGUMENTS"
[[ ${args[*]} == *"$TMP/explicit"* && ${args[*]} != *"$TMP/config"* ]]
before=$(sha256sum "$TMP/config/.env.docker.json" "$TMP/source/start.sh")
cpa_location_register "$TMP/work/cpa-dr" "$TMP/source" "$TMP/config" "$TMP/work"
[[ $(sha256sum "$TMP/config/.env.docker.json" "$TMP/source/start.sh") == "$before" ]]
printf 'PASS: stable/cross-directory/explicit target and true legacy source registration\n'
jq 'del(.manifest_required)' "$TMP/work/cpa-dr/install.json" > "$TMP/local-v1"
cp "$TMP/local-v1" "$TMP/work/cpa-dr/install.json"
bash "$TMP/work/start.sh" status
# The checked-in GitHub metadata with commit:null identifies a local template,
# not a fixed package. Damaged, linked or fixed-commit metadata is not exempt.
template="$TMP/home/github/repo/cpa-dr"
mkdir -p "$template/scripts/packaging" "$TMP/template-config" "$TMP/template-work"
cp "$TMP/source/start.sh" "$template/start.sh"
jq -n '{format_version:1,repository:"by1021/CPA-Active-Standby",commit:null}' > "$template/scripts/packaging/github-source.json"
cp "$template/scripts/packaging/github-source.json" "$TMP/template-origin"
jq --arg source "$template" --arg config "$TMP/template-config" '.source_root=$source|.config_dir=$config' "$TMP/config/.env.docker.json" > "$TMP/template-config/.env.docker.json"
if ! cpa_location_register "$TMP/template-work/cpa-dr" "$template" "$TMP/template-config" "$TMP/template-work" > "$TMP/template-register.out" 2>&1; then
  cat "$TMP/template-register.out" >&2
  echo 'FAIL: ordinary github checkout with commit:null treated as a fixed package' >&2
  exit 1
fi
jq -e '.manifest_required==false' "$TMP/template-work/cpa-dr/install.json" >/dev/null
bash "$TMP/template-work/start.sh" status
for invalid in malformed missing linked fixed; do
  case $invalid in
    malformed) printf 'not json\n' > "$template/scripts/packaging/github-source.json";;
    missing) jq 'del(.commit)' "$TMP/template-origin" > "$template/scripts/packaging/github-source.json";;
    linked) rm "$template/scripts/packaging/github-source.json"; ln -s "$TMP/template-origin" "$template/scripts/packaging/github-source.json";;
    fixed) jq '.commit="1111111111111111111111111111111111111111"' "$TMP/template-origin" > "$template/scripts/packaging/github-source.json";;
  esac
  rm -f "$TEST_ARGUMENTS"
  result=0
  bash "$TMP/template-work/start.sh" status > "$TMP/template-$invalid.out" 2>&1 || result=$?
  [[ $result != 0 && ! -e $TEST_ARGUMENTS ]] && grep -q '源码清单校验失败' "$TMP/template-$invalid.out" || { cat "$TMP/template-$invalid.out" >&2; echo "FAIL: invalid $invalid provenance accepted as a local template" >&2; exit 1; }
  rm "$template/scripts/packaging/github-source.json"
  cp "$TMP/template-origin" "$template/scripts/packaging/github-source.json"
done
bash "$TMP/template-work/start.sh" status
development="$TMP/releases/development/cpa-dr"
mkdir -p "$development" "$TMP/development-config" "$TMP/development-work"
cp "$TMP/source/start.sh" "$development/start.sh"
jq --arg source "$development" --arg config "$TMP/development-config" '.source_root=$source|.config_dir=$config' "$TMP/config/.env.docker.json" > "$TMP/development-config/.env.docker.json"
cpa_location_register "$TMP/development-work/cpa-dr" "$development" "$TMP/development-config" "$TMP/development-work" >/dev/null
jq -e '.manifest_required==false' "$TMP/development-work/cpa-dr/install.json" >/dev/null
bash "$TMP/development-work/start.sh" status
# Genuine local sources may omit a manifest. Previously packaged sources may
# not downgrade to that compatibility branch by deleting provenance files.
for kind in registered github-old bootstrap-old; do
  packaged="$TMP/$kind/cpa-dr"
  [[ $kind != github-old ]] || packaged="$TMP/home/.local/share/cpa-dr/github/1111111111111111111111111111111111111111/cpa-dr"
  mkdir -p "$packaged/scripts/packaging" "$TMP/$kind-config" "$TMP/$kind-work"
  cp "$TMP/source/start.sh" "$packaged/start.sh"
  if [[ $kind == bootstrap-old ]]; then printf 'fixture-invite\n' > "${packaged%/*}/.bootstrap-id"; fi
  # The registered case deliberately uses no fixed directory or origin sidecar.
  jq -n --arg hash "$(sha256sum "$packaged/start.sh" | cut -d' ' -f1)" '{format_version:1,files:[{path:"start.sh",sha256:$hash}]}' > "$packaged/install-manifest.json"
  jq --arg source "$packaged" --arg config "$TMP/$kind-config" '.source_root=$source|.config_dir=$config' "$TMP/config/.env.docker.json" > "$TMP/$kind-config/.env.docker.json"
  cpa_location_register "$TMP/$kind-work/cpa-dr" "$packaged" "$TMP/$kind-config" "$TMP/$kind-work" >/dev/null
  jq -e '.manifest_required==true' "$TMP/$kind-work/cpa-dr/install.json" >/dev/null
  if [[ $kind != registered ]]; then
    # Simulate a compatible v1 association written before manifest_required.
    jq 'del(.manifest_required)' "$TMP/$kind-work/cpa-dr/install.json" > "$TMP/legacy-association"
    cp "$TMP/legacy-association" "$TMP/$kind-work/cpa-dr/install.json"
  fi
  bash "$TMP/$kind-work/start.sh" status
  rm "$packaged/install-manifest.json" "$TEST_ARGUMENTS"
  result=0
  bash "$TMP/$kind-work/start.sh" status > "$TMP/$kind-deleted.out" 2>&1 || result=$?
  if [[ $result == 0 || -e $TEST_ARGUMENTS ]] || ! grep -q '源码清单校验失败' "$TMP/$kind-deleted.out"; then
    cat "$TMP/$kind-deleted.out" >&2
    printf 'FAIL: deleted %s packaged manifest accepted (CLI exit=%s, executed=%s)\n' "$kind" "$result" "$([[ -e $TEST_ARGUMENTS ]] && printf yes || printf no)" >&2
    exit 1
  fi
  result=0
  bash "$TMP/$kind-work/start.sh" status --output "$TMP/explicit" > "$TMP/$kind-explicit.out" 2>&1 || result=$?
  [[ $result != 0 && ! -e $TEST_ARGUMENTS ]] && grep -q '源码清单校验失败' "$TMP/$kind-explicit.out" || { cat "$TMP/$kind-explicit.out" >&2; echo "FAIL: explicit output bypassed missing $kind manifest" >&2; exit 1; }
  if [[ $kind != registered ]]; then
    jq '.manifest_required=false' "$TMP/$kind-work/cpa-dr/install.json" > "$TMP/false-association"
    cp "$TMP/false-association" "$TMP/$kind-work/cpa-dr/install.json"
    result=0
    bash "$TMP/$kind-work/start.sh" status > "$TMP/$kind-false.out" 2>&1 || result=$?
    [[ $result != 0 && ! -e $TEST_ARGUMENTS ]] && grep -q '源码清单校验失败' "$TMP/$kind-false.out" || { cat "$TMP/$kind-false.out" >&2; echo "FAIL: manifest_required=false downgraded $kind package" >&2; exit 1; }
  fi
done
printf 'PASS: manifest obligation persists for registered packages and old GitHub/bootstrap layouts; true local legacy stays compatible\n'
cp "$TMP/work/cpa-dr/install.json" "$TMP/original"
for invalid in malformed symlink writable mismatch source-link manifest-link manifest-type; do
  cp "$TMP/original" "$TMP/work/cpa-dr/install.json"; chmod 600 "$TMP/work/cpa-dr/install.json"
  case $invalid in
    malformed) printf 'not json\n' > "$TMP/work/cpa-dr/install.json";;
    symlink) rm "$TMP/work/cpa-dr/install.json"; ln -s "$TMP/original" "$TMP/work/cpa-dr/install.json";;
    writable) chmod 666 "$TMP/work/cpa-dr/install.json";;
    mismatch) jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$TMP/original" > "$TMP/work/cpa-dr/install.json";;
    source-link) mv "$TMP/source/start.sh" "$TMP/source/original"; ln -s "$TMP/source/original" "$TMP/source/start.sh";;
    manifest-link) ln -s "$TMP/source/missing-manifest" "$TMP/source/install-manifest.json";;
    manifest-type) jq '.manifest_required="false"' "$TMP/original" > "$TMP/work/cpa-dr/install.json";;
  esac
  rm -f "$TEST_ARGUMENTS"
  if bash "$TMP/work/cpa-dr/start.sh" status > "$TMP/error" 2>&1; then echo "FAIL: accepted $invalid" >&2; exit 1; fi
  [[ ! -e $TEST_ARGUMENTS ]]
  if [[ $invalid == source-link ]]; then rm "$TMP/source/start.sh"; mv "$TMP/source/original" "$TMP/source/start.sh"; fi
  [[ $invalid != manifest-link ]] || rm "$TMP/source/install-manifest.json"
  rm -f "$TMP/work/cpa-dr/install.json"
done
cp "$TMP/original" "$TMP/work/cpa-dr/install.json"; chmod 600 "$TMP/work/cpa-dr/install.json"
for invalid in null 1 '{}' '[]'; do
  jq --argjson value "$invalid" '.manifest_required=$value' "$TMP/original" > "$TMP/work/cpa-dr/install.json"
  rm -f "$TEST_ARGUMENTS"
  if bash "$TMP/work/cpa-dr/start.sh" status > "$TMP/manifest-type-error" 2>&1; then echo "FAIL: accepted manifest_required type $invalid" >&2; exit 1; fi
  [[ ! -e $TEST_ARGUMENTS ]]
done
cp "$TMP/original" "$TMP/work/cpa-dr/install.json"; chmod 600 "$TMP/work/cpa-dr/install.json"
printf 'PASS: malformed/link/writable/identity/source-link records rejected before execution\n'
mv "$TMP/config/.env.docker.json" "$TMP/saved-record"
bash "$TMP/work/cpa-dr/start.sh" status --output "$TMP/explicit"
mapfile -t args < "$TEST_ARGUMENTS"
[[ ${args[*]} == *"$TMP/explicit"* ]]
mv "$TMP/saved-record" "$TMP/config/.env.docker.json"
chmod 777 "$TMP/source"
rm -f "$TEST_ARGUMENTS"
if bash "$TMP/work/cpa-dr/start.sh" status > "$TMP/ancestor-error" 2>&1; then echo 'FAIL: writable source ancestor accepted' >&2; exit 1; fi
[[ ! -e $TEST_ARGUMENTS ]]
chmod 755 "$TMP/source"
cp "$TMP/config/.env.docker.json" "$TMP/record-copy"
bash "$TMP/work/cpa-dr/start.sh" logs --output "$TMP/uninstall --purge"
[[ -e $TMP/config/.env.docker.json ]]
bash "$TMP/work/cpa-dr/start.sh" uninstall --purge --yes
jq -e '.status=="purged"' "$TMP/work/cpa-dr/install.json" >/dev/null
bash "$TMP/work/cpa-dr/start.sh" status
[[ ! -e $TMP/config/.env.docker.json ]]
cp "$TMP/record-copy" "$TMP/config/.env.docker.json"
cpa_location_register "$TMP/work/cpa-dr" "$TMP/source" "$TMP/config" "$TMP/work" >/dev/null
bash "$TMP/work/cpa-dr/start.sh" uninstall --purge --yes --output "$TMP/config"
jq -e '.status=="purged"' "$TMP/work/cpa-dr/install.json" >/dev/null
cp "$TMP/record-copy" "$TMP/config/.env.docker.json"
cpa_location_register "$TMP/work/cpa-dr" "$TMP/source" "$TMP/config" "$TMP/work" >/dev/null
printf '2\n2\n0\n' | script -q -e -c "bash $TMP/work/cpa-dr/start.sh" /dev/null > "$TMP/menu-purge" 2>&1
jq -e '.status=="purged"' "$TMP/work/cpa-dr/install.json" >/dev/null
[[ ! -e $TMP/config/.env.docker.json ]]
printf 'PASS: explicit override survives missing old target; writable ancestors reject; successful purge keeps valid launcher receipt\n'

# Exercise the real successful-install finish, including fresh identity after
# purge. Entry preflight and internal registration are different contracts.
(
  source "$ROOT/scripts/install/invitation.sh"
  for backend in docker native; do
    pf="$TMP/purged-finish-$backend"
    project="$pf/work/cpa-dr"
    source_root="$project/releases/1111111111111111111111111111111111111111/cpa-dr"
    config="$project/config"; state="$config/state"
    mkdir -p "$source_root" "$state" "$pf/work"
    printf '#!/usr/bin/env bash\nprintf "FINISH_SOURCE_REACHED\\n"\n' > "$source_root/start.sh"
    jq -n --arg hash "$(sha256sum "$source_root/start.sh" | cut -d' ' -f1)" \
      '{format_version:1,files:[{path:"start.sh",sha256:$hash}]}' > "$source_root/install-manifest.json"
    run_dir=''; [[ $backend != native ]] || run_dir=/run/cpa-dr-native
    jq --arg source "$source_root" --arg config "$config" --arg state "$state" --arg mode "$backend" --arg run "$run_dir" \
      '.source_root=$source|.config_dir=$config|.state_dir=$state|.deployment=$mode|.run_dir=$run' \
      "$TMP/record-copy" > "$config/.env.$backend.json"
    cp "$config/.env.$backend.json" "$pf/original-record"
    cpa_location_register "$project" "$source_root" "$config" "$pf/work" > "$pf/register.out"
    cp "$project/install.json" "$pf/original-association"
    original_sha=$(sha256sum "$project/install.json")
    # Ordinary receipts never authorize replacing an existing deployment ID.
    jq '.install_id="bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"' "$pf/original-record" > "$config/.env.$backend.json"
    result=0
    (cd "$pf/work"; ROOT="$source_root" output="$config" role=backup generate_backup=0 cpa_install_finish) > "$pf/nonpurged-finish.out" 2>&1 || result=$?
    [[ $result != 0 && $(sha256sum "$project/install.json") == "$original_sha" ]] || {
      cat "$pf/nonpurged-finish.out" >&2; echo 'FAIL: nonpurged finish accepted an unrelated new identity' >&2; exit 1;
    }
    cp "$pf/original-record" "$config/.env.$backend.json"
    cpa_location_mark_purged "$source_root" "$config"
    jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$project/install.json" > "$pf/live-bad"
    cat "$pf/live-bad" > "$project/install.json"
    result=0
    bash "$project/start.sh" install --yes > "$pf/live-purged.out" 2>&1 || result=$?
    [[ $result != 0 ]] && ! grep -q FINISH_SOURCE_REACHED "$pf/live-purged.out" || {
      cat "$pf/live-purged.out" >&2; echo 'FAIL: live-purged write entry executed before identity validation' >&2; exit 1;
    }
    cat "$pf/original-association" > "$project/install.json"
    cpa_location_mark_purged "$source_root" "$config"
    rm "$config/.env.$backend.json"
    cpa_location_records_absent "$config"
    cpa_location_read "$project" > "$pf/absent-read.out"
    # Installation now writes a validated new deployment record. Finish must
    # register it rather than strand the old purge receipt after success.
    jq '.install_id="bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"' "$pf/original-record" > "$config/.env.$backend.json"
    result=0
    (cd "$pf/work"; ROOT="$source_root" output="$config" role=backup generate_backup=0 cpa_install_finish) > "$pf/purged-finish.out" 2>&1 || result=$?
    [[ $result == 0 ]] || {
      cat "$pf/purged-finish.out" >&2; printf 'FAIL: real %s finish rejected fresh ID after verified purged absence (exit=%s)\n' "$backend" "$result" >&2; exit 1;
    }
    jq -e --arg mode "$backend" '.install_id=="bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee" and .deployment==$mode and .status==null' "$project/install.json" >/dev/null
    cpa_location_read "$project" > "$pf/refreshed-read.out"
    bash "$project/start.sh" status > "$pf/refreshed-status.out"
    grep -qx FINISH_SOURCE_REACHED "$pf/refreshed-status.out"
  done
  printf 'PASS: real Docker/Native finish registers fresh purged IDs; nonpurged replacement and live-purged writes reject\n'
)
# End focused purged reinstall finish regression.

# Replay the exact sudo argv as real root, stopping before any Native install.
# Root-private records must be checked after elevation, not merely by the caller.
if ((EUID == 0)) && command -v setpriv >/dev/null; then
  (
    nf="$TMP/native-identity"
    project="$nf/work/cpa-dr"; config="$nf/private/config"
    source_root="$project/releases/1111111111111111111111111111111111111111/cpa-dr"
    mkdir -p "$source_root" "$project" "$config" "$nf/data" "$nf/tools" "$nf/user"
    chmod 755 "$TMP" "$nf" "$nf/work" "$nf/data" "$nf/tools"
    cp -a "$ROOT" "$nf/source-input"
    jq '.commit="1111111111111111111111111111111111111111"' "$ROOT/scripts/packaging/github-source.json" > "$nf/source-input/scripts/packaging/github-source.json"
    bash "$ROOT/scripts/packaging/build-install-bundle.sh" "$nf/source-input" "$nf/native-source.tar" > "$nf/native-source.json"
    tar -xf "$nf/native-source.tar" -C "${source_root%/cpa-dr}"
    chmod 755 "$project/releases" "${source_root%/cpa-dr}"
    chmod -R go-w,go+rX "$source_root"
    chmod 700 "$nf/private"
    chown 65534:65534 "$nf/user"
    jq --arg source "$source_root" --arg config "$config" --arg state "$nf/state" --arg data "$nf/data" --arg root "$nf/native-root" \
      '.deployment="native"|.source_root=$source|.config_dir=$config|.state_dir=$state|.data_dir=$data|.install_root=$root|.run_dir="/run/cpa-dr-native"|.project_name=""' \
      "$TMP/record-copy" > "$config/.env.native.json"
    chmod 600 "$config/.env.native.json"
    SUDO_UID=65534 SUDO_GID=65534 cpa_location_register "$project" "$source_root" "$config" "$nf/work" > "$nf/register.out"
    chown -R 65534:65534 "$project"
    cp "$project/install.json" "$nf/association"
    before_native=$(sha256sum "$config/.env.native.json" "$source_root/start.sh")
    cat > "$nf/tools/sudo" <<'SUDO'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$NATIVE_SUDO_ARGS"
exit 99
SUDO
    for tool in rsync sqlite3 nginx spawn-fcgi fcgiwrap sshd systemctl apt-get dnf yum; do
      printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0 $*" >> "$NATIVE_COMMANDS"\nexit 95\n' > "$nf/tools/$tool"
    done
    chmod 755 "$nf/tools/"*
    cat > "$nf/hook" <<'HOOK'
set -T
trap 'if [[ $BASH_COMMAND == cpa_start_install_native ]]; then printf "ROOT_INSTALL_ENTRY_REACHED\n"; exit 77; elif [[ $BASH_COMMAND == cpa_manager_snapshot && ${action:-} == join ]]; then printf "ROOT_JOIN_ENTRY_REACHED\n"; exit 79; elif [[ $BASH_COMMAND == cpa_generate_invitation ]]; then printf "%s\n" "${original_args[@]}" > "$NATIVE_REPLAYED_ARGS"; printf "ROOT_INVITE_ENTRY_REACHED\n"; exit 78; fi' DEBUG
HOOK
    native_args=(install --deployment native --role backup --data-dir "$nf/data" --yes)
    capture_native() {
      rm -f "$nf/user/sudo-args"
      result=0
      (cd -- "${NATIVE_CALL_CWD:-$PWD}"; HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
        setpriv --reuid 65534 --regid 65534 --clear-groups bash "${NATIVE_ENTRY:-$project/start.sh}" "$@") > "$nf/user.out" 2>&1 || result=$?
      [[ $result == 99 && -f $nf/user/sudo-args ]] || { cat "$nf/user.out" >&2; echo 'FAIL: explicit Native mutation did not reach controlled sudo' >&2; exit 1; }
    }
    replay_native() {
      mapfile -t elevated < "$nf/user/sudo-args"
      [[ ${elevated[0]} == -- && ${elevated[1]} == bash ]]
      result=0
      NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" SUDO_UID=65534 SUDO_GID=65534 BASH_ENV="${NATIVE_REPLAY_HOOK:-$nf/hook}" \
        "${elevated[@]:1}" > "$nf/root.out" 2>&1 || result=$?
    }
    # Focused live/purged boundary. Exact sudo argv is replayed by real root;
    # the source hook stops before Native installation or package/service calls.
    cpa_test_live_purged() {
      local entry target invalid
      local -a selected
      cp "$config/.env.native.json" "$nf/live-native-record"
      for entry in "$project/start.sh" "$source_root/start.sh"; do
        for target in default explicit-same; do
          jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"|.status="purged"' "$nf/association" > "$nf/bad"
          cat "$nf/bad" > "$project/install.json"
          selected=("${native_args[@]}"); [[ $target != explicit-same ]] || selected+=(--output "$config/.")
          NATIVE_ENTRY="$entry" capture_native "${selected[@]}"
          replay_native
          if [[ $result == 77 || $result == 0 ]] || ! grep -Eq '身份|关联|上下文' "$nf/root.out"; then
            cat "$nf/root.out" >&2
            printf 'FAIL: live purged %s entry=%s bypassed identity (root=%s)\n' "$target" "$entry" "$result" >&2
            exit 1
          fi
          result=0
          NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" SUDO_UID=65534 SUDO_GID=65534 BASH_ENV="$nf/hook" \
            bash "$entry" "${selected[@]}" > "$nf/purged-root-direct.out" 2>&1 || result=$?
          [[ $result != 77 && $result != 0 ]] || { cat "$nf/purged-root-direct.out" >&2; echo 'FAIL: direct root live-purged source/stable bypassed identity' >&2; exit 1; }
        done
        # A valid live ID is still the same deployment, even with a receipt.
        jq '.status="purged"' "$nf/association" > "$nf/purged"
        cat "$nf/purged" > "$project/install.json"
        NATIVE_ENTRY="$entry" capture_native "${native_args[@]}"
        replay_native
        [[ $result == 77 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: live-purged valid identity was blocked' >&2; exit 1; }
        # Only status changes during sudo; captured ID remains bad and identical.
        jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$nf/association" > "$nf/bad"
        cat "$nf/bad" > "$project/install.json"
        NATIVE_ENTRY="$entry" capture_native "${native_args[@]}"
        jq '.status="purged"' "$nf/bad" > "$nf/changed"
        cat "$nf/changed" > "$project/install.json"
        replay_native
        [[ $result != 77 && $result != 0 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: sudo-time purged flag hid a captured bad live ID' >&2; exit 1; }
        NATIVE_ENTRY="$entry" capture_native "${native_args[@]}" --output "$nf/purged-other-config"
        replay_native
        [[ $result == 77 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: different explicit output lost priority to live-purged old ID' >&2; exit 1; }
      done
      jq '.status="purged"' "$nf/association" > "$nf/purged"
      cat "$nf/purged" > "$project/install.json"
      # Existing, invalid, linked, competing and old dotenv records are not
      # positively absent. read(project,1) intentionally still skips records.
      for invalid in malformed native-link both-backends docker-only docker-link legacy-env legacy-link; do
        cat "$nf/live-native-record" > "$config/.env.native.json"
        case $invalid in
          malformed) printf '{bad-json\n' > "$config/.env.native.json";;
          native-link) rm "$config/.env.native.json"; ln -s "$nf/missing-record" "$config/.env.native.json";;
          both-backends) cp "$nf/live-native-record" "$config/.env.docker.json";;
          docker-only) rm "$config/.env.native.json"; cp "$nf/live-native-record" "$config/.env.docker.json";;
          docker-link) rm "$config/.env.native.json"; ln -s "$nf/missing-record" "$config/.env.docker.json";;
          legacy-env) rm "$config/.env.native.json"; printf 'FIXTURE_LEGACY_ENV=preserve\n' > "$config/.env";;
          legacy-link) rm "$config/.env.native.json"; ln -s "$nf/missing-record" "$config/.env";;
        esac
        SUDO_UID=65534 SUDO_GID=65534 cpa_location_read "$project" 1 > "$nf/purged-explicit-read.out"
        result=0
        NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" SUDO_UID=65534 SUDO_GID=65534 BASH_ENV="$nf/hook" \
          bash "$project/start.sh" "${native_args[@]}" > "$nf/purged-invalid.out" 2>&1 || result=$?
        [[ $result != 77 && $result != 0 ]] || { cat "$nf/purged-invalid.out" >&2; printf 'FAIL: purged %s record was mistaken for absence\n' "$invalid" >&2; exit 1; }
        rm -f "$config/.env.native.json" "$config/.env.docker.json" "$config/.env"
      done
      # No DAC capabilities: source/association are readable, configuration is
      # not traversable. Exercise read directly, not an empty-stdin CLI wrapper.
      chmod 755 "$project"; chmod 644 "$project/install.json"; chmod 000 "$config"
      result=0
      SUDO_UID=65534 SUDO_GID=65534 setpriv --bounding-set=-dac_override,-dac_read_search bash -c \
        'source "$1"; cpa_location_read "$2"' bash "$ROOT/scripts/packaging/location.sh" "$project" > "$nf/purged-unknown.out" 2>&1 || result=$?
      chmod 700 "$project"; chmod 600 "$project/install.json"; chmod 755 "$config"
      [[ $result != 0 ]] || { cat "$nf/purged-unknown.out" >&2; echo 'FAIL: inaccessible configuration ancestor was mistaken for purged absence' >&2; exit 1; }
      for entry in "$project/start.sh" "$source_root/start.sh"; do
        for target in default explicit-same; do
          selected=("${native_args[@]}"); [[ $target != explicit-same ]] || selected+=(--output "$config/.")
          NATIVE_ENTRY="$entry" capture_native "${selected[@]}"
          replay_native
          [[ $result == 77 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: verified missing records blocked purged reinstall' >&2; exit 1; }
        done
      done
      cat "$nf/live-native-record" > "$config/.env.native.json"; chmod 600 "$config/.env.native.json"
      cat "$nf/association" > "$project/install.json"
      [[ $(sha256sum "$config/.env.native.json" "$source_root/start.sh") == "$before_native" && ! -e $nf/commands ]]
      printf 'PASS: live-purged stable/fixed-source identities, sudo-time flag replacement, invalid/unknown records and true absent reinstall\n'
    }
    cpa_test_live_purged
    # End focused live-purged receipt regression.
    # Exercise the real private deployment boundary with original CLI option
    # ordering; aggregate these new regressions so the red run proves each.
    boundary_failures=0
    for mutation in install uninstall start stop restart generate-backup-command configure-ssh; do
      rm -f "$nf/user/sudo-args"
      result=0
      HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
        setpriv --reuid 65534 --regid 65534 --clear-groups bash "$project/start.sh" "$mutation" > "$nf/noninteractive.out" 2>&1 || result=$?
      if [[ $result == 0 || -e $nf/user/sudo-args ]]; then
        printf 'FAIL: non-TTY Native %s without --yes reached sudo (exit=%s)\n' "$mutation" "$result" >&2
        boundary_failures=1
      fi
    done
    for entry in "$project/start.sh" "$source_root/start.sh"; do
      for readonly_action in status doctor logs; do
        rm -f "$nf/user/sudo-args"
        result=0
        HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
          setpriv --reuid 65534 --regid 65534 --clear-groups bash "$entry" --deployment native "$readonly_action" --output "$config/." --yes > "$nf/ordered-readonly.out" 2>&1 || result=$?
        if [[ -e $nf/user/sudo-args || ( $readonly_action != logs && $result != 0 ) ]]; then
          printf 'FAIL: options-before-%s readonly entry elevated or failed (entry=%s exit=%s)\n' "$readonly_action" "$entry" "$result" >&2
          boundary_failures=1
        fi
      done
    done
    rm -f "$nf/user/sudo-args"
    command=$(printf '%q ' env HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
      setpriv --reuid 65534 --regid 65534 --clear-groups bash "$project/start.sh" --deployment native menu --output "$config")
    result=0
    printf '0\n' | script -q -e -c "$command" /dev/null > "$nf/ordered-menu.out" 2>&1 || result=$?
    if [[ $result != 0 || -e $nf/user/sudo-args ]] || ! grep -q '请选择.*0-7' "$nf/ordered-menu.out"; then
      echo 'FAIL: options-before-menu elevated or skipped stable menu' >&2
      boundary_failures=1
    fi
    rm -f "$nf/user/sudo-args"
    result=0
    HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
      setpriv --reuid 65534 --regid 65534 --clear-groups bash "$project/start.sh" --deployment native status install --yes > "$nf/conflicting-actions.out" 2>&1 || result=$?
    if [[ $result == 0 || -e $nf/user/sudo-args ]] || ! grep -q '每次只能指定一种操作' "$nf/conflicting-actions.out"; then
      echo 'FAIL: conflicting Native actions were not rejected before sudo' >&2
      boundary_failures=1
    fi
    # The real source-side purge receipt replacement must remain owned by the
    # original caller even when a privileged source operation writes it first.
    SUDO_UID=65534 SUDO_GID=65534 bash -c 'source "$1"; cpa_location_mark_purged "$2" "$3"' bash \
      "$source_root/scripts/packaging/location.sh" "$source_root" "$config"
    if [[ $(stat -c %u "$project/install.json") != 65534 ]]; then
      echo 'FAIL: source-side Native purge made install.json unreadable to its caller' >&2
      boundary_failures=1
    fi
    cat "$nf/association" > "$project/install.json"
    ((boundary_failures == 0)) || exit 1
    # A parameter value named status is data, not a readonly action.
    mkdir "$nf/user/status"; chown 65534:65534 "$nf/user/status"
    NATIVE_CALL_CWD="$nf/user" capture_native --data-dir status install --deployment native --role backup --yes
    mapfile -t elevated < "$nf/user/sudo-args"
    [[ ${elevated[2]} == "$project/start.sh" && ${elevated[3]} == --native-reentry ]]
    printf 'PASS: Native option ordering, explicit non-TTY confirmation and source-side receipt ownership\n'
    # Real invitation grammar and fixed-release source, before any service
    # query or installation; the DEBUG hook marks that precise boundary.
    ssh-keygen -q -t ed25519 -N '' -f "$nf/user/join-host-key"
    join_host_key=$(awk '{print $1 " " $2}' "$nf/user/join-host-key.pub")
    jq -n --arg data "$nf/data" --arg output "$config" --arg key "$join_host_key" \
      '{version:1,invite_id:"fixture-native-identity",auto_enable:false,primary:{node_id:"fixture-primary",host:"primary.invalid",port:2222,public_key:$key,host_key:$key},backup:{host:"backup.invalid",port:2223,bind_host:"0.0.0.0",deployment:"native",data_dir:$data,output:$output},sources:[{name:"data",kind:"directory",relative_path:"."}],policy:{interval_seconds:900,secondary_interval_seconds:3600,retention_count:30,max_snapshot_bytes:1048576}}' > "$nf/user/join-invite.json"
    chmod 644 "$nf/user/join-invite.json"
    join_failures=0
    rm -f "$nf/user/sudo-args"
    result=0
    HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
      setpriv --reuid 65534 --regid 65534 --clear-groups bash "$source_root/start.sh" join --invite-file "$nf/user/join-invite.json" > "$nf/join-unconfirmed.out" 2>&1 || result=$?
    if [[ $result == 0 || -e $nf/user/sudo-args ]]; then
      echo 'FAIL: fixed-release non-TTY Native join without --yes reached sudo' >&2
      join_failures=1
    fi
    for target in default explicit-same; do
      jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$nf/association" > "$nf/bad"
      cat "$nf/bad" > "$project/install.json"
      selected=(join --invite-file "$nf/user/join-invite.json" --yes)
      [[ $target != explicit-same ]] || selected+=(--output "$config")
      NATIVE_ENTRY="$source_root/start.sh" capture_native "${selected[@]}"
      replay_native
      if [[ $result == 79 || $result == 0 ]]; then
        cat "$nf/root.out" >&2
        printf 'FAIL: fixed-release Native join %s bypassed association identity (exit=%s)\n' "$target" "$result" >&2
        join_failures=1
      fi
    done
    ((join_failures == 0)) || exit 1
    for target in default explicit-same; do
      cp "$nf/association" "$project/install.json"
      selected=(join --invite-file "$nf/user/join-invite.json" --yes)
      [[ $target != explicit-same ]] || selected+=(--output "$config")
      NATIVE_ENTRY="$source_root/start.sh" capture_native "${selected[@]}"
      mapfile -t elevated < "$nf/user/sudo-args"
      [[ ${elevated[2]} == "$project/start.sh" ]]
      replay_native
      [[ $result == 79 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: good fixed-release Native join identity was blocked' >&2; exit 1; }
    done
    jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$nf/association" > "$nf/bad"
    cat "$nf/bad" > "$project/install.json"
    jq --arg output "$nf/other-join-config" '.backup.output=$output' "$nf/user/join-invite.json" > "$nf/user/different-invite.json"
    chmod 644 "$nf/user/different-invite.json"
    NATIVE_ENTRY="$source_root/start.sh" capture_native join --invite-file "$nf/user/different-invite.json" --yes
    replay_native
    [[ $result == 79 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: different invited Native target was blocked by old association identity' >&2; exit 1; }
    cp "$nf/association" "$project/install.json"
    printf 'PASS: fixed-release Native invitation target identity, confirmation and different-target priority\n'
    cat > "$nf/selection-hook" <<'SELECTION'
set -T
trap 'if [[ $BASH_COMMAND == cpa_manager_snapshot ]]; then case ${action:-} in generate-backup-command) printf "ROOT_INVITE_SELECTION_REACHED\n"; exit 78;; configure-ssh) printf "ROOT_SSH_SELECTION_REACHED\n"; exit 80;; esac; fi' DEBUG
SELECTION
    for selected_action in generate-backup-command configure-ssh; do
      if [[ $selected_action == generate-backup-command ]]; then
        selected=(generate-backup-command --primary-host primary.invalid --backup-host backup.invalid); expected_result=78
      else selected=(configure-ssh --ssh-bind-host 0.0.0.0); expected_result=80; fi
      rm -f "$nf/user/sudo-args"
      result=0
      HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
        setpriv --reuid 65534 --regid 65534 --clear-groups bash "$source_root/start.sh" "${selected[@]}" > "$nf/early-action-unconfirmed.out" 2>&1 || result=$?
      [[ $result != 0 && ! -e $nf/user/sudo-args ]]
      selected+=(--yes)
      for target in default explicit-same; do
        args=("${selected[@]}"); [[ $target != explicit-same ]] || args+=(--output "$config")
        jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$nf/association" > "$nf/bad"
        cat "$nf/bad" > "$project/install.json"
        NATIVE_ENTRY="$source_root/start.sh" capture_native "${args[@]}"
        NATIVE_REPLAY_HOOK="$nf/selection-hook" replay_native
        [[ $result != "$expected_result" && $result != 0 ]] && grep -Eq '身份|关联' "$nf/root.out" || { cat "$nf/root.out" >&2; echo 'FAIL: fixed-release early action bypassed association identity' >&2; exit 1; }
        cp "$nf/association" "$project/install.json"
        NATIVE_ENTRY="$source_root/start.sh" capture_native "${args[@]}"
        NATIVE_REPLAY_HOOK="$nf/selection-hook" replay_native
        [[ $result == "$expected_result" ]] || { cat "$nf/root.out" >&2; echo 'FAIL: valid fixed-release early action did not reach its original selector' >&2; exit 1; }
      done
    done
    [[ ! -e $nf/commands ]]
    printf 'PASS: fixed-source invitation/SSH early dispatch revalidates association before privileged service queries\n'
    for target in default explicit-same; do
      cp "$nf/association" "$project/install.json"
      jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$nf/association" > "$nf/bad"
      cat "$nf/bad" > "$project/install.json"
      selected=("${native_args[@]}"); [[ $target != explicit-same ]] || selected+=(--output "$config/.")
      capture_native "${selected[@]}"
      replay_native
      if [[ $result == 77 || $result == 0 ]] || ! grep -Eq '身份|上下文' "$nf/root.out"; then
        cat "$nf/root.out" >&2
        printf 'FAIL: Native %s root sudo replay reached install with mismatched association (exit=%s)\n' "$target" "$result" >&2
        exit 1
      fi
      # Explicit same-output root launches must not bypass the record either.
      result=0
      NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" SUDO_UID=65534 SUDO_GID=65534 BASH_ENV="$nf/hook" \
        bash "$project/start.sh" "${selected[@]}" > "$nf/root-direct.out" 2>&1 || result=$?
      [[ $result != 77 && $result != 0 ]]
      cp "$nf/association" "$project/install.json"
      capture_native "${selected[@]}"
      replay_native
      [[ $result == 77 ]] && grep -qx ROOT_INSTALL_ENTRY_REACHED "$nf/root.out" || { cat "$nf/root.out" >&2; echo 'FAIL: valid Native root replay stopped before the original install entry' >&2; exit 1; }
      [[ $(sha256sum "$config/.env.native.json" "$source_root/start.sh") == "$before_native" && ! -e $nf/commands ]]
    done
    for target in default explicit-same; do
      jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$nf/association" > "$nf/bad"
      cat "$nf/bad" > "$project/install.json"
      selected=("${native_args[@]}"); [[ $target != explicit-same ]] || selected+=(--output "$config")
      NATIVE_ENTRY="$source_root/start.sh" capture_native "${selected[@]}"
      replay_native
      if [[ $result == 77 || $result == 0 ]]; then
        cat "$nf/root.out" >&2
        printf 'FAIL: fixed-release source %s root replay bypassed Native association identity (exit=%s)\n' "$target" "$result" >&2
        exit 1
      fi
      result=0
      NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" SUDO_UID=65534 SUDO_GID=65534 BASH_ENV="$nf/hook" \
        bash "$source_root/start.sh" "${selected[@]}" > "$nf/root-direct-source.out" 2>&1 || result=$?
      [[ $result != 77 && $result != 0 ]] && grep -Eq '身份|关联' "$nf/root-direct-source.out"
      cp "$nf/association" "$project/install.json"
      NATIVE_ENTRY="$source_root/start.sh" capture_native "${selected[@]}"
      mapfile -t elevated < "$nf/user/sudo-args"
      [[ ${elevated[2]} == "$project/start.sh" ]]
      replay_native
      [[ $result == 77 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: valid fixed-release Native source root replay was blocked' >&2; exit 1; }
    done
    NATIVE_CALL_CWD=/ capture_native "${native_args[@]}"
    replay_native
    [[ $result == 77 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: valid Native replay from / lost its original working directory' >&2; exit 1; }
    # An actually different explicit output retains priority over the old ID.
    jq '.install_id="ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee"' "$nf/association" > "$nf/bad"
    cat "$nf/bad" > "$project/install.json"
    capture_native "${native_args[@]}" --output "$nf/other-config"
    replay_native
    [[ $result == 77 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: different explicit Native output was blocked by the old identity' >&2; exit 1; }
    NATIVE_ENTRY="$source_root/start.sh" capture_native "${native_args[@]}" --output "$nf/other-config"
    replay_native
    [[ $result == 77 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: fixed-release explicit different Native output was blocked by the old identity' >&2; exit 1; }
    cp "$nf/association" "$project/install.json"
    # The bridge preserves all invitation options and does not add --yes.
    invitation_args=(generate-backup-command --primary-host primary.invalid --primary-port 2223 --backup-host backup.invalid --backup-port 2224
      --backup-data-dir "$nf/backup data" --backup-deployment native --backup-output "$nf/backup-config" --backup-bind-host 127.0.0.2 --ttl 600 --no-auto-enable --yes)
    capture_native "${invitation_args[@]}"
    NATIVE_REPLAYED_ARGS="$nf/invitation-replayed" replay_native
    [[ $result == 78 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: Native invitation root replay did not enter the original invitation flow' >&2; exit 1; }
    printf '%s\n' "${invitation_args[@]}" --output "$config" > "$nf/invitation-expected"
    cmp "$nf/invitation-expected" "$nf/invitation-replayed"
    # Declining the bridge prevents sudo; accepting it still leaves the
    # original source's final operation confirmation in force.
    interactive_args=(install --deployment native --role backup --data-dir "$nf/data" --no-install-deps)
    command=$(printf '%q ' env HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
      setpriv --reuid 65534 --regid 65534 --clear-groups bash "$project/start.sh" "${interactive_args[@]}")
    rm -f "$nf/user/sudo-args"
    result=0
    printf 'n\n' | script -q -e -c "$command" /dev/null > "$nf/decline.out" 2>&1 || result=$?
    [[ $result != 0 && ! -e $nf/user/sudo-args ]]
    result=0
    printf 'y\n' | script -q -e -c "$command" /dev/null > "$nf/accept.out" 2>&1 || result=$?
    [[ $result == 99 && -f $nf/user/sudo-args ]]
    mapfile -t elevated < "$nf/user/sudo-args"
    [[ " ${elevated[*]} " != *' --yes '* ]]
    command=$(printf '%q ' env NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" SUDO_UID=65534 SUDO_GID=65534 BASH_ENV="$nf/hook" "${elevated[@]:1}")
    result=0
    printf 'n\n' | script -q -e -c "$command" /dev/null > "$nf/final-decline.out" 2>&1 || result=$?
    [[ $result != 0 ]] && grep -q '确认执行上述安装计划' "$nf/final-decline.out"
    ! grep -q ROOT_INSTALL_ENTRY_REACHED "$nf/final-decline.out"
    [[ $(sha256sum "$config/.env.native.json" "$source_root/start.sh") == "$before_native" ]]
    # The captured context, rather than a newly valid but different target,
    # owns the privileged operation if install.json changes during sudo.
    mkdir -p "$nf/alternate-config"
    jq --arg config "$nf/alternate-config" '.config_dir=$config' "$config/.env.native.json" > "$nf/alternate-config/.env.native.json"
    chmod 600 "$nf/alternate-config/.env.native.json"
    for field in install_id config_dir source_root deployment; do
      cp "$nf/association" "$project/install.json"
      capture_native "${native_args[@]}"
      case $field in
        install_id) value=ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee;;
        config_dir) value="$nf/alternate-config";;
        source_root) value="$TMP/source";;
        deployment) value=docker;;
      esac
      jq --arg field "$field" --arg value "$value" '.[$field]=$value' "$nf/association" > "$nf/changed"
      cat "$nf/changed" > "$project/install.json"
      replay_native
      [[ $result != 77 && $result != 0 ]] || { cat "$nf/root.out" >&2; printf 'FAIL: sudo-time %s replacement reached original install\n' "$field" >&2; exit 1; }
    done
    cp "$nf/association" "$project/install.json"
    rm -f "$nf/user/sudo-args"
    for action in status doctor logs; do
      result=0
      HOME="$nf/user" NATIVE_SUDO_ARGS="$nf/user/sudo-args" NATIVE_COMMANDS="$nf/commands" PATH="$nf/tools:$PATH:/usr/sbin:/sbin" \
        setpriv --reuid 65534 --regid 65534 --clear-groups bash "$project/start.sh" "$action" > "$nf/readonly.out" 2>&1 || result=$?
      [[ ! -e $nf/user/sudo-args ]]
    done
    # Purge keeps a receipt and permits a deliberate new installation.
    jq '.status="purged"' "$nf/association" > "$nf/purged"
    cat "$nf/purged" > "$project/install.json"
    mv "$config/.env.native.json" "$nf/native-record"
    capture_native "${native_args[@]}"
    replay_native
    [[ $result == 77 ]] || { cat "$nf/root.out" >&2; echo 'FAIL: Native purged receipt blocked deliberate reinstall' >&2; exit 1; }
    mv "$nf/native-record" "$config/.env.native.json"
    # Old source without location or elevation helpers remains supported.
    legacy="$nf/legacy-source"
    mkdir "$legacy"; chmod 755 "$legacy"
    cat > "$legacy/start.sh" <<'LEGACY'
#!/usr/bin/env bash
[[ $EUID == 0 ]] || exit 96
if [[ ${NATIVE_FINALIZE:-0} == 1 ]]; then
  if [[ ${1:-} == uninstall ]]; then rm -f "$NATIVE_CONFIG/.env.native.json"
  else
    input="$NATIVE_CONFIG/.env.native.json"; id=f3333333-bbbb-cccc-dddd-eeeeeeeeeeee
    [[ -f $input ]] || { input=$NATIVE_RECORD; id=f4444444-bbbb-cccc-dddd-eeeeeeeeeeee; }
    jq --arg id "$id" '.install_id=$id|.status="ready"' "$input" > "$NATIVE_CONFIG/.native-new"
    chmod 600 "$NATIVE_CONFIG/.native-new"; mv "$NATIVE_CONFIG/.native-new" "$NATIVE_CONFIG/.env.native.json"
  fi
  exit 0
fi
printf 'ROOT_INSTALL_ENTRY_REACHED\n'
exit 77
LEGACY
    chmod 755 "$legacy/start.sh"
    jq --arg source "$legacy" '.source_root=$source|.manifest_required=false' "$nf/association" > "$nf/legacy-association"
    cat "$nf/legacy-association" > "$project/install.json"
    jq --arg source "$legacy" '.source_root=$source' "$config/.env.native.json" > "$nf/legacy-record"
    cat "$nf/legacy-record" > "$config/.env.native.json"
    capture_native "${native_args[@]}"
    replay_native
    [[ $result == 77 ]] && grep -qx ROOT_INSTALL_ENTRY_REACHED "$nf/root.out"
    capture_native "${native_args[@]}"
    NATIVE_FINALIZE=1 NATIVE_CONFIG="$config" NATIVE_RECORD="$nf/legacy-record" replay_native
    [[ $result == 0 && $(stat -c %u "$project/install.json") == 65534 ]]
    jq -e '.install_id=="f3333333-bbbb-cccc-dddd-eeeeeeeeeeee"' "$project/install.json" >/dev/null
    capture_native uninstall --deployment native --purge --yes
    NATIVE_FINALIZE=1 NATIVE_CONFIG="$config" NATIVE_RECORD="$nf/legacy-record" replay_native
    [[ $result == 0 && $(stat -c %u "$project/install.json") == 65534 && ! -e $config/.env.native.json ]]
    jq -e '.status=="purged"' "$project/install.json" >/dev/null
    capture_native "${native_args[@]}"
    NATIVE_FINALIZE=1 NATIVE_CONFIG="$config" NATIVE_RECORD="$nf/legacy-record" replay_native
    [[ $result == 0 && $(stat -c %u "$project/install.json") == 65534 ]]
    jq -e '.status==null and .install_id=="f4444444-bbbb-cccc-dddd-eeeeeeeeeeee"' "$project/install.json" >/dev/null
    printf 'PASS: real Native sudo root replay checks default/same-output identity and captured context; valid/purged/legacy targets work and readonly never elevates\n'
  )
fi
