# CPA DR · Linux 原生主备容灾备份

使用 **Bash + Linux 原生命令**实现，不运行 Python 后端。中文管理页面保留，由 **Nginx + fcgiwrap + Shell CGI**提供；数据传输使用 **OpenSSH 受限 RPC**，文件同步/恢复由 `rsync`、`tar`、`sha256sum` 执行，SQLite 使用 `sqlite3 .backup`。

| 能力 | 当前实现 |
|---|---|
| 主／备角色、备份内容与周期 | 安装向导预设角色和数据，页面调整周期；JSON 持久化，不作为 Shell 代码执行 |
| 主→备自动备份 | 定时采集、SHA256 校验、SSH 传输、完整验证后发布 |
| 备机二次备份 | 按独立周期保存已收到的有效副本，分类保留历史 |
| 历史恢复 | 校验、目标预览、明确确认、覆盖前回滚、反映新增／修改／删除 |
| 故障接管与反向回灌 | 管理员确认停写/旧主隔离后执行，失败保持保护态 |
| 部署 | Docker Compose，或宿主 Linux 的 systemd timer + 原生服务 |

**自动执行的是备份；接管、恢复、回切仍需管理员确认。不会修改现有 CPA、Cloudflare Worker、域名或 Tunnel。管理接口 `/healthz` 只说明管理服务存活，不代表 CPA 已准备好接收业务流量。** 快照是明文数据，建议磁盘加密、受限权限及独立离机备份。

## 1. 安装向导（主、备两台分别执行）

`TARGET` 替换为已存在的 CPA **数据父目录**，必须与服务源码、部署目录和状态目录独立。首次终端安装：

```bash
cd cpa-dr
bash start.sh
```

| 顺序 | 输入 | 保存结果 |
|---|---|---|
| 1 | 本机为主机或备机 | `primary` / `backup` |
| 2 | 数据父目录；逐项输入备份路径、标签、类型 | 支持目录、普通文件、SQLite，多项不重叠 |
| 3 | 确认角色和数据 | 取消不安装依赖、不生成配置 |
| 4 | `1` Linux 本地；`2` Docker | 安装所选方式的依赖及服务 |

路径可相对数据父目录，回车选择整个父目录；标签只能使用字母、数字、下划线和短横线。**两端使用相同标签和类型，路径可以不同。** 备机恢复目标可以尚未存在，父目录仍须预先创建；主机来源必须存在。SQLite 应单独选择 SQLite 类型，不把在线数据库当作普通目录文件备份。

安装成功时角色和数据已保存，**新安装定时备份仍为停用**。登录页面核对，再配置周期、对端、公钥及主机指纹。脚本不启停现有 CPA、不修改 Cloudflare，也不自动配对或执行恢复。

### 无人值守与重跑

首次非交互必须明确指定角色、父目录和方式。重复 `--source 标签:类型:路径` 选择多项；不指定时选择整个父目录，标签为 `data`：

```bash
# 主机，Docker；只填写实际需要共享的数据
bash start.sh --role primary --deployment docker --data-dir TARGET \
  --source auths:directory:auths \
  --source shared_config:file:shared-config.yaml \
  --source usage:sqlite:usage.sqlite --yes
# 备机，Linux 本地；备机路径可与主机不同
bash start.sh --role backup --deployment native --data-dir TARGET \
  --source auths:directory:auths --yes
# 已有部署直接重跑；不重新选择或覆盖页面设置
bash start.sh
# 独立配置目录：首次添加 --output DIR，之后也要指定
bash start.sh --output DIR
```

`--yes` 确认缺失依赖安装及卸载/清除，不代替角色、目录、部署方式参数，也不跳过路径/权限/健康检查。`--no-install-deps` 只检查、不安装；二者互斥。终端向导仍负责缺少的选择。冲突的角色、数据、方式或端口参数报错，不悄悄覆盖原配置。选择有历史恢复点的节点身份仍受原有角色保护约束。

可选 `--port 8787`、`--ssh-port 2222`、`--read-only-data`；本地还支持 `--install-root DIR`、`--state-dir DIR`、`--bind-host HOST`。默认监听 loopback。新安装记录写入配置目录的 `.env.docker.json` 或 `.env.native.json`，权限 `0600`；不要删除或交换记录和目录所有权标记。安装失败保留配置、密钥与状态，重跑可继续未完成的引导配置；成功部署重跑保留节点 ID、页面变更和定时开关。

