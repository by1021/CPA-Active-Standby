#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export CPA_ROOT=$ROOT CPA_STATE_DIR=$TMP/state CPA_ALLOWED_ROOT=$TMP/data
mkdir -p "$CPA_ALLOWED_ROOT/auths/empty"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/snapshots.sh"
cpa_init
jq '.sources=[{name:"auths",path:(.allowed_root+"/auths"),kind:"directory"}]' "$CPA_STATE_DIR/config.json" > "$TMP/config.json"
cpa_config_set "$TMP/config.json" >/dev/null
printf '{"value":1}\n' > "$CPA_ALLOWED_ROOT/auths/one.json"
manifest=$(cpa_snapshot_create manual 0)
id=$(jq -r .id <<< "$manifest")
cpa_snapshot_verify "$id" >/dev/null
cpa_snapshot_export "$id" "$TMP/one.tar" >/dev/null
printf '{"value":2}\n' > "$CPA_ALLOWED_ROOT/auths/one.json"
printf new > "$CPA_ALLOWED_ROOT/auths/new"
inode=$(stat -c %i "$CPA_ALLOWED_ROOT/auths/one.json")
owner=$(stat -c '%u:%g' "$CPA_ALLOWED_ROOT/auths/one.json")
result=$(cpa_snapshot_restore "$id")
[[ $(cat "$CPA_ALLOWED_ROOT/auths/one.json") == '{"value":1}' ]]
[[ ! -e "$CPA_ALLOWED_ROOT/auths/new" && -d "$CPA_ALLOWED_ROOT/auths/empty" ]]
[[ $(stat -c %i "$CPA_ALLOWED_ROOT/auths/one.json") == "$inode" ]]
[[ $(stat -c '%u:%g' "$CPA_ALLOWED_ROOT/auths/one.json") == "$owner" ]]
rollback=$(jq -r .rollback_id <<< "$result")
cpa_snapshot_verify "$rollback" >/dev/null
cpa_snapshot_restore "$rollback" >/dev/null
[[ $(cat "$CPA_ALLOWED_ROOT/auths/one.json") == '{"value":2}' && -f "$CPA_ALLOWED_ROOT/auths/new" ]]
printf 'PASS: native snapshot, empty directories, restoration, inode and rollback\n'

expect_failure() {
    if "$@" > "$TMP/rejected.out" 2> "$TMP/rejected.err"; then
        printf 'Expected rejection: %s\n' "$*" >&2
        exit 1
    fi
}

node=$(jq -r .node_id <<< "$manifest")
original_state=$CPA_STATE_DIR
original_data=$CPA_ALLOWED_ROOT
export CPA_STATE_DIR=$TMP/backup-state CPA_ALLOWED_ROOT=$TMP/backup-data
mkdir -p "$CPA_ALLOWED_ROOT"
cpa_init
jq '.node_role="backup"|.sources=[{name:"auths",path:(.allowed_root+"/auths"),kind:"directory"}]' "$CPA_STATE_DIR/config.json" > "$TMP/config.json"
cpa_config_set "$TMP/config.json" >/dev/null
expect_failure cpa_snapshot_import "$TMP/one.tar" "$node" 0 backup
[[ $(cpa_snapshot_list | jq length) == 0 ]]
cpa_snapshot_import "$TMP/one.tar" "$node" 0 primary >/dev/null
cpa_snapshot_import "$TMP/one.tar" "$node" 0 primary >/dev/null
[[ $(cpa_snapshot_list | jq length) == 1 ]]
restored=$(cpa_snapshot_restore "$id")
[[ -f "$CPA_ALLOWED_ROOT/auths/one.json" && -d "$CPA_ALLOWED_ROOT/auths/empty" ]]
cpa_snapshot_restore "$(jq -r .rollback_id <<< "$restored")" >/dev/null
[[ ! -e "$CPA_ALLOWED_ROOT/auths" ]]
printf 'PASS: role/identity verification, idempotent import and initially missing directory recovery\n'

