import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const helper = fs.readFileSync(path.join(root, 'cloudflare-tunnel-manager.ps1'), 'utf8');
const ui = fs.readFileSync(path.join(root, 'AIPrimeCursorManager.ps1'), 'utf8');
const xamlBase64Match = ui.match(/^\$xamlBase64\s*=\s*'([A-Za-z0-9+/=]+)'\s*$/m);
const legacyXamlMatch = ui.match(/\$xaml\s*=\s*@'\r?\n([\s\S]*?)\r?\n'@/);
const uiXaml = xamlBase64Match
  ? Buffer.from(xamlBase64Match[1], 'base64').toString('utf8')
  : (legacyXamlMatch?.[1] ?? ui);
const bridge = fs.readFileSync(path.join(root, 'bridge', 'server.mjs'), 'utf8');
const translationBase64Match = ui.match(/^\$script:UiTranslationsBase64\s*=\s*'([A-Za-z0-9+/=]+)'\s*$/m);
const uiTranslations = translationBase64Match
  ? JSON.parse(Buffer.from(translationBase64Match[1], 'base64').toString('utf8'))
  : {};
const checks = [
  ['language selector contains English, Estonian, French and German', () => {
    assert.match(uiXaml, /x:Name="LanguageCombo"/);
    for (const code of ['en', 'et', 'fr', 'de']) assert.ok(uiXaml.includes('Tag="' + code + '"'));
  }],
  ['localization dictionary provides all four languages', () => {
    assert.ok(Object.keys(uiTranslations).length >= 100);
    for (const key of ['Dashboard', 'Cloudflare Tunnel', 'Settings saved']) {
      assert.ok(uiTranslations[key], 'missing translation key: ' + key);
      for (const code of ['en', 'et', 'fr', 'de']) assert.equal(typeof uiTranslations[key][code], 'string');
    }
    assert.notEqual(uiTranslations.Dashboard.et, uiTranslations.Dashboard.en);
    assert.notEqual(uiTranslations.Dashboard.fr, uiTranslations.Dashboard.en);
    assert.notEqual(uiTranslations.Dashboard.de, uiTranslations.Dashboard.en);
  }],
  ['language choice persists in settings and selection event', () => {
    assert.match(ui, /Language = 'en'/);
    assert.ok(ui.includes("'ApiBaseUrl','Model','Port','Language','RememberApiKey'"));
    assert.ok(ui.includes('Language = [string]$script:CurrentSettings.Language'));
    assert.ok(ui.includes('LanguageCombo.Add_SelectionChanged'));
    assert.ok(ui.includes('Set-UiLanguage $chosenLanguage'));
  }],

  ['v1.7 version banner in UI', () => assert.match(uiXaml, /v1\.7 · Backward-compatible tunnel state/)],
  ['temporary cloudflared filename ends in .exe', () => assert.match(helper, /cloudflared\.download\.exe/)],
  ['obsolete .exe.download path absent', () => assert.doesNotMatch(helper, /\$tempExe\s*=\s*"\$exe\.download"/)],
  ['download reports actual byte progress', () => assert.match(helper, /\$received \+= \$read/)],
  ['download percent is stored in state', () => assert.match(helper, /Write-State 'Downloading'.*\$pct/s)],
  ['download validates file size', () => assert.match(helper, /Length -lt 10000000/)],
  ['download validates MZ executable header', () => assert.match(helper, /0x4D.*0x5A/s)],
  ['download validates cloudflared version before install', () => assert.match(helper, /--version.*cloudflared/s)],
  ['UI migrates legacy tunnel-state JSON by adding missing progress fields', () => { assert.match(ui, /Backwards? compatibility: tunnel-state\.json may come from older releases/); assert.match(ui, /if \(\$null -eq \$state\.PSObject\.Properties\[\$name\]\)/); assert.match(ui, /progress = -1/); assert.match(ui, /bytesDownloaded = 0/); assert.match(ui, /bytesTotal = 0/); }],
  ['UI has visible progress bar and text', () => { assert.match(uiXaml, /x:Name="TunnelProgressBar"/); assert.match(uiXaml, /x:Name="TunnelProgressText"/); }],
  ['UI binds progress controls', () => { assert.match(ui, /\$controlNamesText\s*=/); assert.match(ui, /\$controlNames\s*=\s*\$controlNamesText\s*-split/); assert.ok(ui.includes('TunnelStatusCard|TunnelProgressBar|TunnelProgressText')); }],
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