`--output DIR` 在 Docker 中保存 `.env` 和 `state-native`；在本地模式中保存 Nginx/SSH 配置和单元模板，默认 `/etc/cpa-dr-native`。本地服务/状态/配置目录使用无空格和特殊字符的绝对路径。检测到默认本地和 Docker 两份部署时，须明确指定 `--deployment` 或 `--output`。

### 依赖与权限

选择部署方式后才列出缺失项并询问「是否安装并继续启动？[y/N]」。确认后从现有 `apt-get`、`dnf` 或 `yum` 软件源安装并复检；不添加软件源、不下载执行远程安装器。root 直接安装，普通用户的软件包操作通过 sudo；**本地服务安装/卸载也通过 sudo**。

- Docker 宿主需要 Bash、coreutils、OpenSSH 客户端、OpenSSL、util-linux 和 jq，以及 Engine 与支持 `up --wait --wait-timeout` 的 Compose v2。依赖齐全不操作软件包；Docker daemon 和访问权限仍须就绪，不自动调整 Docker 服务或用户组。
- Compose 软件包兼容 `docker-compose-v2`、`docker-compose-plugin` 或 v2 的 `docker-compose`，不选 v1；`docker.io` 元数据声明独立 `docker-cli` 时同时安装 CLI。
- Linux 本地只检查/安装原生服务命令，不要求 Docker；需要运行中的 systemd、Nginx、fcgiwrap、spawn-fcgi、OpenSSH、rsync、sqlite3、jq 等。服务模板及 `www-data` 组以 Debian/Ubuntu 为基准，其他发行版的包可从现有源安装，但具体路径、组和实际 systemd 启动须核对。
- 非交互缺少依赖必须显式 `--yes` 才安装；拒绝、索引/安装/复检或 sudo 失败均返回非零。卸载只检查必要依赖，从不安装软件包。

### Docker 配置与访问

Docker 构建/启动后等待管理健康（最多120秒），通过容器内原有 CLI 应用引导配置，再显示实际管理地址、管理员令牌和 SSH 公钥；健康只证明管理服务存活。Docker 环境下选择的宿主路径自动转换为容器 `/data` 路径，不需要安装后重新输入。容器创建的 `0600` 配置由容器内读取；普通用户不必修改文件所有权。已卸载服务的显式参数核对使用不启动调度、不发布端口的只读 CLI 临时容器。

已有 `.env` 是数据文件，脚本不执行其中 Shell 代码，并忽略外部同名令牌、挂载和端口变量。可明确编辑 `.env` 的监听地址、端口或读写模式后重跑；数据/状态根与安装记录须一致，不静默换挂载。自定义配置目录的新部署使用独立 Compose 项目名；已有安装保留项目名，重跑与卸载不受外部同名变量静默改写。

`.env`、管理员令牌和私钥初始化权限 `0600`，登录输出含秘密，不要上传。若只初始化、不启动，仍支持 `bash scripts/setup.sh --data-dir TARGET`，再手动使用 Compose；该低层命令不运行角色/数据向导。

打开 `http://127.0.0.1:8787` 登录。远程管理使用既有 SSH 转发：

```bash
ssh -N -L 8787:127.0.0.1:8787 HOST
```

| `.env` 配置 | 默认值 | 用途 |
|---|---|---|
| `CPA_DATA_PATH` | 初始化时指定 | 宿主数据父目录 → 容器 `/data` |
| `STATE_PATH` | `state-native` 的绝对路径 | 状态、密钥、历史及回滚 → `/state` |
| `PORT` / `BIND_HOST` | `8787` / `127.0.0.1` | 中文管理页面 |
| `SSH_PORT` / `SSH_BIND_HOST` | `2222` / `127.0.0.1` | 专用备份 SSH → 容器 `22` |
| `DATA_ACCESS` | `rw` | 支持确认后的恢复；普通备份不改工作目录 |

跨机配对将 `SSH_BIND_HOST` 改为本机内网 IP，仅允许对端来源，重跑入口应用；不要把备份 SSH 配成 CPA 业务入口。管理页面保持 loopback 或使用既有 HTTPS 代理。只备份不恢复可首次加 `--read-only-data`；Docker 恢复前明确改 `.env` 的 `DATA_ACCESS=rw` 并重建容器。

### 卸载与彻底清除

两种部署通用，按配置目录的安装记录识别，不要求再次输入角色或数据：

```bash
# 交互确认；移除容器/本服务systemd单元，保留代码、配置、密钥和备份
bash start.sh uninstall
# 输入 PURGE 后，额外清除本服务备份、回滚、密钥及本地安装文件
bash start.sh uninstall --purge
# 独立配置目录，非交互明确确认
bash start.sh uninstall --output DIR --yes
bash start.sh uninstall --output DIR --purge --yes
# 参数形式也支持
bash start.sh --uninstall --deployment native
```

