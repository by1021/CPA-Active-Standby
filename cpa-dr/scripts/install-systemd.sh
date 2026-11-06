#!/usr/bin/env bash
# Install independent native services; never overwrite existing units or legacy deployments.
set -Eeuo pipefail
umask 077
SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
data='' state=/var/lib/cpa-dr-native root=/opt/cpa-dr-native bind=127.0.0.1 port=8787 ssh_port=2222 dry=false output=''
fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
while (($#)); do
  case $1 in
    --data-dir|--state-dir|--install-root|--bind-host|--port|--ssh-port|--output)
      (($# >= 2)) || fail '参数缺少值'
      case $1 in --data-dir) data=$2;; --state-dir) state=$2;; --install-root) root=$2;; --bind-host) bind=$2;; --port) port=$2;; --ssh-port) ssh_port=$2;; --output) output=$2;; esac
      shift 2;;
    --dry-run) dry=true; shift;;
    --help|-h) printf '%s\n' '用法：sudo bash scripts/install-systemd.sh --data-dir TARGET [--state-dir DIR] [--install-root DIR] [--bind-host HOST] [--port 8787] [--ssh-port 2222]' '只生成单元：bash scripts/install-systemd.sh --dry-run --data-dir TARGET --output DIR'; exit 0;;
    *) fail "未知参数：$1";;
  esac
