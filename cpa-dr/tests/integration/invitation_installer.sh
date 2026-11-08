#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/data"
bash "$ROOT/scripts/setup.sh" --data-dir "$TMP/data" --output "$TMP/docker" --ssh-bind-host 10.20.30.40 >/dev/null
grep -qx 'SSH_BIND_HOST=10.20.30.40' "$TMP/docker/.env"
grep -qx 'BIND_HOST=127.0.0.1' "$TMP/docker/.env"
bash "$ROOT/scripts/install-systemd.sh" --dry-run --data-dir "$TMP/data" --output "$TMP/units" --ssh-bind-host 10.20.30.40 >/dev/null
grep -qx 'ListenAddress 10.20.30.40' "$TMP/units/sshd.conf"
grep -q 'listen 127.0.0.1:8787' "$TMP/units/nginx.conf"
bash "$ROOT/scripts/setup.sh" --data-dir "$TMP/data" --output "$TMP/docker-ipv6" --ssh-bind-host ::1 >/dev/null
grep -qx 'SSH_BIND_HOST=::1' "$TMP/docker-ipv6/.env"
# Exercise the real Compose parser, not only the generated dotenv text.
docker compose --project-directory "$ROOT" --file "$ROOT/deploy/compose.yaml" \
  --env-file "$TMP/docker-ipv6/.env" config --format json > "$TMP/compose-ipv6.json"
jq -e '.services["cpa-dr"].ports |
  any(.target==22 and .published=="2222" and .host_ip=="::1") and
  any(.target==8787 and .published=="8787" and .host_ip=="127.0.0.1")' "$TMP/compose-ipv6.json" >/dev/null
BIND_HOST=::1 docker compose --project-directory "$ROOT" --file "$ROOT/deploy/compose.yaml" \
  --env-file "$TMP/docker-ipv6/.env" config --format json > "$TMP/compose-ipv6-both.json"
jq -e '.services["cpa-dr"].ports |
  any(.target==22 and .published=="2222" and .host_ip=="::1") and
  any(.target==8787 and .published=="8787" and .host_ip=="::1")' "$TMP/compose-ipv6-both.json" >/dev/null
bash "$ROOT/scripts/install-systemd.sh" --dry-run --data-dir "$TMP/data" --output "$TMP/units-ipv6" --ssh-bind-host ::1 >/dev/null
grep -qx 'ListenAddress ::1' "$TMP/units-ipv6/sshd.conf"
if bash "$ROOT/start.sh" join --invite-file "$TMP/missing.json" --ssh-bind-host ::1 > "$TMP/start-ipv6.out" 2>&1; then exit 1; fi
! grep -q 'SSH监听地址含非法字符' "$TMP/start-ipv6.out"
[[ -f "$ROOT/scripts/packaging/bootstrap.sh" && -f "$ROOT/scripts/packaging/generate-command.sh" ]]
# Shell data payloads are never evaluated as code. Archive checks run before extraction.
source "$ROOT/scripts/packaging/bootstrap.sh"
mkdir -p "$TMP/good/cpa-dr/bin"
printf x > "$TMP/good/cpa-dr/bin/cpa-dr"
tar -cf "$TMP/good.tar" -C "$TMP/good" cpa-dr
cpa_bootstrap_check_archive "$TMP/good.tar"
ln -s /etc/passwd "$TMP/good/cpa-dr/bin/link"
tar -cf "$TMP/link.tar" -C "$TMP/good" cpa-dr
if cpa_bootstrap_check_archive "$TMP/link.tar" >/dev/null 2>&1; then echo 'link archive accepted' >&2; exit 1; fi
rm "$TMP/good/cpa-dr/bin/link"
tar -cf "$TMP/traversal.tar" --transform='s,cpa-dr/,cpa-dr/../,' -C "$TMP/good" cpa-dr/bin/cpa-dr
if cpa_bootstrap_check_archive "$TMP/traversal.tar" >/dev/null 2>&1; then echo 'traversal accepted' >&2; exit 1; fi
tar -cf "$TMP/dot-component.tar" --transform='s,cpa-dr/bin/cpa-dr,cpa-dr/.,' -C "$TMP/good" cpa-dr/bin/cpa-dr
if cpa_bootstrap_check_archive "$TMP/dot-component.tar" >/dev/null 2>&1; then echo 'dot path accepted' >&2; exit 1; fi
tar -cf "$TMP/normalized-duplicate.tar" -C "$TMP/good" cpa-dr
tar -rf "$TMP/normalized-duplicate.tar" --transform='s,cpa-dr/bin/cpa-dr,cpa-dr,' -C "$TMP/good" cpa-dr/bin/cpa-dr
if cpa_bootstrap_check_archive "$TMP/normalized-duplicate.tar" >/dev/null 2>&1; then echo 'normalized duplicate accepted' >&2; exit 1; fi
printf '{"version":1,"invite_id":"fixture-invite","temporary_private_key":"fixture-not-a-real-key"}' > "$TMP/invite.json"
command=$(bash "$ROOT/scripts/packaging/generate-command.sh" "$TMP/invite.json")
[[ $command == bash* && $command == *base64* && $command != *'fixture-not-a-real-key'* ]]
help=$(bash "$ROOT/start.sh" --help)
[[ $help == *generate-backup-command* && $help == *configure-ssh* ]]
printf 'PASS: independent SSH binding, bootstrap archive boundaries and installer entrypoints\n'
