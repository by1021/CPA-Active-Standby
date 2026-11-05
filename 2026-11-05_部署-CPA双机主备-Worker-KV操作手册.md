# CPA 双机主备：Worker + KV 简明操作手册

> 适用：两台 Linux 服务器已运行 Docker CPA，各有独立 Tunnel。按 **服务器检查 → Cloudflare 配置 → 验收 → 故障处理** 操作即可。
> 更新日期：2026-11-05。用户已反馈统一入口部署完成，主站关闭后可切到备站；本轮未连接线上服务器，其他故障场景及流式请求仍 **待验证**。
> 新增数据方案见 [轻量自动备份与恢复方案](2026-11-05_部署-CPA双机主备-report.md)。本手册 Worker 代码不变；定时任务、启动保护和自动回灌尚未实施。

## 1. 先确认两台服务器

| 角色 | 地址 | 用途 |
|---|---|---|
| 统一入口 | `https://api.996668.xyz` | 客户端只填写这个地址 |
| 国外主站 | `https://kapi.996668.xyz` | Worker 优先访问 |
| 国内备站 | `https://dapi.996668.xyz` | 主站探测失败时使用 |

**本节基础流量主备要求两台 CPA 和 Tunnel 平时都运行。** Worker 只转发请求，不启动容器、不同步数据、不保证正在进行的流不中断。两台使用相同客户端 API Key，并确认国内能独立调用模型上游；`/v1/models` 正常不等于真实模型可用。

