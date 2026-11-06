#!/usr/bin/env bash
# Isolate credentials/data; simulate Docker while exercising the real initializer.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
[[ -f $ROOT/start.sh ]] || { echo 'FAIL: start.sh is missing' >&2; exit 1; }
mkdir -p "$TMP/mock" "$TMP/data dir" "$TMP/other-data"
export MOCK_COMPOSE_LOG=$TMP/docker.log
export PATH="$TMP/mock:$PATH"
cat > "$TMP/mock/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
for key in ADMIN_TOKEN CPA_DATA_PATH STATE_PATH PORT SSH_PORT BIND_HOST SSH_BIND_HOST DATA_ACCESS; do
  if [[ -v $key ]]; then echo "Inherited Compose override: $key" >&2; exit 9; fi
done
printf '%q ' "$@" >> "$MOCK_COMPOSE_LOG"; printf '\n' >> "$MOCK_COMPOSE_LOG"
failure=${MOCK_DOCKER_FAIL:-}
if [[ ${1:-} == info ]]; then [[ $failure != info ]] || { echo 'fixture daemon unavailable' >&2; exit 7; }; exit 0; fi
[[ ${1:-} == compose ]] || exit 8
shift
envfile=''
while (($#)); do
  case $1 in
    --env-file) envfile=$2; shift 2;;
    --project-directory|--file) shift 2;;
    *) break;;
  esac
done
case ${1:-} in
  version) [[ $failure != version ]] || { echo 'fixture Compose missing' >&2; exit 7; };;
  config)
    [[ $failure != config ]] || { echo 'fixture configuration error' >&2; exit 7; }
    if [[ ${2:-} == --format && ${3:-} == json ]]; then
      data='' state='' port='' ssh_port='' token='' access=''
      while IFS= read -r line; do
        [[ $line == *=* && $line != \#* ]] || continue
        key=${line%%=*}; value=${line#*=}
        if [[ $value == \'*\' || $value == \"*\" ]]; then value=${value:1:${#value}-2}; fi
        case $key in
          CPA_DATA_PATH) data=$value;; STATE_PATH) state=$value;;
          PORT) port=$value;; SSH_PORT) ssh_port=$value;;
          ADMIN_TOKEN) token=$value;; DATA_ACCESS) access=$value;;
        esac
      done < "$envfile"
      jq -n --arg data "$data" --arg state "$state" --arg port "$port" --arg ssh_port "$ssh_port" --arg token "$token" --arg access "$access" \
        '{services:{"cpa-dr":{environment:{CPA_ADMIN_TOKEN:$token},volumes:[{type:"bind",source:$data,target:"/data",read_only:($access=="ro")},{type:"bind",source:$state,target:"/state"}],ports:[{target:8787,published:$port},{target:22,published:$ssh_port}]}}}'
    fi;;
  up)
    if [[ ${2:-} == --help ]]; then
      [[ $failure == old-compose ]] || echo '--wait --wait-timeout'
    else
      [[ $failure != up ]] || { echo 'fixture build or health timeout' >&2; exit 7; }
      [[ " $* " == *' --build '* && " $* " == *' --wait '* && " $* " == *' --wait-timeout 120 '* ]] || exit 8
    fi;;
  ps) echo 'fixture cpa-dr healthy';;
  port)
    port=$(sed -n 's/^PORT=//p' "$envfile")
    printf '127.0.0.1:%s\n' "$port";;
  *) echo "Unexpected Docker command: $*" >&2; exit 8;;
esac
MOCK
chmod +x "$TMP/mock/docker"
expect_failure() {
  if "$@" > "$TMP/failure.out" 2> "$TMP/failure.err"; then
    printf 'Expected failure: %s\n' "$*" >&2; exit 1
  fi
  if grep -q '服务已启动' "$TMP/failure.out"; then echo 'False startup success' >&2; exit 1; fi
}
start() { bash "$ROOT/start.sh" "$@"; }
up_count() { grep -c ' up -d ' "$MOCK_COMPOSE_LOG" || true; }
fingerprint() { find "$TMP/deployment dir" -type f -exec sha256sum {} + | sort; }

MOCK_DOCKER_FAIL=info start --help > "$TMP/help.out"
grep -q -- '--data-dir' "$TMP/help.out"
expect_failure start --unknown
expect_failure start --port
expect_failure start --output "$TMP/noninteractive" < /dev/null
[[ ! -e $TMP/noninteractive/.env ]]
for failure in info version old-compose; do
  export MOCK_DOCKER_FAIL=$failure
  expect_failure start --data-dir "$TMP/data dir" --output "$TMP/preflight-$failure"
  [[ ! -e $TMP/preflight-$failure/.env ]]
