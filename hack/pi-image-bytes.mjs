#!/usr/bin/env node
// Print the exact bytes Pi would put on the wire for an image, without running Pi.
//
// Pi picks an image protocol per terminal and encodes it itself. Asking "will an image Pi prints show up in
// a slopyphus pane?" cannot be answered by hand-writing what I think Pi emits, because the answer turns out
// to hang on details of the header - xterm's iTerm handler refuses a sequence whose header has no `size=`,
// for example - and a hand-written approximation would have missed exactly that.
//
// So this extracts Pi's own encoder out of its shipped bundle and runs it. The function is self-contained
// (it only needs Buffer), which is what makes this possible without importing a whole bundle graph: find
// `function encodeITerm2`, take the balanced braces, eval it, call it the way Pi's own call site calls it.
//
//   node hack/pi-image-bytes.mjs <image file> > seq.bin
//   node hack/pi-image-bytes.mjs <image file> --wrap-tmux > seq.bin   # tmux passthrough DCS wrapper
//   node hack/pi-image-bytes.mjs <image file> --header-only           # the header, no base64 body
//
// --st replaces the OSC terminator: tmux's passthrough reader terminates a DCS with ST, and a BEL inside
// the payload is a plausible way for a wrapper to end early, so whether an iTerm sequence terminated by ST
// survives where the BEL form does not is a thing to measure rather than argue about.
//
// --wrap-tmux exists because tmux has a text screen model: a sequence is forwarded to the outer terminal
// only when it is handed to tmux inside \ePtmux;<payload>, with every escape in the payload doubled. The
// wrapper is written by the program that prints, never by tmux's client, so if a pane runs under tmux this
// is the only spelling that can carry an image.
//
// The closing ST is NOT doubled, which is the opposite of how the tmux man page reads. tmux/input.c's
// dcs_escape state table dispatches the DCS on ESC followed by \\, and reads ESC ESC as one literal ESC; a
// doubled closing ST is therefore payload, the wrapper never ends, and everything the pane prints after it
// is swallowed. hack/pane-byte-cases.sh measures both spellings: the doubled one forwards nothing and stops
// the case's own echo from arriving, the single one forwards a complete OSC 1337 and text carries on.
// is the only spelling that can survive it.
import { readdirSync, readFileSync } from 'node:fs';

const PI_BUNDLE = process.env.PI_BUNDLE ??
  '/root/.pi/agent/install/releases/1.5.0/node_modules/@earendil-works/pi-coding-agent/dist/bundle/chunks';

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : (process.argv[i + 1] ?? true);
}

const file = process.argv[2];
if (!file) {
  console.error('usage: pi-image-bytes.mjs <image file> [--wrap-tmux] [--header-only] [--call-site]');
  process.exit(2);
}

// Find a function in the bundle by name and return its source, brace-balanced. Strings inside the function
// body can contain braces - the encoder builds template literals - so the scan tracks quote state rather
// than counting blindly.
function extractFunction(source, name) {
  const at = source.indexOf(`function ${name}(`);
  if (at === -1) throw new Error(`${name} not found in the Pi bundle`);
  // The body starts after the parameter list, which itself can contain braces (a default parameter such as
  // `options={}`). Starting at the first brace in the line stops on that one and returns half a function.
  let i = at + name.length;
  let parens = 0;
  for (; i < source.length; i++) {
    if (source[i] === '(') parens++;
    if (source[i] === ')') {
      parens--;
      if (parens === 0) { i++; break; }
    }
  }
  while (i < source.length && source[i] !== '{') i++;
  let depth = 0;
  let quote = null;
  for (; i < source.length; i++) {
    const c = source[i];
    if (quote) {
      if (c === '\\') { i++; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
    if (c === '{') depth++;
    if (c === '}') {
      depth--;
      if (depth === 0) return source.slice(at, i + 1);
    }
  }
  throw new Error(`${name}: unbalanced braces`);
}

function findChunk(pattern) {
  for (const name of readdirSync(PI_BUNDLE)) {
    if (!name.endsWith('.js')) continue;
    const text = readFileSync(`${PI_BUNDLE}/${name}`, 'utf8');
    if (text.includes(pattern)) return { name, text };
  }
  throw new Error(`no chunk under ${PI_BUNDLE} contains ${JSON.stringify(pattern)}`);
}

const chunk = findChunk('function encodeITerm2(');
const encoder = extractFunction(chunk.text, 'encodeITerm2');
// Pi's own call site, quoted so the options measured here are the ones Pi actually uses rather than the
// ones I would have guessed. `height:"auto"` is Pi's spelling and is not an iTerm2 unit; whether the
// browser accepts it is a measurement, not something to argue about.
const callSites = (chunk.text.match(/encodeITerm2\([^)]*\{[^{}]*\}\)/g) ?? [])
  .filter((s) => !s.startsWith('encodeITerm2(base64Data,options'));
const encode = new Function(`${encoder}; return ${'encodeITerm2'};`)();

const data = readFileSync(file);
const base64 = data.toString('base64');
const options = { width: Number(arg('width', 80)), height: 'auto', preserveAspectRatio: true };
const sequence = encode(base64, options);

const wrap = process.argv.includes('--wrap-tmux');
let payload = sequence;
if (process.argv.includes('--st')) {
  payload = payload.replace(/\x07$/, '\x1b\\');
}
let out = Buffer.from(payload, 'binary');
if (wrap) {
  const doubled = Buffer.from(payload.replace(/\x1b/g, '\x1b\x1b'), 'binary');
  out = Buffer.concat([
    Buffer.from('\x1bPtmux;\x1b', 'binary'),
    doubled,
    Buffer.from('\x1b\\', 'binary'),
  ]);
}

if (process.argv.includes('--header-only')) {
  out = Buffer.from(sequence.slice(0, sequence.indexOf(':') + 1), 'binary');
}

if (process.argv.includes('--call-site')) {
  console.error(`Pi call sites: ${JSON.stringify(callSites)}`);
}
if (process.stdout.isTTY) {
  console.log(JSON.stringify({
    chunk: chunk.name,
    encoder,
    header: sequence.slice(0, sequence.indexOf(':')),
    sequenceBytes: out.length,
    decodedBytes: data.length,
    wrapped: wrap,
  }, null, 2));
} else {
  process.stdout.write(out);
}
