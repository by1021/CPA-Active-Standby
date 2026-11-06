# Linux 原生命令验收记录

2026-11-06；本轮重新验证原生命令实现，旧Python实现的测试数量不作为新版证据。以下检查均实跑通过（退出码0），表中给出可复验入口；模块检查也通过`athena run -- bash -c '…'`组合运行。未启用`.ai_state`，`athena run`提示未记录sprint证据；本记录不是正式Athena门禁放行，也不是线上部署报告。

## 验收结果

最终普通独立源码复审绑定 `b4c1a8d82d006e8b4c81341fe300e60ee15a5f01`，原样结论见[最终审查](review-native.md)：`VERDICT: PASS`。前三轮共7项发现已关闭；reviewer独立复跑完整服务回归与定向静态检查通过。该结论不代表正式Athena门禁或线上环境验收。

| 范围 | 命令（在`cpa-dr/`运行） | 已验证 |
|---|---|---|
| 数据核心 | `athena run -- bash tests/core.sh` | 13类回归：空目录、inode/本机owner、增改删与回滚、初始缺失目标、身份与幂等导入、恶意/损坏归档、链接、失败补偿、持久写入失败、有效历史保留、SQLite/引号路径/WAL、弱秘密、纳秒排序兼容旧秒时间；目录/file/SQLite目标硬链接整批预检、写前及补偿复查，来源硬链接仍可备份 |
| CLI/调度/交接 | `athena run -- bash tests/service.sh` | 配置/持久作业、确认与受限RPC；失败恢复/中断作业保护；控制请求优先；对端等候6秒持锁；普通副本与交接基线防乱序、同秒不明/无效日历拒绝；commit幂等；启动失败/二次停机/ACK丢失重试保留刷新数据并重新确认启动、同步新基线；三角色确认式历史恢复重试、重启/中断/再次失败、完成发布崩溃窗口、跨流程阻断，历史恢复只停机 |
| CGI | `athena run -- bash tests/api.sh` | Bearer认证、JSON、来源/长度/ID约束、公钥导入；相对CLI路径；忙锁HTTP 409 |
| 部署工具 | `athena run -- bash tests/deployment.sh` | 密钥权限、已有配置不覆盖、数据/状态隔离、systemd dry-run参数和单元、固定FastCGI字段无重复 |
| 页面单测 | `athena run -- node --test tests/browser/ui.test.cjs` | 5项：表单/序列化、确认、秘密不存浏览器持久存储、作业最终结果 |
| 静态检查 | `athena run -- shellcheck --severity=warning -x lib/*.sh bin/* cgi/* scripts/*.sh tests/*.sh` | Bash语法、ShellCheck warning级、`git diff --check`通过；Markdown相对链接检查通过 |
| 镜像 | `athena run -- docker build -t cpa-dr:native-verify .` | 原生镜像构建成功；双机测试检查没有Python命令或项目`.py`源码 |
| 真正Compose部署 | `athena run -- bash tests/compose_smoke.sh` | 文档中的setup + 加固Compose启动；真实nginx/CGI、认证、同源GET/POST、跨域403、健康检查和持久密钥 |
| 真双节点+浏览器 | 见下方命令 | 真实SSH严格hostkey配对、定时主→备、二次副本、接管/旧主拒绝、回灌新增/删除、关闭定时后立即再次接管回切、容器重启持久化；中文页面两角色、错误登录、公钥信任、配置/配对/备份、恢复预览/确认/完成、桌面/手机且无页面异常 |

浏览器开发依赖安装在独立临时目录，不打包进服务。实际执行：

```bash
athena run --env NODE_PATH=/tmp/cpa-dr-browser/node_modules \
  --env CPA_BROWSER=1 -- bash tests/runtime_pair.sh
```

复验时将`NODE_PATH`改为自己的`@playwright/test`依赖目录，并安装Chromium；不用浏览器时执行`athena run -- bash tests/runtime_pair.sh`。

真实双机测试最终输出：

```text
PASS: native CGI, restricted SSH pairing, scheduled primary transfer and secondary snapshot
PASS: no Python; uncredentialed API and arbitrary SSH commands rejected
PASS: real SSH rejects same-epoch stale replay without rolling back latest snapshot
PASS: controlled takeover, old-primary rejection, final backfill additions/deletions
PASS: consecutive takeover/failback with scheduling disabled uses fresh primary baseline
PASS: real SSH repeated handover ACK is idempotent and preserves newer received data
PASS: post-commit standby pause/resume and paused restore/resume preserve handover history
PASS: native CGI failed restore stays protected; confirmed retry repairs data and returns standby
PASS: native browser login, SSH public-key trust, role/path/interval config, pairing and backup
PASS: native CGI restore preview/confirmation/completion; both roles; mobile/desktop; no page errors
PASS: browser confirms historical restore retry from failed protected standby
PASS: config/role/SSH keys persist across container restart
```