| 操作 | Docker | Linux 本地 |
|---|---|---|
| `uninstall` | 停止并移除本项目容器/网络；保留 `.env`、状态 | 停止写者、禁用并删除本服务单元；保留代码、配置、状态 |
| `--purge` | 额外删除专用状态、`.env` 和安装记录 | 额外删除专用代码、状态、运行目录及本服务配置/记录 |
| 始终保留 | 原始 CPA 数据、源码、未知配置、镜像/共用依赖和无关项目 | 原始 CPA 数据、源码、未知配置、共用软件包和其他服务 |

普通卸载后直接重跑即可重启，保留原身份与页面配置；清除后的新安装生成新身份，需重新配对。清理检查规范路径、符号链接、目录所有权及单元摘要；发现异常或服务停止失败时，不继续删除。Docker 的普通卸载不需额外提权，`--purge` 清除容器 root 创建的私有目录时需要 root/sudo，并在停止服务前检查权限。不要先手动删除安装记录。清除不会全局 prune 或卸载共享的软件包。

Linux 本地单元每次启动从持久状态恢复 `/run/cpa-dr-native` 的安装标记，避免系统重启清空运行目录后阻断重跑或卸载；配置、密钥与备份仍保存在持久目录中。

### 容器与数据权限

- 在页面填写**容器内路径**，例如 `/data/auths`，不是宿主机原路径。
- 建议挂载 CPA 数据父目录，避免单文件 bind mount；恢复保留目标目录与既有文件 inode、本机所有权。
- 恢复目标的普通文件不得含硬链接（包括 SQLite），避免原位写入连带改写其他路径；预览和实写均检查。来源备份可读取硬链接，但快照保存为独立文件。
- 镜像默认 root，以读取和恢复已有敏感数据。容器根文件系统只读，不挂载宿主 Docker socket，不使用特权模式。
- 移除默认 capabilities，仅恢复文件操作及 Nginx/SSH 原生进程所需的 `CHOWN`、`DAC_OVERRIDE`、`FOWNER`、`SETUID`、`SETGID`、`SYS_CHROOT`、`NET_BIND_SERVICE`。SSH 禁止密码、PTY、转发，所有命令强制进入备份 RPC；仍需只向可信管理员开放。
- 状态目录及 `.env` 含密钥，不要纳入备份内容。备份数据目录的普通文件名不支持控制字符或反斜线；部署路径不支持引号、美元符、冒号等容易产生配置歧义的字符。

## 2. 双端 SSH 配对并启动备份

### 设置角色和数据标签

1. 核对安装向导保存的角色：主端「主服务器」，备端「备服务器」。低层手动部署则在页面选择。先保持「启用定时任务」关闭。
2. 核对安装时保存的数据**标签**、类型和本机路径；两端标签/类型一致，路径可以不同。需要调整时在页面修改。
3. 两端分别点击「显示本机 SSH 公钥」，将公钥复制到对端「导入对端 SSH 公钥」并确认导入。私钥保留本机，页面只配置私钥路径。
4. 填对端 SSH 地址、端口、用户。Docker 跨机默认填写对端宿主地址及 `2222`；同一容器网络的测试环境可填容器名及 `22`。
5. Docker 本机私钥路径为 `/state/ssh/id_ed25519`，known_hosts 路径为 `/state/ssh/known_hosts`；直接宿主机运行则填写实际状态目录里的路径。

数据配置示例（只配置实际存在且可共享的数据）：

| 标签 | Docker 本机路径 | 类型 |
|---|---|---|
| `auths` | `/data/auths` | 目录 |
| `shared_config` | `/data/shared-config.yaml` | 普通文件 |
| `usage` | `/data/usage.sqlite` | SQLite 一致性备份 |

不要把主机整份机器配置直接恢复到备机：监听、代理、Tunnel 凭据等通常是节点差异。

### 登记并核对对端 SSH 主机指纹

传输严格使用 `StrictHostKeyChecking=yes`，不会自动接受未知主机。**SSH 公钥交换与 SSH 服务器指纹是两件事**，都需要完成。

先从可信的对端控制台取得主机指纹：

```bash
# 在对端服务器执行，核对其持久化 SSH hostkey 指纹。
docker compose exec cpa-dr ssh-keygen -lf /state/ssh/ssh_host_ed25519_key.pub
```

再在本机采集对端 hostkey；`HOST`、`PORT` 替换为页面配置的对端地址和端口：

