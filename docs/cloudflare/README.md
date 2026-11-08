# Cloudflare 主备入口配置

保留原 Worker、KV、Tunnel 手册及 Worker 代码。**Cloudflare 负责请求流向，不复制数据、不启动 CPA、不等待恢复。**

| 手册 | 用途 |
|---|---|
| [中文对照手册](2026-11-05_部署-CPA双机主备-Worker-KV操作手册-中文版.md) | 中文步骤对照英文控件名称 |
| [Worker + KV 简明手册](2026-11-05_部署-CPA双机主备-Worker-KV操作手册.md) | 简明配置及应急入口操作 |

两份手册代码和命令保持一致。历史方案状态以当前[备份文档](../backup/README.md)和[验证记录](../development/verification.md)为准，不把历史“待实施”描述当当前状态。

## 与恢复的关联

- 日常 Worker/KV 按已部署策略切流量，独立服务做主→备备份。
- 故障隔离旧主、恢复备机并验证 CPA，再确认入口切向备机。
- 主恢复保持隔离，备→主最终回灌/角色交接与业务验证后，再回切入口。
- 自动回主可能在主 CPA 刚上线时回主，管理员处理恢复期间入口隔离。

完整顺序见[接管、回灌与回切](../backup/failover-failback.md)。邀请安装不操作 Cloudflare，不收集/复制 Cloudflare Token 或 Tunnel 凭据。

[原始设计](../archive/2026-11-05_部署-CPA双机主备-report.md)保留为历史资料，不是新版安装步骤。真实入口反馈与本地服务验收分开记录，管理 `/healthz` 不当 CPA 业务探测。
