- [P2] cpa-dr/scripts/start-manager.sh:113 — native 状态查询将错误当作已停止，违反 AC2。隔离复现：systemctl show 返回 loaded，is-active 与 is-failed 均返回 124（超时）；status 退出 0 并报告“服务状态：已停止”，应显示未知并阻止基于该状态的服务操作。
VERDICT: CONCERNS
