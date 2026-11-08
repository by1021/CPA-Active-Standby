#!/usr/bin/env bash
# Compatibility test entrypoint; canonical test lives in unit/.
_cpa_test_dir=.
[[ ${BASH_SOURCE[0]} != */* ]] || _cpa_test_dir=${BASH_SOURCE[0]%/*}
exec bash "$_cpa_test_dir/unit/core.sh" "$@"
