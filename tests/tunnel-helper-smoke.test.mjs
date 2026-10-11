import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const helper = fs.readFileSync(path.join(root, 'cloudflare-tunnel-manager.ps1'), 'utf8');
const ui = fs.readFileSync(path.join(root, 'AIPrimeCursorManager.ps1'), 'utf8');
const bridge = fs.readFileSync(path.join(root, 'bridge', 'server.mjs'), 'utf8');
const checks = [
  ['v1.7 version banner in UI', () => assert.match(ui, /v1\.7 · Backward-compatible tunnel state/)],
  ['temporary cloudflared filename ends in .exe', () => assert.match(helper, /cloudflared\.download\.exe/)],
  ['obsolete .exe.download path absent', () => assert.doesNotMatch(helper, /\$tempExe\s*=\s*"\$exe\.download"/)],
  ['download reports actual byte progress', () => assert.match(helper, /\$received \+= \$read/)],
  ['download percent is stored in state', () => assert.match(helper, /Write-State 'Downloading'.*\$pct/s)],
  ['download validates file size', () => assert.match(helper, /Length -lt 10000000/)],
  ['download validates MZ executable header', () => assert.match(helper, /0x4D.*0x5A/s)],
  ['download validates cloudflared version before install', () => assert.match(helper, /--version.*cloudflared/s)],
  ['UI migrates legacy tunnel-state JSON by adding missing progress fields', () => { assert.match(ui, /Backwards? compatibility: tunnel-state\.json may come from older releases/); assert.match(ui, /if \(\$null -eq \$state\.PSObject\.Properties\[\$name\]\)/); assert.match(ui, /progress = -1/); assert.match(ui, /bytesDownloaded = 0/); assert.match(ui, /bytesTotal = 0/); }],
  ['UI has visible progress bar and text', () => { assert.match(ui, /x:Name="TunnelProgressBar"/); assert.match(ui, /x:Name="TunnelProgressText"/); }],
  ['UI binds progress controls', () => { assert.match(ui, /TunnelStatusCard/); assert.match(ui, /TunnelProgressBar/); assert.match(ui, /TunnelProgressText/); assert.match(ui, /\.Split\("\|"\)/); }],
  ['bridge only binds loopback', () => assert.match(bridge, /const HOST = "127\.0\.0\.1"/)],
  ['bridge uses bearer authentication for API endpoints', () => assert.match(bridge, /req\.headers\.authorization === `Bearer \$\{LOCAL_KEY\}`/)],
  ['public URL only accepts Cloudflare trycloudflare host', () => assert.match(ui, /trycloudflare\\\.com/)],
];
let failed=0;
for (const [name, test] of checks) {
  try { test(); console.log(`PASS ${name}`); }
  catch (e) { failed++; console.error(`FAIL ${name}: ${e.message}`); }
}
console.log(`Tunnel static checks: ${checks.length-failed}/${checks.length} passed.`);
if (failed) process.exitCode=1;