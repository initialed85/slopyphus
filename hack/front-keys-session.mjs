// One CDP session against the shared headless chromium: load the desktop, install the onData capture
// hooks, press the chord and the keys, then read back what every pane's client would have sent.
// front-cdp.mjs evaluates before it drives, which cannot install a hook ahead of the keystroke, so this
// exists. The chrome, the viewport and the target hygiene follow hack/front-cdp.mjs's documented rules.
//
//   CHROMIUM_TOKEN=$(kubectl -n auth get secret api-tokens -o jsonpath='{.data.API_TOKEN_EDWARD}' | base64 -d) \
//   node hack/front-keys-session.mjs --url http://192.168.1.213:38137 --wait-ms 9000 \
//     --focus-expression "...focus the source pane's textarea..." --hook-file /tmp/keys-hook.js \
//     --keys "alt+shift+g,a,b,Space,shift+c,shift+d,e,f" --read-file /tmp/keys-read.js
//
// What it proves, and why the panes are pointed at a spare agent: the keystrokes are real (Chrome's input
// pipeline), so they reach the shell too. Point them at an agent nobody is watching - an idle one whose
// window runs `cat` - because a ttyd pane shows the session's ACTIVE window, and typing into a pane whose
// agent has a live chat types into that chat. That is how the broadcast fix was measured: three panes of
// one agent's `cat`, and the bytes each pane's xterm would write to its PTY read out of onData.
import { readFileSync } from 'node:fs';

const BASE = process.env.CHROMIUM ?? 'https://chromium.dev.initialed85.cc';
const TOKEN = process.env.CHROMIUM_TOKEN;
if (!TOKEN) throw new Error('no CHROMIUM_TOKEN');

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
};
const url = arg('url', 'http://192.168.1.213:38137');
const focusExpression = arg('focus-expression', '');
const hookFile = arg('hook-file', '');
const keysFile = arg('keys-file', '');
const readExpression = arg('read-file', '');
const width = Number(arg('width', 1600));
const height = Number(arg('height', 900));
const waitMs = Number(arg('wait-ms', 6000));
const keyGapMs = Number(arg('key-gap-ms', 150));

const MODIFIERS = { alt: 1, ctrl: 2, meta: 4, shift: 8 };
const NAMED = {
  Enter: { vk: 13, code: 'Enter', text: '\r' },
  Space: { vk: 32, code: 'Space', text: ' ' },
  Escape: { vk: 27, code: 'Escape' },
  Tab: { vk: 9, code: 'Tab', text: '\t' },
};

function parseKey(spec) {
  const parts = String(spec).split('+');
  const name = parts.pop();
  let modifiers = 0;
  for (const p of parts) {
    if (!MODIFIERS[p]) throw new Error(`unknown modifier '${p}' in '${spec}'`);
    modifiers |= MODIFIERS[p];
  }
  const named = NAMED[name];
  if (named) return { key: name, code: named.code, vk: named.vk, text: named.text, modifiers };
  const upper = name.toUpperCase();
  const shift = (modifiers & MODIFIERS.shift) !== 0;
  return { key: shift ? upper : name, code: `Key${upper}`, vk: upper.charCodeAt(0), text: shift ? upper : name, modifiers };
}

const http = async (path, init = {}) => {
  const r = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { authorization: `Bearer ${TOKEN}`, ...(init.headers ?? {}) },
  });
  if (!r.ok) throw new Error(`${path} -> ${r.status} ${await r.text()}`);
  return r.text();
};

// SERVICES.md: the bearer token goes on the upgrade itself, and the address to connect to is the
// browser-level one from /json/version, not a per-target url.
const version = JSON.parse(await http('/json/version'));
const tabsBefore = JSON.parse(await http('/json/list')).length;
const ws = new WebSocket(version.webSocketDebuggerUrl, { headers: { authorization: `Bearer ${TOKEN}` } });
await new Promise((res, rej) => {
  ws.addEventListener('open', res);
  ws.addEventListener('error', () => rej(new Error('websocket failed (no 101: the gate is on the handshake)')));
});

let id = 0;
let sessionId = null;
const pending = new Map();
ws.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) {
    const { res, rej } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? rej(new Error(JSON.stringify(msg.error))) : res(msg.result);
  }
};
// Every command after the attach belongs to the page's session; the browser-level connection answers
// "wasn't found" for anything page-scoped otherwise.
const send = (method, params = {}) =>
  new Promise((res, rej) => {
    const n = ++id;
    pending.set(n, { res, rej });
    ws.send(JSON.stringify({ id: n, method, params, ...(sessionId ? { sessionId } : {}) }));
  });

const created = JSON.parse(await http('/json/new?about:blank', { method: 'PUT' }));
const targetId = created.id;
sessionId = (await send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
const s = (method, params = {}) => send(method, params);

await s('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
await s('Page.navigate', { url });
await new Promise((r) => setTimeout(r, waitMs));

const evaluate = async (expression) => {
  const r = await s('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) return { error: r.exceptionDetails.exception?.description ?? String(r.exceptionDetails) };
  return r.result?.value ?? null;
};

const outcome = { targetId, tabsBefore, tabsAfter: 0, focus: null, hook: null, read: null };
if (focusExpression) outcome.focus = await evaluate(focusExpression);
if (hookFile) outcome.hook = await evaluate(readFileSync(hookFile, 'utf8'));

for (const spec of (arg('keys', '') ? arg('keys', '').split(',') : [])) {
  const { key, code, vk, text, modifiers } = parseKey(spec);
  const base = { key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers };
  await s('Input.dispatchKeyEvent', { type: 'rawKeyDown', ...base });
  if (text) await s('Input.dispatchKeyEvent', { type: 'char', ...base, text });
  await s('Input.dispatchKeyEvent', { type: 'keyUp', ...base });
  await new Promise((r) => setTimeout(r, keyGapMs));
}
if (keysFile) {
  for (const spec of JSON.parse(readFileSync(keysFile, 'utf8'))) {
    const { key, code, vk, text, modifiers } = parseKey(spec);
    const base = { key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers };
    await s('Input.dispatchKeyEvent', { type: 'rawKeyDown', ...base });
    if (text) await s('Input.dispatchKeyEvent', { type: 'char', ...base, text });
    await s('Input.dispatchKeyEvent', { type: 'keyUp', ...base });
    await new Promise((r) => setTimeout(r, keyGapMs));
  }
}

await new Promise((r) => setTimeout(r, 800));
if (readExpression) outcome.read = await evaluate(readFileSync(readExpression, 'utf8'));
outcome.tabsAfter = (await http('/json/list')).length;await send('Target.closeTarget', { targetId });
ws.close();
console.log(JSON.stringify(outcome, null, 1));
