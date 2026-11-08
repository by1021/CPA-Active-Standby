# 故障诊断与服务管理

在失败节点先只读检查。在安装执行目录或 `cpa-dr/` 项目目录操作，稳定入口自动关联配置；从其他目录可使用安装输出的完整入口：

```bash
bash start.sh status
bash start.sh doctor
bash start.sh logs --tail 50
```

状态/诊断不自动启动、提权或安装依赖，返回 0 仍可能报告异常/未知。日志可能含业务信息，分享前脱敏，不上传管理员令牌或邀请命令。

`--output TARGET` 仍可明确选择配置目录，`TARGET` 是配置目录，不是源码或 CPA 数据目录。查不到记录会显示查找路径；安装状态、服务状态、配对和调度分别核对。

| 现象 | 检查 |
|---|---|
| `start.sh: No such file or directory` | 核对安装输出的项目入口；已有无关 start.sh 时不覆盖，使用 cpa-dr/start.sh 完整路径。旧版本隐藏目录安装按下节接管 |
| 服务刚启动却提示未安装 | 核对查找配置目录与实际配置；新稳定入口自动关联，旧源码可显式 --output，不重新初始化空配置 |
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
| 入口安装身份与部署记录不符 | 保留项目、配置和数据，核对所选入口/配置与原执行账户；显式同配置和 Native sudo 重入仍须身份一致，不手工改 ID 促使重装 |
| 引导器报告祖先目录权限不足/路径含链接 | 未关联项目在下载源码或安装依赖之前停止；核对实际配置与执行账户，保留旧部署。已有可信 Native 关联的写操作经确认后通过稳定入口 sudo 重验身份；非交互需 `--yes`，只读状态不自动提权 |
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

## 旧 GitHub 隐藏目录安装

旧引导器源码位于 `$HOME/.local/share/cpa-dr/github/<提交SHA>/cpa-dr`，默认主机配置在 `$HOME/.local/share/cpa-dr/deployments/primary`。进入旧源码后，旧管理命令仍须明确配置目录：

```bash
bash start.sh status --output "$HOME/.local/share/cpa-dr/deployments/primary"
```

使用更新后的引导器，在希望留下项目入口的目录执行；原配置自定义时替换 `--output`：

```bash
bash install-cpa-dr.sh --output "$HOME/.local/share/cpa-dr/deployments/primary" --yes
```

已有记录验证通过后只建立稳定入口和部署关联，原配置、状态、源码及 Compose 身份不强制搬迁。以后使用当前目录或 `cpa-dr/` 下的 `start.sh`，不再反复传 `--output`。多份部署、损坏记录或权限不足会停止接管；不要删除记录、公钥或数据来促使重新安装。