```bash
ssh-keyscan -t ed25519 -p PORT HOST > /tmp/cpa-dr-hostscan
ssh-keygen -lf /tmp/cpa-dr-hostscan
```

**与可信对端显示的指纹一致后**，再在本机部署目录登记：

```bash
cat /tmp/cpa-dr-hostscan >> state-native/ssh/known_hosts
chmod 600 state-native/ssh/known_hosts
rm -f /tmp/cpa-dr-hostscan
```

若使用了自定义 `--output`/`STATE_PATH`，修改实际状态目录里的 `ssh/known_hosts`。hostkey 在状态目录持久化，重新创建容器不会主动换钥；指纹意外变化时停止传输并核对原因，不关闭主机校验。

### 启用和验证

两端完成上述步骤后：

1. 点击「保存并测试配对」，检查对端节点 ID 与角色。
2. 点击「保存、配对并启动」；主端可点击「立即备份」。
3. 等待作业最终完成，在备端「备份历史」确认同一有效恢复点。只看到任务已提交或主端本地快照，不代表备端已成功收到。

建议初始同步间隔 `60` 秒、二次备份 `3600` 秒、每类保留 `120` 份；按数据量调整。页面变更周期不需要重建镜像。取消普通「启用定时任务」保留角色，仅暂停定时；高级「暂停并进入保护态」需要额外 `RESUME` 确认。

配置和恢复与正在运行的备份共用锁，控制请求优先于后续定时任务。若显示「另一个任务正在运行」（HTTP 409），等待作业最终完成后重试；已发布的快照不等于作业已结束。不要把周期设得比实际采集/传输耗时更短。

主节点时钟应保持同步；同代次迟到的旧副本拒绝覆盖新副本。主时钟回拨或旧秒精度同秒无法判断顺序时会保护性拒收，应核对时钟和日志，不关闭防回退校验。

## 3. Linux 宿主机直接部署 / systemd

通常在 `start.sh` 向导选择 `1`，或使用 `--deployment native`，自动完成依赖、角色/数据配置和安装。下面保留低层手动安装及 dry-run；手动方式不运行交互向导。

