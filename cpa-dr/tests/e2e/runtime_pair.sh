#!/usr/bin/env bash
# Real native Linux pair: isolated containers, pinned SSH, HTTP CGI, failback.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${CPA_TEST_IMAGE:-cpa-dr:native-verify}
TMP=$(mktemp -d)
SUFFIX=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
NETWORK="cpa-native-test-$SUFFIX"
PRIMARY="cpa-native-primary-$SUFFIX"
BACKUP="cpa-native-backup-$SUFFIX"
cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    for name in "$PRIMARY" "$BACKUP"; do
      printf '\nNative runtime diagnostics: %s\n' "$name" >&2
      docker logs --tail 30 "$name" >&2 || true
      docker top "$name" -eo pid,ppid,stat,etimes,args >&2 || true
      docker exec "$name" bash -c 'cat /state/runtime.json; cat /proc/locks;
        for fd in /proc/[0-9]*/fd/9; do
          [[ ! -e $fd ]] || { ls -l "$fd"; cat "${fd%/fd/9}/cmdline"; printf "\n"; }
        done' >&2 || true
    done
  fi
  docker rm -f "$PRIMARY" "$BACKUP" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$TMP"/{primary,backup}/{data,state}
printf '{"fixture":"primary"}\n' > "$TMP/primary/data/original.json"
mkdir -p "$TMP/primary/data/empty"
docker network create "$NETWORK" >/dev/null
for role in primary backup; do
  name=$PRIMARY; [[ $role == primary ]] || name=$BACKUP
  docker run -d --name "$name" --network "$NETWORK" \
    -p '127.0.0.1::8787' --read-only --tmpfs /run --tmpfs /tmp --tmpfs /var/log/nginx \
    -v "$TMP/$role/state:/state:rw" -v "$TMP/$role/data:/data:rw" "$IMAGE" >/dev/null