## 闭环修复与有界清理

- 初始容器只读根文件系统下，Nginx隐式temp目录导致启动失败：全部temp目录显式放在可写`/run`，Compose与实跑复验通过。
- 2秒测试周期在快照发布但作业未结束时配置抢锁，最初错误报400：保留严格互斥、增加控制请求优先、正确返回409；只有未接纳的409在整合测试里有限重试，其他错误立即失败。对端写入等待60秒，管理等待5秒，tick不等待。
- 高频状态持久写原先每次`sync -f`刷新整个文件系统：改为指定文件/父目录`sync`；完整数据树仍一次`syncfs`，不遗漏子文件落盘。纳秒时间避免同秒随机ID决定保留顺序，兼容旧秒时间。
- 实际浏览器POST最初403：镜像发行版FastCGI默认`HTTP_HOST=$host`丢失外部端口，导致Origin不匹配。改成显式参数、`$http_host`保留端口且每字段只传一次；同源写成功，跨域仍403。
- 首轮独立审查发现4项P1，原始结论保存在[首轮审查](review-native-initial.md)：同代次旧副本回退、重复commit回退基线、启动失败重试误判成功、普通历史恢复误启动待机CPA。已分别加入时间/代次顺序校验、无状态回退的幂等ACK、重新确认启动与刷新副本、历史恢复只停机；核心/服务回归和真实SSH双机验证通过。
- 回切故障注入覆盖启动失败、已启动后基线失败、二次停机、commit ACK丢失及新副本ACK再次丢失。重试保留已刷新OAuth样本数据，重新确认停启成功，并传输当前新主副本后恢复主权威角色，不盲目覆盖已运行的数据。
- [第二轮独立审查](review-native-second.md)补出目标硬链接P1和历史恢复失败缺重试入口P2。均先用未修实现复现失败，再修复：恢复目标硬链接整批预检/写前/补偿拒绝，独立历史恢复持久上下文允许明确确认重试。恢复失败后的普通RESUME和跨交接流程仍拒绝；补测数据IO成功到作业完成之间崩溃窗口，完成与阶段恢复原子发布。核心/服务回归保留真实外部alias、历史增改删和停机断言。
- [第三轮独立审查](review-native-third.md)指出已提交交接历史误挡普通RESUME。补测待机节点交接后暂停/恢复调度、普通暂停内历史恢复/重试成功后恢复调度；只放行已提交历史，不解除未提交交接、恢复失败或双权威保护，也不删除幂等ACK所需nonce。
- 浏览器操作阶段使用3600秒周期，避免人工备份与2秒定时任务争锁；前置真实双机阶段独立验证2秒自动调度。页面确认公钥信任成功和备份HTTP 202，不把未接纳的409算作成功。
- polish：无临时生产调试入口；锁/落盘/恢复复杂步骤有注释；删除重复时间/UUID函数；缩小高频落盘范围；保持固定RPC、JSON配置，不增加任意Shell执行接口。

| polish检查 | 结论 |
|---|---|
| 临时代码 | 无生产调试入口，故障注入只在测试中 |
| 注释 | 互斥、持久完成、权威交接和硬链接复查有边界说明 |
| 重复 | 时间/UUID与恢复上下文判断复用现有函数 |
| 低效 | 高频状态仅同步指定文件；完整数据树仍持久刷新 |
| 范围 | 固定RPC/CGI，无任意命令接口；不引入自动网络分区仲裁 |

## 部署环境边界

测试只使用临时数据、独立Docker网络和回环随机端口，结束自动清理。没有执行宿主机systemd安装、真实CPA/Cloudflare变更或线上数据恢复；systemd检查为安装脚本dry-run，不宣称宿主单元已经启动。

真实CPA版本、UID/挂载、OAuth刷新、SSE排空、启停驱动和入口隔离仍待部署环境演练。文件在线备份不承诺跨文件事务、零丢失或网络分区自动仲裁；接管、恢复与回切需要管理员确认。旧状态和历史不自动转换/删除。
