#!/usr/bin/env node
// Explicitly opt-in live-browser fixture probe, NOT the production browser adapter.
// Only connects to an already-running, user-approved Brave. Never reads auth stores,
// deletes files, launches/closes Brave, or attaches to pre-existing page targets.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const require = createRequire(new URL('../../node-harness/package.json', import.meta.url));
const WebSocket = require('ws');
if (process.env.PI_OS_BRAVE_TEST !== '1') throw new Error('Requires PI_OS_BRAVE_TEST=1 and user consent.');
const pid = Number(process.env.PI_OS_BRAVE_PID);
const port = Number(process.env.PI_OS_BRAVE_PORT);
const reportPath = resolve(process.env.PI_OS_BRAVE_REPORT || '/tmp/pi-os-brave-cdp-result.json');
assert(Number.isInteger(pid) && pid > 1 && Number.isInteger(port) && port > 0 && port < 65536);
const expectedExecutable = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';
const identity = () => execFileSync('/bin/ps', ['-p', String(pid), '-o', 'comm='], { encoding: 'utf8' }).trim();
assert.equal(identity(), expectedExecutable, 'Unexpected browser identity');
const listeners = execFileSync('/usr/sbin/lsof', ['-nP', '-a', '-p', String(pid), '-iTCP', '-sTCP:LISTEN'], { encoding: 'utf8' });
assert(listeners.includes(`TCP 127.0.0.1:${port} (LISTEN)`), 'Endpoint is not owned by the selected Brave process');

const nonce = randomUUID();
const fixturePath = `/pi-os-fixture-${nonce}`;
const page = `<!doctype html><html lang="en"><meta charset="utf-8"><title>pi-os Brave connection fixture</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style nonce="${nonce}">body{font:18px system-ui;max-width:680px;margin:80px auto;padding:24px;color:#20242a;background:#f7f8fa}main{background:white;border:1px solid #ddd;border-radius:16px;padding:32px}input,button{font:inherit;padding:12px;margin:12px 0}input{display:block;width:90%}button{cursor:pointer}p{line-height:1.6}output{font-weight:600}small{color:#59616b}</style>
<main><h1>Brave connection test</h1><p>This is a harmless, local pi-os fixture. No account is connected and no files can be removed by these buttons.</p>
<label for="note">Test note</label><input id="note" autocomplete="off">
<button id="like" type="button" aria-pressed="false">Like fixture</button>
<p>Like clicks: <output id="clicks">0</output></p><p>Input events: <output id="inputs">0</output></p>
<p id="status" role="status">Ready for a scoped CDP test.</p><small>Other tabs are not test targets. You can close this fixture when finished.</small></main>
<script nonce="${nonce}">const input=document.querySelector('#note');const like=document.querySelector('#like');input.addEventListener('input',()=>{document.querySelector('#inputs').textContent=String(Number(document.querySelector('#inputs').textContent)+1)});like.addEventListener('click',()=>{like.setAttribute('aria-pressed','true');document.querySelector('#clicks').textContent=String(Number(document.querySelector('#clicks').textContent)+1);document.querySelector('#status').textContent='PASS: text entry and element-reference click verified in the existing Brave session.'});</script></html>`;
const server = createServer((req, res) => {
  if (req.method !== 'GET' || req.url !== fixturePath) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store',
    'Content-Security-Policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'` });
  res.end(page);
});
await new Promise((done, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', done); });
const fixtureURL = `http://127.0.0.1:${server.address().port}${fixturePath}`;
const report = { timestamp: new Date().toISOString(), status: 'waiting-for-browser-consent',
  checks: [], scope: 'Live transport/fixture proof only; not installed pi-os integration or a deletion sandbox.' };
function save() { writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 }); }
function check(name, value) { assert(value, name); report.checks.push(name); save(); console.log(`PASS ${name}`); }
save();
console.log('Waiting for Brave connection approval (one connection, five-minute limit).');
const ws = new WebSocket(`ws://127.0.0.1:${port}/devtools/browser`, { handshakeTimeout: 300_000, maxPayload: 8 * 1024 * 1024 });
let sequence = 0;
let pending = new Map();
const ownedTargets = new Set();
const sessions = new Map();
let aborted = false;
const methods = new Set(['Browser.getVersion', 'Target.getTargets', 'Target.createTarget', 'Target.attachToTarget', 'Target.detachFromTarget',
  'Page.enable', 'Page.getFrameTree', 'Page.navigate', 'Accessibility.getFullAXTree', 'DOM.resolveNode',
  'Runtime.callFunctionOn', 'Input.insertText']);
