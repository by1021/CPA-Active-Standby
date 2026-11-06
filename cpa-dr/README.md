# CPA DR · Linux 原生主备容灾备份

使用 **Bash + Linux 原生命令**实现，不运行 Python 后端。中文管理页面保留，由 **Nginx + fcgiwrap + Shell CGI**提供；数据传输使用 **OpenSSH 受限 RPC**，文件同步/恢复由 `rsync`、`tar`、`sha256sum` 执行，SQLite 使用 `sqlite3 .backup`。

| 能力 | 当前实现 |
|---|---|
| 主／备角色、备份内容与周期 | 页面配置，JSON 持久化；配置不作为 Shell 代码执行 |
| 主→备自动备份 | 定时采集、SHA256 校验、SSH 传输、完整验证后发布 |
| 备机二次备份 | 按独立周期保存已收到的有效副本，分类保留历史 |
| 历史恢复 | 校验、目标预览、明确确认、覆盖前回滚、反映新增／修改／删除 |
| 故障接管与反向回灌 | 管理员确认停写/旧主隔离后执行，失败保持保护态 |
| 部署 | Docker Compose，或宿主 Linux 的 systemd timer + 原生服务 |

**自动执行的是备份；接管、恢复、回切仍需管理员确认。不会修改现有 CPA、Cloudflare Worker、域名或 Tunnel。管理接口 `/healthz` 只说明管理服务存活，不代表 CPA 已准备好接收业务流量。** 快照是明文数据，建议磁盘加密、受限权限及独立离机备份。

## 1. Docker 部署（主、备两台分别执行）

宿主机需要 Docker、Compose，以及用于初始化/检查的 Bash、coreutils、OpenSSH 客户端、OpenSSL、util-linux（`flock`）和 jq。其他原生命令打包进镜像；不是假定所有 Linux 系统已经预装这些工具。

`TARGET` 替换为已存在的 CPA **数据父目录**。它必须与服务源码、部署目录和状态目录独立。

```bash
cd cpa-dr
bash start.sh --data-dir TARGET
```

`start.sh` 检查宿主依赖与 Docker daemon，复用初始化工具生成配置，构建/启动并等待管理服务健康（最多120秒），成功后显示实际管理地址、管理员令牌和本机 SSH 公钥。脚本可从任意工作目录调用；**不自动安装 Docker/系统软件、不修改现有 CPA，也不自动启用备份**。

首次也可以直接执行 `bash start.sh`，按提示输入数据父目录；非交互运行必须提供 `--data-dir`。已有 `.env` 时直接重跑即可，保留配置、令牌、SSH 密钥和状态：

```bash
bash start.sh
# 首次自定义端口和只读挂载（不是在已有配置上静默覆盖）
bash start.sh --data-dir TARGET --port 8787 --ssh-port 2222 --read-only-data
```

重复传入相同初始化参数可以重跑；与已有 `.env` 冲突的参数会报错。修改端口、监听地址或读写模式，应明确编辑 `.env` 后重跑。可用 `--output DIR` 将配置/状态保存在独立部署目录；后续也要带上相同 `--output DIR`，镜像仍从脚本旁源码构建。脚本不执行 `.env` 中的 Shell 代码，并忽略外部同名令牌、挂载和端口环境变量，以文件配置为准。

`.env`、私钥、管理员令牌初始化权限为 `0600`；状态默认使用新目录 `state-native/`。启动失败返回非零，保留配置和数据并提示查看日志；缺失挂载目录时拒绝自动创建空目录。登录信息包含秘密，不要上传终端输出。若只需初始化、不启动容器，仍可使用 `bash scripts/setup.sh --data-dir TARGET`，再手动执行 `docker compose up -d --build`。

Compose v2 须支持 `docker compose up --wait --wait-timeout`；旧插件需先升级。健康通过仅表示管理服务存活，角色设置、双端配对和真实 CPA 业务验证仍按下文执行。

打开 `http://127.0.0.1:8787`，使用初始化显示的管理员令牌登录。远程管理使用既有 SSH 本地转发：

```bash
ssh -N -L 8787:127.0.0.1:8787 HOST
```

在浏览器打开本机同一地址。管理端口与本服务 SSH 端口默认均只发布到 loopback：

| `.env` 配置 | 默认值 | 用途 |
|---|---|---|
| `CPA_DATA_PATH` | 初始化时指定 | 宿主数据父目录 → 容器 `/data` |
| `STATE_PATH` | `state-native` 的绝对路径 | 状态、密钥、历史及回滚 → 容器 `/state` |
| `PORT` / `BIND_HOST` | `8787` / `127.0.0.1` | 中文管理页面 |
| `SSH_PORT` / `SSH_BIND_HOST` | `2222` / `127.0.0.1` | 专用 SSH 备份传输，映射容器 `22` |
| `DATA_ACCESS` | `rw` | 支持确认后的恢复；普通备份不改工作目录 |

跨服务器配对时，将 `SSH_BIND_HOST` 改为本机内网 IP，来源防火墙只允许对端连接，执行 `docker compose up -d` 重新应用；不要把备份 SSH 地址配置成 CPA 业务入口。管理页面继续保持 loopback，或由既有 HTTPS 代理提供管理访问。

只备份不恢复可初始化时加 `--read-only-data`；恢复前将 `.env` 的 `DATA_ACCESS` 改为 `rw` 并重新创建容器。

### 容器与数据权限

- 在页面填写**容器内路径**，例如 `/data/auths`，不是宿主机原路径。
- 建议挂载 CPA 数据父目录，避免单文件 bind mount；恢复保留目标目录与既有文件 inode、本机所有权。
- 恢复目标的普通文件不得含硬链接（包括 SQLite），避免原位写入连带改写其他路径；预览和实写均检查。来源备份可读取硬链接，但快照保存为独立文件。
- 镜像默认 root，以读取和恢复已有敏感数据。容器根文件系统只读，不挂载宿主 Docker socket，不使用特权模式。
- 移除默认 capabilities，仅恢复文件操作及 Nginx/SSH 原生进程所需的 `CHOWN`、`DAC_OVERRIDE`、`FOWNER`、`SETUID`、`SETGID`、`SYS_CHROOT`、`NET_BIND_SERVICE`。SSH 禁止密码、PTY、转发，所有命令强制进入备份 RPC；仍需只向可信管理员开放。
- 状态目录及 `.env` 含密钥，不要纳入备份内容。备份数据目录的普通文件名不支持控制字符或反斜线；部署路径不支持引号、美元符、冒号等容易产生配置歧义的字符。

## 2. 双端 SSH 配对并启动备份

### 设置角色和数据标签

1. 主端选择「主服务器」，备端选择「备服务器」。先保持「启用定时任务」关闭。
2. 两端添加相同数据**标签**与类型，各自填写本机路径；路径可以不同。
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
# 可选真实浏览器测试，需要预先安装 @playwright/test 和 Chromium。
# NODE_PATH 指向开发测试依赖的 node_modules，不是运行时依赖。
CPA_BROWSER=1 bash tests/runtime_pair.sh
```

双节点、容器及浏览器的整合结果见 [验收记录](docs/verification.md)，组件与约束见 [架构](docs/architecture.md)。

文件在线备份是经过检查的尽力一致副本，不承诺跨文件事务快照或零数据损失；SQLite 使用原生一致性备份。二次副本与工作数据在同一磁盘时不构成独立故障域；持久性依赖底层文件系统兑现 `sync`。正式双机的实际 CPA、OAuth、SSE、入口隔离及服务驱动仍需在部署环境演练。
