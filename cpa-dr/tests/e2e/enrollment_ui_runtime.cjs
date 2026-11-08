// Run with NODE_PATH pointing to the optional Playwright developer installation.
// This serves real page assets against a deterministic fixture API; actual
// enrollment transport and install/first-backup are verified by the pair tests.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const root = path.join(__dirname, "../..");
const config = {node_role:"primary", enabled:false, allowed_root:"/data", sources:[{name:"auths",kind:"directory",path:"/data/auths"}]};

test("Chromium invitation confirmation, revoke, mobile layout and logout race", async () => {
  const http = require("node:http");
  const {chromium} = require("@playwright/test");
  const token = "test-fake-browser-admin-token-123456789";
  const saved = {...config,node_id:"test-fake-primary-node",interval_seconds:60,secondary_interval_seconds:3600,retention_count:120,max_snapshot_bytes:1073741824,peer:{host:"",port:2222,user:"root",identity_file:"/state/ssh/id_ed25519",known_hosts_file:"/state/ssh/known_hosts",node_id:""},service:{driver:"none",name:"",timeout_seconds:60}};
  const status = {node_id:saved.node_id,node_role:"primary",phase:"primary_active",epoch:0,peer:{configured:false},job:{running:false}};
  let createCount = 0;
  let latestBody;
  const invites = [];
  const command = `test-fake-install-command-${"fixture".repeat(600)}`;
  const server = http.createServer(async (req,res) => {
    const send = (code,body) => {res.writeHead(code,{"Content-Type":"application/json"});res.end(JSON.stringify(body));};
    if (req.url.startsWith("/api/")) {
      if (req.headers.authorization !== `Bearer ${token}`) {send(401,{error:"test-fake-invalid-token"});return;}
      if (req.url === "/api/config") {send(200,saved);return;}
      if (req.url === "/api/status") {send(200,status);return;}
      if (req.url === "/api/snapshots") {send(200,{snapshots:[]});return;}
      if (req.url === "/api/enrollment" && req.method === "GET") {send(200,{invites});return;}
      let raw = "";
      for await (const chunk of req) raw += chunk;
      const body = JSON.parse(raw || "{}");
      if (req.url === "/api/enrollment" && req.method === "POST") {
        createCount += 1;latestBody=body;
        const invite = {invite_id:`test-fake-invite-${createCount}`,status:"issued",expires_at:"2099-01-01T00:00:00Z",backup_host:body.backup_host,backup_port:body.backup_port,deployment:body.deployment};
        invites.push(invite);
        if (createCount === 2) await new Promise(resolve=>setTimeout(resolve,400));
        send(200,{invite_id:invite.invite_id,expires_at:invite.expires_at,command});return;
      }
      if (req.url === "/api/enrollment/revoke") {const invite=invites.find(item=>item.invite_id===body.invite_id);invite.status="revoked";send(200,{invite_id:body.invite_id,revoked:true});return;}
      send(404,{error:"test-fake-route-missing"});return;
    }
    const assets = {"/":"www/index.html","/app.js":"www/app.js","/style.css":"www/style.css"};
    if (!assets[req.url]) {res.writeHead(404);res.end();return;}
    res.writeHead(200,{"Content-Type":req.url==="/"?"text/html":req.url.endsWith(".js")?"text/javascript":"text/css"});
    res.end(fs.readFileSync(path.join(root,assets[req.url])));
  });
  await new Promise(resolve=>server.listen(0,"127.0.0.1",resolve));
  let browser;
  try {
    browser = await chromium.launch({headless:true,args:["--no-sandbox"]});
    const page = await browser.newPage({viewport:{width:1440,height:1100}});
    const errors=[];page.on("pageerror",error=>errors.push(error.message));
    page.on("dialog",dialog=>dialog.accept());
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.getByLabel("管理员令牌",{exact:true}).fill(token);
    await page.locator("#login-button").click();
    await page.locator("#app-shell").waitFor({state:"visible"});
    await page.getByRole("button",{name:"节点配置",exact:true}).click();
    await page.locator("#enrollment-open").click();
    await page.locator("#enrollment-dialog").waitFor({state:"visible"});
    assert.ok((await page.locator("#enrollment-preview").textContent()).includes("auths"));
    const fill = async () => {
      for (const [id,value] of [["primary-host","HOST"],["backup-host","standby-fixture"],["backup-bind","0.0.0.0"],["data-dir","/srv/cpa-fixture"]]) await page.locator(`#enrollment-${id}`).fill(value);
    };
    await fill();
    await page.locator("#enrollment-create").click();
    assert.equal(createCount,0,"confirmation required before generating credentials");
    await page.locator("#enrollment-confirm").check();
    await page.locator("#enrollment-create").click();
    await page.locator("#enrollment-result").waitFor({state:"visible"});
    assert.equal(await page.locator("#enrollment-command").inputValue(),command);
    assert.equal(latestBody.ttl_seconds,1800);
    assert.equal(latestBody.auto_enable,true);
    await page.setViewportSize({width:390,height:844});
    assert.ok(await page.locator("body").evaluate(el=>el.scrollWidth<=window.innerWidth));
    await page.setViewportSize({width:1440,height:1100});
    await page.locator("#enrollment-close").click();
    await page.waitForFunction(()=>document.getElementById("enrollment-command").value === "");
    assert.equal(await page.locator("#enrollment-command").inputValue(),"");
    await page.locator("#logout").click();
    await page.getByLabel("管理员令牌",{exact:true}).fill(token);
    await page.locator("#login-button").click();
    await page.locator("#app-shell").waitFor({state:"visible"});
    await page.getByRole("button",{name:"节点配置",exact:true}).click();
    const issuedRevoke = page.locator("#enrollment-list").getByRole("button",{name:"撤销邀请 test-fake-invite-1",exact:true});
    await issuedRevoke.waitFor({state:"visible",timeout:4000});
    assert.equal(await page.locator("#enrollment-command").inputValue(),"","list revocation must not need the private command in memory");
    await issuedRevoke.click();
    await page.locator("#enrollment-list").getByText("已撤销",{exact:true}).waitFor({state:"visible"});
    assert.equal(invites[0].status,"revoked");
    await page.setViewportSize({width:1440,height:1100});
    await page.locator("#enrollment-open").click();
    await page.locator("#enrollment-dialog").waitFor({state:"visible"});
    await fill();await page.locator("#enrollment-confirm").check();
    await page.locator("#enrollment-create").click();
    await page.locator("#enrollment-close").click();
    await page.locator("#logout").click();
    await new Promise(resolve=>setTimeout(resolve,550));
    assert.equal(await page.locator("#enrollment-command").inputValue(),"","pending creation must not repopulate after logout");
    assert.ok(await page.locator("#login-screen").isVisible());
    assert.deepEqual(errors,[]);
  } finally {
    if (browser) await browser.close();
    server.closeAllConnections();
    await new Promise(resolve=>server.close(resolve));
  }
});
