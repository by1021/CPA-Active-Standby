#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
if [[ ! -f $ROOT/scripts/packaging/generate-command.sh ]]; then
  cp -a "$ROOT" "$TMP/source"
  ROOT="$TMP/source"
  mkdir -p "$ROOT/scripts/packaging"
  printf '#!/usr/bin/env bash\nprintf "test fixture generator: %%s\\n" "$(jq -r .invite_id "$1")"\n' > "$ROOT/scripts/packaging/generate-command.sh"
fi
mkdir -p "$TMP/data" "$TMP/backup-data"
printf '{"fixture":"invitation"}\n' > "$TMP/data/item.json"
CLI=("$ROOT/bin/cpa-dr" --state-dir "$TMP/state")
"${CLI[@]}" init --allowed-root "$TMP/data" > "$TMP/init.json"
"${CLI[@]}" config get | jq --arg path "$TMP/data" '.sources=[{name:"auths",kind:"directory",path:$path}]' > "$TMP/config.json"
"${CLI[@]}" config set "$TMP/config.json" >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$TMP/state/ssh/ssh_host_ed25519_key"
jq -n --arg path "$TMP/backup-data" --arg out "$TMP/deployment" '{primary_host:"primary.fixture",primary_port:2222,backup_host:"backup.fixture",backup_port:2222,backup_bind_host:"127.0.0.1",data_dir:$path,output:$out,deployment:"docker",ttl_seconds:1800,auto_enable:true}' > "$TMP/options.json"
test_null_options() {
  local value
  for value in null false true; do
    jq --argjson value "$value" '.auto_enable=$value' "$TMP/options.json" > "$TMP/default-auto.json"
    "${CLI[@]}" enrollment create "$TMP/default-auto.json" | jq -e --argjson value "$value" '.invite.auto_enable==(if $value==null then true else $value end)' >/dev/null
  done
}
test_pin_formats() (
  local state="$TMP/pin-formats" file key alternate port endpoint format before pending
  "$ROOT/bin/cpa-dr" --state-dir "$state" init --allowed-root "$TMP/data" >/dev/null
  export CPA_ROOT="$ROOT" CPA_STATE_DIR="$state"
  source "$ROOT/lib/common.sh"; source "$ROOT/lib/enrollment.sh"
  file="$state/ssh/known_hosts"
  key=$(cut -d ' ' -f1-2 "$TMP/state/ssh/ssh_host_ed25519_key.pub")
  alternate=$(cut -d ' ' -f1-2 "$state/ssh/id_ed25519.pub")
  for port in 22 2222; do
    endpoint=backup.fixture; [[ $port == 22 ]] || endpoint="[backup.fixture]:$port"
    for format in plain alias uppercase hashed duplicate; do
      case $format in
        plain) printf '%s %s fixture-comment\n' "$endpoint" "$key" > "$file";;
        alias) printf 'alias.fixture,%s %s fixture-comment\n' "$endpoint" "$key" > "$file";;
        uppercase) printf '%s %s\n' "${endpoint^^}" "$key" > "$file";;
        hashed) printf '%s %s\n' "$endpoint" "$key" > "$file"; ssh-keygen -H -f "$file" >/dev/null 2>&1;;
        duplicate) printf '%s %s\n%s %s fixture-comment\n' "$endpoint" "$key" "$endpoint" "$key" > "$file";;
      esac
      before=$(sha256sum "$file")
      pending=$(cpa_enrollment_known_host_pending BACKUP.FIXTURE "$port" "$key") || { echo "same-key pin rejected: $format" >&2; exit 1; }
      [[ -z $pending ]]
      cpa_enrollment_known_host BACKUP.FIXTURE "$port" "$key"
      [[ $(sha256sum "$file") == "$before" ]]
    done
    for format in different @revoked @cert-authority; do
      printf '%s %s\n' "$endpoint" "$key" > "$file"
      if [[ $format == different ]]; then printf '%s %s\n' "$endpoint" "$alternate" >> "$file"; else printf '%s %s %s\n' "$format" "$endpoint" "$key" >> "$file"; fi
      before=$(sha256sum "$file")
      if cpa_enrollment_known_host BACKUP.FIXTURE "$port" "$key" >/dev/null 2>&1; then echo "conflicting/marked pin accepted: $format" >&2; exit 1; fi
      [[ $(sha256sum "$file") == "$before" ]]
    done
    : > "$file"
    cpa_enrollment_known_host BACKUP.FIXTURE "$port" "$key"
    grep -Fxq "$endpoint $key" "$file"
  done
)
test_transport_files() (
  local mode=$1 state="$TMP/custom-$1" identity known public id dir before path field default_before trust_before keys_before
  local -a cli=("$ROOT/bin/cpa-dr" --state-dir "$state")
  "${cli[@]}" init --allowed-root "$TMP/data" >/dev/null
  ssh-keygen -q -t ed25519 -N '' -f "$state/ssh/ssh_host_ed25519_key"
  identity="$state/ssh/custom_identity"; known="$state/ssh/custom_known_hosts"
  ssh-keygen -q -t ed25519 -N '' -f "$identity"
  public=$(ssh-keygen -y -P '' -f "$identity" | cut -d ' ' -f1-2)
  printf '# test-fixture default known hosts must remain unchanged\n' > "$state/ssh/known_hosts"
  default_before=$(sha256sum "$state/ssh/known_hosts")
  : > "$known"
  "${cli[@]}" config get | jq --arg data "$TMP/data" --arg identity "$identity" --arg known "$known" '.sources=[{name:"auths",kind:"directory",path:$data}]|.peer.identity_file=$identity|.peer.known_hosts_file=$known' > "$TMP/$mode-transport.json"
  "${cli[@]}" config set "$TMP/$mode-transport.json" >/dev/null
  "${cli[@]}" enrollment create "$TMP/options.json" > "$TMP/$mode-created.json"
  if [[ $mode == custom-identity ]]; then
    jq -e --arg public "$public" '.invite.primary.public_key==$public' "$TMP/$mode-created.json" >/dev/null
    [[ $public != "$(cut -d ' ' -f1-2 "$state/ssh/id_ed25519.pub")" ]]
  fi
  id=$(jq -r .invite_id "$TMP/$mode-created.json"); dir="$state/enrollment/invites/$id"
  ssh-keygen -q -t ed25519 -N '' -f "$dir/peer-key"
  ssh-keygen -q -t ed25519 -N '' -f "$dir/peer-host"
  jq -n --arg key "$(cat "$dir/peer-key.pub")" --arg hostkey "$(cat "$dir/peer-host.pub")" '{node_id:"custom-backup",public_key:$key,host_key:$hostkey,host:"backup.fixture",port:2222}' > "$dir/request.json"
  printf 'publickey %s\n' "$(cat "$dir/invitation-key.pub")" > "$dir/auth"
  printf '[backup.fixture]:2222 %s\n' "$(cut -d ' ' -f1-2 "$state/ssh/ssh_host_ed25519_key.pub")" > "$known"
  before=$(sha256sum "$known")
  if SSH_USER_AUTH="$dir/auth" SSH_ORIGINAL_COMMAND="enroll $id register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" < "$dir/request.json" >/dev/null 2>&1; then echo 'custom known_hosts conflict accepted' >&2; exit 1; fi
  jq -e '.status=="issued" and .claim==null' "$dir/record.json" >/dev/null
  if grep -Fq "$(cut -d ' ' -f1-2 "$dir/peer-key.pub")" "$state/ssh/authorized_keys"; then echo 'custom known_hosts conflict granted permanent identity' >&2; exit 1; fi
  [[ $(sha256sum "$known") == "$before" && $(sha256sum "$state/ssh/known_hosts") == "$default_before" ]]
  : > "$known"
  SSH_USER_AUTH="$dir/auth" SSH_ORIGINAL_COMMAND="enroll $id register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" < "$dir/request.json" | jq -e '.registered==true' >/dev/null
  grep -Fxq "[backup.fixture]:2222 $(cut -d ' ' -f1-2 "$dir/peer-host.pub")" "$known"
  [[ $(sha256sum "$state/ssh/known_hosts") == "$default_before" ]]
  if [[ $mode == custom-identity ]]; then
    cp "$identity" "$state/ssh/no_public_identity"
    jq --arg path "$state/ssh/no_public_identity" '.peer.identity_file=$path' "$TMP/$mode-transport.json" > "$TMP/no-public-transport.json"
    "${cli[@]}" config set "$TMP/no-public-transport.json" >/dev/null
    "${cli[@]}" enrollment create "$TMP/options.json" | jq -e --arg public "$public" '.invite.primary.public_key==$public' >/dev/null
    [[ ! -e $state/ssh/no_public_identity.pub ]]
    ssh-keygen -q -t ed25519 -N 'test-fixture-passphrase' -f "$state/ssh/encrypted_identity"
    ssh-keygen -q -t rsa -b 2048 -N '' -f "$state/ssh/rsa_identity"
    cp "$identity" "$state/ssh/stale_identity"
    cp "$state/ssh/id_ed25519.pub" "$state/ssh/stale_identity.pub"
    before=$(find "$state/enrollment/invites" -mindepth 1 -maxdepth 1 -type d | wc -l)
    trust_before=$(sha256sum "$state/ssh/authorized_keys")
    keys_before=$(sha256sum "$identity" "$state/ssh/id_ed25519" "$state/ssh/stale_identity.pub")
    for path in "$state/ssh/missing_identity" "$identity.pub" "$state/ssh/encrypted_identity" "$state/ssh/rsa_identity" "$state/ssh/stale_identity" "$state/ssh/missing_known_hosts" "$state/ssh" "$identity"; do
      field=identity_file
      [[ $path != "$state/ssh/missing_known_hosts" && $path != "$state/ssh" && $path != "$identity" ]] || field=known_hosts_file
      jq --arg field "$field" --arg path "$path" '.peer[$field]=$path' "$TMP/$mode-transport.json" > "$TMP/bad-transport.json"
      "${cli[@]}" config set "$TMP/bad-transport.json" >/dev/null
      if "${cli[@]}" enrollment create "$TMP/options.json" >/dev/null 2> "$TMP/bad-transport.err"; then echo "unusable transport accepted: $field" >&2; exit 1; fi
      grep -Eq '永久|known_hosts|SSH' "$TMP/bad-transport.err"
      [[ $(find "$state/enrollment/invites" -mindepth 1 -maxdepth 1 -type d | wc -l) == "$before" ]]
      [[ $(sha256sum "$state/ssh/authorized_keys") == "$trust_before" && $(sha256sum "$identity" "$state/ssh/id_ed25519" "$state/ssh/stale_identity.pub") == "$keys_before" ]]
    done
  fi
)
test_interrupted_register() (
  local failure=$1 state="$TMP/register-$1" first second id dir key hostkey file host
  local -a cli=("$ROOT/bin/cpa-dr" --state-dir "$state")
  "${cli[@]}" init --allowed-root "$TMP/data" >/dev/null
  "${cli[@]}" config get | jq --arg path "$TMP/data" '.sources=[{name:"auths",kind:"directory",path:$path}]' > "$TMP/$failure-config.json"
  "${cli[@]}" config set "$TMP/$failure-config.json" >/dev/null
  ssh-keygen -q -t ed25519 -N '' -f "$state/ssh/ssh_host_ed25519_key"
  "${cli[@]}" enrollment create "$TMP/options.json" > "$TMP/$failure-first.json"
  jq '.backup_host="second-backup.fixture"' "$TMP/options.json" > "$TMP/$failure-second-options.json"
  "${cli[@]}" enrollment create "$TMP/$failure-second-options.json" > "$TMP/$failure-second.json"
  first=$(jq -r .invite_id "$TMP/$failure-first.json"); second=$(jq -r .invite_id "$TMP/$failure-second.json")
  for id in "$first" "$second"; do
    dir="$state/enrollment/invites/$id"
    ssh-keygen -q -t ed25519 -N '' -f "$dir/peer-key"
    ssh-keygen -q -t ed25519 -N '' -f "$dir/peer-host"
    host=backup.fixture; [[ $id == "$first" ]] || host="second-backup.fixture"
    jq -n --arg node "backup-$id" --arg key "$(cat "$dir/peer-key.pub")" --arg hostkey "$(cat "$dir/peer-host.pub")" --arg host "$host" '{node_id:$node,public_key:$key,host_key:$hostkey,host:$host,port:2222}' > "$dir/request.json"
    printf 'publickey %s\n' "$(cat "$dir/invitation-key.pub")" > "$dir/auth"
  done
  dir="$state/enrollment/invites/$first"
  key=$(cut -d ' ' -f1-2 "$dir/peer-key.pub")
  hostkey=$(cut -d ' ' -f1-2 "$state/ssh/ssh_host_ed25519_key.pub")
  if [[ $failure == hostkey ]]; then
    printf '[backup.fixture]:2222 %s\n' "$hostkey" > "$state/ssh/known_hosts"
    if SSH_USER_AUTH="$dir/auth" SSH_ORIGINAL_COMMAND="enroll $first register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" < "$dir/request.json" >/dev/null 2>&1; then echo 'conflicting hostkey accepted' >&2; exit 1; fi
    jq -e '.status=="issued" and .claim==null' "$dir/record.json" >/dev/null
    if grep -Fq "$key" "$state/ssh/authorized_keys"; then echo 'hostkey failure granted permanent key' >&2; exit 1; fi
    [[ $(jq -r '.peer.node_id//empty' "$state/config.json") == '' ]]
    : > "$state/ssh/known_hosts"
  else
    # Inject only the config write fault; all records, keys and dispatcher are real.
    if (
      export CPA_ROOT="$ROOT" CPA_STATE_DIR="$state" CPA_ENROLL_AUTH_KEY
      CPA_ENROLL_AUTH_KEY=$(cut -d ' ' -f1-2 "$dir/invitation-key.pub")
      source "$ROOT/lib/common.sh"; source "$ROOT/lib/snapshots.sh"
      source "$ROOT/lib/service.sh"; source "$ROOT/lib/enrollment.sh"
      cpa_save_config() { cpa_fail 'test fixture: interrupted config write'; return 1; }
      cpa_lock; cpa_enrollment_register "$first" "$dir/request.json"
    ) >/dev/null 2>&1; then echo 'injected config failure ignored' >&2; exit 1; fi
    jq -e '.status=="registered" and .claim.node_id!=null' "$dir/record.json" >/dev/null
    [[ $(jq -r '.peer.node_id//empty' "$state/config.json") == '' ]]
    file="$state/enrollment/invites/$second"
    if SSH_USER_AUTH="$file/auth" SSH_ORIGINAL_COMMAND="enroll $second register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" < "$file/request.json" >/dev/null 2>&1; then echo 'second identity bypassed durable claim after config failure' >&2; exit 1; fi
    jq -e '.claim==null' "$file/record.json" >/dev/null
    if grep -Fq "$key" "$state/ssh/authorized_keys"; then echo 'config failure granted permanent key' >&2; exit 1; fi
  fi
  # The original claimant can resume after the fault; its identity is unchanged.
  SSH_USER_AUTH="$dir/auth" SSH_ORIGINAL_COMMAND="enroll $first register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" < "$dir/request.json" | jq -e '.registered==true' >/dev/null
  [[ $(jq -r .peer.node_id "$state/config.json") == "backup-$first" ]]
  printf 'publickey %s\n' "$key" > "$dir/permanent-auth"
  SSH_USER_AUTH="$dir/permanent-auth" SSH_ORIGINAL_COMMAND=status "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" | jq -e '.node_role=="primary"' >/dev/null
  "${cli[@]}" enrollment revoke "$first" >/dev/null
  # Revocation keeps the paired permanent identity, including across interruptions.
  jq '.peer.node_id=""|.peer.host=""' "$state/config.json" > "$TMP/$failure-reset.json"
  "${cli[@]}" config set "$TMP/$failure-reset.json" >/dev/null
  file="$state/enrollment/invites/$second"
  if SSH_USER_AUTH="$file/auth" SSH_ORIGINAL_COMMAND="enroll $second register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" < "$file/request.json" >/dev/null 2>&1; then echo 'revocation erased singleton durable identity' >&2; exit 1; fi
  SSH_USER_AUTH="$dir/permanent-auth" SSH_ORIGINAL_COMMAND=status "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" | jq -e '.node_role=="primary"' >/dev/null
  # A new invitation may maintain the endpoint without replacing that identity.
  jq '.host="second-backup.fixture"' "$dir/request.json" > "$file/same-identity.json"
  SSH_USER_AUTH="$file/auth" SSH_ORIGINAL_COMMAND="enroll $second register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$state" < "$file/same-identity.json" | jq -e '.registered==true' >/dev/null
  jq -e --arg node "backup-$first" '.peer.node_id==$node and .peer.host=="second-backup.fixture"' "$state/config.json" >/dev/null
)
case ${1:-all} in
  null-options) test_null_options; exit;;
  register-hostkey) test_interrupted_register hostkey; exit;;
  register-config) test_interrupted_register config; exit;;
  custom-known-hosts) test_transport_files custom-known-hosts; exit;;
  custom-identity) test_transport_files custom-identity; exit;;
  pin-formats) test_pin_formats; exit;;
  all) test_null_options; test_interrupted_register hostkey; test_interrupted_register config; test_transport_files custom-known-hosts; test_transport_files custom-identity; test_pin_formats;;
  *) echo 'unknown enrollment test case' >&2; exit 1;;
