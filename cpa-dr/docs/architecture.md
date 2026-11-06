# Linux 原生命令架构

## 组件

| 层 | 原生命令／文件 | 责任 |
|---|---|---|
| 管理页面 | `www/`、nginx | 中文配置、状态、历史和危险动作确认 |
| API入口 | `cgi/api.cgi`、fcgiwrap | 管理员Bearer认证、限长JSON、固定路由 |
| 任务／角色 | `bin/cpa-dr`、`lib/service.sh`、flock、jq | 跨进程互斥、持久角色、作业结果、调度 |
| 数据核心 | `lib/common.sh`、`lib/snapshots.sh` | 配置边界、SHA校验、回滚和补偿 |
| 快照／恢复 | tar、sha256sum、rsync、sqlite3 | 文件/目录/SQLite备份、确认后原位恢复 |
| 跨机 | ssh、`bin/cpa-dr-rpc` | 固定RPC白名单、严格known_hosts、归档流 |
| 部署 | `scripts/`、`Dockerfile`、`compose.yaml` | 原生依赖、systemd timer和可选Web服务 |

Cloudflare不参与备份协议，CPA业务端口不充当备份管理接口。运行后端没有Python/Node服务；JavaScript只运行在浏览器，可选页面测试使用Node。

Nginx显式生成固定FastCGI参数，保留外部Host端口，Host/Origin/Authorization各传一次，不依赖发行版默认参数对Host的改写。CGI对浏览器管理请求继续严格核对Origin，不开放跨域管理。

## 数据与互斥

配置是JSON，由jq读取和验证，不作为Shell代码执行。稳定数据标签连接两端各自路径；原始归档路径仅审计。状态与历史库独立于允许的数据父目录，秘密只保存在本机受限文件中。

快照包含来源身份、主/备固定角色、代次、用途、纳秒UTC时间、文件大小/SHA和空目录；历史排序兼容旧秒精度。暂存校验后发布；高频状态写用GNU `sync FILE`同步指定文件及父目录，完整数据树用一次`sync -f`确保子文件落盘，避免每次状态写都刷新整个文件系统。校验失败不覆盖有效恢复点。恢复采用本机标签目标、原位rsync和覆盖前回滚，保留既有挂载inode及本机所有权。普通在线文件不承诺跨文件事务；SQLite由sqlite3 `.backup`生成一致副本。

所有CGI、CLI、调度与SSH写操作共用operation.lock（flock）；control.lock让等待中的控制请求优先于后续tick。管理操作超时返回HTTP 409，表示未接纳、没有创建新任务，等当前写者完成后可重试。长任务有独立ID及持久结果，不因页面断开消失；快照可见不代表作业已经全部完成。保护态不通过普通重启解除。底层sync/文件系统/设备兑现持久性，未承诺多个数据目标的掉电原子事务。

## SSH与角色交接

SSH固定私钥、BatchMode和StrictHostKeyChecking；管理员事先通过其他渠道核对hostkey，再写known_hosts。对端authorized_keys使用restrict + 强制RPC，仅允许状态、备份收发和受控交接，不开放任意命令或端口转发。RPC参数白名单解析，不使用eval。

同代次副本按有效UTC创建时间比较，只接受明确更新的版本；旧秒精度同秒不同ID顺序不明时拒绝，不按随机ID猜顺序。重复当前同ID仍须验证；已提交交接重复确认只返回原确认，不回退最新副本。历史恢复保持CPA停机，待机节点不因RESTORE成为第二写者；回灌启动失败记录尝试与成功两种状态，重试保留已恢复数据，但必须成功启动后才能提交交接。

来源硬链接采集为独立快照文件；恢复目标树中的普通文件必须链接计数为1。整批预览、每项实际写入及失败补偿均复查，防止`rsync --inplace`改写其他路径的同inode文件。

独立历史恢复在作业接纳时原子保存角色/阶段/代次上下文并进入保护态；失败或中断只允许明确确认的同流程`RESTORE`重试，禁止通用`RESUME`和跨接管/回灌流程覆盖。恢复成功的调度阶段与作业完成原子发布，CPA不自动启动；已提交交接历史不当作进行中交接，旧无可信上下文失败状态不推断权威角色。

对端写请求允许等待本机锁60秒；管理操作等待5秒，tick不等待。超过等待/传输上限会保留有效快照并报错，不以并发覆盖换取吞吐。

主正常：primary_active采集，backup_standby接收并做二次副本。备接管：管理员确认旧主隔离/备CPA停写，恢复主有效副本后backup_active，拒绝旧主上传。主恢复：先primary_recovering禁主→备，备停写生成最终副本、主回灌，再同步新的主来源基线并提交交接，之后备待命。失败保留保护态，不盲目启动旧OAuth凭据。

这里是明确确认的单写角色，不是自动网络分区仲裁。二次快照仍在本机故障域；静态加密与离机备份由部署方安排。

## 部署与源码依据

宿主机由systemd timer触发tick，配置秒级周期由tick动态判断。Docker内用原生进程和Shell循环调用相同逻辑；默认不挂宿主Docker socket。Web权限、允许数据根、SSH公钥/hostkey文件由部署配置限制。

当前协议依据交付源码：[配置](../lib/common.sh)、[快照](../lib/snapshots.sh)、[服务](../lib/service.sh)、[CLI](../bin/cpa-dr)、[CGI](../cgi/api.cgi)、[Compose](../compose.yaml)。真实systemd安装、CPA启停/UID、OAuth、长连接及入口隔离须在部署环境验收。
