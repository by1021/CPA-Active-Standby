const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const root = path.join(__dirname, "../..");
const ui = require(path.join(root, "www/app.js"));

test("byte formatter and source validation cover form boundaries", () => {
  assert.equal(ui.formatBytes(0), "0 B");
  assert.equal(ui.formatBytes(1024), "1.0 KiB");
  assert.equal(ui.formatBytes(null), "—");
  assert.equal(ui.validateSource({name: "auths", path: "/data/auths", kind: "directory"}), "");
  assert.match(ui.validateSource({name: "../auths", path: "/data/auths", kind: "directory"}), /标签/);
  assert.match(ui.validateSource({name: "auths", path: "relative", kind: "file"}), /绝对路径/);
  assert.match(ui.validateSource({name: "auths", path: "/data/auths", kind: "unknown"}), /类型/);
});

test("SSH configuration serializer preserves explicit role without peer secrets", () => {
  const data = ui.buildConfig({node_id: "fixture", allowed_root:"/data"}, {
    role: "backup", enabled: false, interval: "60", secondaryInterval: "3600", retention: "120",
    maxBytes: "1048576", peerHost: "HOST", peerPort: "22", peerUser: "root", identityFile: "/state/ssh/id_ed25519", knownHostsFile: "/state/ssh/known_hosts", peerId: "peer-fixture", driver: "none", serviceName: "", serviceTimeout: "60",
    sources: [{name:"auths",path:"/data/auths",kind:"directory"}]
  });
  assert.equal(data.node_role, "backup");
  assert.equal(data.peer.host, "HOST");
  assert.equal(data.peer.port, 22);
  assert.equal(data.peer.identity_file, "/state/ssh/id_ed25519");
  assert.equal(data.peer.token, undefined);
  assert.equal(data.allowed_root, "/data");
  assert.equal(data.interval_seconds, 60);
  assert.equal(data.sources[0].name, "auths");
  const values = {role:"primary", enabled:false, interval:"60", secondaryInterval:"3600", retention:"120", maxBytes:"1024", peerHost:"HOST", peerPort:"22", peerUser:"root", identityFile:"/state/ssh/id_ed25519", knownHostsFile:"/state/ssh/known_hosts", peerId:"", driver:"none", serviceName:"", serviceTimeout:"60", sources:[]};
  assert.throws(()=>ui.buildConfig({node_id:"fixture"},{...values,peerHost:"HOST; command"}), /SSH 地址/);
  assert.throws(()=>ui.buildConfig({node_id:"fixture"},{...values,peerPort:"65536"}), /SSH 端口/);
});

test("required destructive confirmation cannot be skipped", () => {
  assert.equal(ui.validateConfirmation("RESTORE", "RESTORE", [true]), "");
  assert.match(ui.validateConfirmation("RESTORE", "restore", [true]), /RESTORE/);
  assert.match(ui.validateConfirmation("PROMOTE", "PROMOTE", [false,true]), /勾选/);
});

test("assets expose critical controls without unsafe credential storage or HTML injection", () => {
  const js = fs.readFileSync(path.join(root,"www/app.js"),"utf8");
  const html = fs.readFileSync(path.join(root,"www/index.html"),"utf8");
  assert.ok(!js.includes("localStorage"));
  assert.ok(!js.includes(".innerHTML"));
  for(const id of ["login-form","config-form","node-role","interval","secondary-interval","add-source",
    "peer-host","peer-port","peer-user","identity-file","known-hosts-file","peer-public-key","trust-peer-key","test-peer","backup-now","snapshots-body","action-dialog","dialog-confirm","dialog-submit"]) {
    assert.ok(html.includes(`id="${id}"`), id);
  }
  for(const action of ["backup","verify","restore-plan","restore","promote","prepare-recovery","failback","pause","test-peer"]) {
    assert.ok(js.includes(`"${action}"`) || js.includes(`/api/actions/${action}`), action);
  }
});


test("manual job outcome distinguishes running, failed and completed jobs", () => {
  assert.equal(ui.jobOutcome({running:true,finished_at:null}, "备份"), null);
  assert.equal(ui.jobOutcome({running:false,finished_at:null}, "备份"), null);
  const failed = ui.jobOutcome({running:false,finished_at:"2026-11-06T00:00:00Z",error:"fixture transfer interrupted"}, "备份");
  assert.equal(failed.error, true);
  assert.match(failed.message, /fixture transfer interrupted/);
  const complete = ui.jobOutcome({running:false,finished_at:"2026-11-06T00:00:00Z",error:null}, "备份");
  assert.equal(complete.error, false);
  assert.match(complete.message, /已完成/);
  const source = fs.readFileSync(path.join(root,"www/app.js"),"utf8");
  assert.ok(source.includes("/api/jobs/"));
  assert.ok(source.includes("pinnedFailure"));
});
