#!/usr/bin/env bash
# Run real startup preflight in an isolated PATH; never install host packages.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
HOST_PATH=$PATH
required=(bash dirname realpath stat cat mkdir chmod touch openssl ssh-keygen flock jq sha256sum mktemp sync mv rm timeout curl)
reset_fixture() {
  rm -rf -- "${TMP:?}/bin" "$TMP/out"
  mkdir -p "$TMP/bin" "$TMP/out" "$TMP/tools" "$TMP/data"
  : > "$TMP/packages.log"; : > "$TMP/docker.log"
  for tool in "${required[@]}"; do ln -s "$(PATH=$HOST_PATH command -v "$tool")" "$TMP/bin/$tool"; done
  export FIXTURE_BIN="$TMP/bin" FIXTURE_LOG="$TMP/packages.log" FIXTURE_DOCKER_LOG="$TMP/docker.log"
  FIXTURE_JQ=$(PATH=$HOST_PATH command -v jq); FIXTURE_SSH=$(PATH=$HOST_PATH command -v ssh-keygen)
  FIXTURE_CURL=$(PATH=$HOST_PATH command -v curl); FIXTURE_TIMEOUT=$(PATH=$HOST_PATH command -v timeout)
  export FIXTURE_JQ FIXTURE_SSH FIXTURE_CURL FIXTURE_TIMEOUT
  export FIXTURE_COMPOSE=ready FIXTURE_FAIL='' FIXTURE_NO_PACKAGE='' FIXTURE_SPLIT_CLI=0 FIXTURE_COMPOSE_VERSION=2.26.1-4
  for tool in dirname realpath stat cat; do ln -sf "$(command -v "$tool")" "$TMP/tools/$tool"; done
  cat > "$TMP/docker-template" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_DOCKER_LOG"
case "$*" in
  'compose version') [[ $FIXTURE_COMPOSE != missing || -e $FIXTURE_BIN/compose-ready ]];;
  'compose up --help')
    if [[ $FIXTURE_COMPOSE == ready || -e $FIXTURE_BIN/compose-ready ]]; then echo '--wait --wait-timeout'
    elif [[ $FIXTURE_COMPOSE == timeout-only ]]; then echo '--wait-timeout'; fi;;
  info) echo 'fixture daemon reached after dependency checks' >&2; exit 17;;
  *) exit 18;;
esac
MOCK
  chmod +x "$TMP/docker-template"
  cp "$TMP/docker-template" "$TMP/bin/docker"
  cat > "$TMP/bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "apt-get $*" >> "$FIXTURE_LOG"
[[ ${1:-} != "$FIXTURE_FAIL" ]] || { echo 'fixture package operation failed' >&2; exit 12; }
if [[ ${1:-} == install ]]; then
  [[ $FIXTURE_FAIL != no-effect ]] || exit 0
  ln -sf "$FIXTURE_JQ" "$FIXTURE_BIN/jq"
  ln -sf "$FIXTURE_SSH" "$FIXTURE_BIN/ssh-keygen"
  ln -sf "$FIXTURE_CURL" "$FIXTURE_BIN/curl"
  ln -sf "$FIXTURE_TIMEOUT" "$FIXTURE_BIN/timeout"
  for tool in dirname realpath stat cat; do ln -sf "$FIXTURE_BIN/../tools/$tool" "$FIXTURE_BIN/$tool"; done
  if [[ $FIXTURE_SPLIT_CLI == 0 || " $* " == *' docker-cli '* ]]; then
    cp "$FIXTURE_BIN/../docker-template" "$FIXTURE_BIN/docker"
  fi
  touch "$FIXTURE_BIN/compose-ready"
fi
MOCK
  cat > "$TMP/bin/apt-cache" <<'MOCK'
#!/usr/bin/env bash
[[ ${LC_ALL:-} == C ]] || exit 14
case ${1:-} in
  depends) [[ $FIXTURE_SPLIT_CLI == 0 ]] || echo '  Recommends: docker-cli';;
  policy)
    if [[ $FIXTURE_NO_PACKAGE == all || " $FIXTURE_NO_PACKAGE " == *" ${2:-} "* ]]; then echo '  Candidate: (none)'
    elif [[ ${2:-} == docker-compose ]]; then printf '  Candidate: %s\n' "$FIXTURE_COMPOSE_VERSION"
    else echo '  Candidate: 1.0'; fi;;
  *) exit 15;;
esac
MOCK
  cat > "$TMP/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