Debian/Ubuntu 安装原生软件包：

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends bash coreutils findutils grep sed gawk jq tar rsync openssh-client openssh-server util-linux sqlite3 curl nginx fcgiwrap spawn-fcgi openssl
```

其他发行版安装同名功能包；安装脚本的 Nginx、FastCGI、SSH 路径及 `www-data` 组以 Debian/Ubuntu 为基准，其他系统须核对。可先只生成配置检查，不启动或安装服务：

```bash
cd cpa-dr
bash scripts/install-systemd.sh --dry-run --data-dir TARGET --output /tmp/cpa-dr-units
```

确认后安装：

```bash
sudo bash scripts/install-systemd.sh --data-dir TARGET
sudo systemctl status cpa-dr-native-tick.timer cpa-dr-native-web.service cpa-dr-native-ssh.service
```

- 使用独立的 `/opt/cpa-dr-native`、`/var/lib/cpa-dr-native` 和 `cpa-dr-native-*` 单元；已有安装目录、状态目录或同名单元不覆盖。
- `tick.timer` 每秒唤醒一个短检查，实际备份/二次备份按页面配置的间隔执行，共用 `flock` 避免重复写者。
- `fcgi.service` 提供 Shell CGI，`web.service` 运行独立 Nginx 配置，`ssh.service` 运行专用受限 SSH 服务；不修改原有 SSH 配置/监听端口。
- 默认只绑定 `127.0.0.1` 的 `8787` 和 `2222`；跨机使用 `--bind-host HOST` 指定本机内网 IP并限制防火墙。专用 SSH 默认使用 root 公钥登录，需要宿主账户可用；不替用户修改账户密码策略。
- 宿主配对登记的是 `/var/lib/cpa-dr-native/ssh/known_hosts`；公钥交换仍从页面完成。可在对端控制台运行 `ssh-keygen -lf /var/lib/cpa-dr-native/ssh/ssh_host_ed25519_key.pub` 核对指纹。

无页面的 CLI 也可以操作：

```bash
# TARGET 为数据父目录，示例状态目录是新建的独立目录。
bin/cpa-dr --state-dir ./state-native init --allowed-root TARGET
bin/cpa-dr --state-dir ./state-native config get
bin/cpa-dr --state-dir ./state-native status
```

角色、内容与周期保存为 JSON，使用 `bin/cpa-dr --state-dir DIR config set CONFIG_JSON_FILE`；不要 `source` 配置文件。

## 4. 故障接管、回灌和历史恢复

### 主机掉线：在备端确认接管

1. 确认旧主已经停止或隔离，包括自动重启、后台刷新与直连流量。网络不可达不代表它已经停止写入。
2. 停止备 CPA 的全部写入，在备端核对最新有效主副本与本机恢复目标。
3. 「备机确认接管」选择快照、查看预览、勾选停机/隔离确认，输入 `PROMOTE`。
4. 等待完成，按启停驱动启动/核对备 CPA，实际请求验证后开放业务入口。备端成为权威来源，拒绝迟到的旧主副本。

### 主机恢复：先备→主回灌，再回切

1. 保持主 CPA 和入口隔离，避免现有 Cloudflare 规则看到旧主上线就回主。
2. 主端点击「主机准备恢复」，确认主已停写，输入 `RECOVER`。
3. 排空备端请求和长连接，停止全部后台/业务写入，安排最终交接窗口。
4. 主端点击「主机执行回灌」，确认两端停写，输入 `FAILBACK`。服务请求备端生成最终副本、下载校验、回灌主端，并同步新主基线到备端后提交角色交接。
5. 等待最终完成，验证实际 CPA 新增/修改/删除及上游凭据，再开放主入口，恢复主→备备份；备 CPA 保持停止。

### 启停驱动与失败处理

默认人工启停：勾选停机不是自动停机证据，必须真实停止 CPA。可在宿主机配置 `systemd` 或 `docker` 驱动及指定服务/容器名；默认备份容器没有宿主 systemd、Docker CLI/socket 权限，不默认提供高宿主权限。

历史恢复先「校验」和「预览」，停写后输入 `RESTORE`；覆盖前保存回滚副本，失败补偿。SQLite 目标需停止应用并清理/确认残留 WAL/SHM。OAuth 历史凭据可能失效；主机已启动并刷新凭据后不要盲目重灌旧快照。交接失败保持保护态，不通过通用恢复调度掩盖故障。

**普通历史恢复完成后保持 CPA 停止，不自动启动。** 管理员核验数据和唯一权威角色后再启动；待机备节点恢复历史不等于接管，应继续待机。只有确认式接管/回灌流程才按启停驱动启动权威 CPA。

独立历史恢复失败或中断后继续保持保护态。修正目标问题、校验有效快照后，重新通过「预览 / 恢复」勾选停写并输入 `RESTORE`，可确认重试；成功才恢复原调度角色，CPA仍保持停止。普通 `RESUME` 不解除失败保护，接管/回灌失败必须继续其对应流程；没有可信恢复上下文的旧失败状态不推断角色。

## 5. 从旧版本迁移

本版**替换了运行后端与传输协议**：HTTP 对端令牌改为 SSH 公钥与 hostkey 校验。旧版状态格式不直接混用，默认新建 `state-native`；重新选择角色、配置标签/路径、交换公钥并验证第一份备份。

保留旧快照与状态目录用于核对，不自动删除或转换；先停止旧定时器/备份服务，避免两套服务同时接管或恢复同一数据。真实 CPA 和入口不因本项目代码改造而自动改动。

## 6. 验证与边界

```bash
bash tests/start.sh
bash tests/dependencies.sh
bash tests/core.sh
bash tests/service.sh
bash tests/api.sh
bash tests/deployment.sh
shellcheck scripts/*.sh bin/* lib/*.sh cgi/*
# Node 仅用于可选的页面开发测试，不用于服务运行。
node --test tests/browser/ui.test.cjs
# 独立临时容器与回环端口；测试结束自动清理。
docker build -t cpa-dr:native-verify .
bash tests/runtime_pair.sh
bash tests/compose_smoke.sh
# 原生安装器/进程的隔离容器验证；systemctl 使用模拟器，不操作宿主机
bash tests/native_installer.sh
# 可选：root + setpriv + Docker；只改变测试进程UID，不改账户/宿主配置
bash tests/docker_user.sh
# 可选真实浏览器测试，需要预先安装 @playwright/test 和 Chromium。
# NODE_PATH 指向开发测试依赖的 node_modules，不是运行时依赖。
CPA_BROWSER=1 bash tests/runtime_pair.sh
```

双节点、容器及浏览器的整合结果见 [验收记录](docs/verification.md)，组件与约束见 [架构](docs/architecture.md)。

文件在线备份是经过检查的尽力一致副本，不承诺跨文件事务快照或零数据损失；SQLite 使用原生一致性备份。二次副本与工作数据在同一磁盘时不构成独立故障域；持久性依赖底层文件系统兑现 `sync`。正式双机的实际 CPA、OAuth、SSE、入口隔离及服务驱动仍需在部署环境演练。
