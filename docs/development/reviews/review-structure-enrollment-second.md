- [P2] cpa-dr/lib/enrollment.sh:146 — 邀请流程忽略配置的 `peer.known_hosts_file`，固定读写默认文件。真实双机中将主机配置为合法空 `/state/ssh/custom_known_hosts`，生成/注册成功，但 complete 退出 1，报 `No ED25519 host key is known`，配置文件仍空、默认文件新增一行；备机 `join.sh:113-114` 同样忽略自定义文件中的旧指纹，实测冲突预检后仍调用了安装器，违反旧配置兼容及安装前指纹冲突拒绝要求。
VERDICT: REWORK
原 P1：hostkey 冲突、config 写失败注入、异身份抢占/撤销及真实 SSH 权限复验通过。
原 P2：issued 网页撤销、SSH/管理 IPv6 实际 Compose 解析复验通过。
原 P2：默认路径 native/Docker/真实 sshd 换指纹拒绝通过；null/false/true 均实际生成并被 join 接受。自定义路径缺口见上。
审查 HEAD：f93a2ea4ef48682365d4299a121e8594a4245454；tree：fa49bb94eef48b8453b7ac9af643f00c66799702。
