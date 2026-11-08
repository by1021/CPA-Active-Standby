#!/usr/bin/env bash
# Sourced test helper; never used by the installed service.
# shellcheck disable=SC2154
cpa_test_idle_operation() {
  local attempt rc cid before_id
  before_id=$("${COMPOSE[@]}" ps --all --quiet cpa-dr) || return
  for ((attempt=0; attempt<3; attempt++)); do
    if "$@" > "$TMP/idle-operation.out" 2> "$TMP/idle-operation.err"; then
      cat "$TMP/idle-operation.out"; cat "$TMP/idle-operation.err" >&2; return 0
    else rc=$?; fi
    # The disabled scheduler briefly holds these locks every second. Retry
    # only a pre-mutation refusal after proving idle state and unchanged ID.
    # Ownership, sudo, stop failures and SIGPIPE are never retried.
    if ! grep -Eq '^操作失败：(服务任务忙碌、状态未知或锁被占用；未中断服务|服务任务锁被占用，未中断服务|服务控制锁被占用，未中断服务)$' "$TMP/idle-operation.err"; then break; fi
    cid=$("${COMPOSE[@]}" ps --all --quiet cpa-dr) || break
    [[ -n $cid && $cid == "$before_id" ]] || break
    docker exec "$cid" jq -e --slurpfile config /state/config.json '.job.running==false and $config[0].enabled==false' /state/runtime.json >/dev/null || break
    sleep "0.$((3+attempt*3))"
  done
  cat "$TMP/idle-operation.out"; cat "$TMP/idle-operation.err" >&2; return "$rc"
}
