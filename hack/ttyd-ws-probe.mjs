#!/usr/bin/env node
/*
 * Talk to a running ttyd the way its browser client does, from a terminal, without a browser.
 *
 * ttyd's websocket protocol is small enough to hold in your head and worth holding, because it is the
 * only place where the two directions of a pane can be measured separately:
 *
 *   client -> ttyd   one binary frame per action, first byte a command: '0' input (the pty's stdin),
 *                    '1' resize (JSON after it), '2' pause, '3' resume.
 *   ttyd  -> client   '0' pty stdout, '1' window title (JSON), '2' client preferences (JSON).
 *   open             the first frame is plain JSON {AuthToken, columns, rows} on the "tty" subprotocol,
 *                    with no command byte in front of it.
 *
 * What that buys, in order of how this repo has needed it:
 *
 *  - the pty's stdin is addressable, so a key mapping can be tested as the bytes it puts on the wire
 *    rather than as a screenshot, and tmux's own input parsing sits in the path being measured;
 *  - the pty's stdout is addressable too, so an escape sequence an application writes (OSC 52 copy, a
 *    Sixel image, a Kitty query) can be confirmed to arrive at the client even though only a browser
 *    could *render* it;
 *  - none of it needs Chromium, a certificate, or a clipboard permission, which is what makes it the
 *    first probe to reach for when a pane misbehaves.
 *
 *   node hack/ttyd-ws-probe.mjs --url ws://192.168.1.213:38143/keys --send '\r' --expect '\r'
 *   node hack/ttyd-ws-probe.mjs --url ws://192.168.1.213:38144/keys \
 *        --send 'printf a\r' --send '\x1b[13;2u' --expect '\x1b[13;2u'
 *   node hack/ttyd-ws-probe.mjs --url ws://192.168.1.213:38141/test --send-file /tmp/seq.bin
 *
 * --send takes C-style escapes; --send-file takes bytes verbatim, which is the honest way to send a
 * Sixel stream. --expect takes a C-style escaped literal and is what turns a measurement into a CI
 * assertion. Output is JSON so a probe can be piped into something that cares about the difference
 * between "no bytes" and "wrong bytes".
 */

import fs from 'node:fs';

const args = process.argv.slice(2);

function arg(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}
function has(name) {
  return args.includes(`--${name}`);
}
function all(name) {
  const out = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === `--${name}` && i + 1 < args.length) out.push(args[++i]);
  }
  return out;
}

if (!args.includes('--url') || args.includes('--help')) {
  console.error('usage: ttyd-ws-probe.mjs --url ws://host:port/base [--send <escaped>]... [--send-file <path>]...');
  console.error('       [--expect <escaped literal>]... [--gap-ms 400] [--collect-ms 900] [--cols 80] [--rows 24]');
  console.error('       [--token <value> | --token-url http://host:port/base/token] [--raw]');
  process.exit(2);
}

const url = arg('url', '');
const cols = Number(arg('cols', '80'));
const rows = Number(arg('rows', '24'));
const gapMs = Number(arg('gap-ms', '400'));
const collectMs = Number(arg('collect-ms', '900'));

// C-style escapes, and nothing else: \x1b is the escape byte, \e is accepted as a synonym because
// terminfo writes it that way, and a stray backslash should be reported rather than silently eaten.
function unescapeC(text, where) {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch !== '\\') {
      out += ch;
      continue;
    }
    const next = text[++i];
    if (next === undefined) throw new Error(`${where}: a trailing backslash`);
    if (next === 'x') {
      const hex = text.substr(i + 1, 2);
      if (!/^[0-9a-fA-F]{2}$/.test(hex)) throw new Error(`${where}: \\x needs two hex digits near "${text.slice(i)}"`);
      out += String.fromCharCode(parseInt(hex, 16));
      i += 2;
      continue;
    }
    const map = { e: '\x1b', n: '\n', r: '\r', t: '\t', '0': '\0', '\\': '\\' };
    if (!(next in map)) throw new Error(`${where}: unknown escape \\${next}`);
    out += map[next];
  }
  return out;
}

