# Linux 原生命令验收记录

2026-11-06；本轮重新验证原生命令实现，旧Python实现的测试数量不作为新版证据。以下检查均实跑通过（退出码0），表中给出可复验入口；模块检查也通过`athena run -- bash -c '…'`组合运行。未启用`.ai_state`，`athena run`提示未记录sprint证据；本记录不是正式Athena门禁放行，也不是线上部署报告。

## 验收结果

最终普通独立源码复审绑定 `b4c1a8d82d006e8b4c81341fe300e60ee15a5f01`，原样结论见[最终审查](reviews/review-native.md)：`VERDICT: PASS`。前三轮共7项发现已关闭；reviewer独立复跑完整服务回归与定向静态检查通过。该结论不代表正式Athena门禁或线上环境验收。

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
- 首轮独立审查发现4项P1，原始结论保存在[首轮审查](reviews/review-native-initial.md)：同代次旧副本回退、重复commit回退基线、启动失败重试误判成功、普通历史恢复误启动待机CPA。已分别加入时间/代次顺序校验、无状态回退的幂等ACK、重新确认启动与刷新副本、历史恢复只停机；核心/服务回归和真实SSH双机验证通过。
- 回切故障注入覆盖启动失败、已启动后基线失败、二次停机、commit ACK丢失及新副本ACK再次丢失。重试保留已刷新OAuth样本数据，重新确认停启成功，并传输当前新主副本后恢复主权威角色，不盲目覆盖已运行的数据。
- [第二轮独立审查](reviews/review-native-second.md)补出目标硬链接P1和历史恢复失败缺重试入口P2。均先用未修实现复现失败，再修复：恢复目标硬链接整批预检/写前/补偿拒绝，独立历史恢复持久上下文允许明确确认重试。恢复失败后的普通RESUME和跨交接流程仍拒绝；补测数据IO成功到作业完成之间崩溃窗口，完成与阶段恢复原子发布。核心/服务回归保留真实外部alias、历史增改删和停机断言。
- [第三轮独立审查](reviews/review-native-third.md)指出已提交交接历史误挡普通RESUME。补测待机节点交接后暂停/恢复调度、普通暂停内历史恢复/重试成功后恢复调度；只放行已提交历史，不解除未提交交接、恢复失败或双权威保护，也不删除幂等ACK所需nonce。
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

## 一键安装入口（2026-11-06）

需求与验收见 [入口设计](designs/start-design.md)，本轮只新增 Docker 安装入口，不改运行后端或现有 CPA。以下命令在仓库根目录实跑通过；仍未启用 `.ai_state`，不宣称正式 Athena 门禁放行或真实服务器部署。

| 检查 | 可复验命令 | 结果 |
|---|---|---|
| 入口回归 | `athena run -- bash cpa-dr/tests/start.sh` | 帮助/参数/非交互/daemon/Compose能力；任意工作目录；0600；首次与相同参数重跑；冲突参数、缺失挂载、源码/状态嵌套拒绝；外部环境变量不覆写文件；dotenv不执行；配置/构建/健康失败保留状态且非零退出 |
| 原有部署回归 | `athena run -- bash cpa-dr/tests/deployment.sh` | 初始化权限、已有配置保护、路径隔离与systemd dry-run通过 |
| 静态检查 | `athena run -- shellcheck --severity=warning cpa-dr/start.sh cpa-dr/tests/start.sh cpa-dr/tests/compose_smoke.sh` | ShellCheck warning级、Bash语法和`git diff --check`通过 |
| 真正安装/重跑 | `athena run -- bash cpa-dr/tests/compose_smoke.sh` | Docker Engine 26.1.5、Compose 2.26.1；临时数据与独立项目一键构建/启动/健康等待，原命令重跑保留.env/令牌/私钥及node ID；真实CGI认证、同源写入、跨域403通过；结束清理测试项目 |

先红后绿：入口回归最初报`FAIL: start.sh is missing`；实现后通过。首次真实部署发现本机Compose不支持`config --environment`，改为已支持的`config --format json`并用宿主jq解析实际模型，mock与真部署复验均通过。未安装宿主软件包、未启用实际双机备份、未修改现有CPA/Cloudflare。

普通独立复审原样输出见 [入口复审](reviews/review-start.md)，源码集合摘要和审查范围由该记录说明；不是正式Athena review凭证。

## 启动时确认安装缺失依赖（2026-11-06）

现行依赖策略见 [依赖安装设计](designs/dependency-design.md)，替代初版「缺少依赖直接退出」行为；仍未初始化 `.ai_state`，下列为普通本地验证，不是正式 Athena 门禁凭证。

