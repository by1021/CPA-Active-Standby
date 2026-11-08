#!/usr/bin/env bash
# Generate only a fixed CGI endpoint; user request paths never select executable files.
set -Eeuo pipefail
root=${1:-/opt/cpa-dr} state=${2:-/state} run=${3:-/run/cpa-dr} bind=${4:-0.0.0.0} port=${5:-8787}
for value in "$root" "$state" "$run"; do [[ $value =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo '服务/状态/运行目录须使用无空格和特殊字符的绝对路径' >&2; exit 1; }; done
[[ $bind =~ ^[a-zA-Z0-9.:_-]+$ && $port =~ ^[0-9]+$ ]] || exit 1
cat <<CONFIG
user www-data;
worker_processes 1;
pid $run/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 256; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log off;
  client_body_temp_path $run/body;
  fastcgi_temp_path $run/fastcgi;
  proxy_temp_path $run/proxy;
  uwsgi_temp_path $run/uwsgi;
  scgi_temp_path $run/scgi;
  server_tokens off;
  server {
    listen $bind:$port;
    server_name _;
    root $root/www;
    index index.html;
    client_max_body_size 64k;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    location = /healthz { default_type application/json; add_header Cache-Control no-store; return 200 '{"ok":true,"component":"native-management"}'; }
    location /api/ {
      # Forward only explicitly defined CGI fields, exactly once. HTTP_HOST
      # retains the external port so same-origin browser writes remain valid.
      fastcgi_pass_request_headers off;
      fastcgi_param QUERY_STRING \$query_string;
      fastcgi_param REQUEST_METHOD \$request_method;
      fastcgi_param CONTENT_TYPE \$content_type;
      fastcgi_param CONTENT_LENGTH \$content_length;
      fastcgi_param REQUEST_URI \$request_uri;
      fastcgi_param SERVER_PROTOCOL \$server_protocol;
      fastcgi_param GATEWAY_INTERFACE CGI/1.1;
      fastcgi_param SERVER_NAME \$server_name;
      fastcgi_param SERVER_PORT \$server_port;
      fastcgi_param REMOTE_ADDR \$remote_addr;
      fastcgi_param REMOTE_PORT \$remote_port;
      fastcgi_param SCRIPT_FILENAME $root/cgi/api.cgi;
      fastcgi_param SCRIPT_NAME /api;
      fastcgi_param PATH_INFO \$uri;
      fastcgi_param HTTP_HOST \$http_host;
      fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
      fastcgi_param HTTP_ORIGIN \$http_origin;
      fastcgi_param CPA_STATE_DIR $state;
      fastcgi_param CPA_ROOT $root;
      fastcgi_read_timeout 120s;
      fastcgi_pass unix:$run/fcgi.sock;
    }
    location / { try_files \$uri \$uri/ =404; }
  }
}
CONFIG
