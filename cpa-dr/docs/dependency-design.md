# 启动时安装缺失宿主依赖

状态：定稿；2026-11-06。单模块 Feature；未启用 `.ai_state`，沿用普通检查与独立复审，不初始化状态库。

后续需求修订：[安装向导与卸载设计](installer-workflow-design.md) 增加 Linux 本地依赖分支，选择方式后才检查对应依赖；卸载只检查必要命令，不安装软件包。原有 Docker 软件源/权限策略仍保留，以下不改 systemd 入口等内容为历史范围。

## 需求与范围

用户运行 `./start.sh` 时遇到缺少 jq，要求检测后提示用户，再安装缺失依赖，而不是只报错退出。

- 默认列出全部缺失项并询问 `[y/N]`；确认后用宿主已配置的软件源安装，再检查并继续原启动流程。
- 支持 apt-get、dnf、yum；映射 coreutils、OpenSSL、OpenSSH 客户端、util-linux、jq，以及 Docker/Compose 包。Docker 包只从现有软件源选择，不下载执行远程安装器，不添加软件源。
- root 直接安装；其他用户仅对软件包操作调用 sudo，不以 root 重跑整份启动脚本，不改账户组、目录所有权或服务设置。
- `--yes` 明确允许无人值守安装；`--no-install-deps` 保留原先只检查模式。非交互未授权、拒绝、软件源/权限/安装失败或复检失败均在生成部署配置和启动容器前退出。
- 不改 systemd 安装入口、CPA、配对与备份行为；Docker daemon/访问权限仍由原预检查验证。

## 验收

- AC1: 依赖齐全及 `--help` 不触发软件包操作；缺失项一次性列出。终端默认确认后安装，拒绝/回车/EOF 不安装；非交互缺少 `--yes` 不安装。
- AC2: apt-get/dnf/yum 只安装缺失功能对应的去重包；apt 先刷新索引，从有 Candidate 的配置源选择 Docker/Compose。缺少 Compose 或旧版缺少等待能力也进入安装/升级流程，结束后复检全部命令和 Compose 能力。
- AC3: root 不调用 sudo；非 root 在确认后用 sudo 执行软件包命令；缺少 sudo、索引/安装失败、软件包不可用和安装后仍缺失均非零退出并给出具体原因，不产生配置、不启动容器。
- AC4: `--yes` 支持无人值守安装，`--no-install-deps` 禁止安装，二者同时使用报参数冲突。现有首次/重跑、状态保护、路径与配置验证保持不变。
- AC5: 文档说明确认、权限、软件源与非交互行为；Bash 语法、ShellCheck、隔离依赖安装模拟、原入口和部署回归通过。模拟不实际安装宿主软件包。

## 实现

新增只被启动入口加载的 Bash helper，全部命令以数组执行，无 eval。入口定位自身目录不依赖尚未安装的 dirname。先做参数检查，再检测/提示/安装/复检，最后执行原 Docker daemon 和部署流程。apt-cache policy 判断 Candidate，RPM 通过包管理器查询配置源中的包；错误立即退出，不自动尝试另一套安装路径。

本轮需求修订覆盖 `start-design.md` 中历史的「不自动安装」取舍，以及依赖缺失立即退出的历史验收；其他入口验收保持不变。

复审修正（2026-11-06，AC 不变）：本机 Debian 13 的 `apt-cache policy` 与 `dpkg-query -S` 确认 Compose 插件来自 `docker-compose` v2、Docker CLI 来自独立 `docker-cli`，`apt-cache depends docker.io` 将 CLI 列为推荐包。追加版本至少为 v2（含 epoch）的同名 Compose 候选，排除 v1；按 Docker 包元数据显式补齐 CLI。RPM 的同名 Compose 候选也检查版本。新增 Debian 拆包/epoch/v1 排除及 RPM 候选回归，先复现失败再修正。