| 检查 | 可复验命令 | 结果 |
|---|---|---|
| 依赖安装隔离模拟 | `athena run -- bash cpa-dr/tests/dependencies.sh` | apt-get/dnf/yum 映射、缺少 jq/Docker/Compose、旧 Compose、软件源候选；Debian Compose v2 同名包/epoch、CLI 拆包及 RPM 候选、排除 v1；coreutils 去重与无 dirname 自举；终端确认/拒绝/回车；非交互未授权及禁用安装；索引、安装、复检与 sudo 错误；root 与降 UID 后的普通用户分支通过 |
| 完整入口回归 | `athena run -- bash cpa-dr/tests/start.sh` | 原有启动/重跑/路径/配置保护通过；隔离 PATH 缺少 jq 时模拟安装后完整启动成功，重跑保留配置和密钥且不再安装 |
| 原有部署回归 | `athena run -- bash cpa-dr/tests/deployment.sh` | 初始化权限、状态保护、路径隔离和 systemd dry-run 通过 |
| 静态检查 | `athena run -- shellcheck --severity=warning cpa-dr/start.sh cpa-dr/scripts/start-dependencies.sh cpa-dr/tests/dependencies.sh cpa-dr/tests/start.sh` | ShellCheck、逐文件 Bash 语法、`git diff --check` 通过 |
| 实际 Compose 启动/重跑 | `athena run -- bash cpa-dr/tests/compose_smoke.sh` | 本机 Engine 26.1.5、Compose 2.26.1；临时项目构建、健康等待、重跑状态保护与 CGI 检查通过，测试容器结束清理 |

先红后绿：新增缺少 jq 的安装回归最初报「未知参数：--yes」及「confirmed missing jq did not trigger installation」；实现后通过。独立复审指出 Debian 的 Compose 命名及 Docker CLI 拆包；追加回归复现「Debian Compose v2 package was not selected」，修正后通过。本机包管理器元数据及 `dpkg-query -S` 已核对两处拆包事实。

依赖安装、sudo 和 RPM 流程使用临时脚本模拟，不实际安装宿主软件包；真实发行版软件源、sudo 策略和缺少 Docker 时的安装结果待目标宿主验证。实际 Compose 测试只启动独立临时项目，不修改现有 CPA、Cloudflare 或备份配置。

本轮独立只读复审记录见 [依赖安装复审](reviews/review-dependencies.md)。

## 安装向导、两种部署与卸载清除（2026-11-06）

现行需求与验收见 [安装向导与卸载设计](designs/installer-workflow-design.md)。本次为安装模块功能扩展，未初始化 `.ai_state`；以下命令实际退出码0，不是正式 Athena 门禁或真实服务器部署凭证。

| 检查 | 可复验命令（仓库根目录） | 结果 |
|---|---|---|
| 向导/安装/卸载回归 | `athena run -- bash cpa-dr/tests/start.sh` | PTY 角色→多项数据→确认→方式顺序；取消无部署/软件包副作用；目录/file/SQLite映射、备机缺失目标、冲突/重叠/链接；页面修改和身份保留；引导失败重跑；卸载确认/PURGE取消、停止失败、异常记录/所有权/链接保护及原始/未知数据保留 |
| 依赖回归 | `athena run -- bash cpa-dr/tests/dependencies.sh` | 原有 apt/dnf/yum、Docker/Compose包候选和v1排除、缺失coreutils自举、确认/失败/sudo模拟通过；不实际安装宿主软件包 |
| systemd模板 | `athena run -- bash cpa-dr/tests/deployment.sh` | 原生dry-run、自定义配置目录、服务/状态交集拒绝；只读数据同时约束tick/fcgi/ssh模板 |
| 真 Docker 安装链路 | `athena run -- bash cpa-dr/tests/compose_smoke.sh` | 临时独立项目真实构建、管理健康、容器内角色/数据引导、CGI认证/同源/跨域检查、卸载→重装→清除；原始数据和身份保留 |
| 非root真Docker客户端 | `athena run -- bash cpa-dr/tests/docker_user.sh` | 用setpriv仅改变测试进程UID/GID，独立HOME，未改账户或宿主配置；root私有CPA数据、容器root创建0600配置的读/合并、角色/仅来源参数重跑、已停止服务的只读CLI检查、sudo拒绝清除前保持服务运行、普通卸载/重装及root清除通过 |
| 原生安装链路 | `athena run -- bash cpa-dr/tests/native_installer.sh` | 独立无宿主socket/无发布端口容器，真实安装器/状态CLI/Nginx/fcgiwrap/SSH/CGI及健康访问；本地向导分支不要求Docker；失败启动重试、逐单元就绪检查、普通用户sudo派发、页面/密钥持久化；模拟重启清空运行目录后执行生成单元的真实标记恢复命令，重跑及卸载后运行目录丢失的重装通过；同名单元摘要保护、旧uninstalled状态下仍停止实际单元、停止失败与卸载/重装/清除通过 |
| 后端与页面回归 | `athena run -- bash -c 'bash cpa-dr/tests/core.sh && bash cpa-dr/tests/service.sh && bash cpa-dr/tests/api.sh && node --test cpa-dr/tests/browser/ui.test.cjs'` | 数据核心、主备/交接/保护状态、CGI及5项页面单测通过；未改备份、恢复或页面实现 |
| 静态检查 | `athena run -- shellcheck --severity=warning -x cpa-dr/start.sh cpa-dr/scripts/*.sh cpa-dr/tests/*.sh` | ShellCheck warning级、逐文件`bash -n`、`git diff --check`通过 |

