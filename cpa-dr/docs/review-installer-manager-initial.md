- [P1] cpa-dr/scripts/start-lifecycle.sh:201 — 宿主 runtime.json 可读时跳过容器归属检查。复现：有效安装记录、空闲任务状态，加同项目/服务标签但挂载不同 /state、/data 的真实隔离 Compose 容器；status 报归属异常，uninstall --yes 仍停止并删除异源容器及网络，退出 0，违反 AC5。
- [P2] cpa-dr/scripts/start-manager.sh:40 — 仅检查目标目录权限，遗漏不可遍历的祖先。复现：root 所有、权限 0700 的祖先下存在安装记录，普通用户执行 status --output TARGET/private/config；退出 0 并报告“未安装”，应显示“状态未知”，违反 AC2。
- [P2] cpa-dr/docs/verification.md:144 — ShellCheck 通过记录与当前树不符。精确复跑所列命令退出 1，start-manager.sh:353 报 SC2034（attempt 未使用）；包内 manager-final-static.log 同样包含该警告，AC6 尚未满足。
VERDICT: REWORK

已完成 AC1–AC6、正确性、安全、测试风险及过度设计审查。
manager/start/dependencies/deployment/native 隔离回归通过；真实宿主 systemd 仍待验证。源码未修改，临时资源已清理。
