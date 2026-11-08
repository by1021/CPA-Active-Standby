#!/usr/bin/env bash
# Encode trusted program text separately from the invitation JSON data.
set -Eeuo pipefail
[[ $# == 1 && -f $1 && ! -L $1 ]] || { printf '邀请文件异常\n' >&2; exit 1; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
payload=$(base64 -w0 -- "$1")
program=$( { printf 'CPA_BOOTSTRAP_EMBEDDED=1\n'; cat "$here/location.sh" "$here/github.sh" "$here/bootstrap.sh"; } | base64 -w0)
printf "bash -c \"\$(printf '%%s' '%s' | base64 -d)\" -- '%s'\n" "$program" "$payload"
