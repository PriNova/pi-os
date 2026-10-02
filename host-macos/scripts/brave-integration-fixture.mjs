// Model-free acceptance runner for the actual production extension + browser adapter.
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { HostClient } from '../../node-harness/dist/hostClient.js';
import { BrowserSession } from '../../node-harness/dist/browser/session.js';
import { CdpConnection, verifyBraveEndpoint } from '../../node-harness/dist/browser/cdp.js';
import { createComputerUseExtension } from '../../node-harness/dist/agent/computerUseExtension.js';
if (process.env.PI_OS_INSTALLED_TEST !== '1') throw new Error('Explicit fixture opt-in required');
const root = process.argv[2];
const id = randomUUID();
const path = '/pi-os-browser-fixture-' + id;
const html = `<!doctype html><html lang="en"><meta charset="utf-8"><title>pi-os integrated Brave fixture</title><style>body{font:18px system-ui;max-width:700px;margin:60px auto;padding:24px}button,input{font:inherit;padding:10px;margin:10px}article{border:1px solid #ddd;padding:18px}</style><h1>pi-os integrated Brave fixture</h1><p>Local test only. No accounts or real file operations.</p><label>Test note <input id="note"></label><label>Multiline note <textarea id="multiline"></textarea></label><label>Username <input id="username" autocomplete="username" value="PRIVATE-USERNAME-CANARY"></label><label>Password canary <input type="password" value="PRIVATE-FIXTURE-CANARY"></label><article><h2>Fixture post</h2><button id="like" aria-pressed="false" onclick="this.setAttribute('aria-pressed','true');document.querySelector('#count').textContent=String(Number(document.querySelector('#count').textContent)+1)">Like fixture</button><p>Like clicks: <span id="count">0</span></p><button onclick="document.querySelector('#deleted').textContent='1'">Delete file</button><p>Deletion attempts: <span id="deleted">0</span></p></article><p><a href="${path}?next=1">Next fixture page</a></p><script>document.querySelector('#note').addEventListener('input',()=>document.querySelector('#input').textContent=String(Number(document.querySelector('#input').textContent)+1))</script><p>Input events: <span id="input">0</span></p></html>`;
const server = createServer((req, res) => {
  if (req.method !== 'GET' || ![path, path + '?next=1'].includes(req.url)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; base-uri 'none'" }); res.end(html);
});
await new Promise(done => server.listen(0, '127.0.0.1', done));
writeFileSync(join(root, 'fixture-ready.json'), JSON.stringify({ url: `http://127.0.0.1:${server.address().port}${path}` }), { mode: 0o600 });
const report = { checks: [], modelCalls: 0, accountActions: 0, fixtureOnly: true };
let browser;
const check = (name, condition) => { assert(condition, name); report.checks.push(name); console.log('PASS', name); };
try {
  const deadline = Date.now() + 90_000;
  while (!existsSync(join(root, 'fixture-context.json'))) {
    if (Date.now() > deadline) throw new Error('Native context was not supplied');
    await new Promise(done => setTimeout(done, 100));
  }
  const config = JSON.parse(readFileSync(join(root, 'fixture-context.json'), 'utf8'));
  const host = new HostClient({ hostBaseUrl: config.hostURL, hostToken: config.token });
  const snapshot = await host.getSnapshot(config.contextId);
  check('Signed native hotkey pinned the selected Brave tab', snapshot.ok && snapshot.result.browser?.pinned === true);
  const native = await host.invokeTool('input.typeText', { contextId: config.contextId, text: 'MUST-NOT-APPEAR' });
  check('Native input cannot bypass the browser route', !native.ok && native.error.code === 'browser_route_required');
  const calls = [], attaches = [];
  report.cdpMethodCounts = {};
  let baseline, finalTargets;
  browser = new BrowserSession(host, config.contextId, undefined, {
    verifyEndpoint: verifyBraveEndpoint,
    connect: async (port, signal) => {
      const client = await CdpConnection.connect(port, signal);
      return {
        call: async (method, params, sid, abort) => {
          calls.push(method);
          report.cdpMethodCounts[method] = (report.cdpMethodCounts[method] || 0) + 1;
          const result = await client.call(method, params, sid, abort);
          if (method === 'Target.getTargets') baseline = result.targetInfos.filter(t => t.type === 'page').map(t => ({ id: t.targetId, url: t.url }));
          if (method === 'Target.attachToTarget') attaches.push(params.targetId);
          if (method === 'Target.detachFromTarget') finalTargets = (await client.call('Target.getTargets')).targetInfos;
          return result;
        }, onEvent: listener => client.onEvent(listener), close: () => client.close(),
      };
    },
  });
  const tools = new Map();
  const extension = createComputerUseExtension(config.contextId, host, config.capturesDir, false, 'darwin', snapshot.result.screenshot?.imageId, browser);
  extension.factory({ on() {}, registerTool: tool => tools.set(tool.name, tool) });
  check('Production extension exposes browser tools instead of native mutation', tools.has('browser_snapshot') && tools.has('browser_act') && !tools.has('desktop_act'));
  const read = async () => (await tools.get('browser_snapshot').execute('read', {})).content[0].text;
  const act = async params => tools.get('browser_act').execute('act', params);
  const ref = (text, role, name) => {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const m = new RegExp('^\\[([^\\]]+)\\] '+role+' "'+escaped+'"', 'm').exec(text);
    if (!m) throw new Error('Missing fixture reference: ' + name); return m[1];
  };
  let text = await read();
  check('Real semantic DOM snapshot omits credential field values', text.includes('Fixture post') && text.includes('credential field; value omitted') && !text.includes('PRIVATE-FIXTURE-CANARY') && !text.includes('PRIVATE-USERNAME-CANARY'));
  for (const label of ['Username', 'Password canary']) {
    const field = ref(text, 'textbox', label);
    if (config.credentialsAllowed) {
      await act({ action: 'fill', ref: field, text: 'dummy-credential-QA-only' });
      check(label + ' accepts dummy input with explicit Settings permission', true);
    } else {
      await assert.rejects(act({ action: 'fill', ref: field, text: 'MUST-NOT-APPEAR' }), /credential_input_blocked/);
      check(label + ' is blocked by default', true);
    }
    text = await read();
    check(label + ' value stays out of text snapshots', !text.includes('dummy-credential-QA-only') && !text.includes('PRIVATE-FIXTURE-CANARY') && !text.includes('PRIVATE-USERNAME-CANARY'));
  }
  // In the opt-in run the password field is still focused. Clicking Like must use
  // the click destination, not that previously focused field's protection state.
  await act({ action: 'click', ref: ref(text, 'button', 'Like fixture') });
  text = await read();
  check('Like works independently of credential-field focus', /Like fixture" pressed=true/.test(text) && /Like clicks:\s*\n?1/.test(text));
  const stale = ref(text, 'textbox', 'Test note');
  await act({ action: 'fill', ref: stale, text: 'pi-os integrated — Grüß dich 👋' });
  text = await read();
  check('Unicode fill generated a real input event', /Input events:\s*\n?1/.test(text));
  await assert.rejects(act({ action: 'fill', ref: stale, text: 'MUST-NOT-APPEAR' }), /browser_stale/);
  check('Consumed references cannot mutate again', true);
  await act({ action: 'click', ref: ref(text, 'button', 'Like fixture') });
  text = await read();
  check('Second explicitly requested fixture click is delivered once', /Like fixture" pressed=true/.test(text) && /Like clicks:\s*\n?2/.test(text));
  await act({ action: 'fill', ref: ref(text, 'textbox', 'Multiline note'), text: 'First ü😀\r\n\r\n日本語\rLast\n' });
  check('Multiline Unicode/CRLF/CR/blank-line delivery is verified', true);
  text = await read();
  const oldRef = ref(text, 'button', 'Like fixture');
  browser.invalidateReferences();
  await assert.rejects(act({ action: 'click', ref: oldRef }), /browser_stale/);
  check('New user turns cannot inherit browser action references', true);
  text = await read();
  const oldLink = ref(text, 'link', 'Next fixture page');
  await act({ action: 'click', ref: oldLink });
  // Observation-only retries while our known fixture navigation completes.
  for (let i = 0; ; i++) {
    try { text = await read(); if (/Like clicks:\s*\n?0/.test(text)) break; if (i >= 15) throw new Error('Fixture navigation did not finish'); }
    catch (error) { if (i >= 15 || !String(error).includes('browser_stale')) throw error; }
    await new Promise(r => setTimeout(r, 100));
  }
  check('Same-tab navigation preserves native binding and resets the fixture', /Like clicks:\s*\n?0/.test(text));
  await assert.rejects(act({ action: 'click', ref: oldLink }), /browser_stale/);
  check('Pre-navigation references cannot target the new document', true);
  await assert.rejects(act({ action: 'click', ref: ref(text, 'button', 'Delete file') }), /file_deletion_blocked/);
  text = await read();
  check('Recognized Delete control was refused with zero events', /Deletion attempts:\s*\n?0/.test(text));
  await browser.dispose();
  check('Only one page session was attached and detached', attaches.length === 1 && calls.filter(m => m === 'Target.detachFromTarget').length === 1);
  check('All unrelated pre-existing tabs retain their IDs and URLs', baseline.filter(t => t.id !== attaches[0]).every(t => finalTargets.some(x => x.targetId === t.id && x.url === t.url)));
  check('No cookie, storage, network inspection or browser-close methods used', !calls.some(m => /Cookie|Storage|Network\.|Browser\.close|Target\.closeTarget/.test(m)));
  report.passed = true;
} catch (error) { report.passed = false; report.error = String(error); process.exitCode = 1; console.error(error.stack ?? report.error); }
finally {
  await browser?.dispose();
  server.closeAllConnections(); await new Promise(done => server.close(done));
  writeFileSync(join(root, 'browser-report.json'), JSON.stringify(report, null, 2), { mode: 0o600 });
}
