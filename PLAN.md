# Plan: ttyd + tmux + Pi terminal UX

Repo layout relevant to this plan:

| Layer | Where | Notes |
|---|---|---|
| Front desktop (iframe grid) | `index.html.template`, `nginx.conf.template`, `docker-entrypoint.nginx.sh` | built by `Dockerfile.nginx` |
| ttyd server (owned fork) | `vendor/ttyd` @ `slopyphus` (pin `5dbdaab`) | compiled in `Dockerfile`, CI compares `src/html.h` payload |
| xterm.js (owned fork) | `vendor/xterm.js` @ `slopyphus` (pin `9a512d1`) | built into `lib/xterm.js` by `hack/build-ttyd-client.sh` |
| ttyd web client | `vendor/ttyd/html/src/**` | bundled into `src/html.h` |
| tmux + Pi launch | `.tmux.conf`, `docker-entrypoint.sh` | runtime |
| Local client build loop | `hack/build-ttyd-client.sh` | rebuilds `vendor/ttyd/src/html.h` |

Client changes are invisible until `hack/build-ttyd-client.sh` regenerates
`vendor/ttyd/src/html.h` and that header is committed inside the fork.

## Task 1 — copy from tmux into the browser clipboard

Status: **complete** — implemented, deployed, and confirmed in the user's browser at the dev front desktop
(select in a pane, release the mouse, paste into an application outside the browser: the text arrives).

Commit: `initialed85/ttyd` @ `779f6ee` (client + regenerated `src/html.h`).

What was measured, in order:

1. `xterm.js` 5.4.0 has no OSC 52 handler at all (`rg 'osc\(' src` is empty; `InputHandler` registers
   OSC 0/1/2/4/8/10/11/12/104..112 only), but `ITerminal.parser` → `IParser.registerOscHandler` is public
   API (`typings/xterm.d.ts:801`, `src/browser/public/Terminal.ts:83`), so the fix needs no xterm patch.
2. tmux 3.6 in this image **emits OSC 52 by default** (`set-clipboard external`) and its mouse-release
   binding lives in the **copy-mode** table because `mode-keys` defaults to **emacs**. The old
   `.tmux.conf` unbound `MouseDragEnd1Pane` from **copy-mode-vi**, which this configuration never
   activates — that line was a no-op, and the real reason copy did nothing was (1).
3. Battery of pty captures (`/tmp/osc52/run.sh`, one isolated tmux server per case via `-L exp`):
   `set-clipboard off` → 1 sequence; default → 2; `set-clipboard on` → 2; and
   `terminal-overrides ",*:Ms=\E]52;..."` → **0**, because tmux does not expand `\E` there (the `\033`
   form works). Conclusion: turn it on explicitly, do not add an `Ms` override.
4. `hack/app-passthrough` capture against the repo's own `.tmux.conf`: an escape written by an
   application *inside* the pane reaches the outer pty — `codes='c' decoded='pi copy me\n'` — which is
   what `PI_CLIPBOARD_OSC52=1` relies on, and `allow-passthrough on` is what permits it.
5. Browser proof (`hack/probe-osc52-copy.js` through `hack/front-cdp.mjs` against a ttyd built from this
   image): both paths reach the new handler — scratch textareas appear carrying `pi copy me to the
   browser\n` and the line tmux selected — with no console warnings. `execCommand('copy')` returns false
   in headless Chromium and `navigator.clipboard` does not exist over plain http (`secureContext:
   false`), so this proves the handler fires and decodes correctly, not the final write.

Residual, settled live on 2026-11-06 by the user's own browser at
https://slopyphus.dev.initialed85.cc/slopyphus/: through the front (https, secure context) the write goes
through `navigator.clipboard.writeText`, which the http testbed cannot exercise. Two attempts to make ttyd
serve TLS in a testbed failed (`-C`/`-K` accepted, `libssl` linked, but the port answers plain HTTP), so that
half was left to live validation rather than faked - and live validation is what closed it. The chain that
had to work end to end, with only its last link unverifiable headlessly: tmux `set-clipboard on` emitting OSC
52 on mouse release in `copy-mode`, ttyd's registered OSC 52 handler decoding it, and the browser accepting
the write into its own clipboard.

Findings:
- `xterm.js` 5.4.0 has no OSC 52 handler (`rg osc\( src` is empty; OSC 0/1/2/4/8/10/11/12/104..112
  only), but `registerOscHandler` **is public API** (`typings/xterm.d.ts:1805`), so OSC 52 can be
  implemented in the ttyd client fork without patching xterm internals.
- tmux emits OSC 52 when `set-clipboard on` and the outer terminfo has `Ms`; the outer terminal here
  is ttyd's `xterm-256color`.
- `.tmux.conf` deliberately `unbind-key -T copy-mode-vi MouseDragEnd1Pane`, so releasing the mouse
  never copies at all.
- Pi has `PI_CLIPBOARD_OSC52=1` (docs/environment-variables.md) which is exactly the multiplexer case.

Steps:
1. `.tmux.conf`: `set -g set-clipboard on`, `set -g terminal-overrides` `Ms` capability, rebind
   `MouseDragEnd1Pane` to `copy-pipe-and-cancel`.
2. ttyd client: `terminal.registerOscHandler(52, ...)`, decode base64 payload, write to
   `navigator.clipboard` with a textarea + `execCommand('copy')` fallback for non-secure contexts,
   show the ✂ overlay.
3. `docker-entrypoint.sh`: `PI_CLIPBOARD_OSC52=1` so Pi's own copy reaches the browser clipboard.
4. Test: pty capture (`script`) proves tmux emits `\E]52;`; CDP proves the client handler fires.

## Task 2 — Shift+Enter without the front door

Status: **implemented in the fork and measured on all three paths** (direct ttyd path, ttyd through
tmux, ttyd framed by the front desktop). The first version passed its own measurement and failed in a real
browser; the keypress finding below is why the feature is now correct rather than nearly correct.

Observed: works through the slopyphus front (nginx synthesises a Ctrl+J key event into the iframe),
broken when a ttyd path is opened directly (`https://slopyphus.../home-ops/`).

