# 安装主机

## 准备

CPA 已有数据父目录与源码、备份状态、配置目录相互独立。列出实际需要共享的目录、普通文件和 SQLite 数据库；监听、代理及 Tunnel 凭据等节点差异不直接纳入共享配置。

双端须能访问专用备份 SSH。管理默认 `127.0.0.1:8787`，专用 SSH 默认 `2222`；它不是 CPA 业务端口或日常登录的 SSH。

## 安装

无需克隆仓库，在主机终端执行：

```bash
curl -fsSL https://raw.githubusercontent.com/by1021/CPA-Active-Standby/main/install.sh -o install-cpa-dr.sh && bash install-cpa-dr.sh
```

入口默认主机角色，首次将 GitHub 版本固定为完整提交 SHA，再获取服务源码和配置模板。项目位于安装命令的执行目录下 `cpa-dr/`，新主机配置在 `cpa-dr/config`，源码在 `cpa-dr/releases/<提交SHA>/cpa-dr`。在 `/root` 执行时项目就是 `/root/cpa-dr`。安装记录关联真实部署，日常不需要进入 SHA 目录或重复填写 `--output`。

指定 `CPA_GITHUB_REF` 首次安装时，所选提交须包含新版 `github.sh` 和 `location.sh`；辅助文件缺失会明确报错，不回退到 main。已有旧隐藏部署可通过新版引导器关联原源码，无需升级。

安装执行目录留下 `start.sh` 快捷入口，项目目录也有稳定 `start.sh`。已有无关同名文件保留；这时使用安装输出的完整项目入口。`--install-dir TARGET` 指定项目位置，`--output TARGET` 只指定配置位置，二者独立。

已有本地源码也可在项目根目录执行 `bash start.sh`，沿用其原有默认目录。

选择安装，设置主机角色、数据父目录、多项标签/类型/路径、部署方式及端口。GitHub 入口的下载/校验依赖由引导器单独确认并补齐；服务依赖、部署配置与服务启动在完整计划确认后执行。取消计划不写部署配置。

| 方式 | 行为 |
|---|---|
| Docker | 使用现有 Engine/Compose v2；数据父目录映射到 `/data` |
| Linux 本地 | 使用 systemd、Nginx、fcgiwrap、OpenSSH 等，普通用户经 sudo |
| 新安装 | 定时任务停用，不启停 CPA、不自动恢复业务数据 |

首次主机交互安装成功后，直接询问「现在生成备机安装命令？[Y/n]」。继续填写主备地址、专用 SSH 端口、备机数据目录和部署方式，核对计划后生成；取消不影响主机安装。专用 SSH 如果仅监听回环，须确认调整到本机可绑定且对端可达地址；不修改管理监听和防火墙。

非交互示例，`TARGET` 为实际数据父目录，`HOST` 为本机供备机连接的专用 SSH 监听地址：

```bash
bash install-cpa-dr.sh --deployment docker --data-dir TARGET \
  --source auths:directory:auths --ssh-bind-host HOST --yes
```

按实际数据增减 `--source 标签:directory|file|sqlite:路径`；Linux 本地改为 `--deployment native`。`--yes` 明确确认安装和所需依赖，`--no-install-deps` 只检查，二者不同时使用。管理 `--bind-host` 与专用 `--ssh-bind-host` 分开设置。

非交互需要同轮生成备机命令时额外提供 `--generate-backup`、`--primary-host HOST`、`--backup-host HOST` 及备机参数；不指定则只安装，不等待输入。必要参数缺失先报错。

## 管理与核对

安装输出管理员令牌，保存在服务器侧，不上传日志或 Git。登录后核对数据标签、路径、周期与容量，先保存并保持定时任务停用。Docker 页面使用容器 `/data` 路径，本地使用宿主绝对路径。SQLite 选一致性备份类型。

管理电脑使用日常 SSH 登录地址 `HOST` 建转发，打开 `http://127.0.0.1:8787`：

```bash
ssh -N -L 8787:127.0.0.1:8787 HOST
```

专用 SSH 监听双方可达地址，防火墙仅允许对端来源。已有部署改监听用受控入口，核对原配置目录和新监听地址：

```bash
bash start.sh configure-ssh --ssh-bind-host HOST
```

Docker 受任务锁保护停止、更新监听并重新就绪；Linux 本地更新服务源码与专用 SSH 配置并维护归属摘要，保留身份/状态。不要直接修改所有权标记或单元摘要。`/healthz` 只证明管理服务，不代表 CPA 业务正常。

然后按[备机安装](install-standby.md)执行主机生成的完整命令。在安装执行目录或项目目录日常操作：

```bash
bash start.sh
bash start.sh status
bash start.sh install
```

从其他目录使用安装输出的完整入口也能定位同一部署。稳定入口已关联自定义 `--output`；显式 `--output TARGET` 仍可选择另一个已知部署。

重跑 GitHub 引导器默认接管原安装，不追踪 main、不重新下载或重建服务；需要恢复安装时用 `start.sh install`。兼容旧隐藏目录时仅验证记录并关联稳定入口，不搬数据、不变更令牌、公钥或 Compose 项目名。多份记录明确选择，不从空目录重新初始化。
