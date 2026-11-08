- [P1] cpa-dr/lib/snapshots.sh:287 — 恢复目标允许硬链接，`rsync --inplace` 会改写允许数据根之外的文件；快照 item=historical，改为 current 后执行 `ln "$DATA/item" "$TMP/outside"`，恢复成功后 outside 也变为 historical。恢复前应拒绝目标树中链接计数大于1的普通文件。
- [P2] cpa-dr/lib/service.sh:240 — 历史恢复失败后缺少确认式重试路径；backup_standby 执行 RESTORE missing_snapshot 后进入 paused 且 pause_from 被删除，随后有效快照的 RESTORE 和确认 RESUME 均被拒绝，重启仍保持该状态。应保留保护态并提供明确确认的恢复重试。
VERDICT: REWORK