source_snapshot=$original_state/snapshots/$id
tar -C "$source_snapshot" --transform='s|^payload/auths|../outside|' -cf "$TMP/traversal.tar" manifest.json payload
expect_failure cpa_snapshot_import "$TMP/traversal.tar" "$node" 0 primary
tar -C "$source_snapshot" -cf "$TMP/duplicate.tar" manifest.json payload manifest.json
expect_failure cpa_snapshot_import "$TMP/duplicate.tar" "$node" 0 primary
mkdir "$TMP/malicious"
cp -R "$source_snapshot/manifest.json" "$source_snapshot/payload" "$TMP/malicious/"
ln -s /etc/passwd "$TMP/malicious/payload/auths/link"
tar -C "$TMP/malicious" -cf "$TMP/symlink.tar" manifest.json payload
expect_failure cpa_snapshot_import "$TMP/symlink.tar" "$node" 0 primary
unlink "$TMP/malicious/payload/auths/link"
ln "$TMP/malicious/payload/auths/one.json" "$TMP/malicious/payload/auths/hardlink"
tar -C "$TMP/malicious" -cf "$TMP/hardlink.tar" manifest.json payload
expect_failure cpa_snapshot_import "$TMP/hardlink.tar" "$node" 0 primary
unlink "$TMP/malicious/payload/auths/hardlink"
printf x > "$TMP/malicious/payload/auths/unregistered"
tar -C "$TMP/malicious" -cf "$TMP/unregistered.tar" manifest.json payload
expect_failure cpa_snapshot_import "$TMP/unregistered.tar" "$node" 0 primary
unlink "$TMP/malicious/payload/auths/unregistered"
printf '{"value":99}' > "$TMP/malicious/payload/auths/one.json"
tar -C "$TMP/malicious" -cf "$TMP/corrupt.tar" manifest.json payload
expect_failure cpa_snapshot_import "$TMP/corrupt.tar" "$node" 0 primary
cp "$source_snapshot/payload/auths/one.json" "$TMP/malicious/payload/auths/one.json"
rmdir "$TMP/malicious/payload/auths/empty"
tar -C "$TMP/malicious" -cf "$TMP/missing-directory.tar" manifest.json payload
expect_failure cpa_snapshot_import "$TMP/missing-directory.tar" "$node" 0 primary
[[ ! -e "$TMP/outside" && $(cpa_snapshot_list | jq 'map(select(.purpose!="rollback"))|length') == 1 ]]
printf 'PASS: traversal, duplicate, symlink, unregistered, corruption and missing-directory archives rejected\n'

export CPA_STATE_DIR=$original_state CPA_ALLOWED_ROOT=$original_data
ln -s "$TMP/config.json" "$CPA_ALLOWED_ROOT/auths/link"
expect_failure cpa_snapshot_create manual 0
unlink "$CPA_ALLOWED_ROOT/auths/link"
printf invalid > "$CPA_ALLOWED_ROOT/auths/"$'line\nfile'
expect_failure cpa_snapshot_create manual 0
unlink "$CPA_ALLOWED_ROOT/auths/"$'line\nfile'
jq '.peer.host="HOST;touch /tmp/should-not-exist"' "$CPA_STATE_DIR/config.json" > "$TMP/invalid-config.json"
expect_failure cpa_config_set "$TMP/invalid-config.json"
jq '.sources=[{name:"bad",path:"/etc/passwd",kind:"file"}]' "$CPA_STATE_DIR/config.json" > "$TMP/invalid-config.json"
expect_failure cpa_config_set "$TMP/invalid-config.json"
printf 'PASS: unsafe source names, symlinks, SSH host syntax and out-of-root paths rejected\n'

