- [P1] cpa-dr/lib/service.sh:441 — 同代次副本缺少新旧比较；依次执行 receive(NODE,0,old)、receive(NODE,0,new)、再次 receive(NODE,0,old)，三次均成功，latest_received 从 new 回退为 old，下一次接管会恢复过期数据。
- [P1] cpa-dr/lib/service.sh:474 — 已提交交接的重复 commit 再次覆盖有效基线；真实 handover→baseline(old)→commit 后接收 new，再用原 nonce 执行 commit 仍成功，latest_received 从 new 回退为 old。重复确认须幂等，不再修改当前副本。
- [P1] cpa-dr/lib/service.sh:312 — primary_started 仅记录启动已尝试，却被重试当作成功；systemd 驱动 start 返回1后首次回灌失败，再次回灌跳过 start 并提交交接，最终主 primary_active、备 backup_standby、作业无错误，start 仅调用一次且从未成功。
- [P1] cpa-dr/lib/service.sh:335 — 历史恢复无条件启动 CPA，不考虑节点权威角色；backup_standby 配置 systemd 驱动并确认 RESTORE 后，真实恢复完成且驱动调用 stop,start，状态仍 backup_standby。正常主机运行时这会启动第二个 CPA 写者，绕过接管隔离确认。
VERDICT: REWORK