esac
"${CLI[@]}" enrollment create "$TMP/options.json" > "$TMP/created.json"
jq -e '.invite_id and .command and .expires_at and .invite.version==1 and .invite.primary.host_key and .invite.temporary_private_key and .invite.sources==[{name:"auths",kind:"directory",relative_path:"."}] and .invite.policy.interval_seconds==60' "$TMP/created.json" >/dev/null
ID=$(jq -r .invite_id "$TMP/created.json")
DIR="$TMP/state/enrollment/invites/$ID"
[[ $(stat -c %a "$DIR/record.json") == 600 && $(stat -c %a "$DIR/invitation-key") == 600 ]]
[[ $(jq -r .invite.temporary_private_key "$TMP/created.json") != "$(cat "$TMP/state/ssh/id_ed25519")" ]]
if grep -Fq "$(cat "$TMP/state/admin.token")" "$TMP/created.json"; then echo 'invitation exposed admin token' >&2; exit 1; fi
"${CLI[@]}" enrollment list | jq -e '.invites|length==4' >/dev/null
if "${CLI[@]}" enrollment list | grep -Eq 'PRIVATE KEY|temporary_private_key|admin_token'; then echo 'invitation list exposed secrets' >&2; exit 1; fi
tar -tf "$DIR/install-bundle.tar" > "$TMP/package-files"
grep -Fxq 'cpa-dr/install-manifest.json' "$TMP/package-files"
if grep -Eq '(^|/)(state|state-native|tests|docs|\.env)(/|$)' "$TMP/package-files"; then echo 'package included private or non-runtime files' >&2; exit 1; fi
[[ $(sha256sum "$DIR/install-bundle.tar" | cut -d ' ' -f1) == "$(jq -r .invite.bundle.sha256 "$TMP/created.json")" ]]
for change in '.ttl_seconds=1' '.ttl_seconds=false' '.backup_port=false' '.auto_enable="false"' '.primary_host="HOST;id"' '.backup_port=65536' '.data_dir="/tmp/../unsafe"' '.deployment="unknown"'; do
  jq "$change" "$TMP/options.json" > "$TMP/invalid.json"
  if "${CLI[@]}" enrollment create "$TMP/invalid.json" >/dev/null 2>&1; then echo "invalid invitation accepted: $change" >&2; exit 1; fi