新增入口参数的先红后绿记录：最初入口回归退出1，报「未知参数：--role」；实现及回归后退出0。自查修正了容器root创建的私有JSON对普通客户端不可读的问题：引导JSON在容器内读取/合并，显式重跑在容器内读取当前配置；普通客户端无需chown。清除root创建的备份先检查sudo再停止服务，拒绝提权不会先卸载服务。

原生运行验证中的 **systemctl 是测试模拟器**，其余安装器、状态、Nginx、CGI、SSH与HTTP均真实运行；模板中的ReadOnlyPaths只做生成检查，未把模拟器当作真正的systemd沙箱/定时器。**真实宿主机 systemd 启动、只读挂载约束、sudo策略及实际发行版软件源仍待目标环境验证。** 没有安装/卸载宿主服务、改动现有CPA/Cloudflare或触碰真实数据。测试容器、网络和临时数据均已清理。

### 接力复审与修复

[首轮独立复审](reviews/review-installer-workflow-initial.md)发现1项P1：`/run` 在重启后清空，而原生单元未恢复目录所有权标记，导致重跑与卸载报错。新增原生回归先在未修实现上退出1，报 `runtime ownership marker not restored after simulated reboot`；修复让FastCGI/SSH的启动前命令从持久状态恢复权限0600的安装ID。补测卸载后运行目录丢失又发现 `nginx -t` 在systemd启动前需要PID父目录，重装入口仅在目录缺失且原有路径/所有权检查通过时重建。保持原有所有权和单元摘要保护。

接力复跑入口、依赖、部署、静态检查、隔离Docker/非root/native链路及核心/服务/CGI/页面回归；最终普通独立复审原样结论见[安装向导复审](reviews/review-installer-workflow.md)。原生重启检查是模拟生命周期与真实文件命令组合，不是宿主重启或真实systemd启动凭证。

## 管理菜单、只读诊断与服务管理（2026-11-06）

用户确认预览后实现，现行需求见 [安装入口需求](requirements/installer-manager.md)，验收见 [管理入口设计](designs/installer-manager-design.md)。未初始化 `.ai_state`，以下为普通本地检查，不是正式 Athena sprint/ship 门禁或真实服务器部署凭证。

| 检查 | 仓库根目录命令 | 结果 |
|---|---|---|
| 菜单与管理回归 | `athena run -- bash cpa-dr/tests/manager.sh` | 无参数PTY菜单、无效输入/返回/退出、失败刷新、未安装项、非交互分发、未知/停止/异常目标、不可遍历祖先目录、只读无配置/容器副作用、秘密隐藏、日志参数、运行任务/占用锁/符号链接拒绝、停止失败；卸载拒绝异源挂载/标签、多容器及查询失败；无容器时pending/ready/uninstalled清理通过 |
| 安装与依赖回归 | `athena run -- bash -c 'bash cpa-dr/tests/start.sh && bash cpa-dr/tests/dependencies.sh && bash cpa-dr/tests/deployment.sh'` | 新顺序、完整计划、默认与自定义目录/端口、取消无写入、原角色/来源/身份保留；缺curl/timeout包映射及原apt/dnf/yum、sudo、失败保护与systemd dry-run通过 |
| root 真Docker | `athena run -- bash cpa-dr/tests/compose_smoke.sh` | 独立临时项目安装、只读状态、停止/启动/重启及管理API/SSH就绪，卸载/重装/清除；宿主runtime可读时普通卸载及purge均保护同标签异源挂载的真实容器；身份和原始数据保留 |
| 非root真Docker | `athena run -- bash cpa-dr/tests/docker_user.sh` | 进程降UID/GID，root私有JSON/令牌通过已有容器读取；运行容器内任务锁、停止状态、启动/重启不创建辅助容器；卸载/恢复及拒绝sudo清理前保护通过 |
| 原生隔离验证 | `athena run -- bash cpa-dr/tests/native_installer.sh` | 独立无宿主socket/无发布端口容器：真实Nginx/CGI/SSH/安装器，管理/API/SSH分别验证；启停/重启、运行任务拒绝、身份保留、多部署选择、非root只读不提权和写操作sudo派发通过 |
| 业务回归 | `athena run -- bash -c 'bash cpa-dr/tests/core.sh && bash cpa-dr/tests/service.sh && bash cpa-dr/tests/api.sh && node --test cpa-dr/tests/browser/ui.test.cjs'` | 数据核心、主备保护与交接、CGI及5项页面测试通过；未改业务实现 |
| 静态检查 | `athena run -- shellcheck --severity=warning -x cpa-dr/start.sh cpa-dr/scripts/*.sh cpa-dr/tests/*.sh` | ShellCheck、逐文件bash -n及git diff --check通过 |