[[ ${1:-} != -- ]] || shift
exec "$@"
MOCK
  ln -s "$(command -v ln)" "$TMP/bin/ln"
  ln -s "$(command -v cp)" "$TMP/bin/cp"
  chmod +x "$TMP/bin/apt-get" "$TMP/bin/apt-cache" "$TMP/bin/docker" "$TMP/bin/sudo"
}
invoke() {
  PATH="$TMP/bin" bash "$ROOT/start.sh" --role primary --data-dir "$TMP/data" --deployment docker --output "$TMP/out" "$@" > "$TMP/stdout" 2> "$TMP/stderr"
}
expect_stop() {
  if invoke "$@" < /dev/null; then echo 'FAIL: fixture should stop before deployment' >&2; exit 1; fi
  [[ ! -e $TMP/out/.env ]]
}
reset_fixture
rm "$TMP/bin/jq"
expect_stop --yes
grep -qx 'apt-get update' "$FIXTURE_LOG" || { cat "$TMP/stderr" >&2; echo 'FAIL: confirmed missing jq did not trigger installation' >&2; exit 1; }
grep -qx 'apt-get install -y --no-install-recommends jq' "$FIXTURE_LOG"
grep -q 'fixture daemon reached' "$TMP/stderr"
printf 'PASS: explicit noninteractive consent installs missing jq and resumes preflight\n'

reset_fixture
rm "$TMP/bin/timeout" "$TMP/bin/curl"
expect_stop --yes
grep -qx 'apt-get install -y --no-install-recommends coreutils curl' "$FIXTURE_LOG"
grep -q 'fixture daemon reached' "$TMP/stderr"
printf 'PASS: management readiness dependencies timeout/curl map to coreutils/curl\n'

reset_fixture
invoke --help
[[ ! -s $FIXTURE_LOG && ! -s $FIXTURE_DOCKER_LOG ]]
expect_stop
[[ ! -s $FIXTURE_LOG ]]
grep -q 'fixture daemon reached' "$TMP/stderr"
rm "$TMP/bin/jq"
expect_stop
[[ ! -s $FIXTURE_LOG && ! -e $TMP/bin/jq ]]
grep -q -- '--yes' "$TMP/stderr"
expect_stop --no-install-deps
[[ ! -s $FIXTURE_LOG ]]
expect_stop --yes --no-install-deps
[[ ! -s $FIXTURE_LOG ]]
printf 'PASS: help/present dependencies, absent consent, check-only and conflicting flags do not install\n'

for failure in update install no-effect; do
  reset_fixture
  rm "$TMP/bin/jq"
  export FIXTURE_FAIL=$failure
  expect_stop --yes
  ! grep -qx info "$FIXTURE_DOCKER_LOG"
  if [[ $failure == update ]]; then [[ $(wc -l < "$FIXTURE_LOG") == 1 ]]; fi
  if [[ $failure == no-effect ]]; then grep -q jq "$TMP/stderr"; else grep -q 'fixture package operation failed' "$TMP/stderr"; fi
done
reset_fixture
rm "$TMP/bin/jq" "$TMP/bin/apt-get" "$TMP/bin/apt-cache"
expect_stop --yes
[[ ! -s $FIXTURE_LOG ]]
! grep -qx info "$FIXTURE_DOCKER_LOG"
printf 'PASS: index/install/recheck failures and unknown package manager stop before deployment\n'

for compose in missing old timeout-only; do
  reset_fixture
  export FIXTURE_COMPOSE=$compose
  expect_stop --yes
  grep -qx 'apt-get install -y --no-install-recommends docker-compose-v2' "$FIXTURE_LOG"
  grep -q 'fixture daemon reached' "$TMP/stderr"
done
reset_fixture
rm "$TMP/bin/docker"
export FIXTURE_COMPOSE=missing
expect_stop --yes
grep -qx 'apt-get install -y --no-install-recommends docker.io docker-compose-v2' "$FIXTURE_LOG"
grep -q 'fixture daemon reached' "$TMP/stderr"
reset_fixture
export FIXTURE_COMPOSE=missing FIXTURE_NO_PACKAGE=docker-compose-v2
expect_stop --yes
grep -qx 'apt-get install -y --no-install-recommends docker-compose-plugin' "$FIXTURE_LOG"
reset_fixture
export FIXTURE_COMPOSE=missing FIXTURE_NO_PACKAGE=all
expect_stop --yes
[[ $(wc -l < "$FIXTURE_LOG") == 1 ]]
! grep -qx info "$FIXTURE_DOCKER_LOG"
printf 'PASS: missing Docker, missing/old Compose, configured-repository fallback and absent packages\n'

