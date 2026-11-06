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

Status: **not started**

Findings:
- Drag works today only because trzsz's `uploadFiles()` types the literal command `trz` (or `trz -d`)
  into the tty (`trzsz.js/src/filter.ts:243`), so it needs a plain shell in the pane; when the pane runs
  Pi the typed `trz` lands in Pi's editor. `trz` is installed (`/usr/bin/trz`) but that path cannot work
  with a TUI in the pane.
- We own the ttyd fork, so a real upload channel is cheaper than imitating trzsz: new websocket
  commands (`Command` byte) that stream bytes to the server, which writes the file under the pane's
  working directory and replies with the path; the client then types that path into the pane —
  matching what Pi does natively on Linux (temp file, path into the chat).
- Clipboard paste gives the same `DataTransferItemList` shape as drag, so paste and drop can share one
  upload path.

Steps:
1. Fork server: accept upload frames, write to `<working dir>/.slopyphus/uploads/<timestamp>-<name>`,
  bound size and count, reject when the feature is off.
2. Fork client: `paste` listener (files/images only, otherwise untouched) + drag/drop reuse; after the
   server confirms, send the path to the pty.
3. Flag to disable; document the directory and cleanup.

## Task 4 — show images inline (Sixel / iTerm inline images)

Status: **not started**

Findings:
- ttyd already loads `@xterm/addon-image` when `enableSixel=true` (the entrypoint sets it), and the
  addon implements both Sixel and the iTerm inline protocol (`IIPHandler.ts`).
- Pi emits inline images with `terminal.images: "kitty"|"iterm2"|false|"auto"` /
  `PI_IMAGE_PROTOCOL=kitty|iterm2|none|auto` (docs/settings.md:106, docs/terminal-setup.md:216),
  `terminal.imageWidthCells` default 60.
- tmux blocks graphics sequences unless passed through: `.tmux.conf` already has
  `allow-passthrough on` (added for `notify-send`) — needs a real test.

Steps:
1. Prove xterm renders a directly-printed OSC 1337 image and a `img2sixel` image through tmux.
2. Set `PI_IMAGE_PROTOCOL=iterm2` in the entrypoint and confirm Pi's own image rendering.

## Validation recipe

```sh
hack/front-testbed.sh --build            # ttyd test bed on 127.0.0.1:7654 (localhost, CDP works)
hack/build-ttyd-client.sh               # regenerate vendor/ttyd/src/html.h
hack/html-h-payload.mjs --verbose       # detect html.h drift before pushing
hack/probe-fork-terminal.js             # forked client really serves and runs a shell
```

Push order: commit in the fork (`vendor/ttyd`, `vendor/xterm.js`) → push fork → re-pin submodule →
commit main repo → wait for Woodpecker build/ci/lint → wait for pods to roll → user validates from
the front desktop.