先红后绿：新增管理测试初次报“未知参数：status”。新增root Docker启动测试复现任务锁阻塞容器init，日志报“另一个备份/恢复/配置任务正在运行”；修复为停止完成后释放两把任务锁，再启动，防止初始化死锁及测试启动进程继承锁。原生SSH检查发现旧模拟器用相对路径启动sshd，stderr为“sshd re-exec requires execution with an absolute path”；改为真实 `/usr/sbin/sshd` 后，握手和真实CGI验证通过。

CLI依据已用本机 `docker start/stop/ps/inspect/logs --help` 与 `systemctl --help` 核对；Engine 26.1.5、Compose 2.26.1。原生 **systemctl和sudo策略仍是测试模拟器**，真实宿主systemd运行、发行版软件源/账户策略及只读沙箱约束待目标环境验证。没有安装/卸载宿主服务或修改真实CPA/Cloudflare，测试只操作独立临时项目并清理。

普通独立源码审查原样结果见 [管理入口审查](reviews/review-installer-manager.md)。

### 独立复审修复与验证记录

[初轮审查](reviews/review-installer-manager-initial.md)发现1项P1及2项P2，原样保留：

- Docker卸载曾在宿主`runtime.json`可读时跳过容器归属校验。新增红测报`accepted invalid operation: uninstall`；修复为所有UID及记录状态都核对现存容器标签与挂载，缺容器的清理仍允许。补齐Compose模拟器，保证忙碌卸载测试实际进入任务锁而非在配置检查阶段提前失败；真实隔离Compose异源挂载容器在卸载/清理失败后仍运行。
- 普通用户遇到不可遍历的祖先目录曾误报未安装。新增降UID红测报`inaccessible ancestor reported as uninstalled, expected unknown`；修复为遍历检查所有祖先，显示未知且不提权。
- 首轮静态合并命令未正确传播ShellCheck失败，旧`manager-final-static.log`含SC2034，**不是静态通过证据**。修正健康等待循环，并用`set -e`及外层`pipefail`复跑；新增测试的SC2209也已修正，最终ShellCheck、逐文件`bash -n`和`git diff --check`逐项通过。
- 非root连续生命周期复跑发现卸载任务锁忙；隔离检查进一步发现Bash子shell会关闭coprocess描述符，原释放逻辑没有发出`RELEASE`，依赖stdin EOF。新增单元红测报`guard release must send RELEASE explicitly, not subshell/EOF`；父shell直接发送又复现退出141（远端停止后的SIGPIPE）。修复为父shell复制描述符、子shell用副本显式发送，既收到释放消息也隔离SIGPIPE；两种情况都有回归。保留锁忙时拒绝中断的行为，不靠重试放行或放松任务保护。
- 真Docker的空闲scheduler每秒短暂持锁，即使备份停用也可能正确拒绝一次启停。成功链路的测试helper最多3次重试**写入前的锁拒绝**，每次验证容器ID未变、任务空闲且调度停用；归属、sudo、停止失败及SIGPIPE不重试。专门的忙碌/锁占用/符号链接负例保持单次拒绝断言；生产入口仍不自动重试或中断任务。
- [第二轮审查](reviews/review-installer-manager-second.md)补充P2：native将`is-active`/`is-failed`查询失败当作已停止。新增红测报`native query error reported as stopped, expected unknown`；改用`systemctl show --property=ActiveState --value`，查询错误/超时及未识别状态显示未知并阻止操作；启动/停止/维护显示切换中，failed单独显示异常。依据本机`/usr/share/man/man1/systemctl.1.gz`的机器可读show说明及ACTIVE状态表，非真实宿主systemd运行凭证。
- 默认探测保留已存在但不可遍历的native配置目录作为未知候选，不因隐藏记录而默认误报未安装；隔离非root默认status补测该分支。

最终普通检查日志位于本机`.runtime/`：`manager-regression-final.log`、`manager-compose-final.log`、`manager-native-final.log`、`manager-docker-user-final.log`、`manager-backend-verified.log`及`manager-static-verified.log`。它们仅是本地复验证据，不是已初始化状态库的正式门禁凭证。

## 结构整理与备机一键加入（2026-11-08）

