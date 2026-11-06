/* Optional developer-only browser test against the native SSH pair fixtures. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('@playwright/test');
const primary = {base:process.env.CPA_PRIMARY_URL,token:process.env.CPA_PRIMARY_TOKEN};
const backup = {base:process.env.CPA_BACKUP_URL,token:process.env.CPA_BACKUP_TOKEN};
const project = path.resolve(__dirname,'../..');
async function api(node,route,body,method) {
  const deadline=Date.now()+60000;
  while (true) {
    const response=await fetch(node.base+route,{method:method || (body === undefined ? 'GET':'POST'),
      headers:{Authorization:`Bearer ${node.token}`,'Content-Type':'application/json'},
      body:body===undefined?undefined:JSON.stringify(body)});
    const result=await response.json();
    if (response.status===409 && Date.now()<deadline) {
      // Rejected admission has no job side effect; never retry other failures.
      await new Promise(resolve=>setTimeout(resolve,200));continue;
    }
    if (!response.ok) throw new Error(`${route}: ${response.status}: ${result.error}`);
    return result;
  }
}
async function until(fn,timeout=60000) {
  const end=Date.now()+timeout; let last;
  while(Date.now()<end) {try {const result=await fn(); if(result)return result;}catch(error){last=error;} await new Promise(resolve=>setTimeout(resolve,250));}
  throw new Error(`Timed out: ${last || fn.toString()}`);
}
async function login(page,node) {
  await page.goto(node.base);
  await page.getByLabel('管理员令牌',{exact:true}).fill(node.token);
  await page.getByRole('button',{name:'进入控制台'}).click();
  await page.locator('#app-shell').waitFor({state:'visible'});
}
(async()=>{
  assert(primary.base && backup.base && primary.token && backup.token,'Run via CPA_BROWSER=1 bash tests/runtime_pair.sh');
  let browser;
  try {
    browser=await chromium.launch({headless:true,args:['--no-sandbox']});
    const page=await browser.newPage({viewport:{width:1440,height:1000}});
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    await page.goto(primary.base);
    await page.getByLabel('管理员令牌',{exact:true}).fill('wrong-admin-token');
    await page.getByRole('button',{name:'进入控制台'}).click();
    await until(async()=> (await page.locator('#login-error').textContent()).length>0);
    assert(await page.locator('#login-screen').isVisible());
    await login(page,primary);
    await page.getByRole('button',{name:'节点配置',exact:true}).click();
    assert.equal(await page.locator('#node-role').inputValue(),'primary');
    assert.equal(await page.locator('#identity-file').inputValue(),'/state/ssh/id_ed25519');
    assert.equal(await page.locator('[data-field="path"]').first().inputValue(),'/data');
    // The pair's earlier phase already exercises two-second scheduling.
    // Use a long interval here to test manual submission without intentionally
    // racing a newly enabled timer during the browser's multi-request flow.
    await page.locator('#interval').fill('3600');
    await page.locator('#secondary-interval').fill('3600');
    await page.locator('#retention').fill('20');
    const pairing=await api(backup,'/api/pairing');
    await page.locator('#peer-public-key').fill(pairing.public_key);
    const trustResponse=page.waitForResponse(response=>response.url().endsWith('/api/pairing') && response.request().method()==='POST');
    await page.locator('#trust-peer-key').click();
    const trusted=await trustResponse;
    assert(trusted.ok(),`SSH key import: HTTP ${trusted.status()}: ${await trusted.text()}`);
    await until(async()=> (await page.locator('#peer-public-key').inputValue()) === '');
    await page.locator('#test-peer').click();
    await until(async()=> (await page.locator('#peer-node-id').inputValue())===pairing.node_id);
    await page.locator('#save-enable').click();
    await until(async()=> (await api(primary,'/api/config')).enabled);
    await until(async()=> !(await page.locator('#save-enable').isDisabled()));
    await page.getByRole('button',{name:'运行概览',exact:true}).click();
    const backupResponse=page.waitForResponse(response=>response.url().endsWith('/api/actions/backup') && response.request().method()==='POST');
    await page.locator('#backup-now').click();
    const submitted=await backupResponse;
    assert.equal(submitted.status(),202,`Manual backup admission: ${await submitted.text()}`);
    await until(async()=> (await page.locator('#global-message').textContent()).includes('已完成'));
    console.log('PASS: native browser login, SSH public-key trust, role/path/interval config, pairing and backup');
    for(const node of [primary,backup]) {
      await until(async()=>!(await api(node,'/api/status')).job.running);
      const config=await api(node,'/api/config');config.enabled=false;
      await api(node,'/api/config',config,'PUT');
    }
    await page.getByRole('button',{name:'备份历史',exact:true}).click();
    await until(async()=> (await page.locator('#snapshots-body tr').count())>0);
    const artifacts=path.join(project,'.runtime');fs.mkdirSync(artifacts,{recursive:true});
    assert(await page.locator('body').evaluate(el=>el.scrollWidth<=window.innerWidth));
    await page.screenshot({path:path.join(artifacts,'native-desktop.png'),fullPage:true});
    await page.setViewportSize({width:390,height:844});
    assert(await page.locator('body').evaluate(el=>el.scrollWidth<=window.innerWidth));
    await page.screenshot({path:path.join(artifacts,'native-mobile.png'),fullPage:true});
    const other=await browser.newPage({viewport:{width:1440,height:1000}});
    other.on('pageerror',error=>errors.push(error.message));
    await login(other,backup);
    await other.getByRole('button',{name:'节点配置',exact:true}).click();
    assert.equal(await other.locator('#node-role').inputValue(),'backup');
    await other.getByRole('button',{name:'备份历史',exact:true}).click();
    await until(async()=> (await other.locator('#snapshots-body tr').count())>0);
    const failed=await api(backup,'/api/actions/restore',{snapshot_id:'missing_snapshot',confirm:'RESTORE',quiesced:true},'POST');
    await until(async()=> !(await api(backup,`/api/jobs/${failed.job_id}`)).running);
    assert.equal((await api(backup,'/api/status')).phase,'paused');
    assert((await api(backup,`/api/jobs/${failed.job_id}`)).error);
    await other.locator('#snapshots-body tr').first().getByRole('button',{name:/恢复/}).click();
    await other.locator('#action-dialog').waitFor({state:'visible'});
    await until(async()=> !(await other.locator('#dialog-submit').isDisabled()));
    await other.locator('#dialog-confirm').fill('WRONG');
    await other.locator('#dialog-submit').click();
    assert(await other.locator('#action-dialog').isVisible());
    await other.locator('#dialog-confirm').fill('RESTORE');
    for(const checkbox of await other.locator('#dialog-flags input').all()) await checkbox.check();
    await other.locator('#dialog-submit').click();
    await until(async()=> (await other.locator('#global-message').textContent()).includes('恢复已完成'));
    assert.equal((await api(backup,'/api/status')).phase,'backup_standby');
    assert.deepEqual(errors,[]);
    console.log('PASS: native CGI restore preview/confirmation/completion; both roles; mobile/desktop; no page errors');
    console.log('PASS: browser confirms historical restore retry from failed protected standby');
  } finally {if(browser)await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
