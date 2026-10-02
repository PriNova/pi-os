// Deterministic held invocation for testing the REAL installed native host.
// No pi SDK, model/provider discovery, network other than loopback, or arbitrary tools.
import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
const token = process.env.PI_OS_TOKEN;
const recordFile = process.env.PI_OS_TEST_RECORD_FILE;
if (!token || !recordFile || process.env.PI_OS_INSTALLED_TEST !== '1') process.exit(78);
let record;
let turns = 0, closed = false;
const save = () => writeFileSync(recordFile, JSON.stringify({...record, turns, closed}), {mode: 0o600});
const server = createServer(async (req, res) => {
  const json = (status, body) => { res.writeHead(status, {'Content-Type': 'application/json'}); res.end(JSON.stringify(body)); };
  if (req.url === '/health') return json(200, {service: 'installed-fixture-harness', sessionId: process.env.PI_OS_SESSION_ID});
  if (req.headers['x-harness-token'] !== token) return json(401, {});
  let raw = '';
  for await (const chunk of req) { raw += chunk; if (raw.length > 100_000) return json(413, {}); }
  if (req.method === 'POST' && req.url === '/invoke') {
    try { record = {...JSON.parse(raw), state: 'running', activity: 'desktop_act'}; } catch { return json(400, {}); }
    turns = 1; closed = false; save();
    return json(202, {accepted: true, invocationId: record.invocationId});
  }
  if (record && req.url === `/invocations/${record.invocationId}`) return json(200, record);
  if (record && req.url === `/invocations/${record.invocationId}/followup` && req.method === 'POST') {
    if (closed) return json(404, {error: {code: 'session_closed', message: 'Fixture thread is closed'}});
    if (record.state === 'running') return json(409, {error: {code: 'not_idle', message: 'Fixture is busy'}});
    const prompt = JSON.parse(raw).prompt;
    record = {...record, prompt, state: 'running', responseText: undefined, activity: 'thinking', followupAvailable: false};
    turns++; save(); return json(202, {accepted: true});
  }
  if (record && req.url === `/invocations/${record.invocationId}/close` && req.method === 'POST') {
    closed = true; record.followupAvailable = false; save(); return json(200, {closed: true});
  }
  if (record && req.url === `/invocations/${record.invocationId}/cancel`) {
    record.state = 'aborted'; return json(202, {accepted: true});
  }
  if (record && req.url === '/fixture/fail' && req.method === 'POST') {
    record.state = 'failed'; record.activity = undefined; record.followupAvailable = !closed;
    record.failureMessage = 'Dummy follow-up failure'; save(); return json(200, {ok: true});
  }
  if (record && req.url === '/fixture/finish' && req.method === 'POST') {
    record.state = 'completed'; record.activity = undefined; record.followupAvailable = !closed;
    record.responseText = 'Installed-host validation completed without a model call.';
    save(); return json(200, {ok: true});
  }
  return json(404, {});
});
process.stdin.on('end', () => { server.close(); process.exit(0); });
process.stdin.resume();
process.on('SIGTERM', () => { server.close(); process.exit(0); });
server.listen(Number(process.env.PI_OS_NODE_PORT), '127.0.0.1');