范围及验收见[需求](requirements/structure-enrollment.md)、[设计](designs/structure-enrollment.md)和[SSH身份协议决策](designs/ssh-enrollment-decision.md)。基线`e645357`，实现与整合使用隔离worktree。无`.ai_state`，未初始化状态库；`athena run`返回“no active sprint: evidence not recorded”，以下是普通本地复验，不是正式sprint/ship门禁或真实主备部署凭证。

环境：Linux，Docker Engine 26.1.5、Compose 2.26.1、Node 22.23.3、ShellCheck 0.10.0，Playwright 1.65.0及真实Chromium。Node/Playwright只用于测试；Docker无源码E2E额外用测试端Python3选择空闲端口，生产备份后端仍为Bash/jq/OpenSSH。

| 检查 | 仓库根目录命令 | 实际结果 |
|---|---|---|
| 文档与兼容入口 | `athena run -- bash cpa-dr/tests/unit/structure.sh`；`athena run -- node cpa-dr/tests/unit/documentation.cjs` | 文档四分类、根/旧CLI、部署文件与渲染脚本兼容；本地Markdown链接有效，两份Worker代码的SHA256与原始基线完全一致 |
| 邀请边界与包白名单 | `athena run -- bash cpa-dr/tests/unit/enrollment.sh` | 类型/路径/端点/有效期、撤销、认领身份与单主备关系、64KiB邀请与命令长度限制、源文件白名单、秘密不外发、临时/永久身份分派通过 |
| 安装前保护与包预检 | `athena run -- bash -c 'bash cpa-dr/tests/integration/join_preflight.sh && bash cpa-dr/tests/integration/invitation_installer.sh'` | 停止的异邀请、容灾保护态及异常本机记录在安装写入前拒绝；completed原邀请只读保留停止/暂停/后续配置；IPv6及端点长度边界；归档链接、越界、重复规范路径拒绝；独立SSH监听通过 |
| 不可替换服务器指纹 | `CPA_JOIN_DOCKER_IMAGE=cpa-dr:native athena run -- bash cpa-dr/tests/integration/invitation_host_pins.sh` | native与真实Docker同端点旧key、hashed冲突及多候选拒绝且文件不变；相同pin幂等；可信缺失的check只读、write新增；实际隔离sshd替换hostkey后严格SSH拒绝 |
| 真实SSH邀请协议 | `athena run -- bash cpa-dr/tests/integration/enrollment_protocol.sh` | 临时身份只读指定包/认领，普通RPC隔离，严格hostkey、双向配对、首备校验后启用、回调无持锁死锁、过期后绑定永久身份续办和中断提交恢复通过 |
| 无源码Linux本地安装 | `athena run -- bash cpa-dr/tests/e2e/enrollment_install.sh` | 备机移除镜像内服务源码，仅执行主机生成命令；固定包下载、真实安装器/Nginx/CGI/SSH、独立身份、首备通过；临时钥撤销后原命令重跑保留身份及首备；不恢复CPA工作数据 |
| 无源码Docker安装 | `athena run -- bash cpa-dr/tests/e2e/enrollment_docker_install.sh` | 空HOME下真实宿主Docker客户端执行原命令，实际Compose安装、双向SSH、首备、持久源码与原命令重跑通过；仅用独立临时项目，管理端口8787须空闲 |
| 原生升级与生命周期 | `athena run -- bash cpa-dr/tests/e2e/native_installer.sh` | 真实Nginx/CGI/SSH、升级兼容文件实体化及`.dockerignore`、部分原代码移动失败后的回滚、配置/身份/数据保留，安装重跑/重启标记/启停/卸载/重装/清除/未知状态保护通过；systemctl是模拟器 |
| root与非root Docker回归 | `athena run -- bash cpa-dr/tests/e2e/compose_smoke.sh`；`athena run -- bash cpa-dr/tests/e2e/docker_user.sh` | 实际构建、安装/启停/重启、API/SSH就绪、私有身份保留、卸载/重装/清除；同标签异源挂载容器保护，非root客户端与拒绝sudo分支通过 |
| 原有业务与安装回归 | `athena run -- bash -c 'bash cpa-dr/tests/unit/core.sh && bash cpa-dr/tests/integration/service.sh && bash cpa-dr/tests/integration/start.sh && bash cpa-dr/tests/unit/dependencies.sh && bash cpa-dr/tests/integration/deployment.sh && bash cpa-dr/tests/integration/manager.sh'` | 原快照/恢复/主备交接及保护态、TTY向导、依赖/包管理/sudo模拟、配置/密钥/未知数据和安装归属保护通过；整合后额外复跑入口与邀请协议 |
| API与邀请页面 | `athena run -- bash -c 'node --test cpa-dr/tests/unit/ui.test.cjs cpa-dr/tests/unit/enrollment_ui.test.cjs && bash cpa-dr/tests/integration/enrollment_api.sh && bash cpa-dr/tests/integration/api.sh'` | 9项页面单测；实际CGI认证/同源/参数边界/秘密投影及HTTP409通过 |
| Chromium邀请交互 | `NODE_PATH=/tmp/cpa-dr-enrollment-browser/node_modules athena run -- node cpa-dr/tests/e2e/enrollment_ui_runtime.cjs` | 真实浏览器、测试API：确认生成、撤销、移动端布局及登出后的异步返回不重新显示命令通过；不将测试API当实际SSH证据 |
| 双机备份/恢复及真实页面 | `NODE_PATH=/tmp/cpa-dr-enrollment-browser/node_modules CPA_BROWSER=1 athena run -- bash cpa-dr/tests/e2e/runtime_pair.sh` | 真实CGI/受限SSH、2秒周期调度、二次副本、旧副本拒绝、接管/回灌增删、连续回切、重复ACK及历史恢复失败后确认重试、真实浏览器登录/配对/恢复/两端布局、容器重启持久状态通过 |
| 最终静态检查 | 逐文件`bash -n`，全部Shell入口`athena run -- shellcheck --severity=warning -x ...`，`git diff --check` | 语法、warning级ShellCheck及补丁空白检查通过；日志使用`set -e`传播每项失败 |