ln "$CPA_ALLOWED_ROOT/auths/one.json" "$CPA_ALLOWED_ROOT/auths/alias.json"
linked=$(cpa_snapshot_create manual 0)
linked_id=$(jq -r .id <<< "$linked")
[[ $(stat -c %h "$CPA_STATE_DIR/snapshots/$linked_id/payload/auths/alias.json") == 1 ]]
cpa_snapshot_export "$linked_id" "$TMP/linked.tar" >/dev/null
[[ $(tar -tvf "$TMP/linked.tar" | cut -c1 | grep -cx h || true) == 0 ]]
unlink "$CPA_ALLOWED_ROOT/auths/alias.json"
printf 'PASS: source hardlinks become independent snapshot files; hardlink archives are rejected\n'

test_restore_hardlink_targets() {
    local CPA_STATE_DIR=$TMP/hardlink-state CPA_ALLOWED_ROOT=$TMP/hardlink-data
    local hardlink_failures kind first target data snapshot snapshot_id inode owner plan row outside remove_row linked linked_id compensation_target rsync_calls
    export CPA_STATE_DIR CPA_ALLOWED_ROOT
    mkdir -p "$CPA_ALLOWED_ROOT"
    cpa_init
    hardlink_failures=0
    hardlink_expect_failure() {
        if "$@" > "$TMP/hardlink.out" 2> "$TMP/hardlink.err"; then
            printf 'Expected hardlink rejection: %s\n' "$*" >&2
            hardlink_failures=$((hardlink_failures+1))
        fi
    }
    hardlink_unchanged() {
        if ! cmp -s -- "$1" "$2"; then
            printf 'Hardlink protection changed: %s\n' "$2" >&2
            hardlink_failures=$((hardlink_failures+1))
        fi
    }
    for kind in directory file sqlite; do
        mkdir "$CPA_ALLOWED_ROOT/$kind"
        first=$CPA_ALLOWED_ROOT/$kind/first
        target=$CPA_ALLOWED_ROOT/$kind/item
        data=$target
        if [[ $kind == directory ]]; then mkdir "$target"; data=$target/value; fi
        printf historical-first > "$first"
        if [[ $kind == sqlite ]]; then
            sqlite3 "$data" 'CREATE TABLE sample(value);INSERT INTO sample VALUES(1);'
        else printf historical > "$data"; fi
        jq --arg first "$first" --arg target "$target" --arg kind "$kind" \
            '.sources=[{name:"first",path:$first,kind:"file"},{name:"item",path:$target,kind:$kind}]' \
            "$CPA_STATE_DIR/config.json" > "$TMP/hardlink-config.json"
        cpa_config_set "$TMP/hardlink-config.json" >/dev/null
        snapshot=$(cpa_snapshot_create manual 0)
        snapshot_id=$(jq -r .id <<< "$snapshot")
        printf current-first > "$first"
        if [[ $kind == sqlite ]]; then sqlite3 "$data" 'UPDATE sample SET value=2;'
        else printf current > "$data"; fi
        # A plain target still keeps its local inode and owner, including SQLite.
        inode=$(stat -c %i "$data"); owner=$(stat -c '%u:%g' "$data")
        cpa_snapshot_restore "$snapshot_id" >/dev/null
        [[ $(stat -c %i "$data") == "$inode" && $(stat -c '%u:%g' "$data") == "$owner" ]]
        printf current-first > "$first"
        if [[ $kind == sqlite ]]; then sqlite3 "$data" 'UPDATE sample SET value=2;'
        else printf current > "$data"; fi
        cp -- "$data" "$TMP/$kind-before"
        cp -- "$first" "$TMP/first-before"
        # Capture a legitimate preview before a new alias appears, then exercise
        # the same item writer used for both restore and compensation.
        plan=$(cpa_snapshot_plan "$snapshot_id")
        row=$(jq -c '.items[]|select(.name=="item")' <<< "$plan")
        outside=$TMP/$kind-outside-allowed-root
        ln -- "$data" "$outside"
        hardlink_expect_failure cpa_snapshot_plan "$snapshot_id"
        hardlink_expect_failure cpa_snapshot_restore "$snapshot_id"
        hardlink_unchanged "$TMP/first-before" "$first"
        hardlink_unchanged "$TMP/$kind-before" "$outside"
        cp -- "$TMP/$kind-before" "$data"
        hardlink_expect_failure _cpa_restore_item "$CPA_STATE_DIR/snapshots/$snapshot_id" "$row"
        hardlink_unchanged "$TMP/$kind-before" "$outside"
        cp -- "$TMP/$kind-before" "$data"
        # Reject aliases even when the snapshot would remove the target.
        remove_row=$(jq -c '.existed=false|.operation="remove_target"' <<< "$row")
        hardlink_expect_failure _cpa_restore_item "$CPA_STATE_DIR/snapshots/$snapshot_id" "$remove_row"
        hardlink_unchanged "$TMP/$kind-before" "$outside"
        # The red implementation removes the target above; restore the fixture
        # so every regression is exercised against that unmodified implementation.
        if [[ ! -e $data ]]; then
            [[ $kind != directory ]] || mkdir "$target"
            ln -- "$outside" "$data"
        fi
        # Reject directory-internal aliases even with no outside alias remaining.
        if [[ $kind == directory ]]; then
            ln -- "$data" "$target/alias"
            unlink "$outside"
            hardlink_expect_failure cpa_snapshot_plan "$snapshot_id"
            hardlink_expect_failure cpa_snapshot_restore "$snapshot_id"
            hardlink_unchanged "$TMP/first-before" "$first"
            hardlink_unchanged "$TMP/$kind-before" "$target/alias"
            cp -- "$TMP/$kind-before" "$data"
            [[ -e $target/alias ]] || ln -- "$data" "$target/alias"
        fi
        # Source hardlinks remain legal; snapshot payloads are independent files.
        linked=$(cpa_snapshot_create manual 0)
        linked_id=$(jq -r .id <<< "$linked")
        [[ -z $(find "$CPA_STATE_DIR/snapshots/$linked_id/payload" -type f -links +1 -print) ]]
        if [[ $kind == directory ]]; then unlink "$target/alias"; else unlink "$outside"; fi
    done

    # Create an alias after compensation preview, while its first item is being
    # restored. The second item's before-image differs from the late live value.
    first=$CPA_ALLOWED_ROOT/file/first; target=$CPA_ALLOWED_ROOT/file/item
    jq --arg first "$first" --arg target "$target" \
        '.sources=[{name:"first",path:$first,kind:"file"},{name:"item",path:$target,kind:"file"}]' \
        "$CPA_STATE_DIR/config.json" > "$TMP/hardlink-config.json"
    cpa_config_set "$TMP/hardlink-config.json" >/dev/null
    snapshot=$(cpa_snapshot_create manual 0)
    printf before-first > "$first"; printf before-second > "$target"
    compensation_target=$target
    printf late-second > "$TMP/late-before"
    rsync_calls=0
    rsync() {
        command rsync "$@" || return 1
        rsync_calls=$((rsync_calls+1))
        if [[ $rsync_calls == 1 ]]; then return 1; fi
        if [[ $rsync_calls == 2 ]]; then
            printf late-second > "$compensation_target"
            ln -- "$compensation_target" "$TMP/compensation-outside-allowed-root"
        fi
    }
    hardlink_expect_failure cpa_snapshot_restore "$(jq -r .id <<< "$snapshot")"
    unset -f rsync
    if ! grep -q '补偿失败=true' "$TMP/hardlink.err"; then
        printf 'Late compensation hardlink was not rejected.\n' >&2
        hardlink_failures=$((hardlink_failures+1))
    fi
    hardlink_unchanged "$TMP/late-before" "$TMP/compensation-outside-allowed-root"
    [[ $(cat "$first") == before-first ]]
    unset -f hardlink_expect_failure hardlink_unchanged
    [[ $hardlink_failures == 0 ]]
}
test_restore_hardlink_targets
printf 'PASS: directory/file/SQLite target hardlinks block whole-batch previews and writes, including late compensation aliases; source hardlinks and local inode/owner remain supported\n'