// cat -v for a terminal that cannot show a control byte, plus a length: the two facts that decide
// whether a sequence arrived, and whether anything else arrived with it.
function visible(bytes) {
  let out = '';
  for (const b of bytes) {
    if (b === 0x1b) out += '^[';
    else if (b === 0x07) out += '^G';
    else if (b === 0x0a) out += '^J';
    else if (b === 0x0d) out += '^M';
    else if (b === 0x7f) out += '^?';
    else if (b < 0x20 || b === 0x5c) out += `\\x${b.toString(16).padStart(2, '0')}`;
    else if (b > 0x7e) out += `<${b.toString(16).padStart(2, '0')}>`;
    else out += String.fromCharCode(b);
  }
  return out;
}

async function getToken() {
  const direct = arg('token', '');
  if (direct) return direct;
  const tokenUrl = arg('token-url', '');
  if (!tokenUrl) return '';
  const res = await fetch(tokenUrl);
  if (!res.ok) throw new Error(`token endpoint ${tokenUrl} answered ${res.status}`);
  const body = await res.json();
  if (!body.token) throw new Error(`${tokenUrl} returned no token: ${JSON.stringify(body)}`);
  return body.token;
}

const sends = [];
for (const s of all('send')) sends.push({ from: 'arg', bytes: Buffer.from(unescapeC(s, `--send ${s}`), 'binary') });
for (const f of all('send-file')) sends.push({ from: f, bytes: fs.readFileSync(f) });
const expects = all('expect').map((e) => ({ pattern: e, bytes: Buffer.from(unescapeC(e, `--expect ${e}`), 'binary') }));

const token = await getToken();
const received = [];
const messages = [];
const socket = new WebSocket(url, ['tty']);
socket.binaryType = 'arraybuffer';

const Command = { output: 0x30, title: 0x31, preferences: 0x32, input: 0x30, resize: 0x31 };

function frame(command, payload) {
  const body = Buffer.from(payload);
  const out = Buffer.allocUnsafe(body.length + 1);
  out[0] = command;
  body.copy(out, 1);
  return out;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// Attached before the header is sent: ttyd only starts producing output after it, but a pane that
// prints on startup (a shell banner, tmux's redraw) is exactly the traffic worth not missing.
socket.addEventListener('message', (event) => {
  const data = new Uint8Array(event.data);
  if (!data.length) return;
  const command = String.fromCharCode(data[0]);
  const body = data.subarray(1);
  if (command === '0') {
    received.push(Buffer.from(body));
  } else if (command === '1' || command === '2') {
    messages.push({ command: command === '1' ? 'title' : 'preferences', text: Buffer.from(body).toString('utf8') });
  } else {
    messages.push({ command: 'unknown', text: visible(Buffer.from(data)) });
  }
});

await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve);
  socket.addEventListener('error', () => reject(new Error(`websocket error connecting to ${url}`)));
  setTimeout(() => reject(new Error(`websocket open timed out for ${url}`)), 8000);
});

socket.send(JSON.stringify({ AuthToken: token, columns: cols, rows: rows }));
await sleep(500);

for (const s of sends) {
  socket.send(frame(Command.input, s.bytes));
  await sleep(gapMs);
}
await sleep(collectMs);
socket.close();
await sleep(200);

const stream = Buffer.concat(received);
const matched = expects.map((e) => ({ pattern: e.pattern, found: stream.includes(e.bytes), occurrences: countBytes(stream, e.bytes) }));
const failed = matched.filter((m) => !m.found);

function countBytes(haystack, needle) {
  let count = 0;
  for (let i = 0; ; i++) {
    const at = haystack.indexOf(needle, i);
    if (at < 0) break;
    count++;
    i = at + needle.length;
  }
  return count;
}

const report = {
  url,
  cols,
  rows,
  sent: sends.map((s) => ({ from: s.from, bytes: s.bytes.length, visible: visible(s.bytes) })),
  receivedBytes: stream.length,
  received: has("raw") ? stream.toString("utf8") : visible(stream),
  messages,
  expects: matched,
};
process.stdout.write(JSON.stringify(report, null, 2) + '\n');
if (failed.length) {
  console.error(`FAIL: ${failed.map((f) => f.pattern).join(', ')} did not arrive from ${url}`);
  process.exit(1);
}
