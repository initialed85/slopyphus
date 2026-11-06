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

## Task 4 — show images inline (Sixel / iTerm inline images)

Status: **closed as deferred by the pane's owner (home-ops): tmux stays, images wait.** The measurements stand
as the reason, and the placement that would have made images work without a trade does not exist.

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


## Validation recipe

```sh
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
