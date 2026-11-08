- [P1] cpa-dr/scripts/packaging/github.sh:130 — 项目锁未拒绝硬链接，打开时截断关联文件；已有项目执行 `ln 原数据.json 项目/.install.lock` 后重跑，即使下载失败，原数据仍从 27 字节变为 0；项目标记直接写入也有同类风险。
- [P1] cpa-dr/scripts/install/start-manager.sh:43 — 旧配置关联优先于源码自带部署，导致错误目标控制；源码及 HOME/custom 各有有效同源码部署时，实际 `start.sh stop --yes` 退出 0，却停止 custom 目标而非源码自带目标。
- [P2] cpa-dr/scripts/packaging/github.sh:162 — 登记入口仍使用逻辑 `$PWD`；从符号链接工作目录执行公共安装，部署在物理目录创建成功，但登记报路径异常、退出 1，稳定入口缺失；备机引导同样未使用物理执行目录。
- [P2] cpa-dr/scripts/packaging/location.sh:60 — 悬空清单链接被当作不存在，跳过校验；将 `install-manifest.json` 链接到不存在文件后，稳定入口 status 仍退出 0 并执行源码。
- [P2] cpa-dr/scripts/install/start-manager.sh:29 — 配置扫描静默跳过不可读、链接及解析失败的候选；有效 custom 记录对非 root 不可读，或记录损坏时，实际源码入口显示“未安装”，而非未知/异常。
- [P2] cpa-dr/tests/e2e/github_entrypoint.sh:16 — cleanup 只删除容器，未删除项目网络；当前实际残留 3 个 `cpa-location-*_default` 网络，与 verification.md:305 的自动清理声明不符。
- [P3] cpa-dr/scripts/packaging/location.sh:232 — GitHub 安装完成输出缺实际状态目录；实跑 releases 布局的 `cpa_install_finish` 退出 0，但指定的独立 state 路径未出现在输出中。
VERDICT: REWORK
AC1–AC4：DEVIATED；正常布局、接管及身份保留有证据，但上述边界和目标选择未满足。
AC5–AC6：覆盖；邀请确认/取消/失败、sudo、锁交接及两种来源跨目录续装已审。
AC7：MISSING 状态目录集中输出；其余状态区分与秘密隐藏覆盖。
AC8–AC9：DEVIATED；既有红绿及运行证据完整，但新负例未覆盖、网络清理声明失实。
复跑四项新增 integration、语法及结构通过；日志摘要和源码冻结核验一致。

---

普通独立审查；未启用 Athena 状态库。基线 HEAD：5282bd97ce566192f84684dee9e4f53942e93a23。审查源码路径/模式/内容集合 SHA256：3e626e6df2e61bf619fe7b3e30ee6a98a85555d804ee8ccdc13c317e5b790089。原始输出在上方原样保留，本段仅补充冻结元数据。
