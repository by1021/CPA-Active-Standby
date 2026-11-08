# CPA-Active-Standby

为 CPA 双机部署提供数据备份、确认式恢复和流量入口配置方案。

**Cloudflare 负责流量入口，`cpa-dr` 负责备份与恢复。** 两者独立部署：本项目安装器不会安装、启停 CPA 业务，也不会修改 Worker、KV、Tunnel 或防火墙。

## 功能概览

| 能力 | 说明 |
|---|---|
| 主机一键安装 | 从 GitHub 下载固定提交的服务源码及配置模板，按部署方式安装所需依赖 |
| 备机一键加入 | 主机生成一次性命令，继承主备端点、数据标签、类型、相对路径与备份策略 |
| 自动配对 | 备机生成独立身份，固定 SSH 指纹，完成双向连接与首份备份校验 |
| 数据备份 | 支持目录、普通文件和 SQLite；具备周期备份、保留策略与二次副本 |
| 管理界面 | 提供中文配置、连接检查、作业状态、备份历史与安装邀请管理 |
| 恢复与回切 | 显式确认停写、隔离与恢复；支持历史恢复、备机接管和备→主回灌 |
| 部署方式 | Docker Compose 或 Linux 本地 systemd，可在主备两端分别选择 |

> 自动备份不等于自动业务接管。快照接收成功不代表备 CPA 已加载数据；恢复成功也不代表流量已经切换。

## 环境要求

- Linux，Bash 4.3+、curl 和有效的系统 CA 证书。
- 可访问 GitHub 的 `raw.githubusercontent.com`、`api.github.com`、`codeload.github.com`，以及系统软件源；Docker 构建还需访问镜像仓库。
- 软件包安装需要 root 或 sudo；支持现有 apt-get、dnf、yum 软件源。引导器补齐下载/校验工具，正式安装器按所选方式检查并安装依赖。
- Docker 部署需要可用的 Engine 与 Compose v2；Linux 本地部署需要可运行的 systemd。服务安装不自动配置额外软件源或防火墙。
- 主备之间的**专用备份 SSH** 双向可达。默认管理地址为 `127.0.0.1:8787`，专用 SSH 端口为 `2222`；均不属于 CPA 业务端口。
- CPA 数据父目录必须与服务源码、安装配置及备份状态目录分离。先确认需要共享的数据，不直接同步 Tunnel 凭据或节点专属配置。

## 快速开始

### 1. 在主机执行一键安装

无需克隆仓库，在主机终端执行：

```bash
curl -fsSL https://raw.githubusercontent.com/by1021/CPA-Active-Standby/main/install.sh -o install-cpa-dr.sh && bash install-cpa-dr.sh
```

入口默认选择主机角色，首次解析 `main` 为完整提交 SHA，随后从该固定提交下载服务源码和配置模板。项目安装在**执行命令时的当前目录下 `cpa-dr/`**：在 `/root` 执行就是 `/root/cpa-dr`，不是强制安装到隐藏 HOME 目录。按向导填写数据父目录、备份项目、部署方式及监听地址，确认安装计划后启动服务。**新安装保持定时备份停用。**

主机首次交互安装结束后，直接询问是否生成备机安装命令（默认继续）。填写主备互访地址、备机数据目录和部署方式，确认计划后即可复制完整命令，无需退出再手动调用生成器。专用 SSH 仅监听回环时会提示；修改监听须单独确认，管理页面及防火墙不随之修改。取消邀请不影响已完成的主机安装。

非交互安装示例：`TARGET` 替换为已存在的 CPA 数据父目录，`HOST` 替换为本机供备机连接的 SSH 监听地址。

```bash
bash install-cpa-dr.sh --deployment docker --data-dir TARGET \
  --source auths:directory:auths --ssh-bind-host HOST --yes
```

