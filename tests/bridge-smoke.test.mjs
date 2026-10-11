import assert from 'node:assert/strict';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const bridgePath = path.join(root, 'bridge', 'server.mjs');
const TESTS = [];
function test(name, fn) { TESTS.push({ name, fn }); }
function listen(server, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, () => {
      server.removeListener('error', reject);
      resolve(server.address().port);
    });
  });
}
async function getFreePort() {
  const s = http.createServer();
  const port = await listen(s);
  await new Promise(resolve => s.close(resolve));
  return port;
}
function readRequest(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => { raw += chunk; });
    req.on('end', () => resolve(raw));
    req.on('error', reject);
  });
}
function startMockUpstream() {
  const stats = { active: 0, maxActive: 0, calls: 0, receivedModels: [], authHeaders: [] };
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url || '/', 'http://127.0.0.1');
    if (url.pathname === '/stats') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify(stats));
    }
    if (req.method !== 'POST' || url.pathname !== '/v1/chat/completions') {
      res.writeHead(404); return res.end();
    }
    let body;
    try { body = JSON.parse(await readRequest(req)); }
    catch { res.writeHead(400); return res.end('bad json'); }
    stats.active++;
    stats.calls++;
    stats.maxActive = Math.max(stats.maxActive, stats.active);
    stats.receivedModels.push(body.model);
    stats.authHeaders.push(req.headers.authorization || '');
    const content = String(body?.messages?.[0]?.content || '');
    const delayMs = content.startsWith('DELAY:') ? Number(content.slice(6)) : 80;
    await delay(Math.min(Math.max(delayMs || 80, 0), 2500));
    stats.active--;
    if (content === 'FORCE_UPSTREAM_503') {
      res.writeHead(503, { 'content-type': 'application/json', 'x-request-id': 'mock-503' });
      return res.end(JSON.stringify({ error: { message: 'mock provider unavailable' } }));
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      id: 'mock-response', object: 'chat.completion', model: 'mock-upstream-model',
      choices: [{ index: 0, message: { role: 'assistant', content: 'MOCK_OK' }, finish_reason: 'stop' }]
    }));
  });
  return { server, stats };
}
async function startBridge({ port, upstreamBase, localKey = 'local-test-key-83a719', upstreamKey = 'upstream-test-key-419c5b', alias = 'aiprimetech-sonnet-4-6', model = 'claude-sonnet-4-6', queue = 8 }) {
  const logPath = path.join(os.tmpdir(), `ai-prime-bridge-smoke-${process.pid}-${port}.log`);
  fs.rmSync(logPath, { force: true });
  const child = spawn(process.execPath, [bridgePath], {
    cwd: path.dirname(bridgePath),
    env: {
      ...process.env,
      CURSOR_BRIDGE_PORT: String(port),
      CURSOR_BRIDGE_KEY: localKey,
      AIPRIMETECH_API_KEY: upstreamKey,
      AIPRIMETECH_BASE_URL: upstreamBase,
      AIPRIMETECH_MODEL: model,
      CURSOR_MODEL_ALIAS: alias,
      CURSOR_BRIDGE_MAX_CONCURRENCY: '1',
      CURSOR_BRIDGE_MAX_QUEUE: String(queue),
      CURSOR_BRIDGE_QUEUE_TIMEOUT_MS: '15000',
      BRIDGE_LOG_PATH: logPath,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', b => { output += b.toString(); });
  child.stderr.on('data', b => { output += b.toString(); });
  let ready = false;
  for (let i = 0; i < 80; i++) {
    if (child.exitCode !== null) throw new Error(`Bridge exited early (${child.exitCode}): ${output}`);
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      if (res.ok) { ready = true; break; }
    } catch { }
    await delay(50);
  }
  if (!ready) { child.kill(); throw new Error(`Bridge did not become healthy: ${output}`); }
  return { child, port, localKey, upstreamKey, alias, model, logPath, stop: async () => {
    if (child.exitCode === null) child.kill('SIGTERM');
    await Promise.race([new Promise(resolve => child.once('exit', resolve)), delay(2000)]);
    if (child.exitCode === null) child.kill('SIGKILL');
  }};
}
async function requestJson(url, init) {
  const res = await fetch(url, init);
  let body = null;
  const text = await res.text();
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: res.status, headers: res.headers, body };
}

const mock = startMockUpstream();
const upstreamPort = await listen(mock.server);
const upstreamBase = `http://127.0.0.1:${upstreamPort}/v1`;
let bridgeA, bridgeB, bridgeMissingKey;
const portA = await getFreePort();
bridgeA = await startBridge({ port: portA, upstreamBase });
const baseA = `http://127.0.0.1:${portA}`;
const authA = { authorization: `Bearer ${bridgeA.localKey}`, 'content-type': 'application/json' };

// Test 1: health endpoint remains responsive.
test('health endpoint returns ok and runtime state', async () => {
  const r = await requestJson(`${baseA}/health`);
  assert.equal(r.status, 200); assert.equal(r.body.ok, true);
  assert.equal(r.body.model, 'claude-sonnet-4-6'); assert.equal(r.body.alias, 'aiprimetech-sonnet-4-6');
});
// Test 2: model endpoint requires auth.
test('model catalogue rejects missing credentials', async () => {
  const r = await requestJson(`${baseA}/v1/models`);
  assert.equal(r.status, 401); assert.equal(r.body.error.message, 'Invalid local bridge key');
});
// Test 3: model endpoint publishes only configured alias.
test('model catalogue returns exactly one configured alias with valid key', async () => {
  const r = await requestJson(`${baseA}/v1/models`, { headers: { authorization: `Bearer ${bridgeA.localKey}` } });
  assert.equal(r.status, 200); assert.equal(r.body.data.length, 1); assert.equal(r.body.data[0].id, bridgeA.alias);
});
// Test 4: unauthorized chat requests rejected.
test('chat completion rejects invalid local key', async () => {
  const r = await requestJson(`${baseA}/v1/chat/completions`, { method: 'POST', headers: { authorization: 'Bearer wrong', 'content-type': 'application/json' }, body: JSON.stringify({ model: bridgeA.alias, messages: [{ role: 'user', content: 'hi' }] }) });
  assert.equal(r.status, 401);
});
// Test 5: successful request rewrites the alias and sends upstream secret.
test('chat completion relays and rewrites model alias', async () => {
  const r = await requestJson(`${baseA}/v1/chat/completions`, { method: 'POST', headers: authA, body: JSON.stringify({ model: bridgeA.alias, messages: [{ role: 'user', content: 'hello' }], max_tokens: 10 }) });
  assert.equal(r.status, 200); assert.equal(r.body.choices[0].message.content, 'MOCK_OK');
  assert.equal(mock.stats.receivedModels.at(-1), 'claude-sonnet-4-6');
  assert.equal(mock.stats.authHeaders.at(-1), `Bearer ${bridgeA.upstreamKey}`);
});
// Test 6: malformed JSON has a client-error status (not gateway error).
test('malformed JSON returns HTTP 400', async () => {
  const r = await requestJson(`${baseA}/v1/chat/completions`, { method: 'POST', headers: authA, body: '{broken json' });
  assert.equal(r.status, 400); assert.equal(r.body.error.code, 'invalid_json');
});
// Test 7: invalid route is not proxied.
test('unsupported route returns 404', async () => {
  const r = await requestJson(`${baseA}/v1/not-supported`, { headers: { authorization: `Bearer ${bridgeA.localKey}` } });
  assert.equal(r.status, 404);
});
// Test 8: upstream errors are passed through, preserving status and request id.
test('upstream HTTP 503 is passed through', async () => {
  const r = await requestJson(`${baseA}/v1/chat/completions`, { method: 'POST', headers: authA, body: JSON.stringify({ model: bridgeA.alias, messages: [{ role: 'user', content: 'FORCE_UPSTREAM_503' }] }) });
  assert.equal(r.status, 503); assert.equal(r.headers.get('x-request-id'), 'mock-503');
});
// Test 9: concurrent bursts are queued to a single upstream request.
test('five simultaneous requests stay at max upstream concurrency 1', async () => {
  const beforeCalls = mock.stats.calls;
  const responses = await Promise.all(Array.from({ length: 5 }, (_, i) => requestJson(`${baseA}/v1/chat/completions`, { method: 'POST', headers: authA, body: JSON.stringify({ model: bridgeA.alias, messages: [{ role: 'user', content: `DELAY:100` }], max_tokens: 5 }) })));
  assert.ok(responses.every(r => r.status === 200), `statuses: ${responses.map(r=>r.status).join(',')}`);
  assert.equal(mock.stats.maxActive, 1); assert.equal(mock.stats.calls - beforeCalls, 5);
});
// Test 10: bounded queue does not forward excess requests upstream.
test('queue bound returns 429 instead of exceeding provider concurrency', async () => {
  const port = await getFreePort();
  bridgeB = await startBridge({ port, upstreamBase, queue: 1, alias: 'aiprimetech-test', model: 'claude-test-model' });
  const url = `http://127.0.0.1:${port}/v1/chat/completions`;
  const headers = { authorization: `Bearer ${bridgeB.localKey}`, 'content-type': 'application/json' };
  const beforeCalls = mock.stats.calls;
  const results = await Promise.all(Array.from({ length: 3 }, () => requestJson(url, { method: 'POST', headers, body: JSON.stringify({ model: bridgeB.alias, messages: [{ role: 'user', content: 'DELAY:600' }] }) })));
  const statuses = results.map(r => r.status).sort((a,b)=>a-b);
  assert.deepEqual(statuses, [200, 200, 429]);
  assert.equal(mock.stats.maxActive, 1);
  assert.equal(mock.stats.calls - beforeCalls, 2);
});
// Test 11: missing upstream secret becomes a clear 500.
test('missing upstream API key returns a clear 500', async () => {
  const port = await getFreePort();
  bridgeMissingKey = await startBridge({ port, upstreamBase, upstreamKey: '', alias: 'aiprimetech-test-missing-key', model: 'claude-test-model' });
  const url = `http://127.0.0.1:${port}/v1/chat/completions`;
  const headers = { authorization: `Bearer ${bridgeMissingKey.localKey}`, 'content-type': 'application/json' };
  const r = await requestJson(url, { method: 'POST', headers, body: JSON.stringify({ model: bridgeMissingKey.alias, messages: [{ role: 'user', content: 'hello' }] }) });
  assert.equal(r.status, 500); assert.match(r.body.error.message, /API key is missing/i);
});
// Test 12: secrets never appear in bridge logs.
test('API keys are not written to bridge logs', async () => {
  const raw = fs.readFileSync(bridgeA.logPath, 'utf8');
  assert.equal(raw.includes(bridgeA.localKey), false);
  assert.equal(raw.includes(bridgeA.upstreamKey), false);
});

let failures = 0;
try {
  for (const { name, fn } of TESTS) {
    try { await fn(); console.log(`PASS ${name}`); }
    catch (e) { failures++; console.error(`FAIL ${name}\n${e.stack || e}`); }
  }
} finally {
  for (const b of [bridgeA, bridgeB, bridgeMissingKey]) if (b) await b.stop();
  await new Promise(resolve => mock.server.close(resolve));
}
console.log(`\nBridge smoke tests: ${TESTS.length - failures}/${TESTS.length} passed.`);
if (failures) process.exitCode = 1;