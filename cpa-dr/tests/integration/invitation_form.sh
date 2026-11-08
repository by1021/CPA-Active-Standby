#!/usr/bin/env bash
# Exercise actual invitation prompts/serialization with a deterministic CLI edge.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export TEST_ROOT="$ROOT" TEST_REQUEST="$TMP/request.json"
cat > "$TMP/run.sh" <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$TEST_ROOT
source "$ROOT/scripts/install/invitation.sh"
cpa_invitation_select() { deployment=docker; manager_ssh_port=22333; manager_ssh_address=0.0.0.0; record='{"data_dir":"/fixture/default-data"}'; }
cpa_installed_cli() { printf '{"node_role":"primary"}\n'; }
cpa_installed_json() {
  cat > "$TEST_REQUEST"
  jq -n '{invite_id:"test-fake-invitation",expires_at:"2030-01-01T00:00:00Z",command:"echo test-fake-install"}'
}
primary_host=''; primary_port=''; backup_host=''; backup_port=''; backup_data=''; backup_deployment=''; backup_bind=''; backup_output=''
invite_ttl=1800; invite_auto=1; assume_yes=0
prompt() { read -r -p "$1" "$2"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
yes_answer() { [[ $1 == y || $1 == Y || $1 == yes || $1 == YES ]]; }
cpa_generate_invitation
RUN
printf 'primary-fixture\n22334\nbackup-fixture\n22335\n/fixture/backup\nnative\n0.0.0.0\n2400\nn\ny\n' | script -q -e -c "bash $TMP/run.sh" /dev/null > "$TMP/form.out" 2>&1
jq -e '.primary_host=="primary-fixture" and .primary_port==22334 and .backup_host=="backup-fixture" and .backup_port==22335 and .data_dir=="/fixture/backup" and .deployment=="native" and .ttl_seconds==2400 and .auto_enable==false' "$TEST_REQUEST" >/dev/null
printf 'primary-fixture\n\nbackup-fixture\n\n\n\n\n\n\ny\n' | script -q -e -c "bash $TMP/run.sh" /dev/null > "$TMP/default.out" 2>&1
jq -e '.primary_port==22333 and .backup_port==2222 and .data_dir=="/fixture/default-data" and .deployment=="docker" and .ttl_seconds==1800 and .auto_enable==true' "$TEST_REQUEST" >/dev/null
printf 'PASS: actual invitation PTY collects both ports, TTL, first-backup scheduling and preserves default values\n'
