# 架构入口

当前实现：[docs/architecture.md](docs/architecture.md)。

- 后端与CLI：Bash + GNU/Linux命令，不依赖 Python/Node 服务进程。
- 数据：jq配置、tar/SHA256恢复点、rsync原位恢复、sqlite3一致性备份。
- 双节点：OpenSSH密钥认证、已核验known_hosts、受限forced-command RPC。
- 页面：静态HTML/CSS/JS，nginx/fcgiwrap只调用固定Shell CGI。
- 定时：Linux systemd timer，Docker内由Shell循环调用同一个tick。

备份自动；接管/恢复由管理员确认。CPA与Cloudflare为未改动的外部系统。
