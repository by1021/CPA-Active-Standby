#!/usr/bin/env bash
# Install independent native services; never overwrite existing units or legacy deployments.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077
SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
data='' state=/var/lib/cpa-dr-native root=/opt/cpa-dr-native bind=127.0.0.1 port=8787 ssh_port=2222 dry=false output=''
config_dir=/etc/cpa-dr-native config_file='' install_id='' resume=false read_only=false record=''
# shellcheck source=../lib/common.sh
source "$SOURCE/lib/common.sh"
fail() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
while (($#)); do
  case $1 in
    --data-dir|--state-dir|--install-root|--bind-host|--port|--ssh-port|--output|--config-dir|--config-file|--install-id)
      (($# >= 2)) || fail '参数缺少值'
      case $1 in --data-dir) data=$2;; --state-dir) state=$2;; --install-root) root=$2;; --bind-host) bind=$2;; --port) port=$2;; --ssh-port) ssh_port=$2;; --output) output=$2;; --config-dir) config_dir=$2;; --config-file) config_file=$2;; --install-id) install_id=$2;; esac
      shift 2;;
    --dry-run) dry=true; shift;;
    --resume) resume=true; shift;;
    --read-only-data) read_only=true; shift;;
    --help|-h) printf '%s\n' '用法：sudo bash scripts/install-systemd.sh --data-dir TARGET [--state-dir DIR] [--install-root DIR] [--config-dir DIR] [--config-file JSONFILE] [--read-only-data] [--bind-host HOST] [--port 8787] [--ssh-port 2222]' '只生成单元：bash scripts/install-systemd.sh --dry-run --data-dir TARGET --output DIR'; exit 0;;
    *) fail "未知参数：$1";;
  esac
done
[[ -n $data && -d $data ]] || fail '--data-dir 必须是已存在的数据父目录'
for value in "$state" "$root" "$config_dir"; do
  cpa_path_validate "$value" || fail '服务/状态/配置目录须为规范绝对路径，不接受符号链接'
done
data=$(realpath -e -- "$data")
state=$(realpath -m -- "$state")
root=$(realpath -m -- "$root")
config_dir=$(realpath -m -- "$config_dir")
for value in "$state" "$root" "$config_dir"; do
  [[ $value =~ ^/[a-zA-Z0-9_./-]+$ ]] || fail '服务/状态/配置路径使用无空格和特殊字符的绝对路径'
  cpa_path_validate "$value" || fail '服务/状态/配置路径含符号链接'
  cpa_paths_intersect "$value" "$SOURCE" && fail '服务/状态/配置目录与源码必须独立'
