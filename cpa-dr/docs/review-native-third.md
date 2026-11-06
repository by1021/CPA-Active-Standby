- [P2] cpa-dr/lib/service.sh:291 — 普通 RESUME 将已提交的交接历史误判为进行中交接；实际执行 handover→baseline→commit→PAUSE 后，状态为 paused、pause_from=backup_standby、handover.committed=true，确认 RESUME 仍被拒绝。新恢复流程保留普通暂停后也落入此状态。应允许已提交历史下的普通恢复调度，继续阻断未提交交接，并补后续 RESUME 回归。
VERDICT: REWORK