Linux 本地部署使用 `--deployment native`。按实际数据调整 `--source 标签:directory|file|sqlite:路径`。`--yes` 确认安装及所需依赖；`--no-install-deps` 禁止自动安装，需要预装下载引导和服务依赖，二者互斥。

| 安装内容 | 默认位置 |
|---|---|
| 项目及稳定管理入口 | `执行目录/cpa-dr/start.sh` |
| 当前目录快捷入口 | `执行目录/start.sh`（已有无关文件不覆盖） |
| 固定版本源码 | `执行目录/cpa-dr/releases/<提交SHA>/cpa-dr` |
| 新主机安装配置 | `执行目录/cpa-dr/config` |
| Docker 状态、密钥与快照 | `配置目录/state-native` |
| Linux 本地服务 / 状态 | `/opt/cpa-dr-native` / `/var/lib/cpa-dr-native` |

安装会输出项目、源码、配置、状态路径、管理地址与完整管理命令。`--install-dir TARGET` 自定义项目目录，`--output TARGET` 独立自定义配置目录，两者不是同一个选项。稳定入口通过受限 JSON 安装记录关联实际部署，后续管理无需反复传 `--output`；显式提供时仍优先。保持同一执行用户，不复制他人身份或手工修改安装记录。本地克隆安装仍支持 `bash start.sh`，沿用其原有默认路径。

同一执行目录已有本项目安装时，重跑引导器复用原部署，不重新下载、不追踪 `main` 或重置身份。兼容旧隐藏目录安装时先验证原记录再关联入口，不搬迁运行状态；发现多份部署须明确选择配置目录。

如需固定已确认版本，可在安装前设置 `CPA_GITHUB_REF` 为完整提交 SHA 或标签；备机始终使用主机邀请中的固定提交，不自动跟随 `main`。

### 2. 在主机生成备机命令

首次交互安装可直接完成此步骤。以后在安装执行目录运行 `bash start.sh`，菜单选择「生成备机安装命令」；进入 `cpa-dr/` 后运行同一命令也可。

登录管理页面，保存数据项目与策略，在「节点配置 → 一键添加备机」填写：

- 备机访问主机的地址及专用 SSH 端口。
- 主机访问备机的地址、专用 SSH 端口及备机本地监听地址。
- 备机数据父目录、部署方式和可选配置目录。
- 邀请有效期，以及首备成功后是否启用调度。

核对完整计划后生成并复制命令。命令包含短期安装凭据，默认有效期为 **30 分钟**，仅交给指定备机管理员，不公开发布。

也可在安装执行目录或项目目录执行：

```bash
bash start.sh generate-backup-command \
  --primary-host HOST --primary-port PORT \
  --backup-host HOST --backup-port PORT --backup-bind-host HOST \
  --backup-data-dir TARGET --backup-deployment docker --ttl 1800 --yes
```

两个 `HOST`、`PORT` 按各自端点替换；`TARGET` 为备机恢复数据父目录。稳定入口已记录自定义配置；直接使用没有关联记录的源码入口时，可以显式 `--output TARGET` 选择部署。

非交互安装不会等待填写备机地址。需要同轮生成时，安装参数额外加 `--generate-backup`、上述主备连接参数及 `--yes`；缺少必要地址先报参数错误，不在服务安装后等待输入。

### 3. 在备机执行生成的完整命令

备机无需预先克隆仓库或手工交换公钥。请在备机希望存放项目的目录执行，项目同样落在当前目录下 `cpa-dr/` 并生成稳定入口。GitHub 来源的主机生成的命令会：

1. 从 GitHub 获取主机固定提交的源码与配置模板。
2. 重建源码白名单安装包，核对主机给出的版本、SHA-256 摘要及逐文件清单。
3. 安装备份服务，建立独立身份，映射本机数据路径并完成双向 SSH 配对。
4. 接收、验证首份备份，最后按选项启用两端调度。

