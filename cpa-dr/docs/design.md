# Linux 原生命令改造设计

System，基线 a859a1e。需求：用户明确取消 Python，改用 Linux 原生命令；保留既有中文页面、角色/内容/周期设置、历史恢复、二次备份及受控接管回切。无 .ai_state，未获初始化同意，使用普通文档及 athena run 实跑，不伪称正式门禁。部署不触碰现有 CPA/Cloudflare。

## 验收
- AC1: 交付无 Python 源码、Python 镜像或 Python 启动/测试命令；CLI/后端用 Bash、GNU coreutils、jq、tar、rsync、OpenSSH、flock，SQLite 用 sqlite3 CLI。
- AC2: 中文页面继续配置主/备、来源、时间间隔、保留；通过 nginx + fcgiwrap 调用 Bash CGI；管理员令牌只在页面内存，配置不执行 source/eval。
- AC3: 主机定时生成校验快照，通过严格 known_hosts 的 SSH 传输给备机；备机二次快照；失败保留有效版本、状态与配置重启持久。
- AC4: 恢复先预览/停写/确认，覆盖前回滚；增/改/删与空目录正确；SQLite backup；拒绝穿越、链接、损坏/超量归档与无认证请求。
- AC5: 确认隔离旧主后备接管；拒绝旧来源/代次。主先待恢复、备最终停写回灌，再刷新新主基线后交接；失败保护，不做自动跨网仲裁。
- AC6: Linux systemd timer 与 Docker 均能部署；真实双节点 SSH、真实 nginx/CGI、浏览器和容器验证通过。

