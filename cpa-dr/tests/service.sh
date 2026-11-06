#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
mkdir "$TEMP/data"
CLI=("$ROOT/bin/cpa-dr" --state-dir "$TEMP/state")
"${CLI[@]}" init --allowed-root "$TEMP/data" > "$TEMP/init.json"
jq -e '.node_id and (.admin_token|length>=32) and (.public_key|startswith("ssh-ed25519 "))' "$TEMP/init.json" >/dev/null
"${CLI[@]}" status | jq -e '.phase=="unconfigured" and .job.running==false' >/dev/null
"${CLI[@]}" config get > "$TEMP/config.json"
jq --arg data "$TEMP/data" '.sources=[{name:"auths",path:$data,kind:"directory"}]' "$TEMP/config.json" > "$TEMP/new.json"
"${CLI[@]}" config set "$TEMP/new.json" | jq -e '.config.sources[0].name=="auths"' >/dev/null
printf '{"fixture":"original"}' > "$TEMP/data/auth.json"
printf '{"replicate":false}' > "$TEMP/request.json"
JOB=$("${CLI[@]}" action backup "$TEMP/request.json" | jq -r .job_id)
for _ in {1..100}; do
  if "${CLI[@]}" job "$JOB" | jq -e '.running==false' >/dev/null; then break; fi
  sleep .1
done
"${CLI[@]}" job "$JOB" | jq -e '.running==false and .error==null' >/dev/null
"${CLI[@]}" snapshots | jq -e '.snapshots|length>=1' >/dev/null
"${CLI[@]}" config get | jq -e '.peer|has("token")|not' >/dev/null
printf '{"confirm":"WRONG"}' > "$TEMP/request.json"
if "${CLI[@]}" action pause "$TEMP/request.json" >/dev/null 2>&1; then echo 'confirmation bypass' >&2; exit 1; fi
printf '{"confirm":"PAUSE"}' > "$TEMP/request.json"
JOB=$("${CLI[@]}" action pause "$TEMP/request.json" | jq -r .job_id)
for _ in {1..100}; do
  if "${CLI[@]}" job "$JOB" | jq -e '.running==false' >/dev/null; then break; fi
  sleep .1
done
"${CLI[@]}" status | jq -e '.phase=="paused"' >/dev/null
if SSH_ORIGINAL_COMMAND='status; id' "$ROOT/bin/cpa-dr-rpc" --state-dir "$TEMP/state" >/dev/null 2>&1; then echo 'RPC injection accepted' >&2; exit 1; fi
SSH_ORIGINAL_COMMAND=status "$ROOT/bin/cpa-dr-rpc" --state-dir "$TEMP/state" | jq -e '.node_role=="primary"' >/dev/null
"${CLI[@]}" trust-key "$TEMP/state/ssh/id_ed25519.pub" | jq -e '.trusted==true' >/dev/null
grep -q '^restrict,command="' "$TEMP/state/ssh/authorized_keys"
printf 'PASS: native CLI configuration, durable jobs, local backup, confirmation and restricted SSH RPC\n'