ws.on('message', data => {
  let msg;
  try { msg = JSON.parse(data.toString()); } catch { return; }
  if (msg.id && pending.has(msg.id)) {
    const p = pending.get(msg.id); pending.delete(msg.id); clearTimeout(p.timer);
    if (msg.error) p.reject(new Error(`CDP ${p.method} failed (${msg.error.code})`)); else p.resolve(msg.result);
  }
  if (msg.method === 'Target.detachedFromTarget') sessions.delete(msg.params.sessionId);
  // Do not log arbitrary event payloads from the browser.
});
function rejectPending() { for (const p of pending.values()) { clearTimeout(p.timer); p.reject(new Error('Connection ended')); } pending.clear(); }
ws.on('close', rejectPending);
ws.on('error', rejectPending);
function call(method, params = {}, sessionId) {
  assert(!aborted && ws.readyState === WebSocket.OPEN, 'Connection not active');
  assert(methods.has(method), 'Method is outside fixture scope');
  if (sessionId) assert(sessions.has(sessionId), 'Unknown fixture session');
  else assert(method.startsWith('Target.') || method === 'Browser.getVersion', 'Page operation needs a fixture session');
  if (method === 'Target.createTarget') assert.equal(params.url, fixtureURL);
  if (method === 'Target.attachToTarget') assert(ownedTargets.has(params.targetId), 'Cannot attach to an existing user tab');
  if (method === 'Target.detachFromTarget') assert(sessions.has(params.sessionId));
  if (method === 'Page.navigate') assert.equal(params.url, fixtureURL);
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP ${method} timed out; no mutation retry`)); }, 12_000);
    pending.set(id, { resolve, reject, timer, method });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
}
async function snapshot(sessionId) {
  const tree = await call('Page.getFrameTree', {}, sessionId);
  assert.equal(tree.frameTree.frame.url, fixtureURL, 'Fixture navigated away');
  return (await call('Accessibility.getFullAXTree', {}, sessionId)).nodes;
}
async function findNode(sessionId, role, name) {
  const matches = (await snapshot(sessionId)).filter(n => !n.ignored && n.role?.value === role && n.name?.value === name);
  assert.equal(matches.length, 1, 'Fixture element must be unique');
  assert(matches[0].backendDOMNodeId);
  return matches[0].backendDOMNodeId;
}
async function withNode(sessionId, nodeId, fn) {
  await snapshot(sessionId); // Check the fixture origin/document before using the reference.
  const { object } = await call('DOM.resolveNode', { backendNodeId: nodeId }, sessionId);
  assert(object.objectId);
  const r = await call('Runtime.callFunctionOn', { objectId: object.objectId, functionDeclaration: fn, returnByValue: true }, sessionId);
  assert(!r.exceptionDetails, 'Fixture function failed');
  return r.result.value;
}
async function attachFixture() {
  const { targetId } = await call('Target.createTarget', { url: fixtureURL });
  ownedTargets.add(targetId);
  const { sessionId } = await call('Target.attachToTarget', { targetId, flatten: true });
  sessions.set(sessionId, targetId);
  await call('Page.enable', {}, sessionId);
  // Observation-only retries while our new page loads; writes are never retried.
  const deadline = Date.now() + 10_000;
  while (true) {
    try { await findNode(sessionId, 'textbox', 'Test note'); break; }
    catch (error) { if (Date.now() >= deadline) throw error; await new Promise(r => setTimeout(r, 100)); }
  }
  return sessionId;
}
async function state(sessionId) {
  const node = await findNode(sessionId, 'textbox', 'Test note');
  return withNode(sessionId, node, `function(){return {note:this.value,inputs:Number(document.querySelector('#inputs').textContent),clicks:Number(document.querySelector('#clicks').textContent),pressed:document.querySelector('#like').getAttribute('aria-pressed')}}`);
}
const watchdog = setTimeout(() => { aborted = true; ws.terminate(); }, 420_000);
process.once('SIGTERM', () => { aborted = true; ws.terminate(); });
process.once('SIGINT', () => { aborted = true; ws.terminate(); });
try {
  await new Promise((done, reject) => { ws.once('open', done); ws.once('error', () => reject(new Error('Browser connection not approved or unavailable'))); });
  const version = await call('Browser.getVersion');
  report.browserVersion = version.product;
  report.status = 'running'; save();
  check('Attached to the already-running Brave endpoint', identity() === expectedExecutable);
  // Compare only opaque target IDs and URLs in memory. Do not log/store browsing data.
  const baseline = (await call('Target.getTargets')).targetInfos.filter(t => t.type === 'page');
  const canary = await attachFixture();
  const target = await attachFixture();
  check('Two identical fixture tabs have separate target identities', sessions.get(canary) !== sessions.get(target));
  const noteNode = await findNode(target, 'textbox', 'Test note');
  check('Accessibility snapshot resolves one named textbox', !!noteNode);
  await withNode(target, noteNode, 'function(){this.focus();return document.activeElement===this}').then(v => assert.equal(v, true));
  await call('Input.insertText', { text: 'pi-os CDP test — Grüß dich 👋' }, target);
  check('Unicode input delivered with an input event', (await state(target)).note === 'pi-os CDP test — Grüß dich 👋' && (await state(target)).inputs > 0);
  const button = await findNode(target, 'button', 'Like fixture');
  const before = await state(target); assert.equal(before.clicks, 0); assert.equal(before.pressed, 'false');
  await withNode(target, button, 'function(){this.click();return true}');
  const after = await state(target);
  check('Named Like fixture clicked exactly once, state verified', after.clicks === 1 && after.pressed === 'true');
  const untouched = await state(canary);
  check('Duplicate canary fixture received no text or click', untouched.note === '' && untouched.inputs === 0 && untouched.clicks === 0);
  const end = (await call('Target.getTargets')).targetInfos;
  check('Pre-existing page targets remain open at their original URLs', baseline.every(t => end.some(x => x.targetId === t.targetId && x.url === t.url)));
  check('Only fixture page sessions were attached', sessions.size === 2 && [...sessions.values()].every(t => ownedTargets.has(t)));
  for (const sessionId of [...sessions.keys()]) { await call('Target.detachFromTarget', { sessionId }); sessions.delete(sessionId); }
  check('Both fixture sessions explicitly detached', sessions.size === 0);
  report.status = 'passed';
} catch (error) {
  report.status = 'failed'; report.error = error.message;
  console.error(`Fixture probe stopped: ${error.message}`);
  process.exitCode = 1;
} finally {
  clearTimeout(watchdog);
  if (ws.readyState === WebSocket.OPEN) {
    await new Promise(done => { ws.once('close', done); ws.close(); setTimeout(() => { ws.terminate(); done(); }, 1500).unref(); });
  } else ws.terminate();
  server.closeAllConnections(); await new Promise(done => server.close(done));
  report.browserStillRunning = identity() === expectedExecutable;
  report.fixtureTabsLeftOpen = ownedTargets.size;
  report.authStoresRead = false;
  report.accountActionsPerformed = false;
  report.browserRestarted = false;
  save();
  console.log(`Result: ${report.status}. Browser left running; fixture tabs left open. Report: ${reportPath}`);
}