### 缺陷回归与polish

- [本轮初审](reviews/review-structure-enrollment-initial.md)绑定`373eba9bb1159cd431ead51e6775d13b16d5cdd9`（tree `230a8c00ffd27e291ba64474e1282e3bb239d9d4`），原样结论为REWORK：1项P1、4项P2。初审前通过的测试未覆盖这些失败输入，不作为它们已关闭的证据。
- P1部分认领失败曾留下永久授权，并允许另一节点注册。补测指纹冲突失败无claim/权限、配置写入故障仅保留单身份claim、撤销/完成记录仍约束同身份，以及同身份重试成功后才获得RPC；邀请单测与真实SSH协议复验通过（`claim-review-fixes.log`）。
- P2页面漏识别真实API的`issued`状态；修复列表撤销入口，新增第9项页面单测，真实Chromium验证关闭命令、登出重登后仍可列表撤销（`ui-review-fixes.log`）。
- P2 IPv6监听短语法被真实Compose拒绝；改成长语法保留host_ip，IPv6配置与root Compose完整生命周期通过（`ipv6-final.log`）。
- P2显式`auto_enable:null`曾生成备机拒绝的邀请；规范化为默认true，保留显式false，邀请单测与真实SSH协议通过（`claim-review-fixes.log`）。
- P2备机曾静默追加同端点新hostkey；先红后绿改为安装前只读预检、写入前再次核对，OpenSSH查找处理hashed/大小写端点。native与真实Docker负例及实际sshd换key拒绝、两种无源码安装/精确重跑在最终累积树通过（`structure-review2-enrollment.log`）。
- 无源码重跑暴露引导锁被长期服务继承；关闭子进程锁描述符，父进程保留锁直到加入返回，原命令精确重跑通过。
- 首备启用后原调度时间为0，可能立即触发重复备份；在同一临界区设置首次尝试时间，随后按配置周期采集，协议与原2秒调度分别验证。
- 非rootDocker测试曾只复制兼容链接、不复制`deploy/`，报缺失`compose.yaml`；补齐真实源码fixture，原失败日志不作为成功证据，最终`docker-user-final.log`通过。
- 原生升级第二个原目录移动失败曾删除未移动的旧目录；故障注入先红后绿，回滚仅删除成功安装项、恢复成功备份项，再次恢复失败保留备份并明确报错。
- 归档按规范化路径去重；加入前明确区分可信缺失记录与读取/链接/格式异常，拒绝异常而非覆盖。
- 备机激活曾被误当成主机提交完成；新增最终收据确认标志。未确认时只用永久身份续办，拒绝失败/错邀请/错快照/pending收据；确认后的原命令重跑才完全只读，结果提示区分续办提交与历史收据。
- polish：临时代码/冲突标记无遗留；身份分派、跨机锁与重跑边界有注释；仅保留必要协议字段映射重复；无新增后端依赖或无消费者抽象；外部输入/归档/记录校验留在边界。当前架构及操作手册已同步。

日志在本机`.runtime/`：`regression-tests.log`、`enrollment-integrated-final.log`、`native-enrollment-final.log`、`native-upgrade-final.log`、`docker-enrollment-final.log`、`docker-user-final.log`、`ui-api-final.log`、`runtime-pair-final.log`、`marker-container-final.log`、`receipt-native-final.log`、`receipt-docker-final.log`、`receipt-message-final.log`、`static-final.log`。普通独立审查原样结果保存在`docs/development/reviews/`，与源码树及本地证据绑定，不宣称正式Athena门禁放行。

