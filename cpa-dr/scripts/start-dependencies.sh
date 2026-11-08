#!/usr/bin/env bash
# Compatibility entrypoint; implementation lives in install/.
_cpa_compat_dir=.
[[ ${BASH_SOURCE[0]} != */* ]] || _cpa_compat_dir=${BASH_SOURCE[0]%/*}
# shellcheck source=install/start-dependencies.sh
source "$_cpa_compat_dir/install/start-dependencies.sh"
