// A CDP client for the shared headless Chromium (chromium.dev.initialed85.cc), used by the front
// testbed for the two things the one-shot /render /screenshot /eval routes cannot do:
//
//   - wait: those routes evaluate too early to see anything a pane builds after load (xterm only exists
//     once ttyd's websocket opens), and /eval does not await a Promise.
//   - drive: evaluate, then look at the result of what the evaluate did. Expanding a pane, scrolling a
//     pane and then screenshotting it is the only way to check that a CSS change fixed the thing rather
//     than moved it.
//
// It also sets the viewport, which matters because the desktop's overflow depends on it: the deployed
// desktop is 20 panes wide, and at 800px a pane is 40px wide.
//
// Why a websocket client at all: home-ops SERVICES.md documents this exact shape (Node's built-in
// WebSocket carries the bearer token on the upgrade; websocat is not installed on the dev boxes), plus
// the caveats this implements: one socket for the whole batch (rapid reconnects to the same target are
// rejected), a target created with PUT /json/new and closed with Target.closeTarget over the socket
// (no other close path is proxied), tab count measured before acquisition, and a dead target that looks
// like success unless documentURI is read.
//
//   node hack/front-cdp.mjs --url http://192.168.1.213:38137/ [--expression-file f.js] [--wait-ms 3000]
//                           [--shot out.png] [--width 1280] [--height 800] [--keep-tab]
//
// Two more switches exist for the clipboard work, because both halves of it need them:
//   --ignore-cert-errors            a ttyd started with -c/-k serves a self-signed certificate, and
//                                   navigator.clipboard only exists in a secure context, so the https
//                                   path has to be reachable to be tested at all.
//   --grant-permissions a,b,c       clipboard reads are permission-gated, and reading back what a copy
//                                   wrote is the only proof that the copy landed in the browser rather
//                                   than merely being attempted.
//
// And three for the file-into-a-pane work, because a file paste and a file drop are a different event
// class from a keystroke and from text: they carry a DataTransfer holding a File.
//
//   --paste-file <path>[::<name>::<mime>]   one file paste
//   --drop-file  <path>[::<name>::<mime>]   one file drop (dragenter, dragover, then drop)
//   --paste-text <text>                     one plain text paste, which must keep working
//
// These are constructed in the page rather than through CDP, and that is worth being explicit about:
// Input.dispatchKeyEvent has a real input pipeline behind it, but CDP has no way to hand a page a File -
// DragData items are strings, and a genuine OS-level drag needs a desktop with files on it. So the bytes
// are read here, rebuilt as a File in the page, wrapped in a DataTransfer, and dispatched at an element
// inside the terminal. Everything after the event stays real: xterm's own listeners, ttyd's capture
// handler, the websocket, the server, the file on disk. What is not real is the browser's own decision to
// accept a drag from the operating system, and no headless container can produce that.
//
//   --file-selector <css>   where a file event is dispatched (default .xterm-viewport, i.e. inside the
//                           terminal, so the bubbling reaches the capture listener ttyd put on an ancestor)
//   --text-selector <css>   where a text paste is dispatched (default .xterm-helper-textarea, which is the
//                           node xterm itself listens on - dispatching a text paste somewhere else would
//                           prove nothing about xterm)
//   --pane-selector <css>   when the page under test is the desktop rather than a bare ttyd pane, the css
//                           of the pane's iframe to drive. The desktop frames every pane under its own
//                           origin, so the iframe's document is scriptable from the page, and the whole
//                           expression is evaluated through that frame's own window.eval so the File, the
//                           DataTransfer and the event are all built in the realm that receives them.
//   --drop-x / --drop-y     drop coordinates (default: centre of --file-selector)
//   --file-settle-ms        how long to wait after the last file action, because an upload is not a
//                           synchronous event

import { readFileSync, writeFileSync } from "node:fs";

