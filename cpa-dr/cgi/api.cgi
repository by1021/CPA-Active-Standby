#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STATE=${CPA_STATE_DIR:-/state}
CLI=("$ROOT/bin/cpa-dr" --state-dir "$STATE")
temp=$(mktemp -d /tmp/cpa-dr-cgi.XXXXXX)
trap 'rm -rf -- "$temp"' EXIT
emit() {
    local status=$1 body=$2 label
    case "$status" in
        200) label=OK ;; 202) label=Accepted ;; 400) label='Bad Request' ;; 401) label=Unauthorized ;; 403) label=Forbidden ;; 404) label='Not Found' ;; 405) label='Method Not Allowed' ;; 409) label=Conflict ;; 413) label='Payload Too Large' ;; 415) label='Unsupported Media Type' ;; *) label='Internal Server Error' ;;
    esac
    printf 'Status: %s %s\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n%s\n' "$status" "$label" "$body"
    exit 0
}
error() { emit "$1" "$(jq -cn --arg message "$2" '{error:$message}')"; }
[[ -f $STATE/admin.token ]] || error 503 '备份节点尚未初始化'
expected=$(printf 'Bearer %s' "$(cat "$STATE/admin.token")" | sha256sum | cut -d ' ' -f1)
provided=$(printf '%s' "${HTTP_AUTHORIZATION:-}" | sha256sum | cut -d ' ' -f1)
[[ $expected == "$provided" ]] || error 401 '管理员令牌无效'
if [[ -n ${HTTP_ORIGIN:-} ]]; then
    [[ ${HTTP_ORIGIN} == "http://${HTTP_HOST:-}" || ${HTTP_ORIGIN} == "https://${HTTP_HOST:-}" ]] || error 403 '不接受跨域管理请求'
fi
method=${REQUEST_METHOD:-GET}
[[ $method =~ ^(GET|POST|PUT)$ ]] || error 405 '仅接受 GET、POST、PUT'
length=${CONTENT_LENGTH:-0}
[[ $length =~ ^[0-9]{1,9}$ ]] || error 400 '请求长度非法'
(( 10#$length <= 65536 )) || error 413 '管理请求超过64KiB上限'
if [[ $method != GET ]]; then
    [[ ${CONTENT_TYPE:-} == application/json* ]] || error 415 '请求须为 application/json'
    head -c "$length" > "$temp/body.json"
    [[ $(stat -c %s "$temp/body.json") == "$length" ]] || error 400 '请求正文长度不符'
    jq -e 'type=="object"' "$temp/body.json" >/dev/null 2>&1 || error 400 '请求正文须为JSON对象'
else printf '{}' > "$temp/body.json"
fi
route=${PATH_INFO:-${REQUEST_URI:-}}
route=${route%%\?*}
status=200
args=()
case "$method $route" in
    'GET /api/status') args=(status) ;;
    'GET /api/config') args=(config get) ;;
    'PUT /api/config') args=(config set "$temp/body.json") ;;
    'GET /api/pairing') args=(pairing) ;;
    'POST /api/pairing')
        jq -e '(.public_key|type)=="string"' "$temp/body.json" >/dev/null || error 400 '缺少对端 SSH 公钥'
        jq -r .public_key "$temp/body.json" > "$temp/public.key"
        args=(trust-key "$temp/public.key") ;;
    'GET /api/snapshots') args=(snapshots) ;;
    GET\ /api/jobs/*)
        id=${route#/api/jobs/}
        [[ $id =~ ^[A-Za-z0-9_-]{1,128}$ ]] || error 404 '作业不存在'
        [[ -f $STATE/jobs/$id.json ]] || error 404 '作业不存在'
        args=(job "$id") ;;
    POST\ /api/actions/*)
        action=${route#/api/actions/}
        [[ $action =~ ^(backup|verify|restore-plan|restore|promote|prepare-recovery|failback|pause|resume|test-peer)$ ]] || error 404 '操作不存在'
        args=(action "$action" "$temp/body.json")
        [[ $action =~ ^(verify|restore-plan|test-peer)$ ]] || status=202 ;;
    *) error 404 '接口不存在' ;;
esac
if output=$("${CLI[@]}" "${args[@]}" 2> "$temp/error.log"); then
    jq -e . <<< "$output" >/dev/null 2>&1 || error 500 '原生命令返回无效JSON'
    emit "$status" "$output"
else
    code=$?
    message=$(tail -c 2000 "$temp/error.log")
    [[ -n $message ]] || message='原生命令执行失败'
    [[ $code == 75 ]] && error 409 "$message"
    error 400 "$message"
fi
