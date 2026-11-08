const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const root = path.join(__dirname, "../..");
const ui = require(path.join(root, "www/app.js"));
const config = {node_role:"primary", enabled:false, allowed_root:"/data", sources:[{name:"auths",kind:"directory",path:"/data/auths"}]};
const values = {primaryHost:"HOST", primaryPort:"2222", backupHost:"standby-fixture", backupPort:"2222", backupBindHost:"0.0.0.0", dataDir:"/srv/cpa-fixture", deployment:"docker", output:"", ttlSeconds:"1800", autoEnable:true};

test("enrollment serializer forwards bounded install choices without permanent secrets", () => {
  const data = ui.buildEnrollment(config, values);
  assert.deepEqual(data, {primary_host:"HOST",primary_port:2222,backup_host:"standby-fixture",backup_port:2222,backup_bind_host:"0.0.0.0",data_dir:"/srv/cpa-fixture",deployment:"docker",ttl_seconds:1800,auto_enable:true});
  assert.equal(data.admin_token, undefined);
  assert.equal(data.private_key, undefined);
  assert.equal(ui.buildEnrollment(config, {...values,output:"/srv/cpa-deploy-fixture"}).output, "/srv/cpa-deploy-fixture");
  assert.equal(ui.buildEnrollment(config, {...values,deployment:"native",autoEnable:false}).auto_enable, false);
});

test("enrollment refuses unsafe endpoints, paths, roles and schedule state", () => {
  for (const change of [{primaryHost:"HOST;id"},{backupHost:""},{backupPort:"65536"},{primaryPort:"0"},{backupBindHost:"HOST\n"},{dataDir:"relative"},{dataDir:"/srv/../root"},{dataDir:"/"},{output:"/srv/$secret"},{ttlSeconds:"59"},{ttlSeconds:"86401"},{deployment:"shell"}]) {
    assert.throws(() => ui.buildEnrollment(config,{...values,...change}));
  }
  assert.throws(() => ui.buildEnrollment({...config,node_role:"backup"},values), /主机/);
  assert.throws(() => ui.buildEnrollment({...config,enabled:true},values), /停用/);
  assert.throws(() => ui.buildEnrollment({...config,sources:[]},values), /内容/);
});

test("invitation controls isolate their form and clear secrets on logout", () => {
  const html = fs.readFileSync(path.join(root,"www/index.html"),"utf8");
  const js = fs.readFileSync(path.join(root,"www/app.js"),"utf8");
  for (const id of ["enrollment-open","enrollment-dialog","enrollment-form","enrollment-preview","enrollment-confirm","enrollment-create","enrollment-command","enrollment-copy","enrollment-list","enrollment-refresh"]) assert.ok(html.includes(`id="${id}"`), id);
  assert.ok(html.indexOf('id="enrollment-form"') > html.indexOf('</form>',html.indexOf('id="config-form"')));
  assert.ok(js.includes('$("enrollment-command").value = ""'));
  assert.ok(js.includes("enrollmentSession"));
  assert.ok(!js.includes("localStorage"));
  assert.ok(!js.includes(".innerHTML"));
  assert.ok(js.includes("/api/enrollment/revoke"));
});

test("issued and registered backend invitations remain revocable after the command is cleared", () => {
  assert.deepEqual(ui.enrollmentStatus("issued"), {label:"等待备机执行",revocable:true});
  assert.deepEqual(ui.enrollmentStatus("registered"), {label:"已注册 · 等待首备",revocable:true});
  for (const status of ["committing","completed","revoked","expired","pending","claimed","unknown"]) assert.equal(ui.enrollmentStatus(status).revocable,false,status);
});
