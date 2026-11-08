# CPA DR · 服务入口

Bash + jq + OpenSSH + tar/rsync/SHA256 的主备备份服务，SQLite 使用 `sqlite3 .backup`。Nginx + fcgiwrap 提供中文页面，不运行 Python/Node 后端。

用户操作说明统一维护在 [docs/backup/](../docs/backup/README.md)，Cloudflare 配置保留在 [docs/cloudflare/](../docs/cloudflare/README.md)。

项目根目录运行 `bash start.sh`；原方式继续支持：

```bash
cd cpa-dr
bash start.sh
```

| 操作 | 入口 |
|---|---|
| 安装主机 | [主机安装](../docs/backup/install-primary.md) |
| 生成命令、安装备机 | [备机安装](../docs/backup/install-standby.md) |
| 配对与邀请管理 | [主备配对](../docs/backup/pairing.md) |
| 日常备份、历史恢复 | [备份](../docs/backup/backup.md) · [恢复](../docs/backup/restore.md) |
| 接管、回灌与回切 | [恢复交接](../docs/backup/failover-failback.md) |
| 状态、服务管理与诊断 | [故障诊断](../docs/backup/troubleshooting.md) |
| 架构、测试结果 | [架构](../docs/development/architecture.md) · [验证记录](../docs/development/verification.md) |

备份副本不自动写入备 CPA 运行目录；恢复/接管需停写确认。已有 `.env`、安装记录、密钥和快照保持原位置，不随代码分类迁移。管理默认仅本机访问，专用 SSH 与管理监听分别配置；不修改 CPA、Cloudflare 或防火墙。

GitHub 一键安装落在执行目录下 `cpa-dr/`，提供当前目录快捷入口与项目稳定入口，通过 JSON 记录关联实际配置；日常操作不需进入内部版本目录或重复传 `--output`。首次主机交互安装末尾可直接生成备机命令；非交互显式 `--generate-backup` 才同轮生成。详见主备安装手册。
