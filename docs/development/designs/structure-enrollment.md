# 结构整理与一次性安装邀请设计

req: ../requirements/structure-enrollment.md
path: System
base_commit: e645357

项目无 .ai_state，沿用既有 docs 需求/设计、athena run、独立源码审查，不初始化状态库，不宣称正式 sprint 门禁。实现写者使用隔离 worktree；整合后统一复验。

## 顺序交付

1. 结构整理：文档分类、根入口、部署/脚本/测试归类，旧入口兼容。
2. 一键加入：受限SSH邀请协议、安装包、引导命令、两端身份和监听配置。
3. 页面/文档/整合：生成/撤销邀请、安装状态及首备结果、完整运行验证。

## 共用合同

- 服务根保留 cpa-dr；原脚本位置可保留薄兼容包装，新实现放 scripts/install、scripts/runtime、scripts/packaging。部署实际文件在 deploy，原 Dockerfile/compose.yaml 可保留兼容入口。
- 保留 common.sh、snapshots.sh、service.sh 数据/角色/锁不变量；SSH客户端抽到 transport.sh。新增 enrollment.sh、bin/cpa-dr-enroll-rpc、bin/cpa-dr-ssh-dispatch。后端继续 Bash+jq+OpenSSH，不新增 Python/Node 运行后端。
- SSH仍全局强制受限 dispatcher，sshd ExposeAuthInfo=yes 提供认证公钥，dispatcher 区分邀请身份与永久身份，缺失/未知认证信息 fail-closed。临时身份仅能读取指定安装包、注册/查看/完成该邀请，不得进入普通RPC。源码依据本机 sshd_config(5)/ssh(1) 的 ExposeAuthInfo/SSH_USER_AUTH；需真实SSH验证。
- 邀请存 STATE/enrollment/invites/ID，原配置/快照格式不迁移。邀请绑定主节点、备机广告地址、部署方式、数据根、标签相对路径、策略、程序包摘要；只导出临时私钥，不导出主机永久私钥或管理员令牌。记录原子持久化，过期/撤销/并发认领受锁保护。
- 协议CLI：cpa-dr enrollment create JSON_FILE / list / revoke ID；create返回 {invite_id,command,expires_at}。install模块根据部署记录取服务CLI，传入 {primary_host,primary_port,backup_host,backup_port,backup_bind_host,data_dir,deployment,output,ttl_seconds,auto_enable,...}。hostkey来自已持久化服务状态；所有字段有边界校验。
- 邀请SSH操作：bundle（二进制归档）、register（JSON stdin：备机节点ID、公钥、hostkey及端点）、status、complete。认领绑定实际备机身份；complete由受邀端凭新永久密钥证明身份，两端test-peer，主机同步首备确认相同有效ID后才启用调度。不得持操作锁跨机等待回调；所有步骤幂等，失败保留凭据/原身份以续装。
- 生成命令内含最小Bash引导器（脚本被编码为数据，不source/eval邀请JSON），引导器把临时密钥写私有目录，通过固定hostkey的SSH获取包、验证摘要、验证归档路径/类型后解包；运行新 start.sh join --invite-file FILE，源码目录与输出/状态/数据独立；临时秘密不放URL或普通日志。安装包只白名单源码，保留包版本/摘要。
- join在备机复用现有installer，来源类型/标签继承，路径由备机根+relative_path映射；同一邀请重跑保留节点与密钥；不同既有配对/数据配置冲突停止。Docker通过已有容器内CLI执行；native通过sudo。实际安装前展示计划并由生成命令显式确认（--yes）。
- 新参数 --ssh-bind-host 与管理 --bind-host 分离，两种部署支持；已有监听通过受校验的专用入口变更，不手改归属摘要；生成邀请及加入需要确认可达地址，默认不改防火墙。
- API GET/POST /api/enrollment、POST /api/enrollment/revoke，全部沿用管理员认证；POST调用enrollment create（配置和权限同CLI）。网页显示新邀请命令、有效期、撤销；登出清除秘密。不直接导出管理令牌。

## 验收标准

- AC1: 文档按 cloudflare/backup/development/archive 分类；原Worker代码不变、链接有效、历史方案标清。根和旧入口可用，部署/脚本/测试路径调整通过既有回归。
- AC2: 安装包白名单、版本摘要、引导归档预检及临时秘密权限有测试；命令无源码备机可执行且同身份重跑保留。
- AC3: 主机CLI/网页可生成、列出、撤销邀请；角色/端点/策略/路径非法值拒绝；30分钟默认有效期、过期/撤销/并发认领/异节点重用均拒绝。
- AC4: 真SSH验证临时身份仅执行邀请操作，普通备份永久身份保留原权限；严格hostkey未知/替换拒绝；新端独立节点/管理员令牌/密钥。
- AC5: Docker/native及混合模式复用安装器、独立SSH监听、两端标签/类型与本地路径正确；自定义输出、普通Docker客户端/native sudo保持支持。
- AC6: 双向配对、首备校验成功后才启用自动调度；备机出现与主机一致的有效快照；失败、响应丢失或重启可按记录恢复，无跨机持锁死锁。
- AC7: 历史恢复/接管/回灌/防旧副本覆盖行为回归通过；备份不自动写备CPA数据、不改Cloudflare。危险操作维持人工确认。
- AC8: Bash语法/ShellCheck、单元/API/安装集成、真实SSH双机与浏览器验证完成；polish后独立审查，无P1/P2遗留；真实CPA/真实宿主systemd及发行版安装未验证则单独说明。
