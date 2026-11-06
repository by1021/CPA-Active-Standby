#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/data dir" "$TMP/out"
bash "$ROOT/scripts/setup.sh" --data-dir "$TMP/data dir" --output "$TMP/out" --port 18877 --ssh-port 22222 > "$TMP/setup.log"
[[ $(stat -c %a "$TMP/out/.env") == 600 ]]
[[ $(stat -c %a "$TMP/out/state-native/admin.token") == 600 ]]
[[ $(stat -c %a "$TMP/out/state-native/ssh/id_ed25519") == 600 ]]
grep -q '^STATE_PATH=' "$TMP/out/.env"
grep -q '^SSH_PORT=22222$' "$TMP/out/.env"
grep -q '^ADMIN_TOKEN=[a-f0-9]\{64\}$' "$TMP/out/.env"
old=$(sha256sum "$TMP/out/.env")
if bash "$ROOT/scripts/setup.sh" --data-dir "$TMP/data dir" --output "$TMP/out" > /dev/null 2>&1; then echo 'existing env overwritten' >&2; exit 1; fi
[[ $(sha256sum "$TMP/out/.env") == "$old" ]]
if bash "$ROOT/scripts/setup.sh" --data-dir "$TMP/data dir" --output "$TMP/data dir/unsafe" > /dev/null 2>&1; then echo 'nested state accepted' >&2; exit 1; fi
mkdir -p "$TMP/data%unsafe"
if bash "$ROOT/scripts/install-systemd.sh" --dry-run --data-dir "$TMP/data%unsafe" --output "$TMP/unsafeunits" > /dev/null 2>&1; then echo 'systemd percent specifier accepted in data path' >&2; exit 1; fi
bash "$ROOT/scripts/install-systemd.sh" --dry-run --data-dir "$TMP/data dir" --output "$TMP/units" > /dev/null
[[ -f "$TMP/units/cpa-dr-native-tick.timer" ]]
grep -q 'OnUnitInactiveSec=1s' "$TMP/units/cpa-dr-native-tick.timer"
grep -q -- '--state-dir /var/lib/cpa-dr-native tick' "$TMP/units/cpa-dr-native-tick.service"
grep -q 'SCRIPT_FILENAME /opt/cpa-dr-native/cgi/api.cgi' "$TMP/units/nginx.conf"
grep -Fq "fastcgi_param HTTP_HOST \$http_host;" "$TMP/units/nginx.conf"
grep -Fq 'fastcgi_pass_request_headers off;' "$TMP/units/nginx.conf"
[[ $(grep -c 'fastcgi_param HTTP_HOST ' "$TMP/units/nginx.conf") == 1 ]]
[[ $(grep -c 'fastcgi_param HTTP_ORIGIN ' "$TMP/units/nginx.conf") == 1 ]]
[[ $(grep -c 'fastcgi_param HTTP_AUTHORIZATION ' "$TMP/units/nginx.conf") == 1 ]]
for protocol in proxy uwsgi scgi; do
  grep -q "${protocol}_temp_path /run/cpa-dr-native/$protocol;" "$TMP/units/nginx.conf"
done
grep -q 'PasswordAuthentication no' "$TMP/units/sshd.conf"
grep -q 'AuthorizedKeysFile /var/lib/cpa-dr-native/ssh/authorized_keys' "$TMP/units/sshd.conf"
if grep -Ei 'python|pip install' "$ROOT/Dockerfile" "$ROOT/compose.yaml" "$ROOT"/scripts/*.sh; then echo 'unexpected interpreter runtime' >&2; exit 1; fi
grep -q 'rm -f /etc/ssh/ssh_host_' "$ROOT/Dockerfile"
[[ $(grep -c 'StrictHostKeyChecking=no' "$ROOT/README.md" || true) == 0 ]]
bash -n "$ROOT"/scripts/*.sh
printf '%s\n' 'PASS: native setup secret permissions, preservation, path isolation, dry-run units and no interpreter runtime'
