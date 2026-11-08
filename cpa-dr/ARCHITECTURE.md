# 架构入口

当前实现统一维护在 [docs/development/architecture.md](../docs/development/architecture.md)。

- Bash CLI/任务管理；jq 配置，tar/SHA256 快照，rsync 恢复，sqlite3 一致性备份。
- OpenSSH 严格 hostkey 与受限身份；一次性邀请仅服务安装/配对，永久身份负责备份与确认式交接。
- Nginx/fcgiwrap 提供固定 Shell CGI；中文页面管理配置、邀请、作业与恢复。
- Docker 或 Linux 本地独立部署，管理与专用 SSH 监听分开；源码整理不迁移运行状态。
- 自动的是备份，不是 CPA 故障接管或 Cloudflare 切换。
