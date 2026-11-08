# 主备配对与邀请管理

优先使用[备机一键安装](install-standby.md)，自动完成两类信任：客户端公钥允许固定备份 RPC，服务器 hostkey 验证目标并登记到本机 known_hosts。两者不是同一密钥。

邀请固定主机 hostkey，备机登记自己的持久 hostkey；后续使用 `StrictHostKeyChecking=yes`。临时身份仅获取指定安装包、注册或查询本次安装，不进入普通备份、恢复、角色交接或 Shell。最终完成由新备机永久身份证明。

两端永久私钥留在本机，各有独立节点 ID 和管理员令牌；不复制 `.env` 或整个状态目录。

## 手工配对兜底

用于已有服务维护，不与自动安装并发改配置：

1. 两端停用定时任务，核对不同主/备角色及一致数据标签/类型。
2. 页面分别显示本机 SSH 公钥，在对方导入并确认受限公钥。
3. 填对端专用 SSH 地址、端口、`root` 用户。Docker 跨机通常宿主地址与发布端口 `2222`，同容器网络才用 `22`。
4. 填本机私钥/known_hosts 路径，可信控制台核对服务器指纹后登记。
5. 两端保存并测试配对成功；主机立即备份，核对备机同一有效快照后启用调度。

| 方式 | 私钥 | known_hosts |
|---|---|---|
| Docker | `/state/ssh/id_ed25519` | `/state/ssh/known_hosts` |
| Linux 本地默认 | `/var/lib/cpa-dr-native/ssh/id_ed25519` | `/var/lib/cpa-dr-native/ssh/known_hosts` |

## 手工登记指纹

在对端可信控制台查看专用 hostkey。Linux 本地默认：

```bash
sudo ssh-keygen -lf /var/lib/cpa-dr-native/ssh/ssh_host_ed25519_key.pub
```

Docker 使用实际 `STATE_PATH` 下的 `ssh/ssh_host_ed25519_key.pub`，不要误取日常登录 SSH 的 hostkey。

本机采集，`HOST`、`PORT` 与页面配置完全一致：

```bash
ssh-keyscan -t ed25519 -p PORT HOST > /tmp/cpa-dr-hostscan
ssh-keygen -lf /tmp/cpa-dr-hostscan
```

**指纹与可信对端一致后**，追加到本机实际状态目录 `TARGET`：

```bash
sudo tee -a TARGET/ssh/known_hosts < /tmp/cpa-dr-hostscan >/dev/null
sudo chmod 600 TARGET/ssh/known_hosts
rm -f /tmp/cpa-dr-hostscan
```

两端都执行。指纹意外变化先停止传输并确认原因，不关闭校验。
