#!/usr/bin/env bash
# Public project entrypoint; preserve the service's original config defaults.
set -Eeuo pipefail
directory=.
[[ ${BASH_SOURCE[0]} != */* ]] || directory=${BASH_SOURCE[0]%/*}
ROOT=$(cd -- "$directory" && pwd -P)
exec bash "$ROOT/cpa-dr/start.sh" "$@"