# Fault injection replaces only the SSH transport; both peer CLI and archive
# processing are real native commands. The integrator additionally runs SSH.
wait_job() {
    local state=$1 job=$2
    for _ in {1..150}; do
        if "$ROOT/bin/cpa-dr" --state-dir "$state" job "$job" | jq -e '.running==false' >/dev/null; then break; fi
        sleep .1
    done
    "$ROOT/bin/cpa-dr" --state-dir "$state" job "$job" | jq -e '.running==false and .error==null' >/dev/null
}
PSTATE="$TEMP/recovery-primary/state"
BSTATE="$TEMP/recovery-backup/state"
mkdir -p "$TEMP/recovery-primary/data" "$TEMP/recovery-backup/data"
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" init --allowed-root "$TEMP/recovery-primary/data" > "$TEMP/p-init"
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" init --allowed-root "$TEMP/recovery-backup/data" > "$TEMP/b-init"
P_ID=$(jq -r .node_id "$TEMP/p-init")
B_ID=$(jq -r .node_id "$TEMP/b-init")
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" config get | jq --arg data "$TEMP/recovery-primary/data" --arg peer "$B_ID" '.sources=[{name:"auths",path:$data,kind:"directory"}]|.peer.node_id=$peer' > "$TEMP/p-config"
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" config set "$TEMP/p-config" >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" config get | jq --arg data "$TEMP/recovery-backup/data" --arg peer "$P_ID" '.node_role="backup"|.sources=[{name:"auths",path:$data,kind:"directory"}]|.peer.node_id=$peer' > "$TEMP/b-config"
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" config set "$TEMP/b-config" >/dev/null
printf '{"fixture":"primary"}' > "$TEMP/recovery-primary/data/original.json"
printf '{"replicate":false}' > "$TEMP/recovery-request"
JOB=$("$ROOT/bin/cpa-dr" --state-dir "$PSTATE" action backup "$TEMP/recovery-request" | jq -r .job_id)
wait_job "$PSTATE" "$JOB"
SID=$("$ROOT/bin/cpa-dr" --state-dir "$PSTATE" snapshots | jq -r '.snapshots[0].id')
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" peer archive "$SID" | "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer receive "$P_ID" 0 >/dev/null
jq -n --arg id "$SID" '{snapshot_id:$id,confirm:"PROMOTE",fenced:true,quiesced:true}' > "$TEMP/recovery-request"
JOB=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" action promote "$TEMP/recovery-request" | jq -r .job_id)
wait_job "$BSTATE" "$JOB"
rm -- "$TEMP/recovery-backup/data/original.json"
printf '{"fixture":"backup"}' > "$TEMP/recovery-backup/data/new.json"
CPA_ROOT=$ROOT
CPA_STATE_DIR=$PSTATE
export CPA_ROOT CPA_STATE_DIR
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/snapshots.sh
source "$ROOT/lib/snapshots.sh"
# shellcheck source=../lib/service.sh
source "$ROOT/lib/service.sh"
cpa_ssh() {
    if [[ $1 == archive && -f $TEMP/fail-download ]]; then printf 'injected transport failure\n' >&2; return 1; fi
    "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer "$@"
}
cpa_lock
cpa_prepare_recovery >/dev/null
printf '{"confirm":"FAILBACK","quiesced":true,"backup_quiesced":true}' > "$TEMP/recovery-request"
touch "$TEMP/fail-download"
JOB=$(cpa_uuid)
cpa_job_begin failback "$JOB"
cpa_worker failback "$TEMP/recovery-request" "$JOB"
cpa_status | jq -e '.phase=="failback_failed" and .job.error!=null' >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -e '.phase=="paused" and .handover.snapshot_id!=null' >/dev/null
[[ -f $TEMP/recovery-primary/data/original.json && ! -e $TEMP/recovery-primary/data/new.json ]]
rm -- "$TEMP/fail-download"
JOB=$(cpa_uuid)
cpa_job_begin failback "$JOB"
cpa_worker failback "$TEMP/recovery-request" "$JOB"
cpa_status | jq -e '.phase=="primary_active" and .job.error==null' >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -e '.phase=="backup_standby" and .latest_received.node_role=="primary"' >/dev/null
[[ ! -e $TEMP/recovery-primary/data/original.json && -f $TEMP/recovery-primary/data/new.json ]]
printf 'PASS: failed backfill freezes peer and protects primary; retry preserves additions/deletions and refreshes primary baseline\n'
# SSH alone is substituted; the queried peer, completed handover, CLI jobs and
# ordinary pause transitions are real. The integrator also checks real SSH.
mkdir "$TEMP/resume-driver"
cat > "$TEMP/resume-driver/ssh" <<'RESUME_SSH'
#!/usr/bin/env bash
[[ ${!#} == status ]] || exit 1
exec "$CPA_RESUME_ROOT/bin/cpa-dr" --state-dir "$CPA_RESUME_PEER" peer status
RESUME_SSH
chmod +x "$TEMP/resume-driver/ssh"
resume_cli() {
    local state=$1 peer=$2; shift 2
    CPA_RESUME_ROOT=$ROOT CPA_RESUME_PEER=$peer PATH="$TEMP/resume-driver:$TEMP/restore-driver:$PATH" "$ROOT/bin/cpa-dr" --state-dir "$state" "$@"
}
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" config get | jq '.peer.host="fixture"' > "$TEMP/resume-config"
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" config set "$TEMP/resume-config" >/dev/null
COMMITTED_NONCE=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -er '.handover|select(.committed==true)|.id')
JOB=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" action pause "$TEMP/request.json" | jq -r .job_id)
wait_job "$BSTATE" "$JOB"
printf '{"confirm":"RESUME","authoritative":true}' > "$TEMP/early-resume"
# An ordinary-looking pause cannot flatten an open/failed handover. Release
# the mutation lock first so these checks exercise validation, not contention.
for RESUME_BLOCK in handover failback; do
    (
        CPA_STATE_DIR=$BSTATE
        cpa_lock
        if [[ $RESUME_BLOCK == handover ]]; then
            cpa_state_update '.handover.committed=false'
        else
            cpa_state_update '.failback={handover_id:"failed-handover"}'
        fi
    )
    if resume_cli "$BSTATE" "$PSTATE" action resume "$TEMP/early-resume" >/dev/null 2>&1; then
        printf 'FAIL: protected %s resumed ordinary scheduling\n' "$RESUME_BLOCK" >&2; exit 1
    fi
    (
        CPA_STATE_DIR=$BSTATE
        cpa_lock
        cpa_state_update '.handover.committed=true|del(.failback)'
    )
done
if ! JOB=$(resume_cli "$BSTATE" "$PSTATE" action resume "$TEMP/early-resume" 2> "$TEMP/committed-resume-error" | jq -r .job_id); then
    printf 'FAIL: committed standby ordinary pause rejected RESUME: ' >&2
    cat "$TEMP/committed-resume-error" >&2
    exit 1
fi
wait_job "$BSTATE" "$JOB"
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -e --arg nonce "$COMMITTED_NONCE" '.phase=="backup_standby" and .pause_from==null and .handover.id==$nonce and .handover.committed==true' >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer commit "$COMMITTED_NONCE" | jq -e '.committed==true and .idempotent==true' >/dev/null
printf 'PASS: committed standby ordinary pause resumes scheduling and preserves idempotent handover ACK\n'
# A failed destructive action revokes the ordinary pause's generic resume path.
printf '{"snapshot_id":"missing_snapshot","confirm":"RESTORE","quiesced":true}' > "$TEMP/blocked-restore"
JOB=$("${CLI[@]}" action restore "$TEMP/blocked-restore" | jq -r .job_id)
for _ in {1..100}; do
    if "${CLI[@]}" job "$JOB" | jq -e '.running==false' >/dev/null; then break; fi
    sleep .1
done
"${CLI[@]}" status | jq -e '.phase=="paused" and .pause_from==null and .failed_action=="restore" and .job.error!=null' >/dev/null
printf '{"confirm":"RESUME","authoritative":true}' > "$TEMP/blocked-resume"
if "${CLI[@]}" action resume "$TEMP/blocked-resume" >/dev/null 2>&1; then
    printf 'failed destructive protection was flattened by generic resume\n' >&2; exit 1
fi
printf 'PASS: failed destructive restore preserves protection instead of retaining ordinary resume permission\n'
# Lock-free stale jobs are reconciled before any subsequent timer/CGI writer.
exec 9>&-
JOB=$(cpa_uuid)
cpa_job_begin backup "$JOB"
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" tick
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" job "$JOB" | jq -e '.running==false and .error!=null' >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" status | jq -e '.phase=="primary_active"' >/dev/null
JOB=$(cpa_uuid)
cpa_job_begin restore "$JOB"
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" tick
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" status | jq -e '.phase=="paused" and .interrupted_action=="restore" and .pause_from==null' >/dev/null
printf 'PASS: orphaned jobs reconcile under flock; interrupted destructive writer stays protected\n'
# A waiting configuration writer reserves the gate; new timer ticks yield.
exec 9>&-
(
    exec 9>"$PSTATE/operation.lock"
    flock 9
    touch "$TEMP/operation-held"
    sleep 1.5
) &
HOLDER=$!
for _ in {1..100}; do [[ -f $TEMP/operation-held ]] && break; sleep .01; done
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" config get > "$TEMP/priority-config"
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" config set "$TEMP/priority-config" > "$TEMP/priority-result" &
CONTROLLER=$!
for _ in {1..100}; do
    if ! flock -n "$PSTATE/control.lock" true; then break; fi
    sleep .01
done
if flock -n "$PSTATE/control.lock" true; then echo 'controller did not reserve priority' >&2; exit 1; fi
# This is the same nonblocking acquire used by the real timer.
if cpa_lock 0 >/dev/null 2>&1; then echo 'timer jumped a queued controller' >&2; exit 1; else [[ $? == 75 ]]; fi
wait "$HOLDER"
wait "$CONTROLLER"
jq -e '.config.enabled==false' "$TEMP/priority-result" >/dev/null
printf 'PASS: waiting administrator gates future ticks and acquires operation lock after the current writer drains\n'
# Peer writes tolerate a legitimate secondary backup exceeding the API's 5s
# wait budget. The archive and receive are real native peer CLI operations.
PEER_SNAPSHOT=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -er .latest_received.id)
PEER_EPOCH=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -er .epoch)
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer archive "$PEER_SNAPSHOT" > "$TEMP/peer-wait.tar"
(
    exec 9>"$BSTATE/operation.lock"
    flock 9
    touch "$TEMP/peer-operation-held"
    sleep 6
) &
PEER_HOLDER=$!
for _ in {1..100}; do [[ -f $TEMP/peer-operation-held ]] && break; sleep .01; done
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer receive "$P_ID" "$PEER_EPOCH" < "$TEMP/peer-wait.tar" > "$TEMP/peer-wait-result"
wait "$PEER_HOLDER"
jq -e --arg id "$PEER_SNAPSHOT" '.id==$id' "$TEMP/peer-wait-result" >/dev/null
printf 'PASS: peer receive waits through a six-second local writer and validates the archive\n'
# A failed start may already have refreshed credentials. Retrying must preserve
# that working data but cannot commit until start really succeeds.
REGRESSION_FAILURES=0
jq -n --arg id "$PEER_SNAPSHOT" '{snapshot_id:$id,confirm:"PROMOTE",fenced:true,quiesced:true}' > "$TEMP/start-promote"
JOB=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" action promote "$TEMP/start-promote" | jq -r .job_id)
wait_job "$BSTATE" "$JOB"
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" config get | jq '.service={driver:"systemd",name:"cpa-fixture.service",timeout_seconds:60}' > "$TEMP/start-config"
"$ROOT/bin/cpa-dr" --state-dir "$PSTATE" config set "$TEMP/start-config" >/dev/null
(
    CPA_STATE_DIR=$PSTATE
    cpa_lock
    cpa_service_control() {
        [[ $1 == start ]] || return 0
        printf 'start\n' >> "$TEMP/start-attempts"
        if [[ $(wc -l < "$TEMP/start-attempts") == 1 ]]; then
            printf '{"token":"refreshed during failed start"}' > "$TEMP/recovery-primary/data/new.json"
            return 1
        fi
        if [[ $(wc -l < "$TEMP/start-attempts") == 6 ]]; then
            printf '{"token":"refreshed after reconciliation start"}' > "$TEMP/recovery-primary/data/new.json"
        fi
        return 0
    }
    cpa_prepare_recovery >/dev/null
    JOB=$(cpa_uuid)
    cpa_job_begin failback "$JOB"
    cpa_worker failback "$TEMP/recovery-request" "$JOB"
    cpa_status | jq -e '.phase=="failback_failed" and .job.error!=null and .failback.primary_start_attempted==true and .failback.primary_started==false' >/dev/null
    JOB=$(cpa_uuid)
    cpa_job_begin failback "$JOB"
    cpa_worker failback "$TEMP/recovery-request" "$JOB"
    cpa_status > "$TEMP/start-final-status"
    jq -e '.token=="refreshed during failed start"' "$TEMP/recovery-primary/data/new.json" >/dev/null
    # A once-successful start is not proof of current liveness after another
    # prepare-recovery has stopped CPA following a baseline transport failure.
    NEXT_PROMOTE=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -er .latest_received.id)
    jq -n --arg id "$NEXT_PROMOTE" '{snapshot_id:$id,confirm:"PROMOTE",fenced:true,quiesced:true}' > "$TEMP/retry-promote"
    JOB=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" action promote "$TEMP/retry-promote" | jq -r .job_id)
    wait_job "$BSTATE" "$JOB"
    cpa_prepare_recovery >/dev/null
    touch "$TEMP/fail-baseline"
    cpa_ssh() {
        if [[ $1 == baseline && -f $TEMP/fail-baseline ]]; then printf 'injected baseline failure\n' >&2; return 1; fi
        "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer "$@"
    }
    JOB=$(cpa_uuid)
    cpa_job_begin failback "$JOB"
    cpa_worker failback "$TEMP/recovery-request" "$JOB"
    cpa_status | jq -e '.phase=="failback_failed" and .failback.primary_started==true' >/dev/null
    rm -- "$TEMP/fail-baseline"
    cpa_prepare_recovery >/dev/null
    JOB=$(cpa_uuid)
    cpa_job_begin failback "$JOB"
    cpa_worker failback "$TEMP/recovery-request" "$JOB"
    cpa_status > "$TEMP/restart-final-status"
    # Lose the commit acknowledgement after the real backup commits. A retry
    # on a subsequently stopped primary must start and publish fresh working
    # data via ordinary receive, not replay the old final handover data.
    NEXT_PROMOTE=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -er .latest_received.id)
    jq -n --arg id "$NEXT_PROMOTE" '{snapshot_id:$id,confirm:"PROMOTE",fenced:true,quiesced:true}' > "$TEMP/commit-promote"
    JOB=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" action promote "$TEMP/commit-promote" | jq -r .job_id)
    wait_job "$BSTATE" "$JOB"
    cpa_prepare_recovery >/dev/null
    touch "$TEMP/fail-commit-ack"
    cpa_ssh() {
        if [[ $1 == commit && -f $TEMP/fail-commit-ack ]]; then
            "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer "$@" >/dev/null || return
            printf 'injected lost commit acknowledgement\n' >&2
            return 1
        fi
        "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer "$@"
    }
    JOB=$(cpa_uuid)
    cpa_job_begin failback "$JOB"
    cpa_worker failback "$TEMP/recovery-request" "$JOB"
    cpa_status | jq -e '.phase=="failback_failed" and .job.error!=null' >/dev/null
    "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -e '.phase=="backup_standby" and .handover.committed==true' >/dev/null
    rm -- "$TEMP/fail-commit-ack"
    cpa_service_control stop
    touch "$TEMP/fail-reconcile-ack"
    cpa_ssh() {
        if [[ $1 == receive && -f $TEMP/fail-reconcile-ack ]]; then
            "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer "$@" >/dev/null || return
            printf 'injected lost fresh-receive acknowledgement\n' >&2
            return 1
        fi
        "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer "$@"
    }
    JOB=$(cpa_uuid)
    cpa_job_begin failback "$JOB"
    cpa_worker failback "$TEMP/recovery-request" "$JOB"
    cpa_status | jq -e '.phase=="failback_failed" and .job.error!=null' >/dev/null
    rm -- "$TEMP/fail-reconcile-ack"
    cpa_service_control stop
    JOB=$(cpa_uuid)
    cpa_job_begin failback "$JOB"
    cpa_worker failback "$TEMP/recovery-request" "$JOB"
    cpa_status > "$TEMP/reconcile-final-status"
)
if [[ $(wc -l < "$TEMP/start-attempts") != 7 ]] || ! jq -e '.phase=="primary_active" and .job.error==null' "$TEMP/start-final-status" >/dev/null || ! jq -e '.phase=="primary_active" and .job.error==null' "$TEMP/restart-final-status" >/dev/null || ! jq -e '.phase=="primary_active" and .job.error==null' "$TEMP/reconcile-final-status" >/dev/null; then
    printf 'FAIL: failback committed without retrying a failed or subsequently stopped CPA start\n' >&2
    ((REGRESSION_FAILURES+=1))
