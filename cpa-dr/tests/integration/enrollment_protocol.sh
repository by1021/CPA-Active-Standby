#!/usr/bin/env bash
# Real SSH authentication, invitation registration and callback-safe first backup.
set -Eeuo pipefail
case ${1:-all} in
  all) bash "${BASH_SOURCE[0]}" default; exec bash "${BASH_SOURCE[0]}" custom-transport;;
  default|custom-transport) MODE=$1;;
  *) echo 'unknown enrollment transport fixture' >&2; exit 1;;
esac
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${CPA_TEST_IMAGE:-cpa-dr:enrollment-protocol}
TMP=$(mktemp -d)
if [[ ! -f $ROOT/scripts/packaging/generate-command.sh ]]; then
  cp -a "$ROOT" "$TMP/source"
  ROOT="$TMP/source"
  mkdir -p "$ROOT/scripts/packaging"
  printf '#!/usr/bin/env bash\nprintf "test fixture generator: %%s\\n" "$(jq -r .invite_id "$1")"\n' > "$ROOT/scripts/packaging/generate-command.sh"
fi
SUFFIX=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
NETWORK="cpa-enrollment-$SUFFIX"
PRIMARY="cpa-enroll-primary-$SUFFIX"
BACKUP="cpa-enroll-backup-$SUFFIX"
cleanup() {
  local rc=$?
  if ((rc)); then docker logs --tail 30 "$PRIMARY" >&2 || true; docker logs --tail 30 "$BACKUP" >&2 || true; fi
  docker rm -f "$PRIMARY" "$BACKUP" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then docker build -t "$IMAGE" "$ROOT" >/dev/null; fi
mkdir -p "$TMP"/{primary,backup}/{data,state}
printf '{"fixture":"invitation-first-backup"}\n' > "$TMP/primary/data/file.json"
docker network create "$NETWORK" >/dev/null
for role in primary backup; do
  name=$PRIMARY; [[ $role == primary ]] || name=$BACKUP
  docker run -d --name "$name" --network "$NETWORK" --read-only --tmpfs /run --tmpfs /tmp --tmpfs /var/log/nginx \
    -v "$ROOT:/opt/cpa-dr:ro" -v "$TMP/$role/state:/state:rw" -v "$TMP/$role/data:/data:rw" "$IMAGE" >/dev/null
done
wait_for() { local n=0; until "$@"; do ((n+=1)); ((n<150)) || return 1; sleep .2; done; }
ready() { docker exec "$1" test -f /run/cpa-dr/sshd.pid >/dev/null 2>&1; }
wait_for ready "$PRIMARY"; wait_for ready "$BACKUP"
cli() { docker exec "$1" /opt/cpa-dr/bin/cpa-dr --state-dir /state "${@:2}"; }
IDENTITY_NAME=id_ed25519; KNOWN_NAME=known_hosts
if [[ $MODE == custom-transport ]]; then
  IDENTITY_NAME=custom_identity; KNOWN_NAME=custom_known_hosts
  for role in primary backup; do
    ssh-keygen -q -t ed25519 -N '' -f "$TMP/$role/state/ssh/custom_generated_identity"
    cp "$TMP/$role/state/ssh/custom_generated_identity" "$TMP/$role/state/ssh/$IDENTITY_NAME"
    : > "$TMP/$role/state/ssh/$KNOWN_NAME"
    printf '# test-fixture default known_hosts must stay unchanged\n' > "$TMP/$role/state/ssh/known_hosts"
  done
fi
DEFAULT_PRIMARY=$(sha256sum "$TMP/primary/state/ssh/known_hosts" "$TMP/primary/state/ssh/id_ed25519")
DEFAULT_BACKUP=$(sha256sum "$TMP/backup/state/ssh/known_hosts" "$TMP/backup/state/ssh/id_ed25519")
for role in primary backup; do
  name=$PRIMARY; [[ $role == primary ]] || name=$BACKUP
  cli "$name" config get | jq --arg role "$role" --arg identity "/state/ssh/$IDENTITY_NAME" --arg known "/state/ssh/$KNOWN_NAME" '.node_role=$role|.interval_seconds=3600|.sources=[{name:"auths",kind:"directory",path:"/data"}]|.peer.identity_file=$identity|.peer.known_hosts_file=$known' > "$TMP/$role/state/config-input.json"
  cli "$name" config set /state/config-input.json >/dev/null
done
jq -n --arg primary "$PRIMARY" --arg backup "$BACKUP" '{primary_host:$primary,primary_port:22,backup_host:$backup,backup_port:22,backup_bind_host:"0.0.0.0",data_dir:"/fixture/backup-data",output:"/fixture/deployment",deployment:"docker",auto_enable:true}' > "$TMP/primary/state/options.json"
cli "$PRIMARY" enrollment create /state/options.json > "$TMP/created.json"
ID=$(jq -r .invite_id "$TMP/created.json")
INVITE_DIR="$TMP/primary/state/enrollment/invites/$ID"
cp "$INVITE_DIR/invitation-key" "$TMP/backup/state/invitation-key"
chmod 600 "$TMP/backup/state/invitation-key"
printf '%s %s\n' "$PRIMARY" "$(cut -d ' ' -f1-2 "$TMP/primary/state/ssh/ssh_host_ed25519_key.pub")" > "$TMP/backup/state/ssh/$KNOWN_NAME"
ssh_from() {
  local key=$1; shift
  docker exec -i "$BACKUP" ssh -T -oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes -oUserKnownHostsFile="/state/ssh/$KNOWN_NAME" -i "$key" "root@$PRIMARY" "$@"
}
for command in status id 'archive unknown' "enroll-complete $ID"; do
  if ssh_from /state/invitation-key "$command" >/dev/null 2>&1; then echo "temporary credential allowed $command" >&2; exit 1; fi
done
ssh_from /state/invitation-key "enroll $ID bundle" > "$TMP/downloaded.tar"
[[ $(sha256sum "$TMP/downloaded.tar" | cut -d ' ' -f1) == "$(jq -r .invite.bundle.sha256 "$TMP/created.json")" ]]
PKEY=$(ssh-keygen -y -P '' -f "$TMP/primary/state/ssh/$IDENTITY_NAME" | cut -d ' ' -f1-2)
BKEY=$(ssh-keygen -y -P '' -f "$TMP/backup/state/ssh/$IDENTITY_NAME" | cut -d ' ' -f1-2)
jq -e --arg key "$PKEY" '.invite.primary.public_key==$key' "$TMP/created.json" >/dev/null
BNODE=$(jq -r .node_id "$TMP/backup/state/config.json")
PNODE=$(jq -r .node_id "$TMP/primary/state/config.json")
cli "$BACKUP" trust-key /state/primary-key.pub >/dev/null 2>&1 && { echo 'missing public key accepted' >&2; exit 1; } || true
printf '%s\n' "$PKEY" > "$TMP/backup/state/primary-key.pub"
cli "$BACKUP" trust-key /state/primary-key.pub >/dev/null
cli "$BACKUP" config get | jq --arg host "$PRIMARY" --arg node "$PNODE" '.peer.host=$host|.peer.port=22|.peer.node_id=$node' > "$TMP/backup/state/peer-config.json"
cli "$BACKUP" config set /state/peer-config.json >/dev/null
mkdir -p "$TMP/backup/state/enrollment"
jq -n --arg id "$ID" --arg node "$PNODE" --arg key "$PKEY" '{invite_id:$id,primary_node_id:$node,primary_public_key:$key,auto_enable:true,status:"installed"}' > "$TMP/backup/state/enrollment/join.json"
jq -n --arg node "$BNODE" --arg key "$BKEY" --arg hostkey "$(cat "$TMP/backup/state/ssh/ssh_host_ed25519_key.pub")" --arg host "$BACKUP" '{node_id:$node,public_key:$key,host_key:$hostkey,host:$host,port:22}' > "$TMP/register.json"
# A pinned-host conflict must not publish a claim or authorize an orphan key.
printf '%s %s\n' "$BACKUP" "$(cut -d ' ' -f1-2 "$TMP/primary/state/ssh/ssh_host_ed25519_key.pub")" > "$TMP/primary/state/ssh/$KNOWN_NAME"
if ssh_from /state/invitation-key "enroll $ID register" < "$TMP/register.json" >/dev/null 2>&1; then echo 'real SSH accepted conflicting hostkey' >&2; exit 1; fi
jq -e '.status=="issued" and .claim==null' "$INVITE_DIR/record.json" >/dev/null
[[ $(jq -r '.peer.node_id//empty' "$TMP/primary/state/config.json") == '' ]]
if grep -Fq "$BKEY" "$TMP/primary/state/ssh/authorized_keys"; then echo 'hostkey failure authorized permanent key' >&2; exit 1; fi
if ssh_from "/state/ssh/$IDENTITY_NAME" status >/dev/null 2>&1; then echo 'failed registration granted permanent SSH access' >&2; exit 1; fi
: > "$TMP/primary/state/ssh/$KNOWN_NAME"
if [[ $MODE == custom-transport ]]; then
  printf '%s %s\n' "$BACKUP" "$(cut -d ' ' -f1-2 "$TMP/backup/state/ssh/ssh_host_ed25519_key.pub")" > "$TMP/primary/state/ssh/$KNOWN_NAME"
  ssh-keygen -H -f "$TMP/primary/state/ssh/$KNOWN_NAME" >/dev/null 2>&1
  PIN_BEFORE=$(sha256sum "$TMP/primary/state/ssh/$KNOWN_NAME")
fi
ssh_from /state/invitation-key "enroll $ID register" < "$TMP/register.json" | jq -e '.registered==true' >/dev/null
ssh_from "/state/ssh/$IDENTITY_NAME" status | jq -e '.node_role=="primary"' >/dev/null
ssh_from "/state/ssh/$IDENTITY_NAME" "enroll-complete $ID" > "$TMP/completed.json"
jq -e '.completed==true and .enabled==true and .snapshot_id' "$TMP/completed.json" >/dev/null
SNAP=$(jq -r .snapshot_id "$TMP/completed.json")
cli "$PRIMARY" config get | jq -e '.enabled==true' >/dev/null
cli "$BACKUP" config get | jq -e '.enabled==true' >/dev/null
cli "$BACKUP" status | jq -e --arg snapshot "$SNAP" '.latest_received.id==$snapshot' >/dev/null
[[ ! -e $TMP/backup/data/file.json ]]
[[ $(cat "$TMP/primary/state/admin.token") != "$(cat "$TMP/backup/state/admin.token")" && $PNODE != "$BNODE" && $PKEY != "$BKEY" ]]
if ssh_from /state/invitation-key "enroll $ID status" >/dev/null 2>&1; then echo 'completed temporary credential accepted' >&2; exit 1; fi
ssh_from "/state/ssh/$IDENTITY_NAME" "enroll-complete $ID" | jq -e --arg snapshot "$SNAP" '.completed==true and .snapshot_id==$snapshot' >/dev/null
if ssh_from "/state/ssh/$IDENTITY_NAME" id >/dev/null 2>&1; then echo 'permanent key allowed shell commands' >&2; exit 1; fi
if [[ $MODE == custom-transport ]]; then
  [[ $(sha256sum "$TMP/primary/state/ssh/$KNOWN_NAME") == "$PIN_BEFORE" ]]
  [[ $(sha256sum "$TMP/primary/state/ssh/known_hosts" "$TMP/primary/state/ssh/id_ed25519") == "$DEFAULT_PRIMARY" && $(sha256sum "$TMP/backup/state/ssh/known_hosts" "$TMP/backup/state/ssh/id_ed25519") == "$DEFAULT_BACKUP" ]]
  [[ $PKEY != "$(cut -d ' ' -f1-2 "$TMP/primary/state/ssh/id_ed25519.pub")" && $BKEY != "$(cut -d ' ' -f1-2 "$TMP/backup/state/ssh/id_ed25519.pub")" ]]
  [[ ! -e $TMP/primary/state/ssh/$IDENTITY_NAME.pub && ! -e $TMP/backup/state/ssh/$IDENTITY_NAME.pub ]]
fi
printf 'PASS: real SSH %s identity isolation, pinned package, automatic mutual trust and callback-safe first snapshot activation\n' "$MODE"