Findings (measured, each with the pane's application putting its own pty in raw mode — `stty raw -echo;
cat > /tmp/k.bin` — because that is the condition a TUI puts itself in, and a cooked pane quietly
rewrites what you are trying to measure):

- xterm.js 5.4.0 evaluates Enter without consulting Shift (`src/common/input/Keyboard.ts`, case 13:
  `ev.altKey ? ESC + CR : CR`). A pane cannot tell Shift+Enter from Enter, so the browser side is the
  only place the distinction can be made — and `extended-keys on` in `.tmux.conf` cannot rescue it,
  because xterm.js has no Kitty keyboard protocol support at all (`Keyboard.ts` has no extended-keys
  branch, `ITerminalOptions` has no kitty flag; the only keyboard option in ttyd's own client options is
  `macOptionIsMeta`).
- tmux 3.6 *parses* a CSI-u Enter and rewrites it to a plain CR: `\x1b[13;2u` (Shift+Enter) and
  `\x1b[13;5u` (Ctrl+Enter) each arrive on the application's stdin as `\r`, which is Submit — the exact
  opposite of the key's meaning. A raw LF is forwarded unchanged. An earlier revision of this plan said
  tmux turned CSI-u into LF; that reading came from a cooked pane, where ICRNL maps CR to LF and the line
  discipline echoes input. Raw mode is the only version worth trusting.
- LF is what Ctrl+J types, and `tui.input.newLine` defaults to `shift+enter, ctrl+j`
  (`pi/docs/settings.md:204`), so LF is the one spelling both paths already accept. The front page already
  depends on that: its own command textarea uses a literal Ctrl+J for a newline.

Fix shipped:

- `vendor/ttyd/html/src/components/terminal/xterm/index.ts`: an `onKey` handler on
  `attachCustomKeyEventHandler`. Shift+Enter, with Ctrl/Alt/Meta free and not mid-composition, sends `\n`
  and returns false so xterm does not also emit the CR it would otherwise produce. Everything else returns
  true untouched — explicitly including Enter with no modifiers while the socket is closed, because that is
  how ttyd's "Press ⏎ to Reconnect" works, and swallowing it would turn a dead terminal into one that
  ignores the key meant to revive it. Preference `enableShiftEnter` (default true in `app.tsx`, parsed in
  `applyPreferences`), so `-t enableShiftEnter=false` on a ttyd command line, `?enableShiftEnter=false` in
  a URL, and the front's `SET_PREFERENCES` broadcast all reach it.
- `index.html.template`: `translateShiftEnter` and `isShiftEnter` deleted, with a note left at the
  deletion point saying why the page is no longer in the business of rewriting keys it only relays.
- `.woodpecker/ci.yaml`: the vendored-client assertion now also greps `'Shift+Enter -> newline'`
  in the source *and* in the decompressed `vendor/ttyd/src/html.h`, so a dependency refresh that drops the
  handler fails the build instead of shipping a silent regression.

Measured acceptance — bytes on the application's stdin (`od -An -c`), not screenshot-level assertions, with
the pane's application in raw mode and keys pressed through Chrome's own input pipeline (`hack/front-cdp.mjs
--key 'shift+Enter'`, dispatched as rawKeyDown → char → keyUp):

| keystroke | direct ttyd path, production `-t` flags, ttyd → tmux 3.6 | ttyd framed by the front desktop |
| --- | --- | --- |
| Enter | `b \r` | `b \r` |
| Shift+Enter | `b \n` | `b \n` |
| Shift+Enter again, mid-line | `b \n` | `b \n` |
| Alt+Enter | `b 033 \r` | `b 033 \r` |
| Enter again | `b \r` | `b \r` |

Each press is delimited by a `b` typed with a real key event too, so ordinary typing is checked in the same
run and a duplicated or missing byte shows up as a missing or extra delimiter rather than a mystery.

The first version of this handler passed the earlier version of that measurement and still did not work in a
browser, and that is the finding worth keeping. A `KeyboardEvent` built in JavaScript and dispatched at
xterm's helper textarea produces keydown and keyup but never **keypress**, and xterm.js writes terminal data
from both: `_keyDown` sets `_keyDownHandled` only on the way through `cancel()`, and a custom handler that
returns false returns before either point, so the flag stays false - while `_keyPress` skips itself only when
that flag is true. The browser's keypress for the same Enter therefore reached `_keyPress`, took
`String.fromCharCode(charCode)` - 13, a CR - and wrote it *after* our LF: Shift+Enter inserted a newline and
then submitted the line, in that order, which is what it looked like from the pane. The capture that had
"proved" the handler working was measured with synthetic events, so it could not see the second half of the
keystroke at all. Fixed by refusing that keystroke on keypress as well, and cancelling the keydown default,
which is a linefeed inserted into the helper textarea; re-measured through Chrome's input pipeline on both
paths, with the production `-t` flag set rather than a testbed's defaults.

Tools, in increasing amount of browser: `hack/ttyd-ws-probe.mjs` drives ttyd's websocket protocol with no
browser at all (`0` + UTF-8 for input, `1` + JSON for resize, `--send` per frame), so tmux's own key
translation can be measured with exact bytes; `hack/front-cdp.mjs --key` presses keys through Chrome's input
pipeline and is the only thing in this repo that produces the keypress half of a keystroke; and
`hack/probe-keys.js` / `hack/probe-front-keys.js` evaluate inside a page to read what the client logged and
what errors the desktop raised - right for warnings and torn-out template helpers, and now explicitly not the
tool for key behaviour, for the reason above.

Trap found on the way, also fixed: a `name=url` pane in the front renders `proxy_set_header Host …` in its
own location block, and nginx replaces an inherited directive *set* wholesale the moment a nested block
states one of its own — so the server-level `Upgrade`/`Connection` pair silently vanished for those panes.
ttyd logged the websocket handshake as a plain `GET /keys/ws`, never spawned a process, and the pane looked
like a dead terminal with nothing in the desktop saying what was wrong. `docker-entrypoint.nginx.sh` now
re-emits both headers in the site branch. Terminal panes reached by *service name* (every production pane)
were unaffected; one reached by URL was not.

Second trap, found by asking why the Shift+Enter fix looked like it had not deployed: ttyd serves the document
that *carries* the terminal bundle - the bundle is inlined into it and the file is compiled into the binary -
with `content-type` and `content-length` and nothing else. No `Cache-Control`, no `ETag`, no `Last-Modified`,
no conditional path, because an embedded resource has no file to date. A tab opened before a rollout therefore
keeps running the bundle it cached, which from inside the pane is indistinguishable from a fix that never
shipped. The fork now answers `Cache-Control: no-store` on that document (measured on the built image, on the
plain branch and on the gzip branch browsers actually request; nginx passes it through unchanged, so panes
reached through the desktop get it as well):

```
HTTP/1.1 200 OK
server: ttyd/1.7.7-slopyphus (libwebsockets/4.3.5-unknown)
content-type: text/html
cache-control: no-store
content-length: 731516          # 191946 on the wire when the client accepts gzip
```

`no-store` rather than `no-cache` because there is nothing to revalidate *against* - a validator-less
`no-cache` means "ask again", and asking again is what already happened. `no-store` also keeps the response out
of Chrome's back/forward cache, which is the other way an old terminal survives a reload. `.woodpecker/ci.yaml`
asserts it against the shipped image (start ttyd inside the agent image, fetch its own index over loopback,
grep the response headers) rather than by grepping the fork's C, because the header is the thing a
libwebsockets upgrade could plausibly lose; the assertion was run locally both ways first - the real pattern
passes, and a pattern that is absent from the response fails - because a gate that cannot fail is scenery.

Deliberate gap, written down rather than papered over: the `--index` branch of ttyd's document serving is
untouched. In the libwebsockets this build links against, `lws_serve_http_file` takes one raw
`const char *other_headers, int other_headers_len` blob whose accepted shape is not documented, and guessing a
header format into a path that serves a page is worse than leaving it alone. No ttyd in this deployment uses
`--index` (docker-entrypoint.sh serves the embedded document), so if a custom index is ever introduced its
cache headers have to be settled against the libwebsockets version pinned in the Dockerfile.

## Task 3 — clipboard paste / drag of images into a Pi pane

Status: **closed** (2026-11-06). Fork `774a312`, re-pinned here as `vendor/ttyd`.

What it does: paste (Ctrl+V, or the browser's menu) or drag a file onto a pane, and it is written to
`<workdir>/.slopyphus/uploads/<timestamp>-<name>` and the path is typed into the pane, followed by a space.
A screenshot paste is then one step from "describe this image" in Pi, because Pi's file tools can read that
path.

Why a new channel was needed: a browser clipboard paste gives xterm *text*, and the file it came from exists
only in the browser. `DataTransfer` carries `File` objects for paste and drop alike, so one upload path serves
both, and the protocol carries `BEGIN` (name + declared byte count) → `DATA` (base64 frames) → `COMMIT`, with
`ABORT` and a result frame. Capabilities are advertised on connect — whether an upload is possible here at
all, the limit, and the directory — which is what lets a readonly pane refuse a *drop* (accepting one and then
failing is worse than not offering it) and lets the client refuse a 400 MB file before sending a byte of it.

Decisions, and the reasoning that chose them:

- **The pane's own working directory**, not a server-wide temp directory: a pasted image is only useful to
  whatever is running in that pane, and one agreed location is what makes the path readable by Pi's tools.
- **The path is typed as though the user typed it**, with a trailing space. A paste is usually the start of a
  sentence; without the space the user's next keystroke is glued onto the filename. `tmux capture-pane -pt`
  hides trailing whitespace, which is how this nearly shipped unverified — the space is now asserted by name.
- **Names are sanitised, not rejected.** `Screenshot 2026-11-06 at 15.30.05.png` becomes
  `Screenshot-2026-11-06-at-15.30.05.png` because the name is typed into a shell. A name carrying `../` or an
  absolute path lands as a basename inside the uploads directory; refusing it would be the bug, since a browser
  can hand over a real absolute path. Measured: nothing created at `/etc/evil.txt`, stored as `evil.txt`, and
  nothing containing `..` typed into the pane.
- **trzsz's drag-drop is replaced wherever uploads are allowed.** trzsz binds `drop` on an inner node and types
  `trz` into the tty, which needs a plain shell — with Pi in the pane that `trz` lands in Pi's editor, and zmodem
  names nothing. Capturing `paste`/`dragover`/`drop` on the terminal's *parent* element sees the event before
  either xterm or trzsz and stops it reaching them; a target that is not ours must not be silently outranked, and
  the honest knob is `-t enableUpload=false`, which hands the drag back to trzsz.
- **A refusal leaves nothing behind and never names a file that does not exist**: a short transfer unlinks the
  partial file and clears the saved path.

The bug that mattered, and why the gate changed shape because of it. Multi-file paste failed *in the browser*
with "more bytes arrived than the client declared" and passed in the paced probe, so for a while it looked like a
client loop bug. It was not. `lws_b64_decode_string` takes a C string and has no length to be given, and ttyd's
assembled receive buffer was `xmalloc(len)` with no terminator, so a `DATA` frame that happened to be followed in
the buffer by the next frame decoded a few bytes of *that*. Once a log line existed, the server named the numbers:
a **75 byte chunk against a 70 byte declaration**, a **9219 byte chunk against 9216**. It became reproducible only
by removing the probe's pacing (`--upload-gap 0`) — a browser fires `BEGIN`, `DATA` and `COMMIT` in one tick, and a
paced probe could never have seen it. Fix: the buffer is one byte longer with a NUL at the end.

Evidence, split by what each half can actually measure:

- Server half — `hack/upload-gate.sh`, 39 assertions, all passing on this build: the accepted upload is
  byte-identical to the source and its path arrives on the *pane stdin* (`-t` flags set, path typed, a space after
  it); oversize, readonly and `--disable-upload` each refuse with a reason, write nothing and type nothing;
  capabilities answer `false` where an upload is impossible, so no drop is offered; a hostile name is sanitised; a
  truncated transfer unlinks its partial file; six uploads sent back to back on one connection all land
  byte-identical; stray `DATA`/`COMMIT`/`ABORT` frames create nothing and the terminal survives.
- Browser half — Chrome's own input pipeline (`hack/front-cdp.mjs --paste-file`, `--drop-file`, evaluated in the
  front desktop's pane-iframe realm): a 737280 byte paste md5-identical on disk; a drag over the limit refused with
  its reason logged and no file, while a text paste in the same session still landed; a five-run loop of three-file
  pastes, 15 files on disk and all 15 paths typed in the pane, space separated.

Open ends:

- Nothing cleans up `.slopyphus/uploads`. There is a per-file limit (`--upload-max-bytes`, capped at 64 MiB) but no
  total quota and no age limit, so a long-lived pane accumulates screenshots.
- The front page's own file picker (`browseFiles` → trzsz `rz`) is a separate upload path and was left alone; it
  names nothing either.
- A real drag from the OS into a browser cannot be produced headlessly. The gate dispatches `DragEvent`s inside the
  page and asserts everything after the event: the handler, the transfer, the bytes, the file.
- Measurement trap found while verifying: `tmux capture-pane` taken just after a pane's last client detached can
  show a blank screen. Calibrate with a `tmux send-keys` string before believing a blank pane is empty.

### The key that reaches that upload path (Ctrl+V on Linux, Cmd+V on macOS)

A user on a Linux box pressed Ctrl+V and nothing arrived. It had worked on their Mac, which is the whole diagnosis:
the shortcut is platform-specific in the browser, and the client was intercepting the wrong one.

Measured in a container running the shipped ttyd and the shipped client, typing into a `cat` pane through CDP raw
key events (`hack/keys-case.sh`, which records the pane's own stdin with `script(1)` and deliberately writes no
bytes itself, so anything in the recording came from the client):

| keys | bytes that reached the pane before the fix | after |
|---|---|---|
| Ctrl+V | `16` — a literal device-control-1 | nothing |
| Ctrl+Shift+V | nothing | `16` |
| Cmd+V | nothing | nothing |
| Ctrl+V + Ctrl+Shift+V + Cmd+V together | `16` | `16`, and it is the Ctrl+Shift+V one |

Chrome does not send Ctrl+V to the page as text: Linux and Windows deliver it as a `keydown` only, macOS delivers
Cmd+V the same way, and Ctrl+Shift+V is silent because it is the terminal's own literal-next chord. xterm.js
handled the `keydown` by writing `0x16` into the connection and calling `preventDefault()`, which is what cancelled
the browser paste. `hack/keys-case.sh --paste-text` shows the difference on the other side of the same handler: a
*dispatched* `paste` event already worked, because ttyd's capture-phase listener on the parent element never looked
at modifier keys — only the real keyboard path was broken.

The fix is in the fork's `attachCustomKeyEventHandler` (`vendor/ttyd/html/src/components/terminal/xterm/index.ts`):
V with Ctrl and nothing else refuses both the `keydown` and the `keypress`, so xterm writes nothing and the browser
paste reaches its own `paste` listener, where ttyd's upload path takes it — file clipboard goes to the upload
channel, text clipboard goes to the pane. Ctrl+Shift+V is answered directly with `0x16`, which keeps literal-next
alive and is the only way to get that byte into a pane from a browser: Ctrl+Shift+V used to produce no bytes at all,
measured, so the old behaviour was not "terminal-native literal next", it was a no-op.

## Task 4 — show images inline (Sixel / iTerm inline images)

Status: **shipping.** It was deferred first as "tmux stays, images wait", then reopened by measurement (below),
then closed by a trade the pane's owner accepted: inline images are the default pane invocation, and what they
cost is Pi's fullscreen UI, which is now a switch (`PI_PANE_MODE=images|fullscreen`) rather than a fork of the
deployment.

The claim this task existed to test is the obvious one: "ttyd loads `@xterm/addon-image`, therefore images
work". That is true of the far end of the chain and useless as a conclusion, because a pane's bytes are
produced by the program in the pane, then interpreted by tmux, then re-emitted into ttyd's pty, then handed
to xterm.js. Whatever tmux parses and dislikes never reaches the addon.

Two probes now measure this instead of reasoning about it. `hack/image-cases.sh` puts a browser on a real
pane over CDP and counts pixels on a 2D canvas — ttyd's text renderer is WebGL, and `getContext('2d')` on a
WebGL canvas is null, so a 2D canvas carrying pixels can only be the image layer — and it screenshots every
case, because "painted" is not the same claim as "a person saw the flag". `hack/pane-byte-cases.sh` records
the bytes a pane emits at ttyd's own websocket, which is the exact stream xterm.js is handed. Every case
holds its print back until a client is attached: an image lives in xterm's image layer, not the text buffer,
so a client that attaches after the print sees a prompt and no image, which looks exactly like protocol
failure and is not.

| case | bare pane | tmux pane (what production runs) |
|---|---|---|
| hand-written OSC 1337 (iTerm2) | 855225 px | 0 px |
| Pi's own bytes (`hack/pi-image-bytes.mjs`) | 155750 px | 0 px |
| sixel (`img2sixel`) | 12275 px | 2590 px — it renders, rescaled small by tmux |
| Pi's bytes inside tmux's passthrough DCS | 155750 px | **155225 px** |
| sixel inside the same DCS | 12275 px | 11225 px |

What each of those is evidence about:

- **xterm.js refuses an iTerm2 header with no `size=`.** The first version of the probe omitted it and every
  iTerm case came back blank, which was `IIPHandler` aborting the sequence, not the transport failing. A
  sequence that is present in the byte stream and paints nothing has usually been refused at the far end.
- **Pi's header is `File=inline=1;size=<bytes>;width=<columns>;height=auto`**, extracted from the shipped
  bundle by `hack/pi-image-bytes.mjs` rather than guessed. `height=auto` is not a problem: a 160x80 PNG in
  an 80-column pane paints a 560x280 box, which is column widths plus preserved aspect at 3.5x.
- **tmux 3.6a has no notion of the protocols Pi uses, and does have graphics of its own.** It parses OSC 1337 as
  an OSC, finds no handler, and drops it — `grep -c 1337 input.c` is 0, and `grep -rn -i kitty` over the whole
  3.6a tree is 0 hits, so neither of the two protocols Pi can emit means anything to tmux. Sixel is different:
  **the Ubuntu `tmux 3.6a-2ubuntu0.2` already in our image is compiled with `--enable-sixel`.** `tmux display -p
  '#{sixel_support}'` returns 1 on the shipped binary, and `config.status`/`Makefile` DEFS carry `-DENABLE_SIXEL=1`
  in a tree built from the 3.6a tag with that flag. My earlier claim to the opposite — that `ENABLE_SIXEL` was
  absent and `sixel_support` "is not even a valid option name" — is retracted: I probed with `show-options`, and
  `sixel_support` is a *status-line format variable* (`format.c:3437`), which `show-options` will always reject,
  compiled-in or not. That is a probe-shaped error, not a subtle one, and it moved a conclusion. The control that
  makes the shipped binary's `1` mean something: a clean rebuild from the 3.6a tag without the flag reports `0`,
  with it reports `1`, and `/usr/bin/tmux` carries the strings `SIXEL flag is %d`, `sixelimage` and `SIXEL IMAGE `
  that only exist under `ENABLE_SIXEL`. A first attempt at that control copied an already-built tree and `make`
  reused the existing object files, producing a binary compiled *with* sixel out of a configure run that asked
  for none — `make clean` is not optional in a control like this.
  So tmux does parse sixel (`image-sixel.c`, `sixel_parse`, `screen_write_sixelimage`), stores it in the pane's
  grid, and re-emits it to clients it believes are sixel-capable — the gate is the `sixel` terminal feature,
  which tmux derives from the terminfo capability `Sxl` (`tty-features.c:351`) or from `terminal-features`. The
  2590 px against 12275 px is tmux rescaling the image into its cell grid, not discarding it: the flag still
  paints a recognisable flag in the screenshot, at roughly half the linear size.
- **tmux's passthrough wrapper works, but not the way the man page reads.** `tmux/input.c`'s `dcs_escape`
  state table dispatches the DCS on ESC followed by `\`, and reads ESC ESC as one literal ESC. So the payload's
  escapes are doubled and the closing ST is **single**: `ESC P tmux ; ESC` + doubled(payload) + `ESC \`.
  Doubling the closing ST — which is what the man page's literal appears to show — leaves the wrapper open:
  tmux swallows the payload *and everything the pane prints afterwards*, which the probes see directly as the
  case's own `echo` never arriving. `hack/image-sequence-cases.mjs` writes both spellings as cases so the
  wrong one stays demonstrably wrong.
- A wrapped image does not damage the text around it. Wrapped sixel paints 11225 px against 12275 px bare,
  which is tmux re-emitting rather than losing, and echoes printed after a wrapped image arrive normally.

Then the question that decides whether any of this can be shipped: **does the pane need tmux at all?**
`hack/pane-persistence.sh` puts a command in a pane that appends a tick line per second, attaches a client,
detaches it, and counts.

- A **bare** pane ticked 1..9 while attached, ticked **nothing** during the six seconds with no client, and a
  client attaching later saw the counter start again at 1. ttyd starts a pane command only when a client
  attaches and kills it (SIGHUP) when the last one leaves. A bare pane is a per-viewer process.
- The **tmux** pane ticked six more lines while nobody was attached, and the later client received 56 tick
  lines of it out of tmux's scrollback: same process, still running.

So the shape of the task is a genuine trade rather than a missing flag: tmux is what keeps Pi alive when a
tab closes, and tmux is what deletes inline images. Bare panes render exactly what Pi prints and lose the
session on disconnect. There is no configuration that makes both true at once.

What is *not* being done, and why:

- **Nothing in this repo can apply the wrapper.** It has to be applied by whatever prints, because by the
time ttyd sees the bytes tmux has already thrown them away. A pty relay in front of Pi that reframes OSC
1337 would be a new component in front of every agent, and it would have to be right about partial
sequences arriving across read boundaries. That is not a change to land while the persistence trade is
unresolved.
- **Rebuilding tmux with `--enable-sixel` is superseded, not rejected: there is nothing to rebuild.** Ubuntu's
  build already has it on. What would be needed instead is a *producer*, and the reason Pi's own images still
  cannot appear is unchanged: Pi does not choose sixel — it chooses iTerm2 whenever the terminal answers
  XTVERSION, which xterm.js does — and tmux has no handler for either protocol Pi can emit.
- **tmux's sixel re-emission is gated on something about the client that I have not identified yet.** Measured
  with a real 342-byte PNG through `img2sixel`, `pipe-pane` on the pane and `script(1)` on the client, both
  attach orderings, on both the shipped tmux and one with `terminal-features 'xterm-256color:sixel'` added: the
  pane hands tmux the sixel every time (`pane_dcs=1`), and a client attaching with plain `TERM=xterm-256color`
  receives **no sixel at all** (`client_dcs=0`) whether it attached before or after the print, feature option or
  not. Yet the same case through ttyd visibly paints a flag. So the gate is real, it is about the ttyd/xterm.js
  client rather than the option, and "does a viewer that arrives late still see the image" is unanswered at the
  pixel level. An earlier version of this probe built its base64 inside the container, found no PNG, wrote an
  empty one and reported zeros with complete confidence — the placeholder in the probe is a placeholder for a
  reason.
- **`PI_IMAGE_PROTOCOL=none` in the entrypoint** would stop Pi emitting sequences tmux eats, and is the
  opposite of what the task wants. Recorded so the next reader knows it was considered.

One more thing read from the bundle and *not* yet measured in a pane: Pi's alt-screen UI disables iTerm2
images on entry — `capabilities.images === "iterm2"` causes `setCapabilities({ ...capabilities, images: null })`
in `TuiAltScreen.beforeTerminalStart()`. If inline images ever look inconsistent inside Pi, that line is
where to look, and it is a Pi behaviour rather than a slopyphus one.

Resolution, and the one thing the framing got wrong (home-ops, owner of `clusters/dev/applications/slopyphus/`,
2026-11-06):

> Keep tmux. Inline images wait. A missing picture is a capability gap I can live with, a pane that SIGHUPs
> its agent when the last viewer closes a tab is an outage.

With a placement rule attached: no relay, no per-agent wrapper, and if a wrapper is ever written it goes "at
slopyphus's own pane byte pump ... not in front of Pi in every agent", because a per-agent wrapper is a new
component in twenty agent manifests here and in every repo that hosts a pane. That rule is right as a
preference and it turns out to be unavailable as an implementation, which is worth recording because it is
the part neither choice in my framing contained: tmux consumes the image sequence at the pane's pty boundary,
so by the time slopyphus's own copy of PTY bytes to ttyd runs there is nothing left to wrap. Re-measured on
the case that matters (`hack/pane-byte-cases.sh slopyphus-terminal-test:local iterm`, which is the *unwrapped*
case, printed with `allow-passthrough on` already in `.tmux.conf`):

- bare pane: 547 bytes, `OSC 1337;File=inline=1;size=342;width=200;height=100;preserveAspectRatio=0` present,
  terminated by BEL, followed by the case's own marker text.
- tmux pane: 1523 bytes arrive at ttyd's websocket and contain **no OSC 1337 header, not doubled, not wrapped,
  not truncated**. The sequence does not exist in the stream slopyphus would have to rewrite.

So the only writer that could ever apply a wrapper is whatever produces the image. That is why this is not a
placement decision slopyphus can make on its own, and it is the strongest argument for leaving Task 4 closed.

Two findings from reading tmux 3.6's own source (`input.c`, `tmux.1` from the `3.6` tag) while checking the
suggestion that `allow-passthrough` might be the cheap fix. It is not, and the reason is a matter of where the
option is read rather than opinion:

- `allow-passthrough` is read in exactly one place in `input.c`: line 2580, inside `input_dcs_string`, and only
  for a DCS whose body begins `tmux;`, where it becomes `screen_write_rawstring(sctx, buf + prefixlen, len -
  prefixlen, allow_passthrough == 2)`. It is a permission to *use the wrapper*, not a mode that forwards
  sequences tmux does not understand. `tmux.1` describes it the same way: "Allow programs in the pane to bypass
  tmux using a terminal escape sequence (`\ePtmux;...\e\e\e`)".
- `grep -c 1337 input.c` is 0. tmux 3.6 has no iTerm handler of any kind; an OSC 1337 goes through the generic
  OSC state machine and is discarded, and no value of `allow-passthrough` reaches that path. There is also no
  `allow-control-ops` in this version.
- The option's values are `on | off | all`, and `on` is documented as conditional: "passthrough sequences will
  be allowed only if the pane is visible", with `all` allowed "even if the pane is invisible". Measured, that
  distinction is worth less than the page implies: with a client attached, `on` and `all` behave identically, and
  an image printed while nothing was attached is absent from a client that attaches afterwards **under `all` as
  well** — the text printed before and after it arrives, the raw image bytes do not, because they were never
  copied into the pane's history. An image is only ever available to whoever is looking at the moment it is
  printed, whatever the option says.
- The man page's own literal is wrong in a way that costs a program its output, and this is the part of the task
  worth taking outside this repository. It shows the closing as `ESC ESC \`, but `input_state_dcs_escape_table`
  dispatches on `\` (0x5c) directly to `input_dcs_dispatch` and back to ground, while ESC ESC `\` is read as one
  stored ESC (0x1b falls in 0x00–0x5b, `input_input`, back to `dcs_handler`) followed by a stored backslash
  (0x5c falls in 0x40–0x7e, `input_input`, still `dcs_handler`): no dispatch, wrapper open. The measured cost is
  not just a missing image — a marker printed *after* the wrapped sequence reaches the client in every
  single-close case and reaches it in none of the doubled-close cases, so doing what the page says loses the
  image and everything printed after it. `hack/tmux-manpage-dcs-close.sh` reproduces this against plain tmux
  with `pipe-pane` and `script(1)` (no ttyd, no xterm.js, no slopyphus in the path) and prints the table;
  `hack/upstream-tmux-dcs-terminator-report.md` is the filing-ready write-up, with the parser quoted, the table,
  a minimal reproducer, and the traps that made a first attempt report only zeros. It has not been filed: this
  pod has no `gh` and no GitHub credentials, and filing an issue against someone else's repository under your
  name is not something to do without being handed a way to do it.

What is agreed to be off the table, and why: no relay component; no dropping of tmux. The "no tmux rebuilt with
sixel" item is **withdrawn as unnecessary rather than as rejected** — the build we already ship has the flag on,
so there is nothing to rebuild. What is actually missing is a producer: tmux will carry sixel and Pi cannot emit
sixel (`encodeITerm2` and `encodeKitty` are the only encoders in Pi's shipped bundle, and grepping the installed
package for `sixel` finds nothing), which leaves "something in the pane prints sixel" as the one route that needs
no fork of anything — `img2sixel` is already in the agent image, and Task 3 already lands uploaded files on disk.
Re-opening Task 4 now means measuring two things, not re-deriving the blocker: whether tmux re-emits a stored
sixel to a viewer that attaches *after* the print (see the sixel re-emission bullet — the byte-level probe says a
plain terminal client never gets it, which does not match what ttyd's client demonstrably does get), and whether
tmux's rescaling is good enough to look at. Reopening this needs something new, not re-derivation:
a Pi-side change that emits the wrapper itself accepted as a component, or a tmux that re-emits graphics it parsed.

### Reopened, measured against a running Pi rather than against its bundle

The sentence above says reopening needs a Pi-side change. What it actually needs is two flags and a relay, and
that is now measured end to end.

**Pi turns its own images off in fullscreen.** `beforeTerminalStart` in the shipped bundle reads
`capabilities.images === "iterm2"` and calls `setCapabilities({ ...capabilities, images: null })`. Measured in a
bare pty, with no tmux anywhere in the path: a Pi session asked to read a PNG emits **0 × OSC 1337**. The bytes
are never written, so nothing downstream has anything to discard. This is the reason four rounds of transport
measurement kept coming back empty.

**Fullscreen Pi does draw images, in a protocol nothing in this stack can display.** With
`PI_IMAGE_PROTOCOL=kitty` the same session emits 11 graphics sequences: one transmit-and-display carrying a
160×80 PNG (`a=T,f=100,q=2,C=1,c=60,i=3646177082,y=10,h=70,r=13`), three re-plots of that image id at different
scroll positions (`a=p,q=2,C=1,c=60,i=…,y=21,h=59,r=11`), and the bookkeeping deletes (`a=d,d=a`, `a=d,d=A`).
Captured verbatim in `hack/fixtures/pi-kitty-pi-tui.bin`, and the whole screen in
`hack/fixtures/pi-tui-kitty-capture.bin`. Painted pixels of that fixture in the browser harness: **0 bare, 0
through tmux, 0 through tmux's passthrough wrapper**, each with the case confirmed to have run (`pane-ran=done`,
and the `pi-iterm` control in the same run painted 155750 bare / 0 through tmux exactly as every earlier run).
So xterm.js has no kitty handler, and tmux does not composite kitty graphics into sixel either — my own probe of
that question could not decide it because tmux reported `#{client_termfeatures}` without `Sxl` and an empty
`#{client_cell_pixels}`, which are the two gates sixel needs, and `#{sixel_support}=1`.

**Pi has no sixel encoder, confirmed a second way.** `sixel` appears nowhere under
`@earendil-works/pi-coding-agent` (nor in `pi-tui`, `pi-agent-core`, `pi-ai`, `pi-codemode`, `pi-mcp`), and the
protocol values Pi accepts are `kitty | iterm2 | none`.

**Regular mode keeps the iTerm2 path alive.** `--tui-mode regular` is not an alt-screen UI — 0 × `ESC[?1049h`
measured against 1 for `--tui-mode fullscreen` — so the nulling never runs. The protocol still has to be named,
because Pi asks the terminal whether it supports images and a terminal behind tmux does not answer in the form Pi
expects; with `PI_IMAGE_PROTOCOL=iterm2` set, a regular-mode Pi reading a PNG emits **1 × OSC 1337**.

**The relay wraps a running Pi, and what lands in the pane is tmux's own wrapper.** A Pi session under
`tools/tmux-osc-wrap.py` inside a tmux pane wrote, recorded by `pipe-pane` off the pane itself:

```
ESC P tmux ; ESC ESC ESC ]1337;File=inline=1;size=342;width=60;height=auto:iVBORw0KGg…
```

with no unwrapped OSC 1337 anywhere in that stream. That is the last link the previous paragraphs said was
missing: the program that produces the sequences is Pi, and the wrapper is applied while it runs rather than to a
file of bytes somebody wrapped beforehand.

**Rendered size, same 560×280 test image:** 153965 px live relay through tmux · 155225 px for the same bytes
pre-wrapped through tmux · 155750 px in a pane with no tmux. The screenshots show the same flag in all three,
with `CASE-INNER-MARKER` and `CASE-RAN-MARKER` legible around it, which is the marker evidence that a wrapper
closed where it should.

What ships as a result: `tools/tmux-osc-wrap.py` and `tools/pi-images.sh`, installed in the agent image as
`/usr/local/share/slopyphus/tmux-osc-wrap.py` and `/usr/local/bin/pi-images`. The default pane command is
untouched — inline images are opt-in by running `pi-images` where one would run `pi`, and what that gives up is
Pi's fullscreen UI rather than anything about the terminal. Which fullscreen features are lost that way is Pi's
behaviour and has not been measured here; `--tui-mode` precedence is: a mode given later wins, because
`--tui-mode regular --tui-mode fullscreen` enters the alternate screen (1) exactly as fullscreen alone does.

Two things remain open, kept as open measurements rather than folded into the conclusion:

- **tmux's sixel rescaling is not pinned.** Re-running the same `img2sixel` case today gave 12275 px bare and
  2590 px through tmux, where the earlier run of the same case gave 356151 and 72930. The screenshot shows a
  ~62×41 flag in the pane, so the image is real and tiny. The harness shape changed between those runs (tmux's
  session is now created by the container's own command rather than by the shell ttyd spawns for a client), which
  plausibly changes whether tmux has a cell-pixel measurement to scale against — but the *bare* variant's shape
  did not change and its number dropped too, so part of that drop is unexplained and the size claim is not safe
  to quote until it is re-measured.
- **`capture-pane` answering blank is a measurement bug, not a result.** Panes driven from ttyd's client shell
  reported no session content while the browser screenshot of the same container plainly showed
  `CASE-RAN-MARKER` above a full-size image. The tmux variant now creates the session before ttyd starts and the
  case script waits for `/tmp/go`, and the liveness check falls back to a marker file the pane writes after the
  case finishes. That fallback proves the case ran; it does not prove tmux carried the pane's text, which is why
  it sits below the pixel check rather than above it.

The tmux man-page report is still unfiled for the same reason as before: no `gh`, no credentials, and filing under
someone else's name needs a route handed to this pod. The Pi-side ask is now concrete enough to file too, in one
sentence: Pi emits images in a protocol the terminal cannot show and switches the one protocol its own renderer
can show off in fullscreen; either emit sixel when `$TMUX` is set, or emit tmux's own passthrough wrapper.

### Drawing an image without moving the cursor, which is the last thing the pane owed

With the wrapper carrying Pi's sequences into the pane, the picture appeared and the next line of text landed on top
of it. That is not tmux and not Pi: `@xterm/addon-image` paints on a canvas layer (`xterm-image-layer`) that sits
outside the buffer, so drawing a 280-pixel-tall picture leaves the cursor exactly where the sequence arrived. Pi
believes it printed one line. The terminal knows better and nobody tells it.

`hack/image-cases.sh` runs the pair (`rows-baseline` with the relay's reservation off, `rows-fix` with it on) and
`hack/image-rows-report.py` reads the same case three ways — what the relay's arithmetic says, what the renderer
drew (the canvas's painted pixels and bounding box, converted to rows by the client's own measured grid), and where
the text markers actually landed in `capture-pane`:

| case | picture drawn | grid rows the markers landed on | verdict |
|---|---|---|---|
| `rows-baseline` (relay, tmux) | 153440 px, rows 2.0–20.3 | BEFORE 1, AFTER 2, RAN 3 | text OVERLAPS the picture |
| `rows-fix` (relay, tmux) | 156800 px, rows 2.0–20.3 | BEFORE 1, AFTER 22, RAN 23 | text clears the picture |
| `rows-fix` (no tmux) | 156800 px | no grid, `capture-pane` needs tmux | screenshot is the evidence |

The relay's prediction and the observed cursor advance agree exactly: 20 rows reserved, 20 rows the pane actually
moved, 18.3 rows the picture covered. Two rows of slack is the estimate being an estimate; the direction is chosen
on purpose, because a reservation that overshoots costs blank rows and a reservation that falls short draws text on
someone's screenshot.

What the arithmetic reads, in the order the reference renderer does it. The header fields come from the payload
header, and `IIPHeaderParser` is strict in a way that matters: the header ends at the *first* colon, so a `name=`
carrying base64 `=` padding cannot be confused for a field separator. The frame size comes from the image bytes
themselves, mirroring `IIPImageParser`'s magic list: PNG `IHDR`, JPEG's first `SOF0/1/2` (skipping other markers,
which is how a `DHT` before the frame is survived), GIF's logical screen descriptor, BMP's DIB width and height
with a negative height read as top-down rows. Anything else reserves nothing rather than guessing.
`IIPHandler._resize` then decides the drawn frame: `width` and `height` default to the pane width and `auto`, a
percentage is a fraction of the pane, `auto` means keep the aspect, and when both sides are given the *larger*
scale wins (`wScale >= hScale`) rather than the one the caller asked for. The row count is that frame's height in
rows, capped to leave one row for the cursor.

The cell geometry is measured rather than assumed, and the harness says so out loud: a 160×52 client viewport of
1120×780 gives 7.00 px × 15.00 px per cell (tall cell = 0.467 of its width), and through tmux 160×51 gives
7.00 × 15.29 (0.458) because tmux keeps a status line's worth of rows out of the viewport. The shipped defaults are
ratio 0.5 and a 15 px cell; `OSC_WRAP_CELL_RATIO`, `OSC_WRAP_CELL_HEIGHT_PX`, `OSC_WRAP_ROWS=0` and `--no-reserve`
are the knobs, and the reservation is independent of the wrapper — a pane with no tmux needs the blank rows just as
much, which the third row of the table above is there to show.

One discovery worth keeping: Pi resizes on the way out. The 560×280 test image left Pi's encoder as
`File=inline=1;size=342;width=80;height=auto` carrying a 160×80 PNG, so the relay sizes *Pi's frame*, not the
user's file. The rendered result is the same 560×280 px on screen (80 columns × the measured 7.00 px cell), which
is the check that the two are consistent rather than a coincidence.

`hack/test-osc-wrap-rows.py` is the standing test for all of it — 35 checks, all passing: header parsing against
real PNG/JPEG/GIF/BMP bytes built in the test, the resize arithmetic case by case, the reservation against the
measured browser geometry, and byte-for-byte identity with `hack/pi-image-bytes.mjs --wrap-tmux` so the reservation
cannot quietly change the wrapper. A non-image OSC 1337 is still wrapped (tmux discards every OSC 1337, `grep -c
1337 input.c` is 0) and reserves no rows, because inventing a picture that was never drawn is its own bug.

What is not adaptive: the ratio is one number measured at `fontSize=12` in this client with this font. A bigger
font, a different DPI, or a client that reports cell pixels to tmux changes the tall-cell fraction, and the
reservation moves with the constant rather than with the terminal. If a future client reports `client_cell_pixels`
to tmux, the honest change is to ask tmux instead of carrying a constant.


## Task 5 — make an inline image survive a repaint

### First half shipped (07/11): the right click gate

A right click was answered by two independent stacks at once. tmux's built-in
`bind-key -T root MouseDown3Pane display-menu ...` (Horizontal Split, Vertical Split, Swap Up/Down, Swap Marked,
Kill, Respawn, Mark, Zoom, and the same on `M-MouseDown3Pane`) reaches tmux through xterm.js's mouse reporting,
and Chrome answers the `contextmenu` event as well, for the helper textarea xterm.js keeps inside the terminal.
Now the browser menu only answers when Ctrl or Meta is held; `-t enableContextMenuGate=false` restores Chrome's
default. ttyd fork d101262, `src/html.h` rebuilt by `hack/build-ttyd-client.sh`, pinned by slopyphus a464d56.

### Why the picture goes away at all (measured, not inferred)

- tmux never stores an inline image. In a scratch tmux 3.6 session, draw one wrapped OSC 1337 PNG into a pane,
  then resize the pane and show a pane menu: `tmux capture-pane -p -e` reports **0** occurrences of `1337` in the
  pane's history at every stage, while `pipe-pane` on that same pane shows the payload exactly once. tmux's grid
  holds cells.
- Therefore every repaint is lossy and permanent: `WheelUpPane -> copy-mode -e` reprints a history slice, a resize
  or expand reprints the pane, `MouseDown3Pane`'s `display-menu` draws over it, a reattach reprints for the new
  client. Only the application re-emitting restores it, which is exactly the "collapsed to expanded, some show and
  some don't, mostly it figures it out" behaviour.
- The relay cannot fix this on its own. It sits below tmux, and tmux reprints never pass through it.

### Second half shipped (07/11): the relay names the pictures

`--anchor` (and `OSC_WRAP_ANCHOR`, default **off** until the browser side can read them) decodes each OSC 1337
payload it passes, writes it to the pane's own `.slopyphus/images/<10 hex of sha256>.<png|gif|bmp|jpg>`, keeps the
row reservation, and prints one dim text line - `[[img:<10 hex>]]` - on the row below the reserved ones. Saving and
anchoring are one switch: a file no anchor names is a picture nothing will ever ask for. Retention is the newest
`OSC_WRAP_IMAGE_KEEP` (default 200) files, pruned by mtime, and pruning only ever touches names the relay wrote.

Measured with `hack/live-pi-wrap.sh` (the real relay running inside a scratch tmux 3.6a pane, fed the bytes
`hack/pi-image-bytes.mjs` says Pi prints for a 160x80 PNG, 160x52 client): the row reservation and the anchor land
in the **pane's grid**, which is what a repaint redraws from - `reserve_rows` predicted 20 rows and the grid held
**20 blank rows directly above the anchor line**; `capture-pane -p` still reported **1 anchor line** after a
`copy-mode -e` round trip, after narrowing the pane to 90 columns, and after widening it back to 160, while the
same pane's history held **0** copies of the image bytes. The asymmetry is the whole design: text is the one thing
the grid keeps.

One measurement corrected an assumption while building this: tmux *unwraps* the passthrough DCS. The bytes a client
receives contain the original `ESC ]1337;` introducer and no `ESC Ptmux;`, which is expected - the wrapper exists
for tmux's **input** side, to get a sequence through a server that has no handling for 1337 at all - but it means a
byte-level probe of the client's stream cannot confirm the wrapper was used. Probe the pane side instead.


### The shape of the fix

1. **Relay** (the pane's own side of the pipe): shipped as above.
2. **ttyd fork**: shipped as ttyd d2fc92b — `GET <base-path>images/<name>` reads
   `<working directory>/<--image-dir>/<name>` (default `.slopyphus/images`), name validated to ten lowercase hex
   digits plus one of the four extensions the relay writes, type from the name, bytes never sniffed, `Cache-Control:
   public, max-age=31536000, immutable`, `lstat`/`fstat` identity check so a planted symlink is refused, and an
   absolute `--image-dir` rejected at startup.
3. **ttyd client**: an addon (the house already has `addons/overlay.ts` for drawing over the grid) holding a
   `sha -> ImageBitmap` map, scanning rendered buffer lines for the anchor token and drawing the stored image over
   its reserved rows on every render, resize and scroll. Persistence then lives in a file and in the browser, and
   the anchor is ordinary text that tmux already stores.
4. Only after that works: decide whether to stop sending the inline burst at all, so there is no double draw.

### Steps

- [x] gate the browser context menu behind Ctrl/Meta (ttyd d101262, client bundle rebuilt, pinned a464d56)
- [x] live check of the gate through the front: CDP `contextmenu` without modifiers is `defaultPrevented` (true),
      with `ctrlKey` or `metaKey` it is not (false), measured against the deployed image `4d3bd90` through
      `hack/front-cdp.mjs`; the served bundle contains `enableContextMenuGate` (1 occurrence) and the option name
      appears in ttyd's own startup log line
- [x] relay: decode the payload, write `.slopyphus/images/<sha>.<ext>`, emit the anchor token, keep the row
      reservation; extended `hack/test-osc-wrap-rows.py` (10 new checks, 45 total, including byte-identity of the
      saved file, the hash-prefix naming, refresh-not-duplicate, and mtime pruning with the ages stated rather than
      left to the clock). Off by default, so the shipped byte stream is unchanged - the byte-exactness check against
      `hack/pi-image-bytes.mjs --wrap-tmux` still passes
- [x] ttyd fork: the GET endpoint, its path restriction, its cache headers, and a `hack/` probe that proves all
      three. `hack/image-endpoint.sh` builds the fork in the same container base the image build uses (this pod has
      no compiler, and its filesystem is not visible to the Docker daemon on bee-2, so the source arrives on stdin
      as a tar) and passes 23 cases: the served picture is 200 with `image/png`, the immutable cache header, the
      file's own `Content-Length` and a byte-identical body; a right-shaped name whose bytes are not a picture is
      served as bytes rather than sniffed; and nine wrong shapes, four percent-encoded or NUL path escapes, a
      planted symlink into `/etc/passwd`, `/images/` itself, `/index.html` and a raw `.slopyphus/secret` are all
      refused with the same 404 as a picture that is merely absent. The NUL case is answered by libwebsockets
      closing the connection rather than by this handler, which the probe records as `noresponse` instead of
      pretending it was a 404.
- [ ] client addon: anchor scan, image store, redraw on render/resize/scroll
- [ ] turn the anchor on in the entrypoint, once the client understands it, so users never see a token with no picture
- [ ] measure the outcome rather than the implementation: CDP screenshots showing the image still present after a
      wheel scroll, a collapsed-to-expanded pane, a tmux pane menu, and a client reattach
- [ ] README (keyboard table, `PI_PANE_MODE`, what an image now is) and this plan updated with what was learned

### Open questions to settle while building

- Anchor visible or invisible: a visible token is greppable, survives tmux's grid, and is honest about a picture
  being there; an OSC-only anchor would not survive the repaint, which is the entire reason for putting it in the
  grid. The visible token is the direction unless the front's owner objects to the extra line.
- What draws it: `@xterm/addon-image` ^0.7.0 is what renders these pictures today (ttyd's `-t enableSixel=true`
  loads it, and it is the source of the `1337`/IIP support in the shipped bundle). It is fed from the byte stream,
  so an anchor-driven draw needs either its own addon or a patch to that addon, not a reuse.
- Where the images live across restarts: `.slopyphus/uploads/` already survives on the pane's volume, so
  `.slopyphus/images/` should too. Retention now has a default - the newest `OSC_WRAP_IMAGE_KEEP` (200) files,
  pruned by mtime - which is a guess about how much history one agent wants and is worth revisiting once the
  pictures are actually persistent.

## Validation recipe

```sh
hack/image-endpoint.sh                  # build the fork in a container, then assert the image route's 23 cases
hack/front-testbed.sh --build            # ttyd test bed on 127.0.0.1:7654 (localhost, CDP works)
hack/build-ttyd-client.sh               # regenerate vendor/ttyd/src/html.h
hack/html-h-payload.mjs --verbose       # detect html.h drift before pushing
hack/probe-fork-terminal.js             # forked client really serves and runs a shell
hack/upload-gate.sh <test image tag>    # file uploads, asserted against a real pane's own bytes
hack/ttyd-ws-probe.mjs --url ws://… \
  --send $'b\r' --send $'b\n' --expect '/path/to/upload'   # what a pane receives, and what it is typed
hack/image-cases.sh <test image tag>    # does an image paint in a pane, bare and under tmux, per case
hack/pane-byte-cases.sh <test image tag> wrap-st-close-single  # what tmux forwards, byte for byte
hack/pi-image-bytes.mjs <png> --wrap-tmux | base64 -w0   # the wrapper spelling tmux accepts
hack/pane-persistence.sh <test image tag>   # does a pane outlive the last viewer, bare and under tmux
hack/tmux-manpage-dcs-close.sh             # tmux's passthrough terminator, measured on plain tmux alone
hack/sixel-show.sh                         # show a PNG as sixel in this pane + what tmux will do with it
hack/sixel-late-client.sh                  # does tmux re-emit a pane's sixel, and is sixel compiled in
hack/wrap-tmux-dcs.py <file>               # a file's output wrapped in tmux's passthrough DCS
hack/pi-image-bytes.mjs <png> --protocol   # what Pi would put on the wire, read out of Pi's bundle
tools/tmux-osc-wrap.py <cmd>               # wrap a running program's OSC 1337 images as they go
tools/pi-images.sh                         # run Pi so inline images survive tmux: regular mode + named protocol
hack/front-cdp.mjs --url http://front:38137/ --pane-selector iframe \
  --key Shift+Enter --key Gap --key Enter               # keys through Chrome's input pipeline, not JS
hack/front-cdp.mjs --url http://front:38137/ --pane-selector iframe \
  --paste-file 'f.png::a name.png::image/png' --drop-file f.png   # paste and drop through the same pipeline
```

A key or a paste dispatched with `new KeyboardEvent(...)` in the page is not the same event Chrome
produces, and xterm writes terminal data from `keypress` as well as `keydown`: synthetic probes are
structurally blind to half of what happens. Real input goes through `hack/front-cdp.mjs`.

Push order: commit in the fork (`vendor/ttyd`, `vendor/xterm.js`) → push fork → re-pin submodule →
commit main repo → wait for Woodpecker build/ci/lint → wait for pods to roll → user validates from
the front desktop.