const BASE = process.env.CHROMIUM ?? "https://chromium.dev.initialed85.cc";
// The gate's credential (home-ops SERVICES.md: kubectl -n auth get secret api-tokens, key
// API_TOKEN_EDWARD). hack/front-testbed.sh has the token and passes it here; the file is only a fallback
// for running this script on its own.
const TOKEN =
  process.env.CHROMIUM_TOKEN ??
  (() => {
    try {
      return readFileSync(`${process.env.HOME}/.cache/slopyphus/chromium-token`, "utf8").trim();
    } catch (_) {
      throw new Error("no chromium token: set CHROMIUM_TOKEN, or run this through hack/front-testbed.sh cdp");
    }
  })();

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}
const has = (name) => process.argv.includes(`--${name}`);

// Ordered --key list, and the CDP modifier bitmask Chrome expects (alt 1, ctrl 2, meta 4, shift 8).
const keySpecs = [];
for (let i = 0; i < process.argv.length; i++) {
  if (process.argv[i] === "--key") keySpecs.push(process.argv[i + 1]);
}
const keyGapMs = Number(arg("key-gap-ms", 220));

// File actions, kept in the order they were given on the command line, so one run can paste, then drop,
// then paste text and still read one ordered result out.
const fileActions = [];
for (let i = 0; i < process.argv.length; i++) {
  const flag = process.argv[i];
  if (flag === "--paste-file" || flag === "--drop-file" || flag === "--paste-text")
    fileActions.push({ kind: flag.slice(2), spec: process.argv[i + 1] ?? "" });
}
const fileSelector = arg("file-selector", ".xterm-viewport");
const textSelector = arg("text-selector", ".xterm-helper-textarea");
const paneSelector = arg("pane-selector", "");
const dropX = Number(arg("drop-x", 0));
const dropY = Number(arg("drop-y", 0));
const fileSettleMs = Number(arg("file-settle-ms", 2000));
// --capture-console: ttyd's client says things ("pane upload refused: … limit …"), and those words are
// the only window into the browser half of a failure. Runtime.consoleAPICalled covers the page and every
// frame in it, including a pane's iframe.
const captureConsole = has("capture-console");

// <path>[::<name>::<mime>], several of them separated by | so that one event can carry several files -
// copying two screenshots out of Finder and pasting them together is a normal thing a user does, and a
// DataTransfer holding two Files is a different code path from two pastes. The last two fields are
// optional. A browser hands a File with a name and a type attached, and the interesting names are the
// ones a real paste produces ("Screenshot 2026-11-06 at 15.30.05.png"), so the name is worth overriding
// even though it has nothing to do with the path here. The separator is :: because a single colon appears
// in URLs and a semicolon in mimetypes.
const parseFileSpec = (spec) => {
  const parts = spec.split("|").filter((p) => p.length);
  if (!parts.length) throw new Error("--paste-file/--drop-file needs a path");
  return parts.map((part) => {
    const [path, name, mime] = part.split("::");
    if (!path) throw new Error(`--paste-file/--drop-file: empty path in '${part}'`);
    const base = name || path.split("/").pop();
    const type =
      mime ||
      (/\.png$/i.test(path) ? "image/png" : /\.jpe?g$/i.test(path) ? "image/jpeg" : /\.webp$/i.test(path) ? "image/webp" : /\.gif$/i.test(path) ? "image/gif" : /\.txt$/i.test(path) ? "text/plain" : "application/octet-stream");
    return { path, base, type };
  });
};

const CDP_MODIFIERS = { alt: 1, ctrl: 2, meta: 4, shift: 8 };
const NAMED_KEYS = {
  Enter: { vk: 13, code: "Enter", text: "\r" },
  Escape: { vk: 27, code: "Escape" },
  Tab: { vk: 9, code: "Tab", text: "\t" },
  Space: { vk: 32, code: "Space", text: " " },
  Backspace: { vk: 8, code: "Backspace" },
};

