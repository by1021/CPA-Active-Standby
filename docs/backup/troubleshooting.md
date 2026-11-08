# 故障诊断与服务管理

在失败节点先只读检查；`TARGET` 为原自定义配置目录，默认安装可省略 `--output`：

```bash
bash start.sh status --output TARGET
bash start.sh doctor --output TARGET
bash start.sh logs --output TARGET --tail 50
```

状态/诊断不自动启动、提权或安装依赖，返回 0 仍可能报告异常/未知。日志可能含业务信息，分享前脱敏，不上传管理员令牌或邀请命令。

| 现象 | 检查 |
|---|---|
| 已安装但另一台连接失败 | 专用 SSH 监听/发布端口、防火墙、双向路由，不填 CPA 端口 |
| `Permission denied (publickey)` | 受限公钥、私钥路径、账户、邀请有效期；不换主机永久私钥 |
| hostkey 失败 | 对端持久指纹、known_hosts 的地址/端口是否一致；不关闭校验 |
| 自定义 SSH 文件加入失败 | 核对配置的 `peer.identity_file`、`peer.known_hosts_file`，两者独立；私钥为无需口令的 Ed25519，已有 `.pub` 与私钥匹配。停止 Docker 仅核验原 `/state` 挂载内文件，其他路径不自动启动服务来读取 |
| `已有安装状态未确认` | 在原配置目录运行 `status` 核对安装记录、权限和查询工具；保留原目录/数据/身份，修正异常后再续装，不以空记录推断未安装 |
| 已认领未完成 | 原节点续装，检查配对与首备错误；异节点不得复用 |
| 已配对没有备份 | 主机来源、容量/磁盘、首备最终结果、最近传输与备机历史 |
| 主机有快照备机没有 | 本地快照不代表传输成功，检查 SSH 与对端角色 |
| 备 CPA 数据没自动更新 | 正常；备份保存快照，恢复/接管单独停写确认 |
| HTTP 409 / 另一任务运行 | 请求未接纳，等当前作业最终结束后重试，不杀恢复写者 |
| 旧副本拒收 | 节点时钟、角色/代次、迟到传输；不关闭防回退 |
| `status` 未知 | 工具、权限、安装记录可能不可读；未知不等于未安装，不重建身份 |
| 首备失败、调度未启用 | 修正后原邀请/身份续装，不把“已安装”当完成 |

## 启停、重装与卸载

```bash
bash start.sh stop --output TARGET
bash start.sh start --output TARGET
bash start.sh restart --output TARGET
bash start.sh install --output TARGET
bash start.sh configure-ssh --ssh-bind-host HOST --output TARGET
bash start.sh uninstall --output TARGET
bash start.sh uninstall --output TARGET --purge
```

只操作备份服务，不启停 CPA。停止、重启、卸载及监听调整拒绝中断运行任务；`start` 只启动已有服务，`install` 恢复安装并保留身份/历史。`configure-ssh` 在核对部署/归属后更新专用 SSH 监听，`HOST` 为本机可绑定地址。非交互写操作明确 `--yes`。

普通卸载保留备份、配置、密钥；清除需 `PURGE` 确认，只删除本服务专用状态/文件。原始 CPA 数据、源码、共用依赖、无关容器/服务保留，不全局 prune。

Docker `.env` 是数据文件，不 `source`。本地默认配置 `/etc/cpa-dr-native`、状态 `/var/lib/cpa-dr-native`、服务 `/opt/cpa-dr-native`。自定义后所有操作选择同一部署，不在其他目录新建空状态，不手工删安装记录或归属标记。
