#!/usr/bin/env bash
# Compatibility test entrypoint; canonical test lives in integration/.
_cpa_test_dir=.
[[ ${BASH_SOURCE[0]} != */* ]] || _cpa_test_dir=${BASH_SOURCE[0]%/*}
# shellcheck source=integration/installer_fixture.sh
source "$_cpa_test_dir/integration/installer_fixture.sh"
