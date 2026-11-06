"use strict";

/** Pure form helpers are also used by the dependency-free Node tests. */
const CPAUI = (() => {
  const sourceKinds = new Set(["auto", "file", "directory", "sqlite"]);
  function formatBytes(value) {
    if (value === null || value === undefined || !Number.isFinite(Number(value))) return "—";
    const bytes = Number(value);
    if (bytes < 1024) return `${bytes} B`;
    const units = ["KiB", "MiB", "GiB", "TiB"];
    const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)) - 1, units.length - 1);
    return `${(bytes / 1024 ** (index + 1)).toFixed(1)} ${units[index]}`;
  }
  function validateSource(source) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(source.name || "")) return "数据标签须以字母或数字开头，仅使用字母、数字、下划线和短横线，最多 64 位。";
    if (!source.path || !source.path.startsWith("/") || /[\x00-\x1f\x7f\\]/.test(source.path)) return "备份内容须填写不含控制字符或反斜线的本机绝对路径。";
    if (!sourceKinds.has(source.kind)) return "请选择有效的备份类型。";
    return "";
  }
  function integer(value, label) {
    const number = Number(value);
    if (!Number.isSafeInteger(number) || number < 1) throw new Error(`${label}须填写正整数。`);
    return number;
  }
  function buildConfig(current, values) {
    const names = new Set();
    for (const source of values.sources) {
      const error = validateSource(source);
      if (error) throw new Error(error);
      if (names.has(source.name)) throw new Error(`数据标签重复：${source.name}`);
      names.add(source.name);
    }
    if (!["primary", "backup"].includes(values.role)) throw new Error("请选择主服务器或备服务器。");
    if (!["none", "docker", "systemd"].includes(values.driver)) throw new Error("请选择有效的 CPA 管理方式。");
    if (values.peerHost && !/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(values.peerHost.trim())) throw new Error("SSH 地址仅允许主机名或 IP，不填写 Shell 命令。");
    if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(values.peerUser.trim())) throw new Error("请填写有效的 SSH 用户名。");
    if (integer(values.peerPort, "SSH 端口") > 65535) throw new Error("SSH 端口须在 1 到 65535 之间。");
    return {
      node_id: current.node_id,
      allowed_root: current.allowed_root,
      node_role: values.role,
      enabled: Boolean(values.enabled),
      interval_seconds: integer(values.interval, "同步间隔"),
      secondary_interval_seconds: integer(values.secondaryInterval, "二次备份间隔"),
      retention_count: integer(values.retention, "保留份数"),
      max_snapshot_bytes: integer(values.maxBytes, "容量上限"),
      sources: values.sources,
      peer: {host: values.peerHost.trim(), port: integer(values.peerPort, "SSH 端口"), user: values.peerUser.trim(), identity_file: values.identityFile.trim(), known_hosts_file: values.knownHostsFile.trim(), node_id: values.peerId.trim()},
      service: {driver: values.driver, name: values.serviceName.trim(), timeout_seconds: integer(values.serviceTimeout, "启停超时")},
    };
  }
  function validateConfirmation(expected, entered, flags) {
    if (entered !== expected) return `请输入完整的确认文字 ${expected}。`;
    if (flags.some(flag => !flag)) return "请检查并勾选全部隔离／停机确认项。";
    return "";
  }
  function jobOutcome(job, label) {
    if (job.running || !job.finished_at) return null;
    return {
      message: job.error ? `${label}失败：${job.error}` : `${label}已完成。请核对数据与业务验证结果。`,
      error: Boolean(job.error),
    };
  }
  return {formatBytes, validateSource, buildConfig, validateConfirmation, jobOutcome};
})();
if (typeof module !== "undefined") module.exports = CPAUI;