done
unset MOCK_DOCKER_FAIL
expect_failure start --data-dir "$TMP/missing-data" --output "$TMP/missing"
expect_failure start --data-dir "$TMP/data dir" --output "$TMP/bad-port" --port 99999
[[ ! -e $TMP/missing/.env && ! -e $TMP/bad-port/.env ]]
printf 'PASS: help, invalid input, noninteractive initialization and Docker preflight\n'

# Deliberate inherited overrides must not change mounts, credentials or ports.
export ADMIN_TOKEN=wrong CPA_DATA_PATH="$TMP/other-data" STATE_PATH="$TMP/wrong-state" PORT=1 SSH_PORT=2 BIND_HOST=0.0.0.0 SSH_BIND_HOST=0.0.0.0 DATA_ACCESS=rw
(cd /; start --data-dir "$TMP/data dir" --output "$TMP/deployment dir" --port 18877 --ssh-port 22222 --read-only-data) > "$TMP/first.out"
unset ADMIN_TOKEN CPA_DATA_PATH STATE_PATH PORT SSH_PORT BIND_HOST SSH_BIND_HOST DATA_ACCESS
ENVFILE="$TMP/deployment dir/.env"
STATE="$TMP/deployment dir/state-native"
[[ $(stat -c %a "$ENVFILE") == 600 && $(stat -c %a "$STATE/admin.token") == 600 && $(stat -c %a "$STATE/ssh/id_ed25519") == 600 ]]
grep -q '^DATA_ACCESS=ro$' "$ENVFILE"
grep -q '^BIND_HOST=127.0.0.1$' "$ENVFILE"
grep -q 'http://127.0.0.1:18877' "$TMP/first.out"
grep -q "$(cat "$STATE/admin.token")" "$TMP/first.out"
grep -Fq -- "--project-directory $ROOT --file $ROOT/compose.yaml" "$MOCK_COMPOSE_LOG"
[[ $(up_count) == 1 ]]
printf 'preserve state\n' > "$STATE/sentinel"
printf 'preserve known hosts\n' > "$STATE/ssh/known_hosts"
before=$(fingerprint)
start --output "$TMP/deployment dir" > "$TMP/repeat.out"
start --data-dir "$TMP/data dir" --output "$TMP/deployment dir" --port 18877 --ssh-port 22222 --read-only-data > "$TMP/repeat-args.out"
[[ $(fingerprint) == "$before" && $(up_count) == 3 ]]
printf 'PASS: any working directory, private initialization, effective address and identical reruns\n'

expect_failure start --output "$TMP/deployment dir" --data-dir "$TMP/other-data"
expect_failure start --output "$TMP/deployment dir" --port 18878
expect_failure start --output "$TMP/deployment dir" --ssh-port 22223
[[ $(fingerprint) == "$before" && $(up_count) == 3 ]]
mv "$TMP/data dir" "$TMP/data-gone"
expect_failure start --output "$TMP/deployment dir"
[[ ! -e "$TMP/data dir" ]]
mv "$TMP/data-gone" "$TMP/data dir"
mv "$STATE" "$TMP/state-gone"
expect_failure start --output "$TMP/deployment dir"
[[ ! -e $STATE ]]
mv "$TMP/state-gone" "$STATE"
cp "$ENVFILE" "$TMP/original.env"
sed -i "s|^CPA_DATA_PATH=.*|CPA_DATA_PATH='$ROOT'|" "$ENVFILE"
expect_failure start --output "$TMP/deployment dir"
cp "$TMP/original.env" "$ENVFILE"
sed -i "s|^CPA_DATA_PATH=.*|CPA_DATA_PATH='$STATE'|" "$ENVFILE"
expect_failure start --output "$TMP/deployment dir"
cp "$TMP/original.env" "$ENVFILE"
[[ $(up_count) == 3 ]]
printf 'PASS: conflicting parameters, absent mounts and source/state overlap rejected before startup\n'

printf 'FIXTURE_EXEC=$(touch "%s")\n' "$TMP/should-not-exist" >> "$ENVFILE"
start --output "$TMP/deployment dir" > "$TMP/injection.out"
[[ ! -e $TMP/should-not-exist ]]
for failure in config up; do
  export MOCK_DOCKER_FAIL=$failure
  expect_failure start --data-dir "$TMP/data dir" --output "$TMP/failed-$failure"
  [[ -f $TMP/failed-$failure/.env && -f $TMP/failed-$failure/state-native/admin.token ]]
  grep -q "fixture" "$TMP/failure.err"
done
unset MOCK_DOCKER_FAIL
start --data-dir "$TMP/data dir" --output "$TMP/read-write" > /dev/null
expect_failure start --output "$TMP/read-write" --read-only-data
printf 'PASS: dotenv is not executable, configuration/build/health failures preserve state and return nonzero\n'
