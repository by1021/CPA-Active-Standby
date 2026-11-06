#!/usr/bin/env bash
set -Eeuo pipefail
state=${1:-/state} run=${2:-/run/cpa-dr} bind=${3:-0.0.0.0} port=${4:-22} root=${5:-/opt/cpa-dr}
for value in "$state" "$run" "$root"; do [[ $value =~ ^/[a-zA-Z0-9_./-]+$ ]] || exit 1; done
[[ $bind =~ ^[a-zA-Z0-9.:_-]+$ && $port =~ ^[0-9]+$ ]] || exit 1
cat <<CONFIG
Port $port
ListenAddress $bind
HostKey $state/ssh/ssh_host_ed25519_key
PidFile $run/sshd.pid
AuthorizedKeysFile $state/ssh/authorized_keys
ForceCommand $root/bin/cpa-dr-rpc --state-dir $state
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
UsePAM no
StrictModes yes
AllowUsers root
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
PermitTTY no
PermitUserEnvironment no
GatewayPorts no
LogLevel ERROR
CONFIG