done
[[ ! $data =~ [[:cntrl:]] && $data != *[\'\"\\%]* ]] || fail '数据路径不支持控制字符、引号、反斜线或systemd百分号占位符'
[[ $bind =~ ^[a-zA-Z0-9.:_-]+$ ]] || fail '监听地址含非法字符'
for value in "$port" "$ssh_port"; do
  if [[ ! $value =~ ^[0-9]+$ || ${#value} -gt 5 ]]; then fail '端口超出1到65535'; fi
  if ((10#$value < 1 || 10#$value > 65535)); then fail '端口超出1到65535'; fi
done
for location in "$state" "$root" "$config_dir"; do cpa_paths_intersect "$data" "$location" && fail '数据/状态/服务/配置目录必须独立'; done
for location in "$state" "$root"; do
  cpa_paths_intersect "$location" "$config_dir" && fail '服务/状态/配置目录必须独立'
done
cpa_paths_intersect "$state" "$root" && fail '状态与服务目录必须独立'
if [[ -n $config_file ]]; then
  [[ -f $config_file && ! -L $config_file ]] || fail '引导配置须为普通JSON文件'
  jq -e '(.node_role=="primary" or .node_role=="backup") and .enabled==false and (.sources|type=="array")' "$config_file" >/dev/null || fail '引导配置格式异常'
fi
run=/run/cpa-dr-native
for location in "$state" "$root" "$config_dir" "$data"; do
  cpa_paths_intersect "$location" "$run" && fail '运行目录与数据/状态/服务/配置目录必须独立'
done
if "$dry"; then
  [[ -n $output ]] || fail '--dry-run 需要 --output DIR'
  mkdir -p -- "$output"
else
  ((EUID == 0)) || fail '安装需sudo/root；只检查可用--dry-run'
  for command in jq nginx spawn-fcgi fcgiwrap sshd ssh-keygen rsync sqlite3 flock systemctl sha256sum; do command -v "$command" >/dev/null || fail "缺少命令：$command，请先安装README中的原生软件包"; done
  systemctl show --property=Version --value >/dev/null || fail 'systemd管理器未就绪，未写入安装文件'
  getent group www-data >/dev/null || fail '需要www-data组，请核对当前发行版的Nginx/FastCGI配置'
  [[ ! -L $config_dir/.env.native.json ]] || fail '安装记录是符号链接'
  if [[ -f $config_dir/.env.native.json ]]; then
    "$resume" || fail '安装记录已存在，请使用start.sh重跑'
    record=$(cat -- "$config_dir/.env.native.json")
    jq -e --arg data "$data" --arg state "$state" --arg root "$root" --arg config "$config_dir" '.version==1 and .managed_by=="cpa-dr-start" and .deployment=="native" and .status=="pending" and .data_dir==$data and .state_dir==$state and .install_root==$root and .config_dir==$config' <<< "$record" >/dev/null || fail '恢复安装与原记录冲突'
    recorded_id=$(jq -r .install_id <<< "$record")
    [[ -z $install_id || $install_id == "$recorded_id" ]] || fail '安装ID与原记录冲突'
    install_id=$recorded_id
  else
    [[ -z $install_id ]] || fail '指定安装ID时须有对应安装记录'
    install_id=$(cat /proc/sys/kernel/random/uuid)
  fi
  [[ $install_id =~ ^[a-f0-9-]{36}$ ]] || fail '安装ID格式异常'
  for location in "$root" "$state"; do
    if [[ -e $location ]]; then
      "$resume" && [[ -f $location/.cpa-dr-install-id && ! -L $location/.cpa-dr-install-id && $(cat -- "$location/.cpa-dr-install-id") == "$install_id" ]] || fail '服务或状态目录已存在，保留旧安装'
    fi
  done
  if [[ -e $run ]]; then
    "$resume" && [[ -f $run/.cpa-dr-install-id && ! -L $run/.cpa-dr-install-id && $(cat -- "$run/.cpa-dr-install-id") == "$install_id" ]] || fail '运行目录已存在，保留旧安装'
  fi
  for file in nginx.conf sshd.conf cpa-dr-native-tick.service cpa-dr-native-tick.timer cpa-dr-native-fcgi.service cpa-dr-native-web.service cpa-dr-native-ssh.service; do
    if [[ -e $config_dir/$file || -L $config_dir/$file ]]; then
      record_for_check=${record:-'{}'}
      expected=$(jq -r --arg file "$file" '.unit_hashes[$file]//empty' <<< "$record_for_check")
      actual=$(sha256sum -- "$config_dir/$file")
      [[ -f $config_dir/$file && ! -L $config_dir/$file && -n $expected && ${actual:0:64} == "$expected" ]] || fail "已有配置不属于本次安装：$file"
    fi
  done
  for unit in cpa-dr-native-tick.service cpa-dr-native-tick.timer cpa-dr-native-fcgi.service cpa-dr-native-web.service cpa-dr-native-ssh.service; do
    record_for_check=${record:-'{}'}
    expected=$(jq -r --arg unit "$unit" '.unit_hashes[$unit]//empty' <<< "$record_for_check")
    for location in "/etc/systemd/system/$unit" "/usr/lib/systemd/system/$unit" "/lib/systemd/system/$unit"; do
      if [[ -e $location || -L $location ]]; then
        actual=$(sha256sum -- "$location")
        [[ -f $location && ! -L $location && -n $expected && ${actual:0:64} == "$expected" ]] || fail "已有同名systemd单元：$unit"
      fi
      [[ ! -e $location.d && ! -L $location.d ]] || fail "已有单元覆盖配置：$location.d"
    done
  done
  for directory in bin lib cgi www scripts; do [[ -d $SOURCE/$directory ]] || fail "源码缺失：$directory"; done
  install -d -m 755 -- "$config_dir"
  if [[ -z $record ]]; then
    initial=null; [[ -z $config_file ]] || initial=$(cat -- "$config_file")
    record=$(jq -n --arg id "$install_id" --arg data "$data" --arg state "$state" --arg root "$root" --arg config "$config_dir" --arg source "$SOURCE" --arg bind "$bind" --argjson port "$((10#$port))" --argjson ssh_port "$((10#$ssh_port))" --argjson ro "$read_only" --argjson initial "$initial" '{version:1,managed_by:"cpa-dr-start",deployment:"native",status:"pending",install_id:$id,data_dir:$data,state_dir:$state,install_root:$root,config_dir:$config,run_dir:"/run/cpa-dr-native",source_root:$source,project_name:"",port:$port,ssh_port:$ssh_port,bind_host:$bind,read_only:$ro,initial_config:$initial,unit_hashes:{}}')
    printf '%s\n' "$record" | cpa_atomic "$config_dir/.env.native.json"
  fi
  install -d -m 755 -- "$root"
  printf '%s\n' "$install_id" | cpa_atomic "$root/.cpa-dr-install-id"
  for directory in bin lib cgi www scripts; do cp -a -- "$SOURCE/$directory" "$root/"; done
  chmod -R a+rX -- "$root"
  install -d -m 700 -- "$state"
  printf '%s\n' "$install_id" | cpa_atomic "$state/.cpa-dr-install-id"
  "$root/bin/cpa-dr" --state-dir "$state" init --allowed-root "$data" > /dev/null
  if [[ -n $config_file ]]; then
    if jq -e '.configured==true' "$state/runtime.json" >/dev/null; then
      jq -e --slurpfile incoming "$config_file" '.node_role==$incoming[0].node_role and (.sources|sort_by(.name))==($incoming[0].sources|sort_by(.name))' "$state/config.json" >/dev/null || fail '未完成安装与现有页面配置冲突，保留原配置'
    else
      jq --slurpfile incoming "$config_file" '.+$incoming[0]' "$state/config.json" | cpa_atomic "$state/.env.install-config.json"
      "$root/bin/cpa-dr" --state-dir "$state" config set "$state/.env.install-config.json" >/dev/null
      rm -f -- "$state/.env.install-config.json"
    fi
  fi
  [[ -f $state/ssh/ssh_host_ed25519_key ]] || ssh-keygen -q -t ed25519 -N '' -f "$state/ssh/ssh_host_ed25519_key"
  install -d -m 755 -- "$run" /run/sshd
  printf '%s\n' "$install_id" | cpa_atomic "$run/.cpa-dr-install-id"
  output=$config_dir
fi
if ! "$dry"; then
  # Stage all templates, record their hashes, then publish each file atomically.
  stage=$(mktemp -d "$config_dir/.env.units.XXXXXXXX")
  trap 'rm -rf -- "$stage"' EXIT
  output=$stage
fi
data_write="ReadWritePaths=$state \"$data\""
data_protection=''
if "$read_only"; then
  data_write="ReadWritePaths=$state"
  data_protection="ReadOnlyPaths=\"$data\""
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
$data_write
$data_protection
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
# /run is cleared on reboot; restore ownership from the persistent state.
ExecStartPre=/usr/bin/install -m 0600 $state/.cpa-dr-install-id $run/.cpa-dr-install-id
ExecStartPre=/usr/bin/rm -f $run/fcgi.sock
ExecStart=/usr/bin/spawn-fcgi -n -s $run/fcgi.sock -M 0660 -g www-data -- /usr/sbin/fcgiwrap -f
Environment=CPA_STATE_DIR=$state
Environment=CPA_ROOT=$root
$data_protection
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
ExecStartPre=/usr/sbin/nginx -t -c $config_dir/nginx.conf
ExecStart=/usr/sbin/nginx -c $config_dir/nginx.conf -g "daemon off;"
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
ExecStartPre=/usr/bin/install -m 0600 $state/.cpa-dr-install-id $run/.cpa-dr-install-id
ExecStartPre=/usr/sbin/sshd -t -f $config_dir/sshd.conf
ExecStart=/usr/sbin/sshd -D -e -f $config_dir/sshd.conf
$data_protection
Restart=on-failure
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
if "$dry"; then printf 'PASS：仅生成原生配置和systemd单元：%s\n' "$output"; exit 0; fi
hashes='{}'
for file in "$output"/cpa-dr-native-*.service "$output"/cpa-dr-native-*.timer "$output/nginx.conf" "$output/sshd.conf"; do
  hash=$(sha256sum -- "$file")
  hashes=$(jq --arg name "${file##*/}" --arg hash "${hash:0:64}" '.+{($name):$hash}' <<< "$hashes")
done
record=$(jq --argjson hashes "$hashes" '.unit_hashes=$hashes' <<< "$record")
printf '%s\n' "$record" | cpa_atomic "$config_dir/.env.native.json"
for file in "$output"/cpa-dr-native-*.service "$output"/cpa-dr-native-*.timer "$output/nginx.conf" "$output/sshd.conf"; do
  cat -- "$file" | cpa_atomic "$config_dir/${file##*/}"
done
output=$config_dir
install -d -o www-data -g www-data -m 0700 "$run/body" "$run/fastcgi" "$run/proxy" "$run/uwsgi" "$run/scgi"
nginx -t -c "$output/nginx.conf"
sshd -t -f "$output/sshd.conf"
for file in "$output"/cpa-dr-native-*.service "$output"/cpa-dr-native-*.timer; do install -m 644 -- "$file" /etc/systemd/system/; done
systemctl daemon-reload
systemctl enable --now cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-ssh.service
printf '部署完成。管理入口：http://%s:%s\nSSH端口：%s\n管理员令牌：' "$bind" "$port" "$ssh_port"
cat -- "$state/admin.token"
printf '%s\n' '备份默认未启用：登录页面配置角色/路径、双端配对后启动。未修改CPA或Cloudflare。'