done
[[ -n $data && -d $data ]] || fail '--data-dir 必须是已存在的数据父目录'
data=$(realpath -e -- "$data")
state=$(realpath -m -- "$state")
root=$(realpath -m -- "$root")
for value in "$state" "$root"; do [[ $value =~ ^/[a-zA-Z0-9_./-]+$ ]] || fail '服务和状态路径使用无空格/特殊字符的绝对路径'; done
[[ ! $data =~ [[:cntrl:]] && $data != *[\'\"\\%]* ]] || fail '数据路径不支持控制字符、引号、反斜线或systemd百分号占位符'
[[ $bind =~ ^[a-zA-Z0-9.:_-]+$ ]] || fail '监听地址含非法字符'
for value in "$port" "$ssh_port"; do
  if [[ ! $value =~ ^[0-9]+$ || ${#value} -gt 5 ]]; then fail '端口超出1到65535'; fi
  if ((10#$value < 1 || 10#$value > 65535)); then fail '端口超出1到65535'; fi
done
for location in "$state" "$root"; do [[ $data != "$location" && $data != "$location/"* && $location != "$data/"* ]] || fail '数据/状态/服务目录必须独立'; done
run=/run/cpa-dr-native
if "$dry"; then
  [[ -n $output ]] || fail '--dry-run 需要 --output DIR'
  mkdir -p -- "$output"
else
  ((EUID == 0)) || fail '安装需sudo/root；只检查可用--dry-run'
  for command in jq nginx spawn-fcgi sshd ssh-keygen rsync sqlite3 flock systemctl; do command -v "$command" >/dev/null || fail "缺少命令：$command，请先安装README中的原生软件包"; done
  [[ ! -e $root ]] || fail '安装目录已存在，保留旧代码；用新的--install-root或核对原部署'
  [[ ! -e $state ]] || fail '状态目录已存在，保留原数据；用新的--state-dir或核对原部署'
  for unit in cpa-dr-native-tick.service cpa-dr-native-tick.timer cpa-dr-native-fcgi.service cpa-dr-native-web.service cpa-dr-native-ssh.service; do
    [[ ! -e /etc/systemd/system/$unit && ! -e /usr/lib/systemd/system/$unit && ! -e /lib/systemd/system/$unit ]] || fail "已有同名systemd单元：$unit"
  done
  for directory in bin lib cgi www scripts; do [[ -d $SOURCE/$directory ]] || fail "源码缺失：$directory"; done
  install -d -m 755 -- "$root"
  for directory in bin lib cgi www scripts; do cp -a -- "$SOURCE/$directory" "$root/"; done
  chmod -R a+rX -- "$root"
  install -d -m 700 -- "$state"
  "$root/bin/cpa-dr" --state-dir "$state" init --allowed-root "$data" > /dev/null
  ssh-keygen -q -t ed25519 -N '' -f "$state/ssh/ssh_host_ed25519_key"
  install -d -m 755 -- /etc/cpa-dr-native "$run" /run/sshd
  output=/etc/cpa-dr-native
fi
"$SOURCE/scripts/render-nginx.sh" "$root" "$state" "$run" "$bind" "$port" > "$output/nginx.conf"
"$SOURCE/scripts/render-sshd.sh" "$state" "$run" "$bind" "$ssh_port" "$root" > "$output/sshd.conf"
cat > "$output/cpa-dr-native-tick.service" <<UNIT
[Unit]
Description=CPA native backup scheduler tick
After=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=$root/bin/cpa-dr --state-dir $state tick
Environment="CPA_ALLOWED_ROOT=$data"
UMask=0077
ProtectSystem=strict
ReadWritePaths=$state "$data"
PrivateTmp=true
NoNewPrivileges=true
TimeoutStartSec=infinity
UNIT
cat > "$output/cpa-dr-native-tick.timer" <<'UNIT'
[Unit]
Description=CPA native dynamic backup interval timer
[Timer]
OnBootSec=5s
OnUnitInactiveSec=1s
AccuracySec=1s
Unit=cpa-dr-native-tick.service
[Install]
WantedBy=timers.target
UNIT
cat > "$output/cpa-dr-native-fcgi.service" <<UNIT
[Unit]
Description=CPA native Shell FastCGI
After=network.target
[Service]
Type=simple
User=root
RuntimeDirectory=cpa-dr-native
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
ExecStartPre=/usr/bin/rm -f $run/fcgi.sock
ExecStart=/usr/bin/spawn-fcgi -n -s $run/fcgi.sock -M 0660 -g www-data -- /usr/sbin/fcgiwrap -f
Environment=CPA_STATE_DIR=$state
Environment=CPA_ROOT=$root
UMask=0077
NoNewPrivileges=true
Restart=on-failure
KillMode=control-group
TimeoutStopSec=60s
[Install]
WantedBy=multi-user.target
UNIT
cat > "$output/cpa-dr-native-web.service" <<UNIT
[Unit]
Description=CPA native nginx management UI
Requires=cpa-dr-native-fcgi.service
After=cpa-dr-native-fcgi.service
[Service]
Type=simple
ExecStartPre=/usr/bin/install -d -o www-data -g www-data -m 0700 $run/body $run/fastcgi $run/proxy $run/uwsgi $run/scgi
ExecStartPre=/usr/sbin/nginx -t -c /etc/cpa-dr-native/nginx.conf
ExecStart=/usr/sbin/nginx -c /etc/cpa-dr-native/nginx.conf -g "daemon off;"
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGQUIT
Restart=on-failure
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
cat > "$output/cpa-dr-native-ssh.service" <<UNIT
[Unit]
Description=CPA native restricted SSH backup transport
After=network.target
[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p /run/sshd $run
ExecStartPre=/usr/sbin/sshd -t -f /etc/cpa-dr-native/sshd.conf
ExecStart=/usr/sbin/sshd -D -e -f /etc/cpa-dr-native/sshd.conf
Restart=on-failure
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
if "$dry"; then printf 'PASS：仅生成原生配置和systemd单元：%s\n' "$output"; exit 0; fi
install -d -o www-data -g www-data -m 0700 "$run/body" "$run/fastcgi" "$run/proxy" "$run/uwsgi" "$run/scgi"
nginx -t -c "$output/nginx.conf"
sshd -t -f "$output/sshd.conf"
for file in "$output"/cpa-dr-native-*.service "$output"/cpa-dr-native-*.timer; do install -m 644 -- "$file" /etc/systemd/system/; done
systemctl daemon-reload
systemctl enable --now cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-ssh.service
printf '部署完成。管理入口：http://%s:%s\nSSH端口：%s\n管理员令牌：' "$bind" "$port" "$ssh_port"
cat -- "$state/admin.token"
printf '%s\n' '备份默认未启用：登录页面配置角色/路径、双端配对后启动。未修改CPA或Cloudflare。'
