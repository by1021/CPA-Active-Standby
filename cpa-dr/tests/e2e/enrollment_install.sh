#!/usr/bin/env bash
# No-source backup bootstrap -> actual native installer/SSH/CGI -> first backup.
# Only systemctl is simulated, inside a disposable container with no host socket.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
SUFFIX=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
IMAGE="cpa-enrollment-install:$SUFFIX" NETWORK="cpa-enrollment-install-$SUFFIX"
PRIMARY="cpa-enrollment-primary-$SUFFIX" BACKUP="cpa-enrollment-backup-$SUFFIX"
cleanup() {
  local rc=$?
  if ((rc)); then
    for name in "$PRIMARY" "$BACKUP"; do docker logs --tail 25 "$name" >&2 2>/dev/null || true; done
  fi
  docker rm -f "$PRIMARY" "$BACKUP" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
build_source=$ROOT
if [[ ${CPA_TEST_GITHUB:-0} == 1 ]]; then
  commit=1111111111111111111111111111111111111111
  mkdir -p "$TMP/github/CPA-Active-Standby-$commit"
  cp -a "$ROOT" "$TMP/github/CPA-Active-Standby-$commit/cpa-dr"
  build_source="$TMP/github/CPA-Active-Standby-$commit/cpa-dr"
  jq -cn --arg commit "$commit" '{format_version:1,repository:"by1021/CPA-Active-Standby",commit:$commit}' > "$build_source/scripts/packaging/github-source.json"
  tar -czf "$TMP/github-source.tar.gz" -C "$TMP/github" "CPA-Active-Standby-$commit"
fi
docker build -q -f "$build_source/deploy/Dockerfile" -t "$IMAGE" "$build_source" >/dev/null
docker network create "$NETWORK" >/dev/null
mkdir -p "$TMP/primary/data/auths" "$TMP/primary/state"
printf '{"fixture":"primary-original"}\n' > "$TMP/primary/data/auths/original.json"
docker run -d --name "$PRIMARY" --network "$NETWORK" --read-only --tmpfs /run --tmpfs /tmp \
  -v "$TMP/primary/data:/data:rw" -v "$TMP/primary/state:/state:rw" "$IMAGE" >/dev/null
for _ in {1..150}; do
  docker exec "$PRIMARY" curl -fsS http://127.0.0.1:8787/healthz >/dev/null 2>&1 && break
  sleep .2
done
docker exec "$PRIMARY" bash -c 'set -Eeuo pipefail; /opt/cpa-dr/bin/cpa-dr config get | jq '\''.enabled=false|.node_role="primary"|.sources=[{name:"auths",kind:"directory",path:"/data/auths"}]'\'' > /state/fixture-config.json; /opt/cpa-dr/bin/cpa-dr config set /state/fixture-config.json >/dev/null; rm /state/fixture-config.json'
jq -n --arg primary "$PRIMARY" --arg backup "$BACKUP" '{primary_host:$primary,primary_port:22,backup_host:$backup,backup_port:2222,backup_bind_host:"0.0.0.0",data_dir:"/fixture/data",deployment:"native",output:"/etc/cpa-dr-native",auto_enable:true}' > "$TMP/create.json"
docker exec -i "$PRIMARY" sh -c 'umask 077; cat > /tmp/create.json' < "$TMP/create.json"
docker exec "$PRIMARY" /opt/cpa-dr/bin/cpa-dr enrollment create /tmp/create.json > "$TMP/result.json"
if [[ ${CPA_TEST_GITHUB:-0} == 1 ]]; then jq -e --arg commit "$commit" '.invite.bundle.source.commit==$commit' "$TMP/result.json" >/dev/null; fi
jq -r .command "$TMP/result.json" > "$TMP/command.sh"
chmod 600 "$TMP/command.sh" "$TMP/result.json"
# Reuse the mature native lifecycle simulator, without mounting project source.
awk '/^cat > \/usr\/local\/bin\/systemctl <<.MANAGER./ {inside=1;next} /^MANAGER$/ && inside {exit} inside {print}' "$ROOT/tests/e2e/native_installer.sh" > "$TMP/systemctl"
[[ -s $TMP/systemctl ]]
cat > "$TMP/client.sh" <<'CLIENT'
#!/usr/bin/env bash
set -Eeuo pipefail
export MOCK_ROOT=/opt/cpa-dr-native MOCK_STATE=/var/lib/cpa-dr-native MOCK_CFG=/etc/cpa-dr-native
export MOCK_PORT=8787 MOCK_SYSTEMCTL_LOG=/tmp/systemctl.log
mkdir -p /fixture/data /usr/local/bin
install -m 755 /fixture/test/systemctl /usr/local/bin/systemctl
: > "$MOCK_SYSTEMCTL_LOG"
if [[ -f /fixture/test/github-source.tar.gz ]]; then
  cat > /usr/local/bin/curl <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ $argument == https://codeload.github.com/by1021/CPA-Active-Standby/tar.gz/1111111111111111111111111111111111111111 ]]; then
    printf '%s\n' "$argument" >> /tmp/github-downloads
    while (($#)); do
      if [[ $1 == -o ]]; then cp /fixture/test/github-source.tar.gz "$2"; exit 0; fi
      shift
    done
    exit 1
  fi
done
exec /usr/bin/curl "$@"
CURL
  chmod +x /usr/local/bin/curl
fi
# Prove installation does not reuse the image's included service source.
cd /
rm -rf -- /opt/cpa-dr
[[ ! -e /opt/cpa-dr && ! -e /opt/cpa-dr-native ]]
bash /fixture/test/command.sh > /tmp/first-install.out 2>&1 || { tail -35 /tmp/first-install.out >&2; exit 1; }
cli=(/opt/cpa-dr-native/bin/cpa-dr --state-dir /var/lib/cpa-dr-native)
status=$("${cli[@]}" status)
jq -e '.node_role=="backup" and .phase=="backup_standby" and .enabled==true and (.latest_received.id|type=="string")' <<< "$status" >/dev/null
snapshot=$(jq -r .latest_received.id <<< "$status")
jq -e --arg snapshot "$snapshot" '.completion_acknowledged==true and .snapshot_id==$snapshot' "$MOCK_STATE/enrollment/join.json" >/dev/null
"${cli[@]}" snapshots | jq -e --arg snapshot "$snapshot" '.snapshots|any(.id==$snapshot)' >/dev/null
[[ ! -e /fixture/data/auths/original.json ]]
identity=$(sha256sum "$MOCK_STATE/admin.token" "$MOCK_STATE/ssh/id_ed25519" "$MOCK_STATE/ssh/ssh_host_ed25519_key")
node=$(jq -r .node_id <<< "$status")
source_dir=$(jq -r .source_root "$MOCK_CFG/.env.native.json")
[[ $source_dir == /root/.local/share/cpa-dr/sources/*/cpa-dr && -f $source_dir/start.sh ]]
curl -fsS http://127.0.0.1:8787/healthz | jq -e .ok >/dev/null
printf 'PASS: no-source pinned bootstrap, actual native installer/CGI/SSH, automatic pairing and verified first backup\n'
# Original invitation now has a revoked temporary key. Re-executing exactly the
# same generated command must resume from durable source and permanent identity.
bash /fixture/test/command.sh > /tmp/repeat-install.out 2>&1 || { tail -35 /tmp/repeat-install.out >&2; exit 1; }
[[ $(sha256sum "$MOCK_STATE/admin.token" "$MOCK_STATE/ssh/id_ed25519" "$MOCK_STATE/ssh/ssh_host_ed25519_key") == "$identity" ]]
[[ $("${cli[@]}" status | jq -r .node_id) == "$node" ]]
jq -e --arg snapshot "$snapshot" '.status=="completed" and .snapshot_id==$snapshot and .completion_acknowledged==true' "$MOCK_STATE/enrollment/join.json" >/dev/null
printf 'PASS: same generated command resumes completed invitation with revoked temporary credentials and preserves identity\n'
if [[ -f /fixture/test/github-source.tar.gz ]]; then
  [[ $(wc -l < /tmp/github-downloads) == 1 ]]
  jq -e '.commit=="1111111111111111111111111111111111111111"' "$MOCK_ROOT/scripts/packaging/github-source.json" >/dev/null
  printf 'PASS: GitHub-source invitation/HTTPS transport fixture, identical bundle digest, native origin persistence and no redownload on repeat\n'
fi
CLIENT
docker run --name "$BACKUP" --network "$NETWORK" --entrypoint bash \
  -v "$TMP:/fixture/test:ro" "$IMAGE" /fixture/test/client.sh
record=$(docker exec "$PRIMARY" /opt/cpa-dr/bin/cpa-dr enrollment list)
jq -e '.invites|any(.status=="completed")' <<< "$record" >/dev/null
printf 'PASS: primary records completed invitation and automatic backup remains independent of CPA data restore\n'
