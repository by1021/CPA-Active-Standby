- [P2] cpa-dr/scripts/packaging/github.sh:111 — 公共入口把不可遍历的旧部署路径当作不存在：已有有效 `deployments/primary`，HOME/.local 为 root 所有且权限 0700，UID 65534 在无项目记录的新目录执行 `install.sh --deployment docker --data-dir TARGET --yes`，实际退出 0、下载并生成第二份部署；应报告权限异常并停止。可读权限对照正确接管旧部署。
VERDICT: REWORK
首审七项、二审三项原失败输入均已关闭。
AC1–AC3、AC5–AC7：覆盖；AC4：DEVIATED，公共入口权限发现仍有遗漏。
AC8–AC9：已审；五项 integration、依赖/邀请单测、页面/文档及75文件语法/ShellCheck、结构检查通过，日志摘要与冻结清单一致。
Docker/CGI/SSH/首备证据有效；Native systemd、sudo、软件源仍为明确模拟边界。

---

普通独立审查；未启用 Athena 状态库。基线 HEAD：5282bd97ce566192f84684dee9e4f53942e93a23。审查源码路径/模式/内容集合 SHA256：f7077416baec4f6e8843af13d66ead080dda1e889017f684539b8a415162c680。原始输出在上方原样保留，本段仅补充冻结元数据。
