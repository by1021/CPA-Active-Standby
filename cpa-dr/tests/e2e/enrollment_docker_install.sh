#!/usr/bin/env bash
# No-source Docker bootstrap using a real host Docker client, SSH and containers.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
SUFFIX=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
IMAGE="cpa-enrollment-docker:$SUFFIX" NETWORK="cpa-enrollment-docker-$SUFFIX"
PRIMARY="cpa-enrollment-docker-primary-$SUFFIX" project='' backup=''
cleanup() {
  local rc=$?
  if ((rc)); then
    [[ ! -f $TMP/install.out ]] || tail -35 "$TMP/install.out" >&2
    [[ -z $backup ]] || docker logs --tail 15 "$backup" >&2 2>/dev/null || true
  fi
  if [[ -f $TMP/backup/.env.docker.json ]]; then project=$(jq -r .project_name "$TMP/backup/.env.docker.json"); fi
  if [[ -n $project ]]; then
    while IFS= read -r container; do [[ -z $container ]] || docker rm -f "$container" >/dev/null 2>&1 || true; done < <(docker ps -aq --filter "label=com.docker.compose.project=$project")
    docker network rm "${project}_default" >/dev/null 2>&1 || true
  fi
  docker rm -f "$PRIMARY" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
build_source=$ROOT
if [[ ${CPA_TEST_GITHUB:-0} == 1 ]]; then
  commit=1111111111111111111111111111111111111111
  mkdir -p "$TMP/github/CPA-Active-Standby-$commit" "$TMP/bin"
  cp -a "$ROOT" "$TMP/github/CPA-Active-Standby-$commit/cpa-dr"
  build_source="$TMP/github/CPA-Active-Standby-$commit/cpa-dr"
  jq -cn --arg commit "$commit" '{format_version:1,repository:"by1021/CPA-Active-Standby",commit:$commit}' > "$build_source/scripts/packaging/github-source.json"
  tar -czf "$TMP/github-source.tar.gz" -C "$TMP/github" "CPA-Active-Standby-$commit"
  export CPA_GITHUB_FIXTURE="$TMP" CPA_REAL_CURL
  CPA_REAL_CURL=$(command -v curl)
  cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ $argument == https://codeload.github.com/by1021/CPA-Active-Standby/tar.gz/1111111111111111111111111111111111111111 ]]; then
    printf '%s\n' "$argument" >> "$CPA_GITHUB_FIXTURE/github-downloads"
    while (($#)); do
      if [[ $1 == -o ]]; then cp "$CPA_GITHUB_FIXTURE/github-source.tar.gz" "$2"; exit 0; fi
      shift
    done
    exit 1
  fi
done
exec "$CPA_REAL_CURL" "$@"
CURL
  chmod +x "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"
fi
docker build -q -f "$build_source/deploy/Dockerfile" -t "$IMAGE" "$build_source" >/dev/null
docker network create "$NETWORK" >/dev/null
mkdir -p "$TMP/primary/data/auths" "$TMP/primary/state" "$TMP/home"
printf '{"fixture":"primary-original"}\n' > "$TMP/primary/data/auths/original.json"
docker run -d --name "$PRIMARY" --network "$NETWORK" --read-only --tmpfs /run --tmpfs /tmp -p 0:22 \
  -v "$TMP/primary/data:/data:rw" -v "$TMP/primary/state:/state:rw" "$IMAGE" >/dev/null
for _ in {1..150}; do docker exec "$PRIMARY" curl -fsS http://127.0.0.1:8787/healthz >/dev/null 2>&1 && break; sleep .2; done
docker exec "$PRIMARY" bash -c 'set -Eeuo pipefail; /opt/cpa-dr/bin/cpa-dr config get | jq '\''.enabled=false|.node_role="primary"|.sources=[{name:"auths",kind:"directory",path:"/data/auths"}]'\'' > /state/fixture-config.json; /opt/cpa-dr/bin/cpa-dr config set /state/fixture-config.json >/dev/null'
host=$(docker network inspect "$NETWORK" | jq -r '.[0].IPAM.Config[0].Gateway')
port=$(docker inspect "$PRIMARY" | jq -r '.[0].NetworkSettings.Ports["22/tcp"][0].HostPort')
# Reserve available host ports without touching any existing application.
read -r ssh_port < <(python3 - <<'PORTS'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
PORTS
)
jq -n --arg host "$host" --argjson port "$port" --arg data "$TMP/data" --arg output "$TMP/backup" --argjson backup_port "$ssh_port" \
  '{primary_host:$host,primary_port:$port,backup_host:$host,backup_port:$backup_port,backup_bind_host:$host,data_dir:$data,deployment:"docker",output:$output,auto_enable:true}' > "$TMP/create.json"
docker exec -i "$PRIMARY" sh -c 'umask 077; cat > /tmp/create.json' < "$TMP/create.json"
docker exec "$PRIMARY" /opt/cpa-dr/bin/cpa-dr enrollment create /tmp/create.json > "$TMP/result.json"
if [[ ${CPA_TEST_GITHUB:-0} == 1 ]]; then jq -e --arg commit "$commit" '.invite.bundle.source.commit==$commit' "$TMP/result.json" >/dev/null; fi
jq -r .command "$TMP/result.json" > "$TMP/command.sh"
chmod 600 "$TMP/command.sh" "$TMP/result.json"
# Run the exact generated command from an empty private HOME: no source mount.
HOME="$TMP/home" bash "$TMP/command.sh" > "$TMP/install.out" 2>&1
project=$(jq -r .project_name "$TMP/backup/.env.docker.json")
backup=$(docker ps -q --filter "label=com.docker.compose.project=$project")
[[ -n $backup ]]
status=$(docker exec "$backup" /opt/cpa-dr/bin/cpa-dr status)
jq -e '.node_role=="backup" and .phase=="backup_standby" and .enabled and (.latest_received.id|type=="string")' <<< "$status" >/dev/null
snapshot=$(jq -r .latest_received.id <<< "$status")
jq -e --arg snapshot "$snapshot" '.completion_acknowledged==true and .snapshot_id==$snapshot' "$TMP/backup/state-native/enrollment/join.json" >/dev/null
[[ ! -e $TMP/data/auths/original.json ]]
identity=$(sha256sum "$TMP/backup/state-native/admin.token" "$TMP/backup/state-native/ssh/id_ed25519" "$TMP/backup/state-native/ssh/ssh_host_ed25519_key")
source_dir=$(jq -r .source_root "$TMP/backup/.env.docker.json")
[[ $source_dir == "$TMP/home/.local/share/cpa-dr/sources/"*"/cpa-dr" && -f $source_dir/deploy/Dockerfile && -f $source_dir/.dockerignore ]]
HOME="$TMP/home" bash "$TMP/command.sh" > "$TMP/repeat.out" 2>&1
[[ $(sha256sum "$TMP/backup/state-native/admin.token" "$TMP/backup/state-native/ssh/id_ed25519" "$TMP/backup/state-native/ssh/ssh_host_ed25519_key") == "$identity" ]]
jq -e --arg snapshot "$snapshot" '.status=="completed" and .snapshot_id==$snapshot and .completion_acknowledged==true' "$TMP/backup/state-native/enrollment/join.json" >/dev/null
printf 'PASS: no-source Docker client bootstrap, container pairing/first backup, durable source and exact-command identity-preserving replay\n'
if [[ ${CPA_TEST_GITHUB:-0} == 1 ]]; then
  [[ $(wc -l < "$TMP/github-downloads") == 1 ]]
  docker exec "$backup" jq -e --arg commit "$commit" '.commit==$commit' /opt/cpa-dr/scripts/packaging/github-source.json >/dev/null
  printf 'PASS: GitHub-source Docker pairing, digest equality, origin persistence and no redownload on repeat\n'
fi