# A partial rsync failure must put the before-image back, even when the library
# is called in an if-context where Bash disables errexit inside functions.
printf '{"value":55}' > "$CPA_ALLOWED_ROOT/auths/one.json"
rsync() {
    command rsync "$@" || return 1
    if [[ ! -e $TMP/injected ]]; then : > "$TMP/injected"; return 1; fi
}
expect_failure cpa_snapshot_restore "$id"
unset -f rsync
[[ $(cat "$CPA_ALLOWED_ROOT/auths/one.json") == '{"value":55}' ]]
printf 'PASS: partial restoration failure compensates from the durable before-image\n'

# Exact raw rollback retains damaged original JSON rather than overwriting it
# merely because the pre-restore application data was already malformed.
printf damaged > "$CPA_ALLOWED_ROOT/auths/one.json"
result=$(cpa_snapshot_restore "$id")
cpa_snapshot_restore "$(jq -r .rollback_id <<< "$result")" >/dev/null
[[ $(cat "$CPA_ALLOWED_ROOT/auths/one.json") == damaged ]]
printf 'PASS: malformed original data is preserved in an exact rollback\n'

before=$(cat "$CPA_STATE_DIR/config.json")
sync() { return 1; }
expect_failure cpa_atomic "$CPA_STATE_DIR/config.json" <<< 'broken'
unset -f sync
[[ $(cat "$CPA_STATE_DIR/config.json") == "$before" ]]
printf '{"value":66}' > "$CPA_ALLOWED_ROOT/auths/one.json"
old_count=$(cpa_snapshot_list | jq length)
_cpa_flush_tree() { return 1; }
expect_failure cpa_snapshot_create manual 0
unset -f _cpa_flush_tree
source "$ROOT/lib/snapshots.sh"
[[ $(cpa_snapshot_list | jq length) == "$old_count" ]]
printf 'PASS: durable flush failure does not overwrite config or publish a partial snapshot\n'

