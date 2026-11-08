# 安装主机

## 准备

CPA 已有数据父目录与源码、备份状态、配置目录相互独立。列出实际需要共享的目录、普通文件和 SQLite 数据库；监听、代理及 Tunnel 凭据等节点差异不直接纳入共享配置。

双端须能访问专用备份 SSH。管理默认 `127.0.0.1:8787`，专用 SSH 默认 `2222`；它不是 CPA 业务端口或日常登录的 SSH。

## 安装

无需克隆仓库，在主机终端执行：

```bash
curl -fsSL https://raw.githubusercontent.com/by1021/CPA-Active-Standby/main/install.sh -o install-cpa-dr.sh && bash install-cpa-dr.sh
```

入口默认主机角色，将 GitHub 版本固定为完整提交 SHA，再获取服务源码和配置模板。GitHub 安装默认配置目录为 `$HOME/.local/share/cpa-dr/deployments/primary`，源码位于 `$HOME/.local/share/cpa-dr/github/<提交SHA>/cpa-dr`。以安装输出为准，后续操作进入该源码目录并指定相同 `--output`。

已有本地源码也可在项目根目录执行 `bash start.sh`，沿用其原有默认目录。

选择安装，设置主机角色、数据父目录、多项标签/类型/路径、部署方式及端口。GitHub 入口的下载/校验依赖由引导器单独确认并补齐；服务依赖、部署配置与服务启动在完整计划确认后执行。取消计划不写部署配置。

| 方式 | 行为 |
|---|---|
| Docker | 使用现有 Engine/Compose v2；数据父目录映射到 `/data` |
| Linux 本地 | 使用 systemd、Nginx、fcgiwrap、OpenSSH 等，普通用户经 sudo |
| 新安装 | 定时任务停用，不启停 CPA、不自动恢复业务数据 |

非交互示例，`TARGET` 为实际数据父目录，`HOST` 为本机供备机连接的专用 SSH 监听地址：

```bash
bash install-cpa-dr.sh --deployment docker --data-dir TARGET \
  --source auths:directory:auths --ssh-bind-host HOST --yes
```

按实际数据增减 `--source 标签:directory|file|sqlite:路径`；Linux 本地改为 `--deployment native`。`--yes` 明确确认安装和所需依赖，`--no-install-deps` 只检查，二者不同时使用。管理 `--bind-host` 与专用 `--ssh-bind-host` 分开设置。

## 管理与核对

安装输出管理员令牌，保存在服务器侧，不上传日志或 Git。登录后核对数据标签、路径、周期与容量，先保存并保持定时任务停用。Docker 页面使用容器 `/data` 路径，本地使用宿主绝对路径。SQLite 选一致性备份类型。

管理电脑使用日常 SSH 登录地址 `HOST` 建转发，打开 `http://127.0.0.1:8787`：

```bash
ssh -N -L 8787:127.0.0.1:8787 HOST
```

专用 SSH 监听双方可达地址，防火墙仅允许对端来源。已有部署改监听用受控入口，核对原配置目录和新监听地址：

```bash
bash start.sh configure-ssh --ssh-bind-host HOST --output TARGET
```

Docker 受任务锁保护停止、更新监听并重新就绪；Linux 本地更新服务源码与专用 SSH 配置并维护归属摘要，保留身份/状态。不要直接修改所有权标记或单元摘要。`/healthz` 只证明管理服务，不代表 CPA 业务正常。

然后进入[备机安装](install-standby.md)。自定义首次 `--output` 后，后续操作一直选择相同目录：

```bash
bash start.sh status --output TARGET
bash start.sh install --output TARGET
```

已有安装重跑保留配置、身份和历史，不从其他空目录重新初始化。
