- [P2] cpa-dr/scripts/packaging/location.sh:60 — 缺失清单仍跳过校验；完整 GitHub fixture 首装后删除 `install-manifest.json` 并修改 `start.sh`，稳定入口 status 仍退出 0、执行修改后源码，未保持固定源码完整性检查。
- [P2] cpa-dr/scripts/install/start-manager.sh:30 — 已知部署的中间祖先不可遍历时，`-e $base` 为 false，整个扫描被跳过；有效 custom 部署存在、`.local` 对调用者不可遍历时，实际非 root status 退出 0 并显示“未安装”。
- [P2] cpa-dr/scripts/install/start-manager.sh:25 — 源码自带目标优先分支忽略显式后端选择；ROOT 有有效 Docker 记录时，`deployment=native` 仍选 ROOT，而基线选择 `/etc/cpa-dr-native`，导致 native 管理误读 Docker 配置并报方式冲突。
VERDICT: REWORK
首审七项原失败输入已关闭；新增相邻边界仍需修复。
AC1、AC2、AC4：DEVIATED，分别涉及清单完整性、后端选择和权限发现。
AC3、AC5–AC7：覆盖；接管、身份保留、邀请、锁交接、跨目录续装及状态输出已审。
AC8–AC9：证据及文档覆盖；五项 integration、语法/结构复跑通过，日志摘要与冻结清单一致。
真实 Docker/CGI/SSH/首备证据有效；Native systemd、sudo 和软件源模拟边界保持明确。

---

普通独立审查；未启用 Athena 状态库。基线 HEAD：5282bd97ce566192f84684dee9e4f53942e93a23。审查源码路径/模式/内容集合 SHA256：10876dd8de9ed214dbfce7f9f4a81e95ffcda53890f4f79b1f374b2b9b9cbb08。原始输出在上方原样保留，本段仅补充冻结元数据。