recent=$(cpa_snapshot_create manual 0)
recent_id=$(jq -r .id <<< "$recent")
printf corrupt > "$CPA_STATE_DIR/snapshots/$recent_id/payload/auths/one.json"
jq '.retention_count=1' "$CPA_STATE_DIR/config.json" > "$TMP/retention.json"
cpa_config_set "$TMP/retention.json" >/dev/null
cpa_snapshot_prune
cpa_snapshot_verify "$linked_id" >/dev/null
printf 'PASS: retention protects the last verified source/purpose recovery point\n'

# SQLite dot-command arguments safely preserve spaces and both quote kinds.
export CPA_STATE_DIR="$TMP/state quote'\"" CPA_ALLOWED_ROOT="$TMP/data quote'\""
mkdir -p "$CPA_ALLOWED_ROOT"
cpa_init
database="$CPA_ALLOWED_ROOT/live quote'.sqlite"
sqlite3 "$database" 'CREATE TABLE sample(value);INSERT INTO sample VALUES(7);'
jq --arg path "$database" '.sources=[{name:"database",path:$path,kind:"sqlite"}]' "$CPA_STATE_DIR/config.json" > "$TMP/sqlite-config.json"
cpa_config_set "$TMP/sqlite-config.json" >/dev/null
sqlite_manifest=$(cpa_snapshot_create manual 0)
sqlite_id=$(jq -r .id <<< "$sqlite_manifest")
sqlite3 "$database" 'UPDATE sample SET value=8;'
: > "$database-wal"
expect_failure cpa_snapshot_restore "$sqlite_id"
unlink "$database-wal"
cpa_snapshot_restore "$sqlite_id" >/dev/null
[[ $(sqlite3 "$database" 'SELECT value FROM sample;') == 7 ]]
unlink "$database"
result=$(cpa_snapshot_restore "$sqlite_id")
[[ -f $database ]]
cpa_snapshot_restore "$(jq -r .rollback_id <<< "$result")" >/dev/null
[[ ! -e $database ]]
printf 'PASS: SQLite native consistent backup, quoted paths, sidecar protection and initially missing file\n'

