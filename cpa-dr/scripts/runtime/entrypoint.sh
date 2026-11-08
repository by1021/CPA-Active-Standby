#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export CPA_ROOT=${CPA_ROOT:-/opt/cpa-dr} CPA_STATE_DIR=${CPA_STATE_DIR:-/state} CPA_ALLOWED_ROOT=${CPA_ALLOWED_ROOT:-/data}
run=/run/cpa-dr
mkdir -p -- "$run" /run/sshd "$run/body" "$run/fastcgi" "$run/proxy" "$run/uwsgi" "$run/scgi"
chmod 755 /run/sshd "$run"
chmod 700 "$run/body" "$run/fastcgi" "$run/proxy" "$run/uwsgi" "$run/scgi"
chown www-data:www-data "$run/body" "$run/fastcgi" "$run/proxy" "$run/uwsgi" "$run/scgi"
"$CPA_ROOT/bin/cpa-dr" --state-dir "$CPA_STATE_DIR" init --allowed-root "$CPA_ALLOWED_ROOT" > /dev/null
if [[ ! -e $CPA_STATE_DIR/ssh/ssh_host_ed25519_key ]]; then
  ssh-keygen -q -t ed25519 -N '' -f "$CPA_STATE_DIR/ssh/ssh_host_ed25519_key"
fi
chmod 600 "$CPA_STATE_DIR/ssh/ssh_host_ed25519_key"
"$CPA_ROOT/scripts/render-nginx.sh" "$CPA_ROOT" "$CPA_STATE_DIR" "$run" > "$run/nginx.conf"
"$CPA_ROOT/scripts/render-sshd.sh" "$CPA_STATE_DIR" "$run" > "$run/sshd.conf"
nginx -t -c "$run/nginx.conf"
/usr/sbin/sshd -t -f "$run/sshd.conf"
pids=()
shutdown() {
  trap - EXIT TERM INT
  local pid
  for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap shutdown EXIT
trap 'exit 0' TERM INT
spawn-fcgi -n -s "$run/fcgi.sock" -M 0660 -g www-data -- /usr/sbin/fcgiwrap -f &
pids+=("$!")
for ((i=0;i<100;i++)); do [[ -S $run/fcgi.sock ]] && break; sleep 0.05; done
[[ -S $run/fcgi.sock ]] || { echo 'FastCGI socket 未启动' >&2; exit 1; }
/usr/sbin/sshd -D -e -f "$run/sshd.conf" &
pids+=("$!")
nginx -c "$run/nginx.conf" -g 'daemon off;' &
pids+=("$!")
"$CPA_ROOT/bin/cpa-dr" --state-dir "$CPA_STATE_DIR" scheduler &
pids+=("$!")
# Any critical native child exiting stops the container rather than leaving a healthy shell.
wait -n "${pids[@]}"