function parseKeySpec(spec) {
  const parts = String(spec).split("+");
  const name = parts.pop();
  let modifiers = 0;
  for (const p of parts) {
    if (!CDP_MODIFIERS[p]) throw new Error(`--key: unknown modifier '${p}' in '${spec}'`);
    modifiers |= CDP_MODIFIERS[p];
  }
  const named = NAMED_KEYS[name];
  if (named) return { key: name, code: named.code, vk: named.vk, text: named.text, modifiers };
  if (name.length === 1) {
    const upper = name.toUpperCase();
    const shift = (modifiers & CDP_MODIFIERS.shift) !== 0;
    return { key: shift ? upper : name, code: `Key${upper}`, vk: upper.charCodeAt(0), text: shift ? upper : name, modifiers };
  }
  throw new Error(`--key: unsupported key '${name}' in '${spec}'`);
}

const url = arg("url", "about:blank");
const expressionFile = arg("expression-file", "");
const waitMs = Number(arg("wait-ms", 3000));
const shot = arg("shot", "");
const width = Number(arg("width", 1280));
const height = Number(arg("height", 800));

const auth = { authorization: `Bearer ${TOKEN}` };

async function http(path, init = {}) {
  const res = await fetch(`${BASE}${path}`, { ...init, headers: { ...auth, ...(init.headers ?? {}) } });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path} -> ${res.status} ${text.slice(0, 200)} (a 401 is the token gate)`);
  return text;
}

const version = JSON.parse(await http("/json/version"));
const tabsBefore = JSON.parse(await http("/json/list")).length;

const ws = new WebSocket(version.webSocketDebuggerUrl, { headers: auth });
await new Promise((resolve, reject) => {
  ws.addEventListener("open", resolve);
  ws.addEventListener("error", () => reject(new Error("websocket failed (no 101: the gate is on the handshake)")));
});

let id = 0;
const pending = new Map();
const events = [];
ws.addEventListener("message", (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  } else if (msg.method) {
    events.push(msg);
  }
});

function send(method, params = {}, sessionId) {
  const msgId = ++id;
  const payload = { id: msgId, method, params };
  if (sessionId) payload.sessionId = sessionId;
  ws.send(JSON.stringify(payload));
  return new Promise((resolve, reject) => {
    pending.set(msgId, { resolve, reject });
    setTimeout(() => pending.has(msgId) && reject(new Error(`${method} timed out`)), 30000).unref?.();
  });
}

// Tab acquisition, in the order SERVICES.md says this service needs it: reuse a spare about:blank,
// otherwise PUT one into existence, otherwise reuse anything already live.
async function acquireTarget() {
  const tabs = JSON.parse(await http("/json/list"));
  const spare = tabs.find((t) => t.type === "page" && (t.url === "about:blank" || t.url === ""));
  if (spare?.webSocketDebuggerUrl) return { targetId: spare.id, reused: "spare about:blank" };
  try {
    const created = JSON.parse(await http("/json/new?about:blank", { method: "PUT" }));
    if (created?.id) return { targetId: created.id, reused: "created" };
  } catch (_) {
    // A crowded /json/new has been measured answering without a usable id.
  }
  const live = tabs.find((t) => t.type === "page");
  if (live) return { targetId: live.id, reused: "existing tab (spent)" };
  throw new Error("no tab available");
}

const target = await acquireTarget();
const { sessionId } = await send("Target.attachToTarget", { targetId: target.targetId, flatten: true });

await send("Page.enable", {}, sessionId);
if (captureConsole) {
  await send("Runtime.enable", {}, sessionId);
  await send("Log.enable", {}, sessionId);
}
await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false }, sessionId);
// Security.* is per target and has to be set before the navigation that would otherwise fail on a
// self-signed certificate; Browser.grantPermissions is browser level, so it goes without a sessionId.
if (has("ignore-cert-errors")) {
  await send("Security.enable", {}, sessionId);
  await send("Security.setIgnoreCertificateErrors", { ignore: true }, sessionId);
}
const grant = arg("grant-permissions", "");
if (grant) {
  const permissions = grant.split(",").map((s) => s.trim()).filter(Boolean);
  const origin = new URL(url).origin;
  await send("Browser.grantPermissions", { origin, permissions });
}
await send("Page.navigate", { url }, sessionId);

// A load event is the honest wait; the timer is the fallback for a page that never finishes loading.
const loaded = new Promise((resolve) => {
  const until = Date.now() + Math.max(waitMs, 10000);
  const poll = setInterval(() => {
    if (events.some((e) => e.sessionId === sessionId && e.method === "Page.loadEventFired")) {
      clearInterval(poll);
      resolve("loadEventFired");
    } else if (Date.now() > until) {
      clearInterval(poll);
      resolve("timed out waiting for load");
    }
  }, 100);
  poll.unref?.();
});

const outcome = { targetId: target.targetId, tab: target.reused, tabsBefore, tabsAfter: 0, load: null, value: null, error: null };
outcome.load = await loaded;
await new Promise((r) => setTimeout(r, waitMs)); // xterm, websockets and lazy layout are not load events

// Keys go through Chrome's input pipeline, so a press produces keydown, keypress (when the key carries
// text) and keyup the way a physical keyboard does. Focus first: Chrome delivers key events to the focused
// element, and a headless page has nothing focused.
if (keySpecs.length) {
  // Focus is what routes a key event, and a headless page has nothing focused. The default targets a bare
  // ttyd pane; a pane framed by the desktop needs the expression to reach into the iframe instead, so it is
  // configurable rather than guessed at.
  const focusExpression = arg(
    "focus-expression",
    `(() => { const t = document.querySelector('.xterm-helper-textarea'); t && t.focus(); return !!t; })()`,
  );
  await send("Runtime.evaluate", { expression: focusExpression }, sessionId);
  for (const spec of keySpecs) {
    const { key, code, vk, text, modifiers } = parseKeySpec(spec);
    const base = { key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers };
    await send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...base }, sessionId);
    if (text) await send("Input.dispatchKeyEvent", { type: "char", ...base, text }, sessionId);
    await send("Input.dispatchKeyEvent", { type: "keyUp", ...base }, sessionId);
    await new Promise((r) => setTimeout(r, keyGapMs));
  }
}

if (fileActions.length) {
  outcome.fileActions = [];
  for (const action of fileActions) {
    const isText = action.kind === "paste-text";
    const selector = isText ? textSelector : fileSelector;
    const specs = isText ? null : parseFileSpec(action.spec);
    const items = isText
      ? null
      : specs.map((spec) => ({ b64: readFileSync(spec.path).toString("base64"), name: spec.base, type: spec.type }));
    const payload = isText ? action.spec : JSON.stringify(items);

    // Built as one self-contained expression per action, dispatched against a real element in the real
    // page. Each dispatched event reports defaultPrevented, which is how "the upload path took this
    // event, and only this event" is measured from the browser side.
    const expression = isText
      ? `(() => {
          const target = document.querySelector(${JSON.stringify(selector)});
          if (!target) return { ok: false, reason: 'no element matching ${selector}' };
          const transfer = new DataTransfer();
          transfer.setData('text/plain', ${JSON.stringify(payload)});
          const event = new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: transfer });
          target.dispatchEvent(event);
          return { ok: true, kind: 'paste-text', text: ${JSON.stringify(payload)}, defaultPrevented: event.defaultPrevented };
        })()`
      : `(() => {
          const target = document.querySelector(${JSON.stringify(selector)});
          if (!target) return { ok: false, reason: 'no element matching ${selector}' };
          const items = ${payload};
          const transfer = new DataTransfer();
          const made = items.map((item) => {
            const bytes = Uint8Array.from(atob(item.b64), (c) => c.charCodeAt(0));
            const file = new File([bytes], item.name, { type: item.type });
            transfer.items.add(file);
            return { name: file.name, type: file.type, size: file.size };
          });
          const rect = target.getBoundingClientRect();
          const x = ${dropX} || Math.round(rect.left + rect.width / 2);
          const y = ${dropY} || Math.round(rect.top + rect.height / 2);
          const fired = [];
          const fire = (ctor, type, init) => {
            const event = new ctor(type, { bubbles: true, cancelable: true, ...init });
            target.dispatchEvent(event);
            fired.push({ type, defaultPrevented: event.defaultPrevented });
          };
          if (${JSON.stringify(action.kind)} === 'paste-file') {
            fire(ClipboardEvent, 'paste', { clipboardData: transfer });
          } else {
            // A drop that a page has not accepted with dragover never arrives at all, so the dragover
            // answer is part of the measurement rather than setup.
            fire(DragEvent, 'dragenter', { dataTransfer: transfer, clientX: x, clientY: y });
            fire(DragEvent, 'dragover', { dataTransfer: transfer, clientX: x, clientY: y });
            fire(DragEvent, 'drop', { dataTransfer: transfer, clientX: x, clientY: y });
          }
          return { ok: true, kind: ${JSON.stringify(action.kind)}, files: made, at: [x, y], fired };
        })()`;

    const result = await send(
      "Runtime.evaluate",
      {
        expression: paneSelector
          ? `(() => {
              const pane = document.querySelector(${JSON.stringify(paneSelector)});
              if (!pane || !pane.contentWindow) return { ok: false, reason: 'no iframe matching ${paneSelector}' };
              return pane.contentWindow.eval(${JSON.stringify(`(${expression})`)});
            })()`
          : expression,
        returnByValue: true,
        awaitPromise: true,
      },
      sessionId,
    );
    if (result.exceptionDetails) {
      outcome.fileActions.push({
        kind: action.kind,
        error: result.exceptionDetails.exception?.description ?? JSON.stringify(result.exceptionDetails),
      });
      continue;
    }
    outcome.fileActions.push(result.result?.value ?? { kind: action.kind, error: "the page returned nothing" });
    await new Promise((r) => setTimeout(r, fileSettleMs));
  }
}

if (expressionFile) {
  const expression = readFileSync(expressionFile, "utf8");
  // documentURI first: a target that failed to connect is Chrome's own error page and evaluates fine.
  const guard = await send(
    "Runtime.evaluate",
    { expression: "document.documentURI", returnByValue: true },
    sessionId,
  );
  const uri = guard.result?.value ?? "";
  if (uri.startsWith("chrome-error://")) {
    outcome.error = `the target never left ${uri} (the url did not load)`;
  } else {
    const result = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (result.exceptionDetails) {
      outcome.error = result.exceptionDetails.exception?.description ?? JSON.stringify(result.exceptionDetails);
    } else {
      outcome.value = result.result?.value;
    }
  }
}

if (captureConsole) {
  // A CDP event is {method, params}: the interesting fields live in params, and reading them off the
  // envelope is how a capture comes back full of empty lines that look like a silent page.
  const argText = (a) =>
    a.type === "string"
      ? a.value
      : a.value !== undefined
        ? String(a.value)
        : a.description ??
          (a.preview?.properties ?? []).map((p) => `${p.name}=${p.value ?? p.type}`).join(", ") ??
          a.type;
  const consoleLines = events
    .filter((e) => e.method === "Runtime.consoleAPICalled")
    .map((e) => ({ level: e.params?.type, text: (e.params?.args || []).map(argText).join(" ") }));
  const logLines = events
    .filter((e) => e.method === "Log.entryAdded")
    .map((e) => ({ level: e.params?.entry?.level, text: `${e.params?.entry?.source} ${e.params?.entry?.url ?? ""}: ${e.params?.entry?.text ?? ""}` }));
  outcome.console = consoleLines.concat(logLines);
}

if (shot) {
  const { data } = await send("Page.captureScreenshot", { format: "png" }, sessionId);
  writeFileSync(shot, Buffer.from(data, "base64"));
  outcome.shot = shot;
}

if (!has("keep-tab")) {
  await send("Target.closeTarget", { targetId: target.targetId });
}
outcome.tabsAfter = JSON.parse(await http("/json/list")).length;
ws.close();

console.log(JSON.stringify(outcome, null, 1));
