#!/usr/bin/env bash
# Source layout and public entrypoint compatibility; does not install services.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROJECT=$(dirname -- "$ROOT")
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
[[ -f $PROJECT/start.sh ]] || { echo 'FAIL: root start.sh missing' >&2; exit 1; }
bash "$PROJECT/start.sh" --help > "$TMP/root-help"
bash "$ROOT/start.sh" --help > "$TMP/service-help"
cmp "$TMP/root-help" "$TMP/service-help"
for file in setup.sh install-systemd.sh start-dependencies.sh start-lifecycle.sh start-manager.sh; do
  [[ -f $ROOT/scripts/install/$file && -f $ROOT/scripts/$file ]]
done
for file in entrypoint.sh render-nginx.sh render-sshd.sh; do
  [[ -f $ROOT/scripts/runtime/$file && -f $ROOT/scripts/$file ]]
done
for file in Dockerfile compose.yaml .env.example; do
  [[ -f $ROOT/deploy/$file && -f $ROOT/$file ]]
  cmp "$ROOT/deploy/$file" "$ROOT/$file"
done
for file in render-nginx.sh render-sshd.sh; do
  "$ROOT/scripts/$file" > "$TMP/legacy"
  "$ROOT/scripts/runtime/$file" > "$TMP/current"
  cmp "$TMP/legacy" "$TMP/current"
done
bash "$ROOT/scripts/setup.sh" --help > "$TMP/legacy"
bash "$ROOT/scripts/install/setup.sh" --help > "$TMP/current"
cmp "$TMP/legacy" "$TMP/current"
for file in \
  2026-11-05_部署-CPA双机主备-Worker-KV操作手册.md \
  2026-11-05_部署-CPA双机主备-Worker-KV操作手册-中文版.md; do
  [[ -f $PROJECT/docs/cloudflare/$file ]]
done
for file in \
  2026-11-05_部署-CPA双机主备-report.md \
  2026-11-06_部署-CPA双机备份恢复操作手册.md; do
  [[ -f $PROJECT/docs/archive/$file ]]
  grep -q '历史资料' "$PROJECT/docs/archive/$file"
done
[[ -f $PROJECT/docs/development/architecture.md && -f $PROJECT/docs/development/verification.md ]]
[[ ! -d $ROOT/docs ]]
printf 'PASS: categorized source/docs and root/legacy CLI, scripts and deployment compatibility\n'