for version in 2.26.1-4 2:2.26.1-4; do
  reset_fixture
  export FIXTURE_COMPOSE=missing FIXTURE_NO_PACKAGE='docker-compose-v2 docker-compose-plugin' FIXTURE_COMPOSE_VERSION=$version
  expect_stop --yes
  grep -qx 'apt-get install -y --no-install-recommends docker-compose' "$FIXTURE_LOG" || { cat "$TMP/stderr" >&2; echo 'FAIL: Debian Compose v2 package was not selected' >&2; exit 1; }
  grep -q 'fixture daemon reached' "$TMP/stderr"
done
reset_fixture
export FIXTURE_COMPOSE=missing FIXTURE_NO_PACKAGE='docker-compose-v2 docker-compose-plugin' FIXTURE_COMPOSE_VERSION=1.29.2-3
expect_stop --yes
[[ $(wc -l < "$FIXTURE_LOG") == 1 ]]
! grep -qx info "$FIXTURE_DOCKER_LOG"
reset_fixture
rm "$TMP/bin/docker"
export FIXTURE_COMPOSE=missing FIXTURE_SPLIT_CLI=1 FIXTURE_NO_PACKAGE='docker-compose-v2 docker-compose-plugin'
expect_stop --yes
grep -qx 'apt-get install -y --no-install-recommends docker.io docker-cli docker-compose' "$FIXTURE_LOG"
grep -q 'fixture daemon reached' "$TMP/stderr"
reset_fixture
rm "$TMP/bin/docker"
export FIXTURE_SPLIT_CLI=1 FIXTURE_NO_PACKAGE=docker-cli
expect_stop --yes
[[ $(wc -l < "$FIXTURE_LOG") == 1 ]]
! grep -qx info "$FIXTURE_DOCKER_LOG"
printf 'PASS: Debian Compose v2 alias/epoch, v1 rejection and split Docker CLI dependencies\n'

