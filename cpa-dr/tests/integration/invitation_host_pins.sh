#!/usr/bin/env bash
# Native pin behavior; opt-in real Docker and SSH identity replacement fixtures.
# shellcheck disable=SC2034
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
cleanup() {
  local rc=$?
  [[ -z ${PIN_CONTAINER:-} ]] || docker rm -f "$PIN_CONTAINER" >/dev/null 2>&1 || true
  [[ -z ${SSH_CONTAINER:-} ]] || docker rm -f "$SSH_CONTAINER" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
source "$ROOT/scripts/install/start-lifecycle.sh"
source "$ROOT/scripts/install/join.sh"
fail() { printf '%s\n' "$*" >&2; exit 1; }
for key in old new client; do ssh-keygen -q -t ed25519 -N '' -f "$TMP/$key"; done
old=$(awk '{print $1 " " $2}' "$TMP/old.pub")
new=$(awk '{print $1 " " $2}' "$TMP/new.pub")
mkdir -p "$TMP/native/ssh" "$TMP/docker/ssh"
deployment=native state="$TMP/native"
jq -n --arg state "$state" '{peer:{identity_file:($state+"/ssh/id_ed25519"),known_hosts_file:($state+"/ssh/known_hosts")}}' > "$state/config.json"
pins="$state/ssh/known_hosts"
printf 'HOST %s\n' "$old" > "$pins"
before=$(sha256sum "$pins")
if (cpa_join_known_host HOST 22 "$new") > "$TMP/error" 2>&1; then echo 'changed native hostkey accepted' >&2; exit 1; fi
[[ $(sha256sum "$pins") == "$before" ]]
printf 'HOST %s\n' "$new" > "$pins"
before=$(sha256sum "$pins")
cpa_join_known_host HOST 22 "$new different-comment"
[[ $(sha256sum "$pins") == "$before" ]]
ssh-keygen -H -f "$pins" >/dev/null 2>&1
before=$(sha256sum "$pins")
cpa_join_known_host HOST 22 "$new"
[[ $(sha256sum "$pins") == "$before" ]]
if (cpa_join_known_host HOST 22 "$old") >/dev/null 2>&1; then echo 'hashed changed pin accepted' >&2; exit 1; fi
[[ $(sha256sum "$pins") == "$before" ]]
printf 'HOST %s\nHOST %s\n' "$new" "$old" > "$pins"
before=$(sha256sum "$pins")
if (cpa_join_known_host HOST 22 "$new") >/dev/null 2>&1; then echo 'multiple conflicting candidates accepted' >&2; exit 1; fi
[[ $(sha256sum "$pins") == "$before" ]]
rm -- "$pins"
cpa_join_known_host HOST 22 "$new" check
[[ ! -e $pins ]]
cpa_join_known_host HOST 22 "$new"
ssh-keygen -F HOST -f "$pins" | grep -Fq "$new"
printf 'PASS: native old/conflicting/hashed pin replacement rejects unchanged; same pin and trusted absence are idempotent\n'
mkdir -p "$state/custom"
cp "$TMP/client" "$state/custom/identity"
# OpenSSH consults a present .pub sidecar; refuse mismatches without rewriting it.
cp "$TMP/old.pub" "$state/custom/identity.pub"
jq --arg known "$state/custom/known_hosts" --arg key "$state/custom/identity" '.peer.known_hosts_file=$known|.peer.identity_file=$key' "$state/config.json" > "$TMP/config.json"
mv "$TMP/config.json" "$state/config.json"
printf 'HOST %s\n' "$old" > "$state/custom/known_hosts"
before=$(sha256sum "$pins" "$state/config.json" "$state/custom/known_hosts" "$state/custom/identity" "$state/custom/identity.pub")
if cpa_join_known_host HOST 22 "$new" check; then echo 'custom native pin conflict ignored' >&2; exit 1; fi
[[ $(sha256sum "$pins" "$state/config.json" "$state/custom/known_hosts" "$state/custom/identity" "$state/custom/identity.pub") == "$before" ]]
if cpa_join_public_key >/dev/null 2>&1; then echo 'stale native identity sidecar accepted' >&2; exit 1; fi
[[ $(sha256sum "$pins" "$state/config.json" "$state/custom/known_hosts" "$state/custom/identity" "$state/custom/identity.pub") == "$before" ]]
cp "$TMP/client.pub" "$state/custom/identity.pub"
[[ $(cpa_join_public_key) == "$(awk '{print $1 " " $2}' "$TMP/client.pub")" ]]
rm -- "$state/custom/identity.pub"
rm -- "$state/custom/known_hosts"
default_before=$(sha256sum "$pins")
cpa_join_known_host HOST 22 "$new"
[[ $(sha256sum "$pins") == "$default_before" ]]
[[ $(cpa_join_public_key) == "$(awk '{print $1 " " $2}' "$TMP/client.pub")" ]]
printf 'PASS: native custom trust alone is inspected/written; registration key derives from configured private identity\n'

if [[ -n ${CPA_JOIN_DOCKER_IMAGE:-} ]]; then
  suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  PIN_CONTAINER="cpa-invitation-pin-$suffix"
  mkdir -p "$TMP/docker/custom"
  docker run -d --name "$PIN_CONTAINER" --read-only --entrypoint sleep \
    -v "$TMP/docker:/state:rw" -v "$TMP/docker/custom:/custom:rw" "$CPA_JOIN_DOCKER_IMAGE" 300 >/dev/null
  deployment=docker state="$TMP/docker" manager_container=$PIN_CONTAINER manager_service=运行中
  jq -n '{peer:{identity_file:"/state/ssh/id_ed25519",known_hosts_file:"/state/ssh/known_hosts"}}' > "$state/config.json"
  pins="$TMP/docker/ssh/known_hosts"
  printf '[HOST]:2222 %s\n' "$old" > "$pins"
  before=$(sha256sum "$pins")
  if (cpa_join_known_host HOST 2222 "$new") > "$TMP/error" 2>&1; then echo 'changed Docker hostkey accepted' >&2; exit 1; fi
  [[ $(sha256sum "$pins") == "$before" ]]
  printf '[HOST]:2222 %s\n' "$new" > "$pins"
  ssh-keygen -H -f "$pins" >/dev/null 2>&1
  before=$(sha256sum "$pins")
  cpa_join_known_host HOST 2222 "$new"
  [[ $(sha256sum "$pins") == "$before" ]]
  if (cpa_join_known_host HOST 2222 "$old") >/dev/null 2>&1; then echo 'changed hashed Docker hostkey accepted' >&2; exit 1; fi
  [[ $(sha256sum "$pins") == "$before" ]]
  rm -- "$pins"
  cpa_join_known_host HOST 2222 "$new" check
  [[ ! -e $pins ]]
  cpa_join_known_host HOST 2222 "$new"
  ssh-keygen -F '[HOST]:2222' -f "$pins" | grep -Fq "$new"
  printf 'PASS: real Docker old/hashed hostkey replacement rejects unchanged; same and absent pins succeed\n'
  mkdir -p "$state/custom"
  cp "$TMP/client" "$state/custom/identity"
  cp "$TMP/old.pub" "$state/custom/identity.pub"
  jq '.peer.known_hosts_file="/state/custom/known_hosts"|.peer.identity_file="/state/custom/identity"' "$state/config.json" > "$TMP/config.json"
  mv "$TMP/config.json" "$state/config.json"
  printf '[HOST]:2222 %s\n' "$old" > "$state/custom/known_hosts"
  before=$(sha256sum "$pins" "$state/config.json" "$state/custom/known_hosts" "$state/custom/identity" "$state/custom/identity.pub")
  if cpa_join_known_host HOST 2222 "$new" check; then echo 'custom Docker pin conflict ignored' >&2; exit 1; fi
  [[ $(sha256sum "$pins" "$state/config.json" "$state/custom/known_hosts" "$state/custom/identity" "$state/custom/identity.pub") == "$before" ]]
  if cpa_join_public_key >/dev/null 2>&1; then echo 'stale Docker identity sidecar accepted' >&2; exit 1; fi
  [[ $(sha256sum "$pins" "$state/config.json" "$state/custom/known_hosts" "$state/custom/identity" "$state/custom/identity.pub") == "$before" ]]
  cp "$TMP/client.pub" "$state/custom/identity.pub"
  [[ $(cpa_join_public_key) == "$(awk '{print $1 " " $2}' "$TMP/client.pub")" ]]
  rm -- "$state/custom/identity.pub"
  rm -- "$state/custom/known_hosts"
  default_before=$(sha256sum "$pins")
  cpa_join_known_host HOST 2222 "$new"
  [[ $(sha256sum "$pins") == "$default_before" ]]
  [[ $(cpa_join_public_key) == "$(awk '{print $1 " " $2}' "$TMP/client.pub")" ]]
  jq '.peer.known_hosts_file="/custom/known_hosts"|.peer.identity_file="/custom/identity"' "$state/config.json" > "$TMP/config.json"
  mv "$TMP/config.json" "$state/config.json"
  cpa_join_known_host HOST 2222 "$new" check
  [[ $(cpa_join_public_key) == "$(awk '{print $1 " " $2}' "$TMP/client.pub")" ]]
  printf 'PASS: real Docker uses custom /state and external mounted paths; rejects stale sidecar without changing identity\n'

  mkdir -p "$TMP/server"
  cp "$TMP/old" "$TMP/server/active-key"
  cp "$TMP/client.pub" "$TMP/server/authorized_keys"
  cat > "$TMP/server/sshd.conf" <<'SSHD'
Port 22
ListenAddress 0.0.0.0
HostKey /fixture/ssh/active-key
AuthorizedKeysFile /fixture/ssh/authorized_keys
ForceCommand /usr/bin/printf fixture-ssh-ok
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM no
StrictModes yes
SSHD
  SSH_CONTAINER="cpa-invitation-pin-ssh-$suffix"
  docker run -d --name "$SSH_CONTAINER" --entrypoint /usr/sbin/sshd \
    -v "$TMP/server:/fixture/ssh:ro" "$CPA_JOIN_DOCKER_IMAGE" -D -e -f /fixture/ssh/sshd.conf >/dev/null
  host=$(docker inspect "$SSH_CONTAINER" | jq -r '.[0].NetworkSettings.IPAddress')
  deployment=native state="$TMP/native"
  pins="$state/custom/known_hosts"
  printf '%s %s\n' "$host" "$old" > "$pins"
  ssh=(ssh -T -oBatchMode=yes -oStrictHostKeyChecking=yes -oIdentitiesOnly=yes -oConnectTimeout=2 -o "UserKnownHostsFile=$pins" -i "$TMP/client" "root@$host" fixture-check)
  for _ in {1..50}; do [[ $("${ssh[@]}" 2>/dev/null || true) == fixture-ssh-ok ]] && break; sleep .1; done
  [[ $("${ssh[@]}" 2>/dev/null) == fixture-ssh-ok ]]
  jq -n --arg host "$host" '{primary:{host:$host,port:22}}' > "$TMP/invite.json"
  native_before=$(sha256sum "$state/config.json" "$state/ssh/known_hosts" "$state/custom/identity")
  [[ $(cpa_join_ssh permanent fixture-check "$TMP/invite.json") == fixture-ssh-ok ]]
  [[ $(sha256sum "$state/config.json" "$state/ssh/known_hosts" "$state/custom/identity") == "$native_before" ]]
  deployment=docker state="$TMP/docker" manager_service=运行中
  printf '%s %s\n' "$host" "$old" > "$state/custom/known_hosts"
  docker_before=$(sha256sum "$state/config.json" "$state/ssh/known_hosts" "$state/custom/identity")
  [[ $(cpa_join_ssh permanent fixture-check "$TMP/invite.json") == fixture-ssh-ok ]]
  [[ $(sha256sum "$state/config.json" "$state/ssh/known_hosts" "$state/custom/identity") == "$docker_before" ]]
  printf 'PASS: native and actual Docker permanent SSH authenticate with configured custom identity/trust without modifying defaults\n'
  deployment=native state="$TMP/native"
  cp "$TMP/new" "$TMP/server/active-key"
  docker restart "$SSH_CONTAINER" >/dev/null
  # A bounded readiness probe only: never import its unauthenticated result.
  for _ in {1..50}; do
    observed=$(ssh-keyscan -T 1 -t ed25519 "$host" 2>/dev/null | awk '$2=="ssh-ed25519" {print $2 " " $3}' || true)
    [[ $observed == "$new" ]] && break
    sleep .1
  done
  [[ $observed == "$new" ]]
  before=$(sha256sum "$pins")
  if (cpa_join_known_host "$host" 22 "$new") >/dev/null 2>&1; then echo 'real replaced SSH identity added to old pin' >&2; exit 1; fi
  [[ $(sha256sum "$pins") == "$before" ]]
  if "${ssh[@]}" > "$TMP/ssh.out" 2> "$TMP/ssh.error"; then echo 'real strict SSH accepted replaced hostkey' >&2; exit 1; fi
  grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED\|Host key verification failed' "$TMP/ssh.error"
  printf 'PASS: real SSH authenticated original hostkey; actual replacement is rejected without altering trusted pin\n'
fi