saved_token=$(cat "$CPA_STATE_DIR/admin.token")
printf short > "$CPA_STATE_DIR/admin.token"
expect_failure cpa_init
[[ $(cat "$CPA_STATE_DIR/admin.token") == short ]]
printf '%s\n' "$saved_token" > "$CPA_STATE_DIR/admin.token"
cpa_init
printf 'PASS: weak existing administrator secret fails closed without replacement\n'

# Freeze the wall-clock second and deliberately reverse UUID lexical order.
# This makes the old second-only timestamp bug deterministic rather than
# depending on how fast the host runs three consecutive native operations.
sqlite3 "$database" 'CREATE TABLE sample(value);INSERT INTO sample VALUES(9);'
printf '0\n' > "$TMP/clock-counter"
printf '0\n' > "$TMP/uuid-counter"
date() {
    local n
    case "$*" in
        '-u +%Y-%m-%dT%H:%M:%S.%NZ')
            n=$(< "$TMP/clock-counter"); n=$((n+1)); printf '%s\n' "$n" > "$TMP/clock-counter"
            printf '2030-01-01T00:00:00.%09dZ\n' "$n" ;;
        '-u +%Y-%m-%dT%H:%M:%SZ') printf '2030-01-01T00:00:00Z\n' ;;
        '-u +%Y%m%dT%H%M%SZ') printf '20300101T000000Z\n' ;;
        *) command date "$@" ;;
    esac
}
cpa_uuid() {
    local n
    n=$(< "$TMP/uuid-counter"); n=$((n+1)); printf '%s\n' "$n" > "$TMP/uuid-counter"
    case $n in 1) printf 'z-first\n';; 2) printf 'a-second\n';; 3) printf '0-third\n';; *) printf 'zz-legacy\n';; esac
}
fast_first=$(cpa_snapshot_create manual 0)
fast_second=$(cpa_snapshot_create manual 0)
fast_clone=$(cpa_snapshot_clone "$(jq -r .id <<< "$fast_second")" manual)
fast_latest=$(jq -r .id <<< "$fast_clone")
if [[ $(cpa_snapshot_list | jq -r 'first.id') != "$fast_latest" ]]; then
    printf 'Same-second snapshot/clone ordering selected UUID order instead of creation order.\n' >&2
    exit 1
fi
[[ $(jq -r .created_at <<< "$fast_clone") == 2030-01-01T00:00:00.000000003Z ]]
legacy=$(cpa_snapshot_clone "$fast_latest" manual)
legacy_id=$(jq -r .id <<< "$legacy")
legacy_file=$CPA_STATE_DIR/snapshots/$legacy_id/manifest.json
jq '.created_at="2030-01-01T00:00:00Z"' "$legacy_file" | cpa_atomic "$legacy_file"
cpa_snapshot_verify "$legacy_id" >/dev/null
[[ $(cpa_snapshot_list | jq -r 'first.id') == "$fast_latest" ]]
jq '.retention_count=1' "$CPA_STATE_DIR/config.json" > "$TMP/fast-retention.json"
cpa_config_set "$TMP/fast-retention.json" >/dev/null
cpa_snapshot_prune
cpa_snapshot_verify "$fast_latest" >/dev/null
[[ ! -e $CPA_STATE_DIR/snapshots/$legacy_id ]]
[[ ! -e $CPA_STATE_DIR/snapshots/$(jq -r .id <<< "$fast_first") ]]
[[ ! -e $CPA_STATE_DIR/snapshots/$(jq -r .id <<< "$fast_second") ]]
unset -f date cpa_uuid
source "$ROOT/lib/common.sh"
[[ $(cpa_now) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{9}Z$ ]]
printf 'PASS: nanosecond timestamps sort consecutive snapshots/clones and retain the true latest; legacy seconds remain compatible\n'