下载、摘要、权限、连接或首备检查失败时，保留进度并停止，不切换下载来源、不报告成功。原命令支持同身份续装；邀请进度记录原项目位置，即使换工作目录重跑仍复用原安装。已完成邀请重跑只读返回历史收据，不重新下载、重启服务或改变管理员后续配置。

**兼容说明：**直接由本地源码安装、没有固定 GitHub 来源信息的旧部署，仍使用原有固定摘要 SSH 安装包。要使用 GitHub 下载链路，请从新入口安装，并确认主机运行版本来自该固定提交；不通过伪造来源信息改写旧部署。

## 日常管理

在安装执行目录或 `cpa-dr/` 项目目录操作：

```bash
bash start.sh
bash start.sh status
bash start.sh doctor
bash start.sh logs --tail 50
```

从其他目录调用安装输出的完整入口也可，入口不依赖当前工作目录。需要选择另一份部署时再使用 `--output TARGET`。状态分别显示安装、服务运行、配对及调度；已安装但停止或状态未知不等于尚未安装，不自动创建新身份。

管理页面默认仅监听回环地址。可通过日常登录 SSH 建立转发，在管理电脑打开 `http://127.0.0.1:8787`：

```bash
ssh -N -L 8787:127.0.0.1:8787 HOST
```

专用备份 SSH 应监听主备可达地址，防火墙限制对端来源。管理员令牌、邀请命令和 SSH 私钥只保存在受限本机目录，不上传 GitHub。

## 操作文档

| 主题 | 文档 |
|---|---|
| 完整安装与首备流程 | [主备备份总流程](docs/backup/README.md) |
| 主机部署 | [主机安装](docs/backup/install-primary.md) |
| 备机命令与续装 | [备机一键安装](docs/backup/install-standby.md) |
| 自动 / 手工配对 | [主备配对](docs/backup/pairing.md) |
| 备份策略与成功判定 | [日常备份](docs/backup/backup.md) |
| 历史数据恢复 | [历史恢复](docs/backup/restore.md) |
| 接管、回灌与回切 | [接管与回切](docs/backup/failover-failback.md) |
| 故障诊断 | [连接、权限与作业检查](docs/backup/troubleshooting.md) |
| Cloudflare 流量入口 | [Worker / KV 配置说明](docs/cloudflare/README.md) |
| 工程依据 | [架构](docs/development/architecture.md) · [验证记录](docs/development/verification.md) |

## 数据一致性与运行边界

```text
日常：主机数据 → 主机快照 → SSH → 备机快照库 → 二次备份
故障：隔离旧主 → 确认恢复备机数据 → 验证备 CPA → 切业务入口
回切：备机继续服务 → 停写交接 → 备→主回灌 → 验证主 CPA → 回切入口
```

- 普通文件在线采集为尽力一致；SQLite 使用一致性备份类型。不承诺跨文件事务、零数据丢失或网络分区自动仲裁。
- 历史恢复、接管和回切需要明确确认停写与隔离；Worker 不等待数据恢复、不启动 CPA。
- 二次副本仍在备机本地故障域；离机备份及静态加密需单独安排。
- 本地容器验证与真实宿主验收分别记录。真实 systemd、发行版依赖安装、CPA 版本/权限、OAuth 与业务入口联动仍须在目标环境演练。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `install.sh` | GitHub 固定版本主机安装入口 |
| `start.sh` | 本地源码管理入口，兼容原 `cpa-dr/start.sh` |
| `cpa-dr/` | Bash 后端、管理页面、部署模板、安装工具及分层测试 |
| `docs/backup/` | 当前备份服务操作手册 |
| `docs/cloudflare/` | Cloudflare 配置说明与保留的 Worker 代码 |
| `docs/development/` | 架构、设计、审查与验证资料 |
| `docs/archive/` | 历史方案，不作为当前安装步骤 |

安装包仅包含服务源码白名单和公共配置模板。实际配置、管理员令牌、SSH 密钥、业务数据、快照与本地验证日志不纳入 Git 或安装包。