for manager in dnf yum; do
  reset_fixture
  rm "$TMP/bin/apt-get" "$TMP/bin/apt-cache" "$TMP/bin/jq" "$TMP/bin/ssh-keygen"
  cat > "$TMP/bin/$manager" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${0##*/} $*" >> "$FIXTURE_LOG"
if [[ ${1:-} == -q ]]; then
  package=${@: -1}
  [[ " $FIXTURE_NO_PACKAGE " != *" $package "* ]] || exit 16
  printf '%s.noarch %s fixture\n' "$package" "$FIXTURE_COMPOSE_VERSION"
  exit 0
fi
[[ ${1:-} == install ]] || exit 17
ln -sf "$FIXTURE_JQ" "$FIXTURE_BIN/jq"
ln -sf "$FIXTURE_SSH" "$FIXTURE_BIN/ssh-keygen"
cp "$FIXTURE_BIN/../docker-template" "$FIXTURE_BIN/docker"
touch "$FIXTURE_BIN/compose-ready"
MOCK
  chmod +x "$TMP/bin/$manager"
  expect_stop --yes
  grep -qx "$manager install -y jq openssh-clients" "$FIXTURE_LOG"
  grep -q 'fixture daemon reached' "$TMP/stderr"
  : > "$FIXTURE_LOG"
  rm "$TMP/bin/docker" "$TMP/bin/compose-ready"
  export FIXTURE_COMPOSE=missing FIXTURE_NO_PACKAGE=docker-compose-plugin
  expect_stop --yes
  grep -qx "$manager install -y docker-ce docker-compose" "$FIXTURE_LOG"
  grep -q 'fixture daemon reached' "$TMP/stderr"
  : > "$FIXTURE_LOG"
  rm "$TMP/bin/compose-ready"
  export FIXTURE_COMPOSE_VERSION=1.29.2-3
  expect_stop --yes
  ! grep -q "$manager install" "$FIXTURE_LOG"
done
printf 'PASS: dnf/yum RPM mapping, Docker/Compose v2 fallback and v1 rejection\n'

reset_fixture
rm "$TMP/bin/dirname" "$TMP/bin/realpath" "$TMP/bin/stat" "$TMP/bin/cat"
invoke --help
[[ ! -s $FIXTURE_LOG && ! -s $FIXTURE_DOCKER_LOG ]]
expect_stop --yes
grep -qx 'apt-get install -y --no-install-recommends coreutils' "$FIXTURE_LOG"
grep -q 'fixture daemon reached' "$TMP/stderr"
printf 'PASS: coreutils bootstrap works without dirname and duplicate package mappings are merged\n'

if ((EUID == 0)) && command -v setpriv >/dev/null; then
  reset_fixture
  rm "$TMP/bin/jq" "$TMP/bin/sudo"
  mkdir -p "$TMP/app/scripts/packaging" "$TMP/app/lib"
  cp "$ROOT/start.sh" "$TMP/app/start.sh"
  cp "$ROOT/scripts/start-dependencies.sh" "$TMP/app/scripts/"
  cp "$ROOT/scripts/start-lifecycle.sh" "$TMP/app/scripts/"
  cp "$ROOT/scripts/start-manager.sh" "$TMP/app/scripts/"
  cp -a "$ROOT/scripts/install" "$TMP/app/scripts/"
  cp "$ROOT/scripts/packaging/location.sh" "$TMP/app/scripts/packaging/"
  cp "$ROOT/lib/common.sh" "$TMP/app/lib/"
  chmod 755 "$TMP" "$TMP/app" "$TMP/app/scripts" "$TMP/app/lib"
  chmod 777 "$TMP/bin" "$TMP/out"
  chmod 666 "$FIXTURE_LOG" "$FIXTURE_DOCKER_LOG"
  user_start() {
    setpriv --reuid 65534 --regid 65534 --clear-groups env PATH="$TMP/bin" \
      bash "$TMP/app/start.sh" --role primary --data-dir "$TMP/data" --deployment docker --output "$TMP/out" --yes > "$TMP/stdout" 2> "$TMP/stderr"
  }
  if user_start < /dev/null; then echo 'FAIL: non-root fixture should stop' >&2; exit 1; fi
  grep -q sudo "$TMP/stderr"
  [[ ! -s $FIXTURE_LOG && ! -e $TMP/out/.env ]]
  cat > "$TMP/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "sudo $*" >> "$FIXTURE_LOG"
[[ $FIXTURE_FAIL != sudo ]] || { echo 'fixture sudo denied' >&2; exit 13; }
[[ ${1:-} != -- ]] || shift
exec "$@"
MOCK
  chmod +x "$TMP/bin/sudo"
  export FIXTURE_FAIL=sudo
  if user_start < /dev/null; then exit 1; fi
  grep -q 'fixture sudo denied' "$TMP/stderr"
  ! grep -q '^apt-get' "$FIXTURE_LOG"
  : > "$FIXTURE_LOG"
  export FIXTURE_FAIL=''
  if user_start < /dev/null; then exit 1; fi
  grep -qx 'sudo -- apt-get update' "$FIXTURE_LOG"
  grep -qx 'sudo -- apt-get install -y --no-install-recommends jq' "$FIXTURE_LOG"
  grep -q 'fixture daemon reached' "$TMP/stderr"
  [[ ! -e $TMP/out/.env ]]
  : > "$FIXTURE_LOG"
  rm "$TMP/bin/jq"
  expect_stop --yes
  ! grep -q '^sudo ' "$FIXTURE_LOG"
  printf 'PASS: non-root uses sudo only for packages; missing/denied sudo stops; root skips sudo\n'
fi

# PTY exercises the default confirmation without changing host packages.
reset_fixture
rm "$TMP/bin/jq"
pty_command="env PATH='$TMP/bin' bash '$ROOT/start.sh' --role primary --data-dir '$TMP/data' --source data:directory:. --deployment docker --output '$TMP/out'"
printf 'n\n' | script -q -e -c "$pty_command" /dev/null > "$TMP/pty" 2>&1 && exit 1
[[ ! -s $FIXTURE_LOG && ! -e $TMP/out/.env ]]
grep -q '\[y/N\]' "$TMP/pty"
printf '\n' | script -q -e -c "$pty_command" /dev/null > "$TMP/pty" 2>&1 && exit 1
[[ ! -s $FIXTURE_LOG ]]
printf 'y\ny\n' | script -q -e -c "$pty_command" /dev/null > "$TMP/pty" 2>&1 && exit 1
grep -qx 'apt-get install -y --no-install-recommends jq' "$FIXTURE_LOG"
grep -q 'fixture daemon reached' "$TMP/pty"
printf 'PASS: interactive yes installs; no/empty answer preserve the host\n'