done
base() { printf 'http://127.0.0.1:%s' "$(docker inspect --format '{{(index (index .NetworkSettings.Ports "8787/tcp") 0).HostPort}}' "$1")"; }
PB=$(base "$PRIMARY"); BB=$(base "$BACKUP")
wait_for() {
  local count=0
  until "$@"; do
    (( count+=1 )); (( count < 180 )) || { printf 'Timed out: %s\n' "$*" >&2; return 1; }
    sleep 0.3
  done
}
ready() { [[ -s $TMP/$1/state/admin.token ]] && curl -fsS --max-time 2 "$2/healthz" >/dev/null 2>&1; }
wait_for ready primary "$PB"
wait_for ready backup "$BB"
PT=$(< "$TMP/primary/state/admin.token"); BT=$(< "$TMP/backup/state/admin.token")
api() {
  local base=$1 token=$2 route=$3 method=${4:-GET} body=${5:-}
  local args=(-sS --max-time 30 -w $'\n%{http_code}' -H "Authorization: Bearer $token" -H "Origin: $base" -H 'Content-Type: application/json' -X "$method")
  [[ -z $body ]] || args+=(--data-binary "$body")
  local result code deadline=$((SECONDS+60))
  while :; do
    result=$(curl "${args[@]}" "$base$route") || return
    code=${result##*$'\n'}; result=${result%$'\n'*}
    if [[ $code == 2?? ]]; then printf '%s\n' "$result"; return 0; fi
    # A snapshot can be published before its writer has drained. HTTP 409
    # rejects admission (no task created), so only that conflict is retryable.
    if [[ $code == 409 ]] && ((SECONDS < deadline)); then sleep .2; continue; fi
    printf '%s %s: HTTP %s: %s\n' "$method" "$route" "$code" "$result" >&2
    return 1
  done
}
PP=$(api "$PB" "$PT" /api/pairing); BP=$(api "$BB" "$BT" /api/pairing)
PN=$(jq -r .node_id <<< "$PP"); BN=$(jq -r .node_id <<< "$BP")
for role in primary backup; do
  base=$PB token=$PT other=$BACKUP node=$BN key=$(jq -r .public_key <<< "$BP")
  if [[ $role == backup ]]; then base=$BB; token=$BT; other=$PRIMARY; node=$PN; key=$(jq -r .public_key <<< "$PP"); fi
  api "$base" "$token" /api/pairing POST "$(jq -n --arg key "$key" '{public_key:$key}')" >/dev/null
  config=$(api "$base" "$token" /api/config)
  config=$(jq --arg role "$role" --arg host "$other" --arg node "$node" '
    .node_role=$role | .enabled=false | .interval_seconds=2 | .secondary_interval_seconds=2 | .retention_count=20 |
    .sources=[{name:"auths",path:"/data",kind:"directory"}] |
    .peer={host:$host,port:22,user:"root",identity_file:"/state/ssh/id_ed25519",known_hosts_file:"/state/ssh/known_hosts",node_id:$node}' <<< "$config")
  api "$base" "$token" /api/config PUT "$config" >/dev/null
done
# Test infrastructure trusts keys by comparing scanned bytes to the peer's
# actual persistent host public key, not by blind ssh-keyscan acceptance.
for role in primary backup; do
  name=$PRIMARY other=$BACKUP; [[ $role == primary ]] || { name=$BACKUP; other=$PRIMARY; }
  docker exec "$name" ssh-keyscan -t ed25519 "$other" > "$TMP/scanned-$role" 2>/dev/null
  expected=$(docker exec "$other" cat /state/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
  [[ $(awk '!/^#/ {print $3}' "$TMP/scanned-$role") == "$expected" ]]
  install -m 600 "$TMP/scanned-$role" "$TMP/$role/state/ssh/known_hosts"
done
api "$PB" "$PT" /api/actions/test-peer POST '{}' >/dev/null
api "$BB" "$BT" /api/actions/test-peer POST '{}' >/dev/null
for role in primary backup; do
  base=$PB token=$PT; [[ $role == primary ]] || { base=$BB; token=$BT; }
  config=$(api "$base" "$token" /api/config | jq '.enabled=true')
  api "$base" "$token" /api/config PUT "$config" >/dev/null
done
received() { api "$BB" "$BT" /api/status | jq -e '.latest_received.id != null' >/dev/null; }
secondary() { api "$BB" "$BT" /api/snapshots | jq -e '.snapshots | any(.purpose=="secondary")' >/dev/null; }
wait_for received
wait_for secondary
printf 'PASS: native CGI, restricted SSH pairing, scheduled primary transfer and secondary snapshot\n'
# Native image and project have no Python runtime or old source.
if docker exec "$PRIMARY" sh -c 'command -v python3 || command -v python' >/dev/null 2>&1; then echo 'Unexpected Python runtime' >&2; exit 1; fi
[[ -z $(docker exec "$PRIMARY" find /opt/cpa-dr -name '*.py' -print) ]]
# The accepted peer key must not grant arbitrary remote commands.
if docker exec "$PRIMARY" ssh -oBatchMode=yes -oStrictHostKeyChecking=yes -oUserKnownHostsFile=/state/ssh/known_hosts \
  -i /state/ssh/id_ed25519 "root@$BACKUP" 'id' >/dev/null 2>&1; then echo 'RPC allowed arbitrary command' >&2; exit 1; fi
code=$(curl -sS -o "$TMP/unauth" -w '%{http_code}' "$PB/api/status")
[[ $code == 401 ]]
printf 'PASS: no Python; uncredentialed API and arbitrary SSH commands rejected\n'
job() {
  local base=$1 token=$2 action=$3 body=$4 id result count=0
  result=$(api "$base" "$token" "/api/actions/$action" POST "$body")
  id=$(jq -er .job_id <<< "$result")
  while :; do
    result=$(api "$base" "$token" "/api/jobs/$id")
    if [[ $(jq -r .running <<< "$result") == false ]]; then
      [[ $(jq -r '.error // ""' <<< "$result") == '' ]] || { printf '%s\n' "$result" >&2; return 1; }
      api "$base" "$token" /api/status
      return 0
    fi
    (( count+=1 )); (( count < 300 )) || return 1
    sleep 0.2
  done
}
for role in primary backup; do
  base=$PB token=$PT; [[ $role == primary ]] || { base=$BB; token=$BT; }
  config=$(api "$base" "$token" /api/config | jq '.enabled=false')
  api "$base" "$token" /api/config PUT "$config" >/dev/null
done
idle() { api "$1" "$2" /api/status | jq -e '.job.running != true' >/dev/null; }
wait_for idle "$PB" "$PT"
OLDER=$(api "$BB" "$BT" /api/status | jq -er .latest_received.id)
job "$PB" "$PT" backup '{}' >/dev/null
NEWER=$(api "$BB" "$BT" /api/status | jq -er .latest_received.id)
[[ $NEWER != "$OLDER" ]]
docker exec "$PRIMARY" /opt/cpa-dr/bin/cpa-dr --state-dir /state peer archive "$OLDER" > "$TMP/replayed.tar"
if docker exec -i "$PRIMARY" ssh -oBatchMode=yes -oStrictHostKeyChecking=yes \
  -oUserKnownHostsFile=/state/ssh/known_hosts -i /state/ssh/id_ed25519 "root@$BACKUP" "receive $PN 0" \
  < "$TMP/replayed.tar" >/dev/null 2>&1; then echo 'Same-epoch old snapshot replay was accepted' >&2; exit 1; fi
[[ $(api "$BB" "$BT" /api/status | jq -er .latest_received.id) == "$NEWER" ]]
printf 'PASS: real SSH rejects same-epoch stale replay without rolling back latest snapshot\n'
job "$PB" "$PT" pause '{"confirm":"PAUSE"}' >/dev/null
SNAP=$(api "$BB" "$BT" /api/status | jq -er .latest_received.id)
status=$(job "$BB" "$BT" promote "$(jq -n --arg id "$SNAP" '{snapshot_id:$id,confirm:"PROMOTE",fenced:true,quiesced:true}')")
[[ $(jq -r .phase <<< "$status") == backup_active ]]
[[ -f $TMP/backup/data/original.json && -d $TMP/backup/data/empty ]]
rm -- "$TMP/backup/data/original.json"
printf '{"fixture":"backup takeover"}\n' > "$TMP/backup/data/new.json"
# A delayed archive from the old primary must be refused while backup is active.
docker exec "$PRIMARY" /opt/cpa-dr/bin/cpa-dr --state-dir /state peer archive "$SNAP" > "$TMP/old.tar"
if docker exec -i "$PRIMARY" ssh -oBatchMode=yes -oStrictHostKeyChecking=yes \
  -oUserKnownHostsFile=/state/ssh/known_hosts -i /state/ssh/id_ed25519 "root@$BACKUP" "receive $PN 0" \
  < "$TMP/old.tar" >/dev/null 2>&1; then echo 'Old primary accepted after takeover' >&2; exit 1; fi
job "$PB" "$PT" prepare-recovery '{"confirm":"RECOVER","quiesced":true}' >/dev/null
status=$(job "$PB" "$PT" failback '{"confirm":"FAILBACK","quiesced":true,"backup_quiesced":true}')
[[ $(jq -r .phase <<< "$status") == primary_active ]]
[[ -f $TMP/primary/data/new.json && ! -e $TMP/primary/data/original.json ]]
[[ $(api "$BB" "$BT" /api/status | jq -r .phase) == backup_standby ]]
printf 'PASS: controlled takeover, old-primary rejection, final backfill additions/deletions\n'
# No timer tick may occur between this failback and another outage.
FRESH=$(api "$BB" "$BT" /api/status | jq -er .latest_received.id)
job "$PB" "$PT" pause '{"confirm":"PAUSE"}' >/dev/null
job "$BB" "$BT" promote "$(jq -n --arg id "$FRESH" '{snapshot_id:$id,confirm:"PROMOTE",fenced:true,quiesced:true}')" >/dev/null
[[ -f $TMP/backup/data/new.json && ! -e $TMP/backup/data/original.json ]]
printf '{"fixture":"second takeover"}\n' > "$TMP/backup/data/second.json"
job "$PB" "$PT" prepare-recovery '{"confirm":"RECOVER","quiesced":true}' >/dev/null
job "$PB" "$PT" failback '{"confirm":"FAILBACK","quiesced":true,"backup_quiesced":true}' >/dev/null
[[ -f $TMP/primary/data/new.json && -f $TMP/primary/data/second.json ]]
printf 'PASS: consecutive takeover/failback with scheduling disabled uses fresh primary baseline\n'
# A replayed acknowledgement must not repoint a newer normal backup to the
# already committed handover baseline.
job "$PB" "$PT" backup '{}' >/dev/null
STATE=$(api "$BB" "$BT" /api/status)
ACK=$(jq -er .handover.id <<< "$STATE")
LATEST=$(jq -er .latest_received.id <<< "$STATE")
[[ $LATEST != "$(jq -er .handover.baseline.id <<< "$STATE")" ]]
docker exec "$PRIMARY" ssh -oBatchMode=yes -oStrictHostKeyChecking=yes \
  -oUserKnownHostsFile=/state/ssh/known_hosts -i /state/ssh/id_ed25519 "root@$BACKUP" "commit $ACK" | jq -e '.committed==true' >/dev/null
[[ $(api "$BB" "$BT" /api/status | jq -er .latest_received.id) == "$LATEST" ]]
printf 'PASS: real SSH repeated handover ACK is idempotent and preserves newer received data\n'
# Committed handover history is not a pending handover. Ordinary pause/resume
# must work without discarding the nonce needed for repeat acknowledgements.
job "$BB" "$BT" pause '{"confirm":"PAUSE"}' >/dev/null
job "$BB" "$BT" resume '{"confirm":"RESUME","authoritative":true}' >/dev/null
[[ $(api "$BB" "$BT" /api/status | jq -r .phase) == backup_standby ]]
job "$BB" "$BT" pause '{"confirm":"PAUSE"}' >/dev/null
job "$BB" "$BT" restore "$(jq -n --arg id "$LATEST" '{snapshot_id:$id,confirm:"RESTORE",quiesced:true}')" >/dev/null
[[ $(api "$BB" "$BT" /api/status | jq -r .phase) == paused ]]
job "$BB" "$BT" resume '{"confirm":"RESUME","authoritative":true}' >/dev/null
STATE=$(api "$BB" "$BT" /api/status)
[[ $(jq -r .phase <<< "$STATE") == backup_standby && $(jq -er .handover.id <<< "$STATE") == "$ACK" ]]
printf 'PASS: post-commit standby pause/resume and paused restore/resume preserve handover history\n'
# An independent historical restore failure keeps the node protected, but a
# new explicit RESTORE can repair it even after a committed handover history.
FAILED=$(api "$BB" "$BT" /api/actions/restore POST '{"snapshot_id":"missing_snapshot","confirm":"RESTORE","quiesced":true}')
FAILED_ID=$(jq -er .job_id <<< "$FAILED")
failed_restore_done() { api "$BB" "$BT" "/api/jobs/$FAILED_ID" | jq -e '.running==false and .error!=null' >/dev/null; }
wait_for failed_restore_done
[[ $(api "$BB" "$BT" /api/status | jq -r .phase) == paused ]]
if api "$BB" "$BT" /api/actions/resume POST '{"confirm":"RESUME","authoritative":true}' >/dev/null 2>&1; then echo 'Failed restore allowed generic resume' >&2; exit 1; fi
printf 'transient' > "$TMP/backup/data/restore-only.txt"
job "$BB" "$BT" restore "$(jq -n --arg id "$LATEST" '{snapshot_id:$id,confirm:"RESTORE",quiesced:true}')" >/dev/null
[[ $(api "$BB" "$BT" /api/status | jq -r .phase) == backup_standby ]]
[[ ! -e $TMP/backup/data/restore-only.txt && -f $TMP/backup/data/second.json ]]
printf 'PASS: native CGI failed restore stays protected; confirmed retry repairs data and returns standby\n'
if [[ ${CPA_BROWSER:-0} == 1 ]]; then
  CPA_PRIMARY_URL=$PB CPA_BACKUP_URL=$BB CPA_PRIMARY_TOKEN=$PT CPA_BACKUP_TOKEN=$BT \
    node "$ROOT/tests/browser/runtime.cjs"
fi
docker restart "$PRIMARY" >/dev/null
PB=$(base "$PRIMARY")
wait_for ready primary "$PB"
[[ $(api "$PB" "$PT" /api/status | jq -r .phase) == primary_active ]]
[[ $(api "$PB" "$PT" /api/config | jq -r '.sources[0].name') == auths ]]
api "$PB" "$PT" /api/actions/test-peer POST '{}' >/dev/null
printf 'PASS: config/role/SSH keys persist across container restart\n'
