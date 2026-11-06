- [P1] cpa-dr/scripts/start-lifecycle.sh:318 — Linux 重启清空 `/run` 后，systemd 重建 `/run/cpa-dr-native` 却不恢复所有权标记；随后重跑和 `uninstall --yes` 均退出 1，报“目录缺少本服务所有权标记”。同样影响第 278 行的安装检查。标记仅在 `install-systemd.sh:130` 写入，应补启动时恢复及重启回归。

VERDICT: REWORK

AC1、AC2、AC3、AC6 已覆盖；AC4、AC5 的重启后生命周期存在 DEVIATED，其余未发现新增问题。
独立复跑入口、依赖、部署、ShellCheck 和 `git diff --check`，全部退出 0。
上述失败已在独立临时容器复现；不将模拟器称为真实 systemd 验证。
全部 16 个审查文件摘要一致，清单 SHA-256：`d4541e125c7059e6257f1c11a06cd5edc75fd52a9687b13490b6468461dd4315`。
未修改源码或操作既有服务。
