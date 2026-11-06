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

Status: **implemented, deployed on the fork, waiting for user validation**

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

Residual, to be settled by the user's own browser: through the front (https, secure context) the write
goes through `navigator.clipboard.writeText`, which the http testbed cannot exercise. Two attempts to
make ttyd serve TLS in a testbed failed (`-C`/`-K` accepted, `libssl` linked, but the port answers plain
HTTP), so that half is left to live validation rather than faked.

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

Status: **not started**

Observed: works through the slopyphus front (nginx synthesises a Ctrl+J key event into the iframe),
broken when a ttyd path is opened directly (`https://slopyphus.../home-ops/`).

Findings:
- `.tmux.conf` already sets `extended-keys on`; xterm.js 5.4.0 has **no Kitty keyboard protocol**
  support (`rg kittyKeyboard` empty), so tmux cannot report a modified Enter to Pi. The browser is the
  only place that can tell Shift+Enter from Enter.
- Therefore the fix belongs in the ttyd client (`customKeyEventHandler`) with a ttyd flag to disable it.

Steps:
1. ttyd client: map Shift+Enter to `sendData('\n')` (Ctrl+J), plus Alt+Enter/Ctrl+Enter variants
   behind the same switch; expose `ClientOptions` key so `--client-option shiftEnter=...` works and the
   existing `SET_PREFERENCES` path can toggle it.
2. `docker-entrypoint.sh`: enable by default for all agent panes; `hack/front-testbed.sh` proves it on
   a localhost port.
3. `index.html.template`: delete `translateShiftEnter` once the sub-path case works.

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
