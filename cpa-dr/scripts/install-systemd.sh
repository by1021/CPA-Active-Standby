#!/usr/bin/env bash
# Compatibility entrypoint; implementation lives in install/.
_cpa_compat_dir=.
[[ ${BASH_SOURCE[0]} != */* ]] || _cpa_compat_dir=${BASH_SOURCE[0]%/*}
exec bash "$_cpa_compat_dir/install/install-systemd.sh" "$@"