## 切片/隔离写集
1. core writer: lib/common.sh, lib/snapshots.sh, tests/core.sh。负责配置/路径、JSON、持久发布、校验/恢复/回滚。
2. service writer: bin/*, lib/service.sh, cgi/*, tests/service.sh, tests/api.sh。负责 CLI、状态/锁/调度、SSH/受限rpc、CGI认证和角色交接。
3. UI/deploy writer: www/*, scripts/*.sh, deploy/*, Dockerfile, compose.yaml, .env.example, .dockerignore, README.md, tests/browser/ui.test.cjs, tests/deployment.sh。原页面移到www，改SSH字段，部署/启动无Python。
4. integrator: design/requirements/architecture/verification、真实双端测试；旧Python包/测试/安装脚本删除、交付与根README。各写者独立worktree，不覆盖别人修改。

## 冻结接口（所有库仅source可信项目脚本，配置只由jq解析）
所有运行脚本 Bash >=5、set -Eeuo pipefail；库中的关键步骤显式检查错误（函数被if调用时不能依赖errexit）。JSON输出 stdout，诊断 stderr。
CPA_ROOT=项目绝对路径；CPA_STATE_DIR=本机状态绝对路径；CPA_ALLOWED_ROOT=允许的数据父目录，默认/data；CPA_ADMIN_TOKEN可初始化覆写（>=32安全字符）。
lib/common.sh 提供 cpa_fail MESSAGE(返回1), cpa_atomic DEST(从stdin原子私有写入+sync指定文件/父目录), cpa_init(幂等创建私有state/config.json/admin.token，默认根CPA_ALLOWED_ROOT), cpa_config_get(原始配置JSON), cpa_config_public(脱敏配置JSON), cpa_config_set JSONFILE(原子校验保存), cpa_id_valid ID。
配置：{node_id:uuid不可变,node_role:primary|backup,enabled:false,interval_seconds:60,secondary_interval_seconds:3600,retention_count:120,max_snapshot_bytes:1073741824,allowed_root:固定绝对路径,sources:[{name,path,kind:auto|file|directory|sqlite}],peer:{host:'',port:22,user:'root',identity_file:'',known_hosts_file:'',node_id:''},service:{driver:none|docker|systemd,name:'',timeout_seconds:60}}。key/knownhosts路径是本机绝对路径；host/user严格白名单，不执行任意shell片段；已有有效数据后危险换role受service约束。main在init后生成state/ssh/id_ed25519及known_hosts空文件，public/pairing不暴露私钥。
lib/snapshots.sh 提供 cpa_snapshot_create PURPOSE EPOCH -> manifest JSON, cpa_snapshot_list -> JSON array, cpa_snapshot_verify ID -> manifest, cpa_snapshot_export ID DEST -> 归档路径, cpa_snapshot_import ARCHIVE EXPECTED_NODE EXPECTED_EPOCH -> manifest, cpa_snapshot_clone ID PURPOSE -> manifest, cpa_snapshot_plan ID -> {snapshot_id,items:[{name,target,kind,...}],warnings}, cpa_snapshot_restore ID -> {rollback_id,restored}, cpa_snapshot_prune -> 无输出。调用者持operation.lock。snapshot ID仅[A-Za-z0-9_-]；manifest基本字段沿用 format_version/id/node_id/node_role/epoch/purpose/created_at/total_bytes/file_count/items/files，增加directories可保空目录。payload/<name>/...，单文件payload/<name>/data。导入验证类型/数量/路径/总大小/所有sha及登记，不信任original_path；拒绝控制字符/反斜线文件名以消除tar文本歧义。恢复用当前sources标签，rsync --inplace --delete保留目录/既有inode、本机owner；失败补偿，异常停止保护由service处理。SQLite .backup且停止后拒绝残留WAL/SHM。历史分用途/来源，保留latest_received及最近rollback。

## CLI/服务/SSH合同
bin/cpa-dr --state-dir DIR COMMAND [ARGS]，init [--allowed-root ROOT]、config get|set JSONFILE、status、pairing、snapshots、action NAME JSONFILE、tick、scheduler、peer ...；init输出node_id/admin_token/public_key。bin路径用CPA_ROOT计算。服务运行状态state/runtime.json：phase/epoch/job/last_backup/last_replication/latest_received；作业历史最近20个state/jobs/ID.json。所有写者含CGI/CLI/peer/tick共用state/operation.lock flock；长任务action返回{job_id}由继承锁的后台进程完成，短verify/restore-plan/test-peer同步JSON。config set输出{config:public}。
SSH全程BatchMode+StrictHostKeyChecking=yes+显式known_hosts/identity，只发固定rpc操作和严格ID/epoch参数，归档走stdin/stdout；不开放shell/端口转发。bin/cpa-dr-rpc --state-dir DIR读取SSH_ORIGINAL_COMMAND，仅read -a白名单解析、不eval，转到主CLI peer子命令。authorized_keys行由CLI trust-key KEYFILE或CGI POST /api/pairing {public_key}生成，restrict,command="绝对bin/cpa-dr-rpc --state-dir DIR"；node/state路径限制可安全写入forced command。公钥只接受验证过的ssh-ed25519。配对GET {node_id,public_key}，不再使用HTTP peer_token。
peer子命令：status(角色/phase/epoch/node_id)，receive NODE EPOCH(stdin tar，仅backup_standby并匹配配对主身份/代次)，archive ID(stdout tar)，handover NODE EXPECTED_EPOCH QUIESCED(仅backup_active -> paused生成最终副本返回snapshot_id/epoch/handover_id)，baseline NODE EPOCH HANDOVERID(stdin tar，仅匹配paused交接nonce)，commit HANDOVERID(有有效新主baseline才standby)。主failback先生成最终备副本、恢复、启动driver时CPA、生成并发给备新主baseline、commit后primary_active；不中途盲目恢复旧token。无driver真实停机由确认负责。
CGI路由保持既有管理API：GET /api/status,/api/config,/api/pairing,/api/snapshots,/api/jobs/ID；PUT /api/config；POST /api/pairing(导入对端公钥)、/api/actions/{backup,verify,restore-plan,restore,promote,prepare-recovery,failback,pause,resume,test-peer}。动作JSON confirmation/flags沿用原版；认证Bearer admin.token，不开放CORS、no-store；请求64KiB限制；HTTP状态/error JSON。peer不用HTTP接口。

## 部署/UI
Nginx服务静态www，/api映射固定cgi/api.cgi，经fcgiwrap；不让用户路径变成可执行脚本。systemd一个tick服务+1秒timer动态遵守配置间隔；可选web.service/fcgiwrap实例。Docker Debian slim apt --no-install-recommends原生包，包含nginx/fcgiwrap/spawn-fcgi/sshd/Bash/jq/tar/rsync/flock/sqlite3/curl，无Python。entrypoint启动原生进程并监控、退出清理；SSH服务hostkey持久state/ssh，authorized_keys为受限rpc。管理默认127.0.0.1:8787，SSH发布127.0.0.1:2222，可按内网防火墙配置；state /state、data /data，明确权限与服务驱动边界。
scripts/setup.sh --data-dir TARGET幂等保护已有.env/密钥，创建新state-native默认以避免Python旧状态混用，输出管理token/SSH公钥；脚本不eval/source.env，shell配置用JSON。install-systemd.sh不覆盖已有同名unit，真实安装需用户部署执行。本轮只测试临时样本，不执行真实CPA/Cloudflare/宿主服务安装。
