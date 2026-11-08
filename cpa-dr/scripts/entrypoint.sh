#!/usr/bin/env bash
# Compatibility entrypoint; implementation lives in runtime/.
_cpa_compat_dir=.
[[ ${BASH_SOURCE[0]} != */* ]] || _cpa_compat_dir=${BASH_SOURCE[0]%/*}
exec bash "$_cpa_compat_dir/runtime/entrypoint.sh" "$@"
