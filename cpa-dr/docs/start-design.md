# 一键安装入口

状态：定稿；2026-11-06。原始需求：「创建一键安装脚本start.sh」。单模块 Feature，需求和本次设计合并记录；未启用 `.ai_state`，不初始化状态库，也不把普通测试/复审称作正式 Athena 门禁。

## 范围与取舍

- 在 `cpa-dr/start.sh` 提供现有 Docker 部署的一键入口：检查依赖、首次初始化、构建/启动、等待管理服务健康、显示登录信息。
- 首次支持交互输入数据父目录，也支持 `--data-dir`、`--output`、`--port`、`--ssh-port`、`--read-only-data`；已有配置可直接重跑。重复传入的初始化参数必须与原配置一致，冲突时报错，不悄悄覆盖。
- Docker Engine、支持 `up --wait --wait-timeout` 的 Compose v2，以及初始化用的 Linux 命令和 jq 需预先安装。沿用 README 的依赖前提，不自动下载执行安装器、不更改宿主软件包或权限。
- 不安装 systemd、不修改 CPA/Cloudflare、不自动配对或启用备份、不删除状态和备份。健康检查只证明管理服务存活。

## 验收

- AC1: 从任意工作目录运行都使用脚本旁的源码/Compose；首次生成私有配置、密钥并以 `--build --wait --wait-timeout` 启动，成功后显示实际管理地址、管理员令牌和公钥。
- AC2: 重跑（包括相同参数）保留 `.env`、密钥和状态；冲突参数、缺失的数据/状态目录及数据与源码/状态嵌套，在启动容器前拒绝。
- AC3: 参数错误、非交互缺少数据目录、依赖/daemon/Compose能力缺失均非零退出；预检查失败不生成配置。构建/健康等待失败非零退出，不输出成功、不清理配置和数据。
- AC4: `.env` 只通过 Compose 解析，绝不 `source`/`eval`；外部同名数据/令牌/端口环境变量不覆盖文件配置。仅使用已有的 loopback 默认监听。
- AC5: README 给出首次、重跑、端口/只读设置和依赖说明；mock 回归、现有部署测试、ShellCheck 与真实隔离 Compose 安装/重跑均通过。

## 实现方案

入口复用 `scripts/setup.sh`，不复制密钥生成逻辑。固定 Compose 文件与项目目录、显式传入绝对 `.env`；`--output` 只改变私有配置/状态位置，不改变镜像源码位置。`COMPOSE_PROJECT_NAME` 可用于隔离测试项目。通过 `docker compose config --format json` 和 jq 读取实际挂载/端口/令牌，验证路径与重复参数；本机 Compose 2.26.1 的 `config --help` 未提供 `--environment`，实际调用亦报 unknown flag，故采用已支持的 JSON 模型。用 `up --wait` 使用镜像既有健康检查，失败仅提示排错命令。行为先写回归并复现缺失入口，再实现；最终独立只读复审。
