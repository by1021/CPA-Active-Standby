#!/usr/bin/env bash
# Compatibility test entrypoint; canonical test lives in e2e/.
_cpa_test_dir=.
[[ ${BASH_SOURCE[0]} != */* ]] || _cpa_test_dir=${BASH_SOURCE[0]%/*}
exec bash "$_cpa_test_dir/e2e/docker_user.sh" "$@"