五项初审修复后的`f93a2ea`主线程累积树复验均退出0：`structure-review2-regression.log`（核心/服务/入口/依赖/部署/管理）、`structure-review2-enrollment.log`（邀请/真实SSH/不可替换pin/两种无源码安装重跑）、`structure-review2-docker-preflight.log`（真实Docker异常marker及冲突pin写入前拒绝）、`structure-review2-static-ui.log`（全量语法/ShellCheck/文档/9项页面单测/API/真实Chromium）、`structure-review2-runtime.log`（新镜像、实际双机备份恢复与浏览器、native/root/nonroot完整生命周期）。polish保留严格输入边界与固定RPC，更新认领/指纹架构和验证事实，不新增生产功能；文档与静态复查见`structure-review2-polish.log`。

[二审](reviews/review-structure-enrollment-second.md)原样绑定上述HEAD/tree，确认原五项通过，另补1项P2：自定义known_hosts仍被默认路径忽略。修复后邀请/安装器统一读取实际配置的信任文件、私钥及公钥侧文件；默认/custom双端独立身份的实际SSH首备完成通过（`structure-review3-core.log`）。native/真实Docker自定义旧pin、缺失私钥、陈旧/链接`.pub`及同路径私钥/known_hosts均在安装写入前拒绝；匹配或缺失`.pub`允许，默认文件不误写；停止Docker外部路径拒绝，但已确认历史收据仍完全只读。最终合并`d4f9bf5`的真实pin/预检及Docker/native两种无源码首装、精确重跑通过（`structure-review3-installer-verified.log`）。

首次合并安装日志`structure-review3-installer.log`退出1：native通过，Docker显示管理健康后，后续安装记录/服务核验拒绝，原输出没有具体原因，**不作为整体成功证据，也未宣称根因已定位**。补充非秘密服务/原因诊断，保留原核验条件、不加盲重试；后续新建隔离项目两种安装完整退出0，诊断负例也通过。部署中若再出现该问题，应结合新的服务/原因输出核对，不把健康端点当安装完成。

### 最终传输兼容复验与polish

主机信任预检补齐逐候选算法/公钥核对：合法同key的别名、hashed、大小写、注释及重复记录保持原文件；任一异key或撤销/证书标记拒绝。施工报告（`enrollment_core`，提交`ea157254`）记录新增注释正例先红后绿；整合为`0d8bdbf`后主线程独立复验，不以施工报告替代以下运行证据。

- `structure-final-transport-install.log`整体退出0，绑定`0d8bdbf21d38410316211d2b8274a00e632cb1c8`：全量邀请unit（22/2222全部格式正负例）、默认/custom真实SSH（custom预置hashed pin、首备/完成后原文件摘要不变）、新镜像构建、native/真实Docker自定义身份与信任、真实sshd换key、安装前预检及包边界，以及两种无源码首装和原命令精确重跑全部通过。
- `structure-final-static-ui.log`整体退出0，绑定同一源码：全部Shell逐文件语法及ShellCheck warning级、结构/本地Markdown链接/原Worker摘要、9项页面unit、实际CGI/API及`git diff --check`通过。
- `f93a2ea`的核心/服务/2秒调度/恢复接管回灌/真实浏览器及完整root/nonroot生命周期证据仍绑定该树；其后仅修改邀请传输、安装预检及诊断，按上列定向场景复验，不将旧日志改称最后源码全量重跑。

最终polish仅同步架构、故障诊断和验证事实，无额外生产功能：

| 检查 | 结论 |
|---|---|
| 临时/调试痕迹 | 本轮增量无调试输出、冲突标记或临时施工逻辑 |
| 注释 | 身份与信任读取、停止Docker映射、历史收据只读边界有说明 |
| 重复 | 复用既有传输预检，保留容器/宿主所需的边界适配 |
| 低效 | 未增加网络往返、后台探测或无谓服务启动 |
| 过度设计/防御 | 不新增后端依赖；严格验证留在密钥、指纹和安装记录输入边界 |

文档同步后的静态/结构/文档复查见`structure-final-polish.log`；最终独立审查按新packet重新绑定冻结树，原样结果单独保存。

### 安装发现异常的写入前保护

[三审](reviews/review-structure-enrollment-third.md)原样绑定`c775e305f19cbc9be2d5e9bd7368023585442c66`（tree `df3be6f99b94c9abd491bde6ec667e5a0cf36bf6`），确认原五项及自定义transport修复通过，补1项P2：损坏现有`.env.native.json`使实际discovery返回空record/异常，join曾创建数据目录并调用安装器后才失败；既有安装器仍保护配置与角色/恢复点，未复现恢复数据破坏。