if (typeof document !== "undefined") {
  document.addEventListener("DOMContentLoaded", () => {
    const $ = id => document.getElementById(id);
    const state = {token: "", config: null, status: {}, snapshots: [], panel: "overview", busy: false, dialog: null, polling: false, manualJob: null, pinnedFailure: ""};
    const roleNames = {primary: "主服务器", backup: "备服务器"};
    const phaseNames = {unconfigured: "等待配置", primary_active: "主机服务中", backup_standby: "备机待命", backup_active: "备机已接管", primary_recovering: "主机待恢复", promoting: "正在接管", paused: "保护态 · 已暂停", failback_failed: "回灌失败 · 已保护", handover_pending: "最终交接中"};
    const actionNames = {backup: "备份", secondary: "二次备份", restore: "恢复", promote: "备机接管", "prepare-recovery": "主机准备恢复", failback: "最终回灌", pause: "暂停", resume: "恢复调度", verify: "校验"};
    const purposeNames = {scheduled: "定时备份", manual: "手动备份", secondary: "二次备份", rollback: "覆盖前回滚", handover: "最终交接", received: "对端副本"};
    let sourceIndex = 0;
    let messageTimer;

    function element(tag, text, className) {
      const node = document.createElement(tag);
      if (text !== undefined) node.textContent = text;
      if (className) node.className = className;
      return node;
    }
    function date(value) {
      if (!value) return "—";
      if (typeof value === "object") value = value.created_at || value.completed_at || value.finished_at || value.at;
      if (!value) return "—";
      const parsed = new Date(value);
      return Number.isNaN(parsed.getTime()) ? String(value) : parsed.toLocaleString("zh-CN", {hour12: false});
    }
    function showMessage(message, error = false, persistent = false) {
      if (state.pinnedFailure && !error) return;
      clearTimeout(messageTimer);
      if (persistent && error) state.pinnedFailure = message;
      $("global-message").textContent = message;
      $("global-message").classList.toggle("error", error);
      $("global-message").hidden = false;
      if (!error) messageTimer = setTimeout(() => { $("global-message").hidden = true; }, 8000);
    }
    function setBusy(value) {
      state.busy = value;
      for (const id of ["login-button", "save-config", "save-enable", "test-peer", "backup-now", "dialog-submit"]) $(id).disabled = value;
      if (!value) $("backup-now").disabled = Boolean(state.status.job?.running);
      $("dialog-submit").textContent = value ? "正在提交…" : "确认执行";
    }
    async function request(path, method = "GET", body) {
      const headers = {Authorization: `Bearer ${state.token}`};
      if (body !== undefined) headers["Content-Type"] = "application/json";
      const response = await fetch(path, {method, headers, body: body === undefined ? undefined : JSON.stringify(body), cache: "no-store", credentials: "omit"});
      let data;
      try { data = await response.json(); } catch { throw new Error(`服务返回了非 JSON 响应（HTTP ${response.status}）。请检查服务及反向代理。`); }
      if (!response.ok) {
        if (response.status === 401 && !$("app-shell").hidden) logout("登录令牌已失效，请重新登录。");
        throw new Error(typeof data.error === "string" ? data.error : data.message || `操作失败（HTTP ${response.status}）。`);
      }
      return data;
    }
    function logout(message = "") {
      state.token = "";
      state.config = null;
      state.manualJob = null;
      state.pinnedFailure = "";
      $("app-shell").hidden = true;
      $("login-screen").hidden = false;
      $("admin-token").value = "";
      $("local-public-key").value = "";
      $("peer-public-key").value = "";
      $("pairing-secret").hidden = true;
      $("login-error").textContent = message;
      if ($("action-dialog").open) $("action-dialog").close();
    }
    function panel(name) {
      state.panel = name;
      for (const node of document.querySelectorAll(".panel")) node.hidden = node.id !== `panel-${name}`;
      for (const node of document.querySelectorAll(".nav-button")) node.classList.toggle("active", node.dataset.panel === name);
      $("page-breadcrumb").textContent = {overview: "运行概览", config: "节点配置", snapshots: "备份历史", recovery: "接管与回灌"}[name];
      if (name === "snapshots") refreshSnapshots().catch(error => showMessage(error.message, true));
    }
    function renderStatus(status) {
      state.status = status;
      const config = state.config || {};
      const role = roleNames[status.node_role] || "未配置";
      const phase = phaseNames[status.phase] || status.phase || "等待配置";
      $("sidebar-role").textContent = role;
      $("metric-role").textContent = role;
      $("metric-phase").textContent = phase;
      $("metric-enabled").textContent = config.enabled ? "已启用" : "未启用";
      $("metric-interval").textContent = config.enabled ? `同步 ${config.interval_seconds} 秒 · 二次 ${config.secondary_interval_seconds} 秒` : "保存配置并启用后自动执行";
      $("metric-last-backup").textContent = date(status.last_backup);
      $("metric-last-replication").textContent = status.last_replication ? `最近传输 ${date(status.last_replication)}` : "尚无成功传输记录";
      $("overview-node-id").textContent = status.node_id || "—";
      $("node-epoch").textContent = String(status.epoch ?? "—");
      const peer = status.peer || {};
      $("peer-status").textContent = peer.configured ? peer.reachable ? "已配对 · 可达" : "已配置 · 待检查" : "尚未配对";
      if (peer.last_error) $("peer-status").textContent = `连接异常：${peer.last_error}`;
      $("topology-mode").textContent = phase;
      $("flow-label").textContent = status.phase === "backup_active" ? "备机权威" : status.phase === "primary_recovering" ? "待回灌" : "主 → 备";
      $("primary-status").textContent = status.phase === "backup_active" || status.phase === "primary_recovering" ? "保持隔离 · 等待恢复" : "正常时提供服务";
      $("backup-status").textContent = status.phase === "backup_active" ? "已接管 · 保留新数据" : "接收副本与历史快照";
      const job = status.job || {};
      $("job-title").textContent = job.running ? `${actionNames[job.action] || job.action || "任务"}执行中` : job.error ? "上次任务失败" : job.finished_at ? "上次任务已完成" : "当前无任务";
      $("job-detail").textContent = job.running ? "任务不重入，请等待当前操作完成。" : job.finished_at ? `结束时间 ${date(job.finished_at)}` : "启用定时任务后自动运行。";
      $("job-error").textContent = job.error || "";
      $("onboarding").hidden = Boolean(config.enabled && peer.configured);
      $("connection").textContent = "本机已连接";
      $("connection").classList.remove("error");
      $("promote").disabled = status.node_role !== "backup" || job.running || status.phase === "backup_active";
      $("prepare-recovery").disabled = status.node_role !== "primary" || job.running;
      $("failback").disabled = status.node_role !== "primary" || job.running || !["primary_recovering", "failback_failed"].includes(status.phase);
      if (!state.busy) $("backup-now").disabled = Boolean(job.running);
    }
    async function refreshStatus() {
      const status = await request("/api/status");
      const pending = state.manualJob;
      if (pending) {
        const job = await request(`/api/jobs/${encodeURIComponent(pending.id)}`);
        status.job = job;
        const outcome = CPAUI.jobOutcome(job, actionNames[pending.action] || pending.action);
        if (outcome) {
          state.manualJob = null;
          showMessage(outcome.message, outcome.error, outcome.error);
        }
      }
      renderStatus(status);
    }
    function trackJob(result, action) {
      if (!result.job_id) throw new Error("任务响应缺少作业 ID，请核对服务端状态。");
      state.pinnedFailure = "";
      state.manualJob = {id: result.job_id, action};
    }
    function addSource(source = {name: "", path: "", kind: "auto"}) {
      const index = ++sourceIndex;
      const row = element("div", undefined, "source-row");
      row.dataset.sourceRow = "true";
      for (const [field, title, placeholder] of [["name", "数据标签", "例如 auths"], ["path", "本机绝对路径", "/data/auths"]]) {
        const wrapper = element("div");
        const label = element("label", title);
        const input = element("input");
        input.id = `source-${index}-${field}`;
        label.htmlFor = input.id;
        input.dataset.field = field;
        input.value = source[field] || "";
        input.placeholder = placeholder;
        input.required = true;
        input.autocomplete = "off";
        wrapper.append(label, input);
        row.append(wrapper);
      }
      const wrapper = element("div");
      const label = element("label", "备份类型");
      const select = element("select");
      select.id = `source-${index}-kind`;
      select.dataset.field = "kind";
      label.htmlFor = select.id;
      for (const [value, title] of [["auto", "自动识别"], ["directory", "目录"], ["file", "普通文件"], ["sqlite", "SQLite 一致性备份"]]) {
        const option = element("option", title);
        option.value = value;
        select.append(option);
      }
      select.value = source.kind || "auto";
      wrapper.append(label, select);
      row.append(wrapper);
      const remove = element("button", "移除", "source-remove");
      remove.type = "button";
      remove.setAttribute("aria-label", `移除第 ${index} 项备份内容`);
      remove.addEventListener("click", () => { row.remove(); $("sources-empty").hidden = Boolean($("sources-list").children.length); });
      row.append(remove);
      $("sources-list").append(row);
      $("sources-empty").hidden = true;
    }
    function renderConfig(config) {
      state.config = config;
      const fields = {"node-role": config.node_role, interval: config.interval_seconds, "secondary-interval": config.secondary_interval_seconds, retention: config.retention_count, "max-bytes": config.max_snapshot_bytes, "config-node-id": config.node_id, "peer-host": config.peer?.host || "", "peer-port": config.peer?.port || 22, "peer-user": config.peer?.user || "root", "identity-file": config.peer?.identity_file || "/state/ssh/id_ed25519", "known-hosts-file": config.peer?.known_hosts_file || "/state/ssh/known_hosts", "peer-node-id": config.peer?.node_id || "", "service-driver": config.service?.driver || "none", "service-name": config.service?.name || "", "service-timeout": config.service?.timeout_seconds || 60};
      for (const [id, value] of Object.entries(fields)) $(id).value = value ?? "";
      $("enabled").checked = Boolean(config.enabled);
      $("sources-list").replaceChildren();
      for (const source of config.sources || []) addSource(source);
      $("sources-empty").hidden = Boolean(config.sources?.length);
      renderStatus(state.status);
    }
    function collectConfig(enabledOverride) {
      const values = {role: $("node-role").value, enabled: enabledOverride ?? $("enabled").checked, interval: $("interval").value, secondaryInterval: $("secondary-interval").value, retention: $("retention").value, maxBytes: $("max-bytes").value, peerHost: $("peer-host").value, peerPort: $("peer-port").value, peerUser: $("peer-user").value, identityFile: $("identity-file").value, knownHostsFile: $("known-hosts-file").value, peerId: $("peer-node-id").value, driver: $("service-driver").value, serviceName: $("service-name").value, serviceTimeout: $("service-timeout").value, sources: []};
      for (const row of $("sources-list").children) {
        const source = {};
        for (const input of row.querySelectorAll("[data-field]")) source[input.dataset.field] = input.value.trim();
        values.sources.push(source);
      }
      return CPAUI.buildConfig(state.config, values);
    }
    async function saveConfig(mode = "save") {
      $("config-error").textContent = "";
      setBusy(true);
      try {
        if (!$("config-form").reportValidity()) return;
        const config = collectConfig(mode === "enable" ? false : undefined);
        await request("/api/config", "PUT", config);
        if (mode !== "save") await request("/api/actions/test-peer", "POST", {});
        if (mode === "enable") {
          const paired = await request("/api/config");
          paired.enabled = true;
          await request("/api/config", "PUT", paired);
        }
        renderConfig(await request("/api/config"));
        await refreshStatus();
        showMessage(mode === "enable" ? "配对成功，定时备份已启动。" : mode === "pair" ? "配置已保存，对端身份校验通过。" : "配置已保存。");
      } catch (error) {
        $("config-error").textContent = error.message;
        showMessage(error.message, true);
      } finally { setBusy(false); }
    }
    function renderSnapshots(snapshots) {
      state.snapshots = snapshots;
      $("snapshots-body").replaceChildren();
      let total = 0;
      for (const snapshot of snapshots) {
        total += Number(snapshot.total_bytes || 0);
        const row = element("tr");
        const idCell = element("td");
        idCell.append(element("div", snapshot.id, "snapshot-id"), element("small", date(snapshot.created_at)));
        const sourceCell = element("td");
        sourceCell.append(element("strong", roleNames[snapshot.node_role] || snapshot.node_role || "—"), element("small", String(snapshot.node_id || "—").slice(0, 16)));
        const purposeCell = element("td");
        purposeCell.append(element("span", purposeNames[snapshot.purpose] || snapshot.purpose || "副本", "tag"));
        const sizeCell = element("td");
        sizeCell.append(element("strong", CPAUI.formatBytes(snapshot.total_bytes)), element("small", `${snapshot.file_count || 0} 个文件`));
        const actions = element("td");
        const wrapper = element("div", undefined, "table-actions");
        const verify = element("button", "校验", "text-button");
        verify.type = "button";
        verify.addEventListener("click", () => verifySnapshot(snapshot.id, verify));
        const restore = element("button", "预览 / 恢复", "text-button");
        restore.type = "button";
        restore.addEventListener("click", () => openDialog("restore", snapshot.id));
        wrapper.append(verify, restore);
        actions.append(wrapper);
        row.append(idCell, sourceCell, purposeCell, sizeCell, actions);
        $("snapshots-body").append(row);
      }
      $("snapshots-empty").hidden = snapshots.length > 0;
      $("snapshots-summary").textContent = `${snapshots.length} 个有效恢复点 · 清单与 SHA256 可复验`;
      $("metric-count").textContent = String(snapshots.length);
      $("metric-size").textContent = snapshots.length ? `快照逻辑容量 ${CPAUI.formatBytes(total)}` : "等待第一份有效快照";
    }
    async function refreshSnapshots() {
      const result = await request("/api/snapshots");
      renderSnapshots(result.snapshots || []);
    }
    async function verifySnapshot(id, button) {
      button.disabled = true;
      try {
        await request("/api/actions/verify", "POST", {snapshot_id: id});
        showMessage(`快照校验通过：${id}`);
      } catch (error) { showMessage(error.message, true); }
      finally { button.disabled = false; }
    }
    async function trigger(action, body = {}) {
      setBusy(true);
      try {
        const result = await request(`/api/actions/${action}`, "POST", body);
        trackJob(result, action);
        showMessage(`${actionNames[action] || "操作"}任务已提交，请查看任务状态和最终结果。`);
        await refreshStatus();
      } catch (error) { showMessage(error.message, true); }
      finally { setBusy(false); }
    }
    const dialogActions = {
      restore: {title: "恢复历史快照", word: "RESTORE", description: "此操作按数据标签恢复到本机配置的目标，并反映删除。覆盖前保留原数据；恢复完成保持 CPA 停机，不自动接管或启动。", snapshot: true, flags: [["quiesced", "目标 CPA 已停止全部写入；恢复后我核验唯一权威角色，再按需启动并验证真实调用。"]]},
      promote: {title: "备机确认接管", word: "PROMOTE", description: "将选中的主机有效副本恢复到备机本地目标，并将备机标记为权威。旧主副本后续不再覆盖备机。", snapshot: true, flags: [["fenced", "旧主 CPA 已停止或被隔离，自动重启及所有直连写入路径已处理。"], ["quiesced", "本机目标 CPA 已停止写入，备机恢复路径与容器权限已核对。"]]},
      "prepare-recovery": {title: "主机进入待恢复", word: "RECOVER", description: "将主机置于待恢复状态，禁止主→备发布；确认备机已接管，主机业务入口继续隔离。", flags: [["quiesced", "旧主 CPA 已停止写入；使用人工方式时已在主机实际执行停机。"]]},
      failback: {title: "最终回灌与交接", word: "FAILBACK", description: "备机暂停后生成最终副本，再回灌主机并完成角色交接。存在维护窗口；失败时保持保护态，不盲目启动旧数据。", flags: [["quiesced", "主机 CPA 已停止、入口隔离，数据目标可写且已安排维护窗口。"], ["backup_quiesced", "备机在途请求已排空，全部写入与后台刷新已停止；人工方式已真实停止备机 CPA。"]]},
      resume: {title: "确认恢复调度", word: "RESUME", description: "仅恢复此前由管理员明确暂停的权威角色调度，不启动 CPA。交接失败产生的保护态须按对应恢复流程处理。", flags: [["authoritative", "已核对当前节点仍是唯一权威，对端未接管或存在冲突；实际 CPA 与入口由我管理。"]]},
      pause: {title: "暂停并进入保护态", word: "PAUSE", description: "停止新调度与发布并进入持久保护状态。这不等同于停止 CPA 或关闭 Cloudflare 入口。", flags: []},
    };
    async function loadRestorePlan() {
      const id = $("dialog-snapshot").value;
      if (!id) throw new Error("请选择有效快照。");
      $("dialog-plan").hidden = false;
      $("dialog-plan-text").textContent = "正在读取本机恢复目标与差异…";
      const result = await request("/api/actions/restore-plan", "POST", {snapshot_id: id});
      $("dialog-plan-text").textContent = JSON.stringify(result, null, 2);
    }
    async function openDialog(action, snapshotId) {
      const options = dialogActions[action];
      state.dialog = {action, options};
      $("dialog-title").textContent = options.title;
      $("dialog-description").textContent = options.description;
      $("dialog-confirm-word").textContent = options.word;
      $("dialog-confirm").value = "";
      $("dialog-error").textContent = "";
      $("dialog-plan").hidden = true;
      $("dialog-snapshot-field").hidden = !options.snapshot;
      $("dialog-flags").replaceChildren();
      for (const [key, text] of options.flags) {
        const label = element("label");
        const input = element("input");
        input.type = "checkbox";
        input.dataset.flag = key;
        label.append(input, element("span", text));
        $("dialog-flags").append(label);
      }
      $("action-dialog").showModal();
      if (!options.snapshot) return;
      $("dialog-submit").disabled = true;
      try {
        await refreshSnapshots();
        $("dialog-snapshot").replaceChildren();
        const snapshots = action === "promote" ? state.snapshots.filter(item => item.node_role === "primary" && item.purpose !== "rollback") : state.snapshots;
        for (const snapshot of snapshots) {
          const option = element("option", `${date(snapshot.created_at)} · ${snapshot.id} · ${CPAUI.formatBytes(snapshot.total_bytes)}`);
          option.value = snapshot.id;
          $("dialog-snapshot").append(option);
        }
        if (snapshotId) $("dialog-snapshot").value = snapshotId;
        if (!snapshots.length) throw new Error("当前没有可用于本操作的有效快照。请先完成备份并核对恢复映射。");
        await loadRestorePlan();
        $("dialog-submit").disabled = false;
      } catch (error) { $("dialog-error").textContent = error.message; }
    }
    $("login-form").addEventListener("submit", async event => {
      event.preventDefault();
      setBusy(true);
      $("login-error").textContent = "";
      state.token = $("admin-token").value.trim();
      try {
        const [status, config] = await Promise.all([request("/api/status"), request("/api/config")]);
        $("admin-token").value = "";
        $("login-screen").hidden = true;
        $("app-shell").hidden = false;
        state.status = status;
        renderConfig(config);
        await refreshSnapshots();
      } catch (error) { logout(error.message); }
      finally { setBusy(false); }
    });
    $("config-form").addEventListener("submit", event => { event.preventDefault(); saveConfig("save"); });
    $("save-enable").addEventListener("click", () => saveConfig("enable"));
    $("test-peer").addEventListener("click", () => saveConfig("pair"));
    $("add-source").addEventListener("click", () => addSource());
    $("backup-now").addEventListener("click", () => trigger("backup", {replicate: true}));
    $("logout").addEventListener("click", () => logout());
    for (const button of document.querySelectorAll("[data-panel]")) button.addEventListener("click", () => panel(button.dataset.panel));
    for (const action of ["promote", "prepare-recovery", "failback", "pause", "resume"]) $(action).addEventListener("click", () => openDialog(action));
    for (const id of ["dialog-close", "dialog-cancel"]) $(id).addEventListener("click", () => $("action-dialog").close());
    $("dialog-snapshot").addEventListener("change", async () => {
      $("dialog-submit").disabled = true;
      $("dialog-error").textContent = "";
      try { await loadRestorePlan(); $("dialog-submit").disabled = false; }
      catch (error) { $("dialog-error").textContent = error.message; }
    });
    $("dialog-form").addEventListener("submit", async event => {
      event.preventDefault();
      const {action, options} = state.dialog;
      const inputs = [...$("dialog-flags").querySelectorAll("input")];
      const error = CPAUI.validateConfirmation(options.word, $("dialog-confirm").value.trim(), inputs.map(input => input.checked));
      if (error) { $("dialog-error").textContent = error; return; }
      const body = {confirm: options.word};
      for (const input of inputs) body[input.dataset.flag] = input.checked;
      if (options.snapshot) body.snapshot_id = $("dialog-snapshot").value;
      setBusy(true);
      try {
        const result = await request(`/api/actions/${action}`, "POST", body);
        trackJob(result, action);
        $("action-dialog").close();
        showMessage(`${options.title}任务已提交。请等待最终状态，业务入口由管理员核对后开放。`);
        await refreshStatus();
      } catch (failure) { $("dialog-error").textContent = failure.message; }
      finally { setBusy(false); }
    });
    $("reveal-pairing").addEventListener("click", async () => {
      try {
        const pairing = await request("/api/pairing");
        $("local-public-key").value = pairing.public_key;
        $("pairing-secret").hidden = false;
      } catch (error) { showMessage(error.message, true); }
    });
    $("hide-public-key").addEventListener("click", () => { $("local-public-key").value = ""; $("pairing-secret").hidden = true; });
    $("copy-public-key").addEventListener("click", async () => {
      try { await navigator.clipboard.writeText($("local-public-key").value); showMessage("本机 SSH 公钥已复制，可交给对端管理员导入。"); }
      catch { $("local-public-key").select(); showMessage("浏览器剪贴板不可用，已选中公钥，请手动复制。", true); }
    });
    $("trust-peer-key").addEventListener("click", async () => {
      try {
        const publicKey = $("peer-public-key").value.trim();
        if (!/^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$/.test(publicKey)) throw new Error("请粘贴完整的对端 Ed25519 SSH 公钥。");
        await request("/api/pairing", "POST", {public_key: publicKey});
        $("peer-public-key").value = "";
        showMessage("对端公钥已导入为受限备份 RPC，不允许普通 Shell 登录。仍须在服务器核对主机指纹并登记 known_hosts。");
      } catch (error) { showMessage(error.message, true); }
    });
    async function refreshAll() {
      try { await refreshStatus(); await refreshSnapshots(); }
      catch (error) { showMessage(error.message, true); }
    }
    $("refresh").addEventListener("click", refreshAll);
    $("refresh-snapshots").addEventListener("click", () => refreshSnapshots().catch(error => showMessage(error.message, true)));
    setInterval(async () => {
      if (!state.token || state.polling || state.busy || document.hidden) return;
      state.polling = true;
      try { await refreshStatus(); if (state.panel === "snapshots" || state.panel === "overview" || state.status.job?.running) await refreshSnapshots(); }
      catch (error) { $("connection").textContent = "连接异常"; $("connection").classList.add("error"); showMessage(error.message, true); }
      finally { state.polling = false; }
    }, 3000);
  });
}
