- [P2] cpa-dr/scripts/install/join.sh:220 — 仅在 record 非空时检查 manager_reason；现有 `.env.native.json` 写入 `{broken-json` 后，实际 discovery 返回空 record/异常状态，join 仍创建原不存在的数据目录并调用安装器，之后才拒绝。异常现有部署未在安装及数据写入前停止。

VERDICT: REWORK

初审五项、二审自定义 transport 原失败输入及扩展负例均独立复验通过。
真实 SSH、Chromium、Docker/native 无源码安装及精确重跑退出 0。
真实 legacy Docker 的来源冲突及既有角色/恢复点保护仍有效，未复现配置或恢复数据被破坏。
审查 HEAD：c775e305f19cbc9be2d5e9bd7368023585442c66；tree：df3be6f99b94c9abd491bde6ec667e5a0cf36bf6。
