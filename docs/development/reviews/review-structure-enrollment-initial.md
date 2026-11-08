- [P1] cpa-dr/lib/enrollment.sh:167 — singleton 仅检查 config.peer：邀请 A 注册时预置同端点冲突 hostkey，注册失败后 A 的 claim 和永久授权已持久化、peer 仍为空；异节点邀请 B 随后注册成功，而 A 的永久身份仍可执行普通 RPC，撤销 A 后权限仍保留。
- [P2] cpa-dr/www/app.js:333 — 后端新邀请返回 `status:"issued"`，页面仅为 pending/claimed/registered 显示撤销按钮；生成后关闭对话框或重新登录，未认领邀请失去网页撤销入口。真实 Chromium 复现按钮数量为 0。
- [P2] cpa-dr/deploy/compose.yaml:13 — `--ssh-bind-host ::1` 被接受，但端口短语法未包裹 IPv6；实际 `docker compose config` 退出 15，报 `too many colons in address`，Docker 邀请安装无法继续。
- [P2] cpa-dr/scripts/install/join.sh:74 — 同端点已有不同 hostkey 时直接追加新 key，不拒绝冲突；真实隔离 sshd 验证 `StrictHostKeyChecking=yes` 随后成功连接替换后的服务器，违反 AC4 指纹替换拒绝要求。Docker 分支第 73 行同样存在。
- [P2] cpa-dr/lib/enrollment.sh:82 — `auto_enable:null` 通过 create 校验并原样进入邀请，但 join 要求 boolean，立即报“邀请格式不完整”；生成成功的命令不可执行，显式 null 应拒绝或规范化为默认值。

VERDICT: REWORK

只读复验：结构/文档、邀请单元、API、安装预检、真实 SSH 协议及 8 项页面单测退出 0；上述失败输入另行实测复现。