fi
RECONCILED_ID=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -er .latest_received.id)
if ! jq -e '.token=="refreshed after reconciliation start"' "$BSTATE/snapshots/$RECONCILED_ID/payload/auths/new.json" >/dev/null; then
    printf 'FAIL: reconciled standby does not hold credentials refreshed by the successful start\n' >&2
    ((REGRESSION_FAILURES+=1))
fi
printf 'CHECK: failed-start retry preserves refreshed data and requires a successful start\n'

# Fixed timestamps reconstruct delayed/replayed transports deterministically;
# fixture creation still uses the native snapshot/export/receive pipeline.
PEER_EPOCH=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -er .epoch)
HANDOVER_ID=$("$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -er .handover.id)
fixture_archive() {
    local tag=$1 timestamp=$2 epoch=${3:-$PEER_EPOCH}
    (
        CPA_STATE_DIR=$PSTATE
        cpa_lock
        cpa_now() { printf '%s\n' "$timestamp"; }
        manifest=$(cpa_snapshot_create scheduled "$epoch")
        id=$(jq -r .id <<< "$manifest")
        cpa_snapshot_export "$id" "$TEMP/$tag.tar" >/dev/null
        printf '%s\n' "$id"
    )
}
assert_replay_rejected() {
    local archive=$1 expected=$2 operation=${3:-receive} field
    local -a args=(peer "$operation" "$P_ID" "$PEER_EPOCH")
    [[ $operation != baseline ]] || args+=("$HANDOVER_ID")
    if "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" "${args[@]}" < "$archive" >/dev/null 2>&1; then
        printf 'FAIL: %s replay or ambiguous timestamp was accepted\n' "$operation" >&2
        ((REGRESSION_FAILURES+=1))
    fi
    field=latest_received
    [[ $operation != baseline ]] || field=handover.baseline
    if ! "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -e --arg id "$expected" ".$field.id==\$id" >/dev/null; then
        printf 'FAIL: %s replay moved the authoritative pointer\n' "$operation" >&2
        ((REGRESSION_FAILURES+=1))
    fi
}
fixture_archive old-baseline '2027-01-01T00:00:00.100000000Z' >/dev/null
NEW_BASELINE=$(fixture_archive new-baseline '2027-01-01T00:00:00.200000000Z')
# Reopen only the isolated runtime fixture's handover window to exercise nonce
# baseline ordering; production handovers create this state through promote.
(
    CPA_STATE_DIR=$BSTATE
    cpa_lock
    cpa_state_update '.phase="paused"|.handover.committed=false|.handover.baseline=null'
)
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer baseline "$P_ID" "$PEER_EPOCH" "$HANDOVER_ID" < "$TEMP/old-baseline.tar" >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer baseline "$P_ID" "$PEER_EPOCH" "$HANDOVER_ID" < "$TEMP/new-baseline.tar" >/dev/null
assert_replay_rejected "$TEMP/old-baseline.tar" "$NEW_BASELINE" baseline
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer baseline "$P_ID" "$PEER_EPOCH" "$HANDOVER_ID" < "$TEMP/new-baseline.tar" >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer commit "$HANDOVER_ID" >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" config get | jq '.retention_count=1' > "$TEMP/replay-retention"
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" config set "$TEMP/replay-retention" >/dev/null

fixture_archive old-received '2028-01-01T00:00:00.100000000Z' >/dev/null
NEW_RECEIVED=$(fixture_archive new-received '2028-01-01T00:00:00.200000000Z')
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer receive "$P_ID" "$PEER_EPOCH" < "$TEMP/old-received.tar" >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer receive "$P_ID" "$PEER_EPOCH" < "$TEMP/new-received.tar" >/dev/null
assert_replay_rejected "$TEMP/old-received.tar" "$NEW_RECEIVED"
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer receive "$P_ID" "$PEER_EPOCH" < "$TEMP/new-received.tar" >/dev/null
[[ ! -d $BSTATE/snapshots/$NEW_BASELINE ]]
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer commit "$HANDOVER_ID" >/dev/null
if ! "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -e --arg id "$NEW_RECEIVED" '.latest_received.id==$id' >/dev/null; then
    printf 'FAIL: replayed committed handover replaced a newer received snapshot\n' >&2
    ((REGRESSION_FAILURES+=1))
fi
fixture_archive equal-received '2028-01-01T00:00:00.200000000Z' >/dev/null
assert_replay_rejected "$TEMP/equal-received.tar" "$NEW_RECEIVED"
LEGACY_RECEIVED=$(fixture_archive legacy-received '2029-01-01T00:00:00Z')
fixture_archive ambiguous-received '2029-01-01T00:00:00.100000000Z' >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer receive "$P_ID" "$PEER_EPOCH" < "$TEMP/legacy-received.tar" >/dev/null
assert_replay_rejected "$TEMP/ambiguous-received.tar" "$LEGACY_RECEIVED"
fixture_archive invalid-received '2029-02-30T00:00:00.100000000Z' >/dev/null
assert_replay_rejected "$TEMP/invalid-received.tar" "$LEGACY_RECEIVED"
PRECISE_RECEIVED=$(fixture_archive precise-received '2030-01-01T00:00:00.100000000Z')
fixture_archive legacy-after-precise '2030-01-01T00:00:00Z' >/dev/null
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer receive "$P_ID" "$PEER_EPOCH" < "$TEMP/precise-received.tar" >/dev/null
assert_replay_rejected "$TEMP/legacy-after-precise.tar" "$PRECISE_RECEIVED"
NEXT_RECEIVED=$(fixture_archive next-epoch '2025-01-01T00:00:00.100000000Z' "$((PEER_EPOCH+1))")
((PEER_EPOCH+=1))
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer receive "$P_ID" "$PEER_EPOCH" < "$TEMP/next-epoch.tar" >/dev/null
if "$ROOT/bin/cpa-dr" --state-dir "$BSTATE" peer commit "$HANDOVER_ID" >/dev/null 2>&1; then
    printf 'FAIL: an earlier-epoch commit was accepted\n' >&2
    ((REGRESSION_FAILURES+=1))
fi
"$ROOT/bin/cpa-dr" --state-dir "$BSTATE" status | jq -e --arg id "$NEXT_RECEIVED" '.latest_received.id==$id' >/dev/null
printf 'CHECK: delayed/duplicate ordinary and handover baselines never rewind pointers\n'
# Generic historical restore is data-only: a standby must not become a second
# CPA writer through an implicit service start outside the promote workflow.
(
    CPA_STATE_DIR=$BSTATE
    cpa_lock
    cpa_status | jq -e '.phase=="backup_standby"' >/dev/null
    cpa_service_control() { printf '%s\n' "$1" >> "$TEMP/restore-service-verbs"; }
    jq -n --arg id "$NEXT_RECEIVED" '{snapshot_id:$id,confirm:"RESTORE",quiesced:true}' > "$TEMP/standby-restore"
    JOB=$(cpa_uuid)
    cpa_job_begin restore "$JOB"
    cpa_run_action restore "$TEMP/standby-restore" >/dev/null
    cpa_job_finish "$JOB" '' '{}'
)
if [[ $(cat "$TEMP/restore-service-verbs") != stop ]]; then
    printf 'FAIL: generic standby restore implicitly started a second CPA writer\n' >&2
    ((REGRESSION_FAILURES+=1))
fi
# Independent historical recovery retries use the same confirmed public entry.
# Only the OS service driver is replaced; jobs, locks, snapshots and restore IO
# run through the real CLI. Runtime edits below simulate lost/legacy writers.
mkdir "$TEMP/restore-driver"
cat > "$TEMP/restore-driver/systemctl" <<'DRIVER'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$CPA_STATE_DIR/service-verbs"
DRIVER
chmod +x "$TEMP/restore-driver/systemctl"
restore_cli() {
    PATH="$TEMP/restore-driver:$PATH" "$ROOT/bin/cpa-dr" --state-dir "$RSTATE" "$@"
}
restore_finished() {
    local job=$1
    for _ in {1..150}; do
        if restore_cli job "$job" | jq -e '.running==false' >/dev/null; then break; fi
        sleep .1
    done
    restore_cli job "$job" | jq -e '.running==false' >/dev/null
}
restore_rejected() {
    local action=$1 request=$2
    if restore_cli action "$action" "$request" >/dev/null 2>&1; then
        printf 'FAIL: %s flattened a protected %s fixture\n' "$action" "$RPHASE" >&2
        exit 1
    fi
}
restore_fixture_state() {
    (
        CPA_STATE_DIR=$RSTATE
        cpa_lock
        cpa_state_update "$@"
    )
}
for RPHASE in primary_active backup_standby backup_active; do
    RSTATE="$TEMP/restore-$RPHASE/state"
    RDATA="$TEMP/restore-$RPHASE/data"
    RROLE=backup
    [[ $RPHASE != primary_active ]] || RROLE=primary
    RPEER_STATE=$PSTATE RPEER_ID=$P_ID
    if [[ $RROLE == primary ]]; then RPEER_STATE=$BSTATE RPEER_ID=$B_ID; fi
    mkdir -p "$RDATA"
    restore_cli init --allowed-root "$RDATA" >/dev/null
    restore_cli config get | jq --arg data "$RDATA" --arg role "$RROLE" --arg peer "$RPEER_ID" '.node_role=$role|.peer.host="fixture"|.peer.node_id=$peer|.sources=[{name:"auths",path:$data,kind:"directory"}]|.service={driver:"systemd",name:"cpa-fixture.service",timeout_seconds:60}' > "$TEMP/restore-config"
    restore_cli config set "$TEMP/restore-config" >/dev/null
    printf '{"fixture":"historical"}' > "$RDATA/history.json"
    RSID=$(
        CPA_STATE_DIR=$RSTATE
        cpa_lock
        cpa_state_update '.phase=$phase' --arg phase "$RPHASE"
        cpa_snapshot_create manual 0 | jq -r .id
    )
    jq -n --arg id "$RSID" '{snapshot_id:$id,confirm:"RESTORE",quiesced:true}' > "$TEMP/restore-valid"
    # A completed handover is durable history, not an open handover window.
    if [[ $RPHASE == backup_standby ]]; then
        restore_fixture_state '.handover={id:"committed-history",committed:true}'
    fi
    for ORIGIN in ordinary paused; do
        if [[ $ORIGIN == paused ]]; then
            JOB=$(restore_cli action pause "$TEMP/request.json" | jq -r .job_id)
            restore_finished "$JOB"
        fi
        printf '{"fixture":"current"}' > "$RDATA/history.json"
        printf 'must be deleted by successful retry\n' > "$RDATA/obsolete"
        JOB=$(restore_cli action restore "$TEMP/blocked-restore" | jq -r .job_id)
        restore_finished "$JOB"
        restore_cli status | jq -e '.phase=="paused" and .pause_from==null and .failed_action=="restore" and .job.error!=null' >/dev/null
        jq -e '.fixture=="current"' "$RDATA/history.json" >/dev/null
        [[ -f $RDATA/obsolete ]]
        restore_rejected resume "$TEMP/blocked-resume"
        restore_cli init --allowed-root "$RDATA" >/dev/null
        # Wrong confirmations do not consume a valid persisted retry context.
        restore_rejected restore "$TEMP/request.json"
        if ! JOB=$(restore_cli action restore "$TEMP/restore-valid" 2> "$TEMP/restore-retry-error" | jq -r .job_id); then
            printf 'FAIL: confirmed historical restore retry rejected after %s failure (%s): ' "$RPHASE" "$ORIGIN" >&2
            cat "$TEMP/restore-retry-error" >&2
            exit 1
        fi
        restore_finished "$JOB"
        restore_cli job "$JOB" | jq -e '.error==null' >/dev/null
        EXPECTED_PHASE=$RPHASE
        [[ $ORIGIN != paused ]] || EXPECTED_PHASE=paused
        restore_cli status | jq -e --arg phase "$EXPECTED_PHASE" --arg old "$RPHASE" '.phase==$phase and .restore_context==null and .failed_action==null and .interrupted_action==null and (if $phase=="paused" then .pause_from==$old else .pause_from==null end)' >/dev/null
        jq -e '.fixture=="historical"' "$RDATA/history.json" >/dev/null
        [[ ! -e $RDATA/obsolete ]]
        [[ $(sort -u "$RSTATE/service-verbs") == stop ]]
        if [[ $ORIGIN == paused ]]; then
            JOB=$(resume_cli "$RSTATE" "$RPEER_STATE" action resume "$TEMP/blocked-resume" | jq -r .job_id)
            restore_finished "$JOB"
            if [[ $RPHASE == backup_active ]]; then
                # The primary peer is active: resuming another writer must
                # still fail, without consuming its ordinary pause context.
                restore_cli status | jq -e '.phase=="paused" and .pause_from=="backup_active" and (.job.error|contains("权威节点"))' >/dev/null
            else
                restore_cli status | jq -e --arg phase "$RPHASE" '.phase==$phase and .pause_from==null and .job.error==null' >/dev/null
                if [[ $RPHASE == backup_standby ]]; then
                    restore_cli status | jq -e '.handover.id=="committed-history" and .handover.committed==true' >/dev/null
                fi
                JOB=$(restore_cli action pause "$TEMP/request.json" | jq -r .job_id)
                restore_finished "$JOB"
            fi
            [[ $(sort -u "$RSTATE/service-verbs") == stop ]]
        fi
    done
    # Interrupt another retry after stopping CPA; restart reconciliation must
    # preserve its original ordinary-pause context and still deny RESUME.
    JOB=$(
        CPA_STATE_DIR=$RSTATE
        cpa_lock
        id=$(cpa_uuid)
        cpa_job_begin restore "$id"
        PATH="$TEMP/restore-driver:$PATH" cpa_service_control stop
        printf '%s\n' "$id"
    )
    restore_cli tick
    restore_cli status | jq -e '.phase=="paused" and .interrupted_action=="restore" and .pause_from==null and .job.running==false' >/dev/null
    restore_rejected resume "$TEMP/blocked-resume"
    JOB=$(restore_cli action restore "$TEMP/blocked-restore" | jq -r .job_id)
    restore_finished "$JOB"
    restore_rejected resume "$TEMP/blocked-resume"
    # Neither a handover nor another failed destructive action may borrow the
    # independent restore context, even when a restore marker is also present.
    cp "$RSTATE/runtime.json" "$TEMP/restore-protected-runtime"
    for BLOCK in promote prepare-recovery failback handover; do
        case "$BLOCK" in
            handover) restore_fixture_state '.handover={id:"open-handover",committed:false}' ;;
            failback) restore_fixture_state '.failback={handover_id:"protected-failback"}' ;;
            *) restore_fixture_state '.failed_action=$action' --arg action "$BLOCK" ;;
        esac
        restore_rejected restore "$TEMP/restore-valid"
        cp "$TEMP/restore-protected-runtime" "$RSTATE/runtime.json"
    done
    # The signal-abort path also keeps the context when a retry is interrupted.
    (
        CPA_STATE_DIR=$RSTATE
        cpa_lock
        id=$(cpa_uuid)
        cpa_job_begin restore "$id"
        cpa_worker_abort restore "$id"
    ) || [[ $? == 1 ]]
    restore_cli init --allowed-root "$RDATA" >/dev/null
    restore_rejected resume "$TEMP/blocked-resume"
    # Completing data IO is not durable job completion. A crash in between
    # must retain retry authority rather than resurrecting ordinary RESUME.
    JOB=$(
        CPA_STATE_DIR=$RSTATE
        cpa_lock
        id=$(cpa_uuid)
        cpa_job_begin restore "$id"
        PATH="$TEMP/restore-driver:$PATH" cpa_run_action restore "$TEMP/restore-valid" >/dev/null
        printf '%s\n' "$id"
    )
    if ! restore_cli status | jq -e '.phase=="paused" and .pause_from==null and .restore_context!=null and .job.running==true' >/dev/null; then
        printf 'FAIL: %s restore released protection before durable job completion\n' "$RPHASE" >&2
        exit 1
    fi
    restore_cli tick
    restore_rejected resume "$TEMP/blocked-resume"
    JOB=$(restore_cli action restore "$TEMP/restore-valid" | jq -r .job_id)
    restore_finished "$JOB"
    restore_cli status | jq -e --arg old "$RPHASE" '.phase=="paused" and .pause_from==$old and .restore_context==null and .failed_action==null and .interrupted_action==null and .job.error==null' >/dev/null
    [[ $(sort -u "$RSTATE/service-verbs") == stop ]]
    # Legacy failure states and mismatched persisted authority are not guessed.
    restore_fixture_state '.phase="paused"|.failed_action="restore"|del(.pause_from,.restore_context)'
    restore_rejected restore "$TEMP/restore-valid"
    restore_fixture_state '.interrupted_action="restore"|del(.failed_action)'
    restore_rejected restore "$TEMP/restore-valid"
    restore_fixture_state '.restore_context={node_role:"wrong-role",phase:$phase,epoch:.epoch}' --arg phase "$RPHASE"
    restore_rejected restore "$TEMP/restore-valid"
    restore_fixture_state '.restore_context={node_role:$role,phase:$phase,epoch:(.epoch+1)}' --arg role "$RROLE" --arg phase "$RPHASE"
    restore_rejected restore "$TEMP/restore-valid"
    printf 'PASS: %s confirmed restore retries survive failures/restarts/interruptions, retain phase and never start CPA\n' "$RPHASE"
done
printf 'PASS: start confirmation, replay/ambiguity rejection, commit idempotence and stop-only restore\n'

(( REGRESSION_FAILURES == 0 )) || exit 1
