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

const outcome = { targetId: target.targetId, tab: target.reused, tabsBefore, tabsAfter: 0, load: null, value: null, error: null };outcome.load = await loaded;
await new Promise((r) => setTimeout(r, waitMs)); // xterm, websockets and lazy layout are not load events

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