接入数据自动化后，待机 CPA 的常驻/按需启动方式按 [新方案第 5 节](2026-11-05_部署-CPA双机主备-report.md#5-和现有-worker-的衔接) 确认；两台使用相同 OAuth 凭据时，先验证后台刷新与写入冲突。原主恢复时先回灌，再允许接流量。

在**两台服务器的 Bash** 中分别执行，将 `CPA_CONTAINER` 换成实际容器名：

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
docker inspect CPA_CONTAINER --format '{{json .Mounts}}'
docker inspect CPA_CONTAINER --format '{{.HostConfig.RestartPolicy.Name}}'
read -rsp 'CPA API Key: ' TOKEN; echo
curl -fsS --max-time 10 -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8317/v1/models
unset TOKEN
```

检查重点：

- 当前 CPA 官方 Compose 使用 `config.yaml`、`auths/`；容器内认证目录通常是 `/root/.cli-proxy-api`。**以 `docker inspect` 的实际挂载为准**，不要照抄旧文的 `config.ymal` 或假定目录叫 `auth-dir`。[6]
- `cloudflared` 在宿主机运行时，CPA 端口映射用 `127.0.0.1:8317:8317`，Tunnel 服务地址用 `http://127.0.0.1:8317`。修改 Compose 后，在对应目录运行 `docker compose up -d` 使映射生效。[7]
- `cloudflared` 在独立 Docker 容器中时，`localhost` 指它自己；让两容器加入同一 Docker 网络，Tunnel 指向 `http://CPA服务名:8317`，CPA 在容器内监听可达地址。此情形按容器网络检查，不照搬上面的宿主机 curl。[7]
- 不向公网开放 8317，也不通过这两个域名开放管理接口；确认 CPA 管理远程访问保持关闭。两边版本、模型配置和凭据可用性要匹配。[6]

## 2. Cloudflare 按这条顺序配置

使用英文控件名定位；中文界面按对应含义查找。**先配好 Worker 再接统一入口，本节无需 Wrangler 或 Cloudflare Cron。** 新增的备份任务在 Linux 服务器侧另行配置，不由这段 Worker 代码执行。

### 2.1 检查现有 Tunnel

当前官方路径：**账号首页 → Networking → Tunnels → 选择对应 Tunnel → Routes**。[1]

确认国外 Tunnel 的 Published application 指向 `kapi`，国内指向 `dapi`，服务地址按第 1 节选择。缺少路由时点 **Add route → Published application**，填写子域名、域名和 **Service URL**，再点 **Add route**。已有正确路由就保留；不要把统一入口 `api` 加到 Tunnel。

### 2.2 创建 Worker 和 KV

| 顺序 | 界面操作 | 填什么 |
|---|---|---|
| ① Worker | **Workers & Pages → Create application → Start with Hello World! → Get started → Deploy** | 名称 `cpa-ha-proxy` |
| ② KV | **Workers KV → Create instance → Create** | namespace 名称 `CPA_HA_STATE`；普通 KV 即可，不选 Instant 私测功能 |
| ③ 初始开关 | 进入该 namespace → **KV Pairs → Add entry** | Key：`mode`；Value：`auto`，纯文本，不加引号、不设过期 |
| ④ 绑定 | 进入 Worker → 顶部 **Bindings → Add binding → KV namespace → Add binding** | Variable name：`HA_STATE`；选择 `CPA_HA_STATE`，再点 **Add binding** |

以上控件名来自官方 KV 入门文档；**Bindings 是 Worker 的独立页签**，不是旧文含糊的 Settings / Bindings。[2]

### 2.3 添加变量与密钥

Worker → **Settings → Variables and Secrets → Add**，逐项填写，最后 **Deploy**。[3]

| 名称 | 类型 | 值 |
|---|---|---|
| `PRIMARY_ORIGIN` | Text | `https://kapi.996668.xyz` |
| `BACKUP_ORIGIN` | Text | `https://dapi.996668.xyz` |
| `HEALTHCHECK_TOKEN` | Secret | 两台都接受的 CPA API Key；用探测专用 Key，不用管理密钥 |

### 2.4 粘贴代码并部署

打开 Worker 的在线代码编辑器（**Edit code**），替换默认代码，再 **Deploy**。这里固定用 `/v1/models` 做进程探测，超时 5 秒，验证响应是模型列表 JSON；业务响应保持流式，不套用 5 秒超时。

<details>
<summary>展开：完整 Worker 代码（整段复制）</summary>

```javascript
const fail = (message, status = 503) => new Response(message, {
  status, headers: { "Cache-Control": "no-store" },
});

async function healthy(origin, token) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5000);
  try {
    const r = await fetch(new URL("/v1/models", origin), {
      headers: { Authorization: `Bearer ${token}` },
      signal: controller.signal, redirect: "manual", cache: "no-store",
    });
    if (!r.ok || !r.headers.get("content-type")?.includes("application/json")) {
      await r.body?.cancel();
      return false;
    }
    const data = await r.json();
    return data.object === "list" && Array.isArray(data.data);
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

export default {
  async fetch(request, env) {
    let mode, primary, backup;
    try {
      primary = new URL(env.PRIMARY_ORIGIN);
      backup = new URL(env.BACKUP_ORIGIN);
      if (!env.HEALTHCHECK_TOKEN || [primary, backup].some(u =>
        u.protocol !== "https:" || u.host === new URL(request.url).host ||
        u.username || u.password || u.pathname !== "/" || u.search || u.hash
      ) || primary.host === backup.host) return fail("Invalid Worker configuration");
      mode = await env.HA_STATE.get("mode");
    } catch {
      return fail("Configuration or KV unavailable");
    }
    if (!["auto", "primary", "backup", "pause"].includes(mode)) {
      return fail("Set KV mode to auto, primary, backup or pause");
    }
    if (mode === "pause") return fail("Maintenance");

    const candidates = mode === "auto" ? [["primary", primary], ["backup", backup]]
      : mode === "primary" ? [["primary", primary]] : [["backup", backup]];
    for (const [name, origin] of candidates) {
      if (!await healthy(origin, env.HEALTHCHECK_TOKEN)) continue;
      const target = new URL(request.url);
      target.protocol = origin.protocol;
      target.host = origin.host;
      const upstream = new Request(target, request);
      upstream.headers.delete("host");
      upstream.headers.delete("forwarded");
      upstream.headers.delete("x-forwarded-for");
      upstream.headers.delete("x-forwarded-host");
      try {
        const r = await fetch(upstream, { redirect: "manual", cache: "no-store" });
        const headers = new Headers(r.headers);
        headers.set("X-HA-Origin", name);
        headers.set("X-HA-Mode", mode);
        headers.set("Cache-Control", "no-store");
        return new Response(r.body, { status: r.status, statusText: r.statusText, headers });
      } catch {
        // 已发送业务请求，不向另一节点重放，避免重复执行或计费。
        return fail("Origin connection failed; request was not replayed", 502);
      }
    }
    return fail("Selected origin unhealthy");
  },
};
```

</details>

KV 只存人工开关，不写健康缓存。跨地区更新可能 **60 秒或更久**才可见，不是即时锁；读取失败返回 503，不擅自恢复 `auto`。旧版 `expirationTtl: 30` 已移除，KV 写入 TTL 最低为 60 秒。[4]

### 2.5 绑定统一入口

Worker → **Settings → Domains & Routes → Add → Custom Domain**，填写 `api.996668.xyz`（不加 `https://` 或 `/*`）→ **Add Custom Domain**。[5]

域名须在当前账号的有效 Cloudflare Zone 内。若 `api` 已有 CNAME，先记录旧值，安排切换窗口并移除冲突记录；Cloudflare 为 Custom Domain 自动创建 DNS 和证书。**保留 `kapi`、`dapi` 的 Tunnel 记录**，不要额外创建覆盖所有子域名的 Worker Route。[5]

## 3. 用一次演练确认能用

在能访问三个域名的终端执行（Bash）：

```bash
read -rsp 'CPA API Key: ' TOKEN; echo
for HOST in kapi.996668.xyz dapi.996668.xyz api.996668.xyz; do
  printf '\n--- %s ---\n' "$HOST"
  curl -sS -i --max-time 20 -H "Authorization: Bearer $TOKEN" "https://$HOST/v1/models"
done
unset TOKEN
```

| 演练 | 预期 |
|---|---|
| 两台运行，`mode=auto` | 三个地址均为模型列表；统一入口响应头 `X-HA-Origin: primary` |
| 在国外执行 `docker stop CPA_CONTAINER` | 新请求探测主站失败后走国内，响应头 `X-HA-Origin: backup`；首次可能多等约 5 秒 |
| 主站保持停止，将 KV `mode` 改为 `backup` | 从实际客户端反复确认 `X-HA-Mode: backup`；不要仅凭一次请求或固定等待认定全网生效 |
| 通过统一入口做一次普通模型调用和一次 SSE 调用 | 国内独立出站成功；检查首字节、持续输出、结束信号；使用实际模型名和测试 Key |
| 主站恢复后先保持 `backup` 并完成回灌，再允许回切 | 校验主站含备站接管期间的新数据；未实施自动化时按第 4 节应急流程处理 |

补测：所选节点都停机时应为 503；无效客户端 Key 应被 CPA 拒绝。**探测通过后业务请求若断连，返回 502，不再切备重放；源站 4xx/5xx 原样返回。** 已开始的 SSE 中断不续传。现有代码在主站恢复响应时，`auto` 会自动回切，并不等待数据验收；数据自动化必须增加服务器侧启动/就绪保护，或另行实现等效选路保护，避免旧主提前响应探测。

本示例针对普通 HTTP / SSE；WebSocket、其他协议和大请求体 **待验证**。Worker → **Observability** 查看错误，不记录 Key 或认证文件内容。[8]

## 4. 数据同步与故障接管：只记这张表

### 4.1 现有主备开关

在 **Workers KV → CPA_HA_STATE → KV Pairs** 编辑已有的 `mode` 项：

| 值 | 行为 | 什么时候用 |
|---|---|---|
| `auto` | 主站优先，探测失败才用备站；恢复后自动回主 | 数据就绪后的日常运行；本值不提供数据保护 |
| `backup` | 只用国内，国内故障则 503 | 国内接管、国外修复及回灌期间 |
| `primary` | 只用国外，国外故障则 503 | 排查或临时回退为单节点 |
| `pause` | 返回 503，不发业务请求 | 应急维护或最终交接窗口，不用于日常周期备份 |

**故障接管：** 主站故障后尽快设 `backup`，暂停已有的国外→国内同步任务，并在服务器/云控制台停止或隔离旧主，防止它重启后携带旧数据参与服务。KV 和 Tunnel 状态都不代替服务器隔离；两台常驻时仍可能各自刷新认证，这不是严格单写方案。[4]

### 4.2 日常目标：轻量自动备份与恢复

采用 `rsync + SSH + Linux 定时任务 + 备机本地历史快照`，详见 [完整方案](2026-11-05_部署-CPA双机主备-report.md)。**这部分是待实施方案，不是上方 Worker 已具备的功能。**

| 状态 | 服务节点 | 复制与备份方向 |
|---|---|---|
| 主站正常 | 主站 | 每 2 分钟检查主→备；先暂存校验，再发布有效副本 |
| 主站宕机、备站接管 | 备站 | 停止主→备，以备站数据为准，继续本地历史快照 |
| 主站重新上线 | 仍为备站 | 主站保持待恢复；先备→主，校验及最后增量完成后再回切 |
| 回切完成 | 主站 | 恢复主→备，拒绝旧角色迟到任务发布 |

建议备机每小时保存一次历史快照、保留 7 天；每次覆盖前另存目标原数据。角色不明、文件损坏、同步失败时保留原有效版本并告警。日常备份不停止服务节点；恢复目标可能自动重启，最终交接可能短暂中断。

**先回灌，再回切。** 主机上线、Docker 重启或 CPA 自动重启均需经过待恢复检查；仅切 KV 不替代启动保护。应用待机数据期间不接业务；若待机 CPA 采用接管时启动，需要配套恢复脚本，现有 Worker 不会替它启动容器。

### 4.3 应急人工恢复：不是日常定时流程

以下保留原有双机停机命令，用于自动化尚未落地或经确认需要人工处理的应急场景；不要直接把这些命令塞进定时任务。同步始终按当前权威源单向执行，不建双向盲目覆盖任务。

<details>
<summary>展开：应急人工同步或回灌（停止两台 CPA，会中断服务）</summary>

1. 选择权威源：正常为国外→国内；国内接管后的回灌为国内→国外。设 `mode=pause`，暂停现有同步任务，**在两台分别执行 `docker stop CPA_CONTAINER`**，确认无其他进程写认证目录。
2. 在目标机执行下面命令。假定实际目录已核实为 `/root/cpa/auths` 和 `/root/cpa/config.yaml`；否则先修改路径。两台需安装 rsync，SSH 应使用密钥并通过可信渠道核对源机主机指纹；`HOST` 是可达 SSH 地址，不是 CPA HTTP 域名。只走 Tunnel 的 SSH 需先配置可用的 SSH/Access 通道。

```bash
# 在接收数据的目标机执行；HOST 换成权威源机的 SSH 地址。
set -e
umask 077
SNAP="/root/cpa-before-sync-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$SNAP" -C /root/cpa config.yaml auths
rsync -acni --delete -e 'ssh -o StrictHostKeyChecking=yes' \
  root@HOST:/root/cpa/auths/ /root/cpa/auths/
read -rp '核对上方覆盖/删除清单，输入 YES 才继续: ' CONFIRM
test "$CONFIRM" = YES
rsync -aci --delete -e 'ssh -o StrictHostKeyChecking=yes' \
  root@HOST:/root/cpa/auths/ /root/cpa/auths/
rsync -acni --delete -e 'ssh -o StrictHostKeyChecking=yes' \
  root@HOST:/root/cpa/auths/ /root/cpa/auths/
```

3. 最后一条应无差异输出，所有命令成功才继续。配置文件单独比较：同步 API Key/模型等必要配置，保留各机代理、路径等差异；不整目录覆盖 Compose，不手工合并冲突 token。命令失败就保持停机，先查原因。
4. 按本节基础双常驻部署，用 `docker start CPA_CONTAINER` 启动两台，重复第 3 节直连检查及真实模型测试。回灌后先保持 `backup`，确认国外数据和调用正常，再改 `auto`。**本节应急流程结束时备站保持运行**；若已实施启动/就绪保护，应通过配套流程恢复，不用裸启动命令跳过保护。

快照包含密钥，保留在权限受限目录；它是同机回滚副本，不是异地灾备。回滚认证目录时先停容器，再从对应快照恢复原挂载路径，检查后启动；不要在运行中改名替换 bind mount 目录。

</details>

## 5. 常见问题与最终检查

| 现象 | 先查什么 |
|---|---|
| 503，`Configuration or KV unavailable` | `HA_STATE` 绑定、变量、KV 用量；缺少/拼错 `mode` 也会拒绝请求 |
| 503，`Selected origin unhealthy` | 对应域名的 `/v1/models`、Key、Tunnel 服务地址；HTML 登录页/Access 挑战不是健康响应 |
| 模型列表正常，但真实请求失败 | 国内上游出站、凭据和模型配置；不能只看 Tunnel 的 Healthy |
| KV 改了但未切换 | 等待传播并从实际客户端复测；维修期间旧主继续隔离 |
| 入口绑定失败 | `api` 同名 CNAME、Zone 所属账号、是否误选 Route |

免费额度不是无限：当前 Workers Free 为 **10 万请求/日**；KV Free 为 **10 万读取/日、1,000 写入/日**，同账号其他用途也占额度。本版每个有效配置下的入口请求读一次 KV，业务请求另有 1–2 次源站健康探测；超额或 KV 故障可能导致入口不可用。[9]

- [ ] 主备域名分别可用，统一入口确实返回 `X-HA-Origin`。
- [ ] 停主站后，备站的真实模型请求和 SSE 均通过。
- [ ] 凭据备份、单向恢复和回切已实际演练，待机方式与部署方案一致。
- [ ] 数据自动化实施后：主重启不会提前接流量；先备→主再回切；旧角色任务不覆盖新数据。
- [ ] 数据自动化实施后：历史快照保留及恢复通过，运行中备份的完整性与 OAuth 刷新行为已验证。
- [ ] 需要回退时设 `primary` 或让客户端暂用健康的原入口；**先确认数据权威节点，不直接删除 Custom Domain**。

### 核对依据

历史手册记录：30 项 Worker 模拟测试、3 段 Bash 语法检查通过，原测试用例未随本仓库提供。本轮保持 Worker 与 Bash 代码不变，更新数据方案及状态说明；本地检查和模拟测试均不代表 Cloudflare 边缘、真实服务器或自动备份已经验收。

[1] [Tunnel 当前创建与 Routes 界面](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)；[2] [Worker / KV 创建、Bindings、KV Pairs](https://developers.cloudflare.com/kv/get-started/)；[3] [Secrets](https://developers.cloudflare.com/workers/configuration/secrets/) / [环境变量](https://developers.cloudflare.com/workers/configuration/environment-variables/)。

[4] [KV 写入 TTL](https://developers.cloudflare.com/kv/api/write-key-value-pairs/) / [一致性](https://developers.cloudflare.com/kv/concepts/how-kv-works/)；[5] [Custom Domain 界面及 DNS 前提](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)。

[6] [CPA 官方 Compose](https://github.com/router-for-me/CLIProxyAPI/blob/main/docker-compose.yml) / [配置示例](https://github.com/router-for-me/CLIProxyAPI/blob/main/config.example.yaml)；[7] [Docker 端口绑定](https://docs.docker.com/engine/network/port-publishing/) / [容器网络](https://docs.docker.com/engine/network/)；[8] [Workers Logs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/) / [Request API](https://developers.cloudflare.com/workers/runtime-apis/request/)；[9] [Workers 限制](https://developers.cloudflare.com/workers/platform/limits/) / [KV 计费](https://developers.cloudflare.com/kv/platform/pricing/)。