done
# Separate invitations contend on the same singleton peer configuration.
"${CLI[@]}" enrollment create "$TMP/options.json" > "$TMP/second-created.json"
SECOND=$(jq -r .invite_id "$TMP/second-created.json")
jq 'del(.output)' "$TMP/options.json" > "$TMP/default-options.json"
"${CLI[@]}" enrollment create "$TMP/default-options.json" | jq -e '.invite.backup.output==""' >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$TMP/peer-key"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/peer-host"
jq -n --arg key "$(cat "$TMP/peer-key.pub")" --arg hostkey "$(cat "$TMP/peer-host.pub")" '{node_id:"backup-fixture",public_key:$key,host_key:$hostkey,host:"backup.fixture",port:2222}' > "$TMP/register.json"
printf 'publickey %s\n' "$(cat "$DIR/invitation-key.pub")" > "$TMP/auth"
SSH_USER_AUTH="$TMP/auth" SSH_ORIGINAL_COMMAND="enroll $ID register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" < "$TMP/register.json" | jq -e '.registered==true' >/dev/null
SSH_USER_AUTH="$TMP/auth" SSH_ORIGINAL_COMMAND="enroll $ID register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" < "$TMP/register.json" | jq -e '.registered==true' >/dev/null
jq '.node_id="another-node"' "$TMP/register.json" > "$TMP/other.json"
if SSH_USER_AUTH="$TMP/auth" SSH_ORIGINAL_COMMAND="enroll $ID register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" < "$TMP/other.json" >/dev/null 2>&1; then echo 'invitation allowed another node claim' >&2; exit 1; fi
printf 'publickey %s\n' "$(cat "$TMP/state/enrollment/invites/$SECOND/invitation-key.pub")" > "$TMP/second-auth"
if SSH_USER_AUTH="$TMP/second-auth" SSH_ORIGINAL_COMMAND="enroll $SECOND register" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" < "$TMP/other.json" >/dev/null 2>&1; then echo 'different invitation replaced paired node' >&2; exit 1; fi
[[ $(jq -r .peer.node_id "$TMP/state/config.json") == backup-fixture ]]
[[ $(jq -r .claim "$TMP/state/enrollment/invites/$SECOND/record.json") == null ]]
jq '.expires_unix=0' "$TMP/state/enrollment/invites/$SECOND/record.json" > "$TMP/expired.json"
mv "$TMP/expired.json" "$TMP/state/enrollment/invites/$SECOND/record.json"
if SSH_USER_AUTH="$TMP/second-auth" SSH_ORIGINAL_COMMAND="enroll $SECOND status" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" >/dev/null 2>&1; then echo 'expired invitation accepted' >&2; exit 1; fi
"${CLI[@]}" enrollment list | jq -e --arg id "$SECOND" '.invites|any(.invite_id==$id and .status=="expired")' >/dev/null
for command in status id 'receive node 0' "enroll-complete $ID" "enroll $ID complete"; do
  if SSH_USER_AUTH="$TMP/auth" SSH_ORIGINAL_COMMAND="$command" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" >/dev/null 2>&1; then echo "temporary identity allowed: $command" >&2; exit 1; fi
