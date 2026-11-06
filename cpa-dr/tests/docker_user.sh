#!/usr/bin/env bash
# A real non-root Docker client with access to the existing daemon; no account changes.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
((EUID == 0)) && command -v setpriv >/dev/null || { echo 'SKIP: Docker client UID fixture needs root and setpriv'; exit 0; }
TMP=$(mktemp -d)
NAME="cpa-user-smoke-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
cleanup() {
  local rc=$?
  if [[ -f $TMP/deployment/.env ]]; then
    docker compose --project-directory "$TMP/source" --file "$TMP/source/compose.yaml" --env-file "$TMP/deployment/.env" --project-name "$NAME" down >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
mkdir "$TMP/source" "$TMP/data" "$TMP/user-home"
chown 65534 "$TMP/user-home"
for path in bin lib cgi www scripts start.sh Dockerfile compose.yaml .dockerignore; do cp -a -- "$ROOT/$path" "$TMP/source/"; done
chmod 755 "$TMP" "$TMP/source"
chmod -R a+rX "$TMP/source"
printf '{"private":true}\n' > "$TMP/data/settings.json"
chmod 700 "$TMP/data"
# Only the deployment directory is writable by the fixture UID.
mkdir "$TMP/deployment"
chown 65534 "$TMP/deployment"
SOCKET_GID=$(stat -c %g /var/run/docker.sock)
PORT=$((32000 + RANDOM % 8000)); SSH_PORT=$((41000 + RANDOM % 8000))
user_start() {
  setpriv --reuid 65534 --regid "$SOCKET_GID" --clear-groups \
    env HOME="$TMP/user-home" DOCKER_CONFIG="$TMP/user-home/.docker" COMPOSE_PROJECT_NAME="$NAME" bash "$TMP/source/start.sh" "$@"
}
args=(--role primary --deployment docker --data-dir "$TMP/data" --source config:file:settings.json --output "$TMP/deployment" --port "$PORT" --ssh-port "$SSH_PORT" --no-install-deps)
user_start "${args[@]}" > "$TMP/first.out"
STATE="$TMP/deployment/state-native"
[[ $(stat -c %u "$STATE/config.json") == 0 && $(stat -c %a "$STATE/config.json") == 600 ]]
jq -e '.node_role=="primary" and .enabled==false and .sources==[{name:"config",path:"/data/settings.json",kind:"file"}]' "$STATE/config.json" >/dev/null
identity=$(sha256sum "$STATE/config.json" "$STATE/admin.token" "$STATE/ssh/id_ed25519")
# Source-only and role/source reruns read private configuration in the container.
user_start --output "$TMP/deployment" --source config:file:settings.json --no-install-deps > "$TMP/source-repeat.out"
user_start "${args[@]}" > "$TMP/repeat.out"
[[ $(sha256sum "$STATE/config.json" "$STATE/admin.token" "$STATE/ssh/id_ed25519") == "$identity" ]]
mkdir "$TMP/deny-sudo"
printf '#!/usr/bin/env bash\necho "fixture sudo denied" >&2\nexit 77\n' > "$TMP/deny-sudo/sudo"
chmod 755 "$TMP/deny-sudo" "$TMP/deny-sudo/sudo"
if PATH="$TMP/deny-sudo:$PATH" user_start --purge --yes --output "$TMP/deployment" > "$TMP/denied-purge.out" 2>&1; then echo 'denied cleanup accepted' >&2; exit 1; fi
grep -q 'fixture sudo denied' "$TMP/denied-purge.out"
docker compose --project-directory "$TMP/source" --file "$TMP/source/compose.yaml" --env-file "$TMP/deployment/.env" --project-name "$NAME" ps --status running --quiet cpa-dr | grep -q .
[[ -f $STATE/config.json ]]
user_start uninstall --output "$TMP/deployment" --yes > "$TMP/uninstall.out"
[[ -f $STATE/config.json ]]
# Explicit checks on a stopped service use a read-only one-off CLI container.
user_start "${args[@]}" > "$TMP/reinstall.out"
[[ $(sha256sum "$STATE/config.json" "$STATE/admin.token" "$STATE/ssh/id_ed25519") == "$identity" ]]
COMPOSE_PROJECT_NAME="$NAME" bash "$TMP/source/start.sh" --purge --output "$TMP/deployment" --yes > "$TMP/purge.out"
[[ ! -e $STATE && ! -e $TMP/deployment/.env && -f $TMP/data/settings.json ]]
printf 'PASS: real non-root Docker install on private CPA data, container-owned config read/merge, identical/source-only reruns, uninstall/reinstall and root purge preserve original data\n'