修复为先检查完整discovery原因，空record只有在明确未安装时允许首次安装，不把损坏/链接/不可读/legacy记录或查询失败当不存在。`installer`隔离施工先红报`discovery malformed-json mutated before rejection: installer called`（`discovery-preflight-red.log`），绿测来源`be5cbd789`（`discovery-preflight-worker-green.log`）；主线程整合为`72dbbd11874ae4da6291fd6530994d2291a3e4f9`后再次独立实跑：

- `structure-final-discovery-install.log`整体退出0，绑定上述最后源码：最终新镜像、实际manager discovery的malformed/link/真实权限/legacy/缺timeout写入前拒绝、明确首次安装正例、停止真实Docker的历史ACK只读、原custom/pin/marker/readiness预检，以及Docker/native两种无源码首装和原命令精确重跑全部通过。
- `structure-final-discovery-static-ui.log`整体退出0：全部Shell语法及ShellCheck warning、结构/Markdown链接/原Worker摘要、9项页面unit和实际CGI/API通过。
- 生成命令的bootstrap在join前检查jq/timeout，缺少时从现有源安装jq/coreutils；realpath来自coreutils并在discovery前实际使用。手工join缺查询工具提前停止，不为读取异常现存配置先安装依赖或启动服务。
- 最终polish无新增子系统、依赖、网络往返或抽象，仅前移已有边界检查和同步架构/诊断/验证；保留前节五项结论。文档同步后复查见`structure-final-discovery-polish.log`。其后独立审查重新绑定冻结树，结果原样保存在reviews目录。

**未验证范围：**Linux本地测试的systemctl及sudo/包管理策略为模拟；真实宿主systemd定时器、只读沙箱、发行版依赖安装与网络/防火墙，真实CPA版本/权限/OAuth/业务健康及Cloudflare入口联动均待目标环境演练。没有在真实主备服务器安装、修改CPA/Cloudflare、推送仓库或迁移现有数据。测试结束清理独立容器、网络及临时数据。

## 2026-11-08 GitHub 一键安装交付

本轮在既有源码整理与自动配对基础上增加 GitHub 下载入口，验收见 [交付设计](github-install-design.md)。没有初始化 `.ai_state`；`athena run` 实际执行检查，但明确输出无活动 sprint，不称为正式 Athena 门禁证据。独立审查结论另存 `reviews/review-github-install.md`。

| 验证范围 | 命令 / 本地日志 | 事实边界 |
|---|---|---|
| 主机与备机固定源码下载 | `bash cpa-dr/tests/integration/github_install.sh`；`.runtime/github-install-download.log` | 模拟 GitHub HTTPS 传输，真实归档、打包与清单；检查 SHA 固定、参数边界、下载失败、越界/重复/链接、摘要不符、持久源码损坏与无重复下载续装 |
| GitHub 来源真实主备配对 | `CPA_TEST_GITHUB=1 bash cpa-dr/tests/e2e/enrollment_install.sh` / `enrollment_docker_install.sh`；`.runtime/github-install-pair-final.log` | GitHub 下载为本地传输 fixture；主机与备机实际容器、SSH、CGI、首备验证及精确原命令重跑，native 的 systemctl 为隔离模拟，Docker 使用真实客户端 |
| 原功能回归 | `.runtime/github-install-regression.log` / `github-install-regression-final.log` | 原日志核心、服务、安装入口通过，随后普通用户 fixture 因工作区入口读权限不足退出；恢复入口 755 后，从依赖到部署、管理、邀请、实际 SSH 协议、API 与页面的剩余测试独立复验；失败由 `set -e` 传播 |
| 静态与文档 | `.runtime/github-install-static.log` | 全部 Shell 语法、warning 级 ShellCheck、结构兼容、本地 Markdown 链接、原 Worker 代码摘要与补丁空白检查 |
| 上传检查 | Git 暂存清单、远端 main 核对 | 不纳入 `.runtime` / `.mindfs`、实际 `.env`、管理员令牌、私钥或业务数据；既有工作区源码与文档整理一起提交 |

原回归失败日志不作为整体成功证据；普通用户权限失败的 stderr 保存在 `.runtime/github-dependencies-stderr.log`，修正后结果以 final 日志为准。

GitHub 与 Docker/native 的文件权限可能不同，安装包已统一目录、可执行入口及公共文件权限，使同一提交在三种来源下生成相同归档摘要。下载错误不会继续使用部分归档；备机摘要与主机不符时停止，不回退 SSH。旧本地源码邀请保留原 SSH 安装包链路。

在线检查仅验证 GitHub 提交解析与固定版本 raw/codeload 文件下载，不执行真实主机安装。Linux 宿主 systemd、包管理及网络策略、CPA/OAuth/业务恢复、Cloudflare 切换仍属目标环境待验证范围。以上本地日志不上传仓库，避免公开邀请凭据。