done
if SSH_USER_AUTH='' SSH_ORIGINAL_COMMAND=status "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" >/dev/null 2>&1; then echo 'missing SSH authentication context accepted' >&2; exit 1; fi
printf 'publickey %s\n' "$(cat "$TMP/peer-key.pub")" > "$TMP/permanent-auth"
SSH_USER_AUTH="$TMP/permanent-auth" SSH_ORIGINAL_COMMAND=status "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" | jq -e '.node_role=="primary"' >/dev/null
"${CLI[@]}" enrollment revoke "$ID" | jq -e '.revoked==true' >/dev/null
if SSH_USER_AUTH="$TMP/auth" SSH_ORIGINAL_COMMAND="enroll $ID status" "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" >/dev/null 2>&1; then echo 'revoked invitation accepted' >&2; exit 1; fi
SSH_USER_AUTH="$TMP/permanent-auth" SSH_ORIGINAL_COMMAND=status "$ROOT/bin/cpa-dr-ssh-dispatch" --state-dir "$TMP/state" | jq -e '.node_role=="primary"' >/dev/null
before=$(sha256sum "$TMP/state/ssh/authorized_keys")
"${CLI[@]}" config get | jq --arg root "$TMP/data" '.sources=[range(0;128)|{name:("source"+(.|tostring)),kind:"directory",path:($root+"/"+("x"*620)+(.|tostring))}]' > "$TMP/oversize-config.json"
"${CLI[@]}" config set "$TMP/oversize-config.json" >/dev/null
if "${CLI[@]}" enrollment create "$TMP/options.json" > "$TMP/oversize.out" 2> "$TMP/oversize.err"; then echo 'oversized invitation accepted' >&2; exit 1; fi
grep -q '超过64KiB' "$TMP/oversize.err"
[[ $(sha256sum "$TMP/state/ssh/authorized_keys") == "$before" ]]
"${CLI[@]}" config set "$TMP/config.json" >/dev/null
# Source packaging is a file whitelist, not an accidental subtree snapshot.
cp -a "$ROOT" "$TMP/package-source"
printf 'test-only credential blob\n' > "$TMP/package-source/lib/credentials.json"
if bash "$ROOT/scripts/packaging/build-install-bundle.sh" "$TMP/package-source" "$TMP/forbidden.tar" >/dev/null 2>&1; then echo 'unexpected source file bundled' >&2; exit 1; fi
printf 'PASS: invitation schema, package whitelist, secrets, validation, claim identity, scoped SSH dispatch and revocation\n'
