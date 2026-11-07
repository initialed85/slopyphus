# slopyphus

A browser terminal for a [pi](https://pi.dev) agent, and a desktop that composes many of them.

Two images:

| image | built from | what it is |
| --- | --- | --- |
| `initialed85/slopyphus` | `Dockerfile` | one agent: ubuntu, tmux, ttyd (built from `vendor/ttyd`, see **Forks**), pi, trzsz, docker-cli, uv, go, node, kubectl |
| `initialed85/slopyphus-nginx` | `Dockerfile.nginx` | the UI: nginx plus an entrypoint that renders its config from environment variables |

The repo used to be `slophyphus` (a stray h) while the images were always `initialed85/slopyphus`; the
GitHub repo is now `slopyphus`, so all three spellings agree. The image names never changed, because
they are what the cluster and anyone pulling by hand already used.

# One agent

```sh
NAME=coder-7 MODEL=rooter/auto ./run-agent.sh   # http://localhost:7681/coder-7/
```

`NAME` is what everything is keyed on — the workspace directory (`/workspace/$NAME`), the tmux session,
the pi identity (`pi --name $NAME`), and ttyd's base path (`-b /$NAME`). It defaults to the container's
hostname, which is the agent name in compose and Docker, but a generated pod name in Kubernetes — so set
`NAME` explicitly in a pod spec and the pod name stops mattering.

`MODEL` is required (the entrypoint fails loudly rather than starting an agent with no model).

`PI_PANE_MODE` chooses what the pane runs: `images` (the default) starts Pi through `pi-images`, which is Pi's
non-fullscreen UI behind a relay that wraps every inline-image sequence in tmux's passthrough escape — the only
shape measured to put a picture on screen in a pane. `fullscreen` starts plain `pi`, which gets Pi's alternate-screen
TUI back and cannot show inline images at all, because Pi switches its own image output off in that mode and the
protocol it uses there (kitty graphics) has no decoder in this stack. The trade is real either way, which is why
it is a switch and not a surprise.

# The whole stack (compose)

```sh
docker compose up -d          # coordinator, coder-1..4, tester, deployer, and nginx on :80
```

`.env` holds the models (`COORDINATOR_MODEL`, `CODER_MODEL`). The `nginx` service builds
`Dockerfile.nginx` and takes its whole layout from `UI_COLUMNS` / `UI_ROWS` / `UI_LAYOUT` /
`UI_PAGE_TITLE`, which default to the desktop described below.

# Composing a desktop

The front renders `nginx.conf` and `index.html` at container start from these variables:

| variable | default | meaning |
| --- | --- | --- |
| `COLUMNS` | empty | comma separated `name=url` pairs, one full-height column each |
| `ROWS` | empty | comma separated `name=url` pairs, one full-width band each |
| `LAYOUT` | `columns_left` | `columns_left` \| `columns_right` \| `rows_top` \| `rows_bottom` |
| `AGENT_PORT` | `7681` | the port a bare host is assumed to be a ttyd on |
| `PAGE_TITLE` | `slopyphus` | browser tab title |
| `RESOLVER` | auto | DNS server for upstream resolution; `off` to resolve at start instead |
| `SVC_SUFFIX` | empty | appended to bare hosts when looking them up; see [Kubernetes](#kubernetes) |

At least one of `COLUMNS` / `ROWS` must be set; both may be. `LAYOUT` decides how the viewport is split
between the two groups, and each group splits its half equally among its panes — one pane or fifty both
work.

```
columns_left                     rows_top
┌────┬────┬────┬────────────┐    ┌──────────────────────┐
│ co │ te │ de │  coder-1   │    │      coder-1         │
│    │    │    ├────────────┤    ├──────────────────────┤
│    │    │    │  coder-2   │    │      coder-2         │
│    │    │    ├────────────┤    ├──────────────────────┤
│    │    │    │  coder-3   │    │      coder-3         │
│    │    │    ├────────────┤    ├──────────────────────┤
│    │    │    │  coder-4   │    │      coder-4         │
└────┴────┴────┴────────────┘    ├──────────┬───────────┤
                                 │   co     │    te     │
                                 └──────────┴───────────┘
```

## `name=url`

The name is what the UI calls the pane: the iframe path (`/name/`), the nginx location that proxies it,
and the label in the corner of the pane. The url is what it proxies to, and it can be written at as much
or as little detail as you like:

| written | upstream | upstream base path | notes |
| --- | --- | --- | --- |
| `coder-1` | `http://coder-1:7681` | `/coder-1` | a slopyphus container; ttyd serves itself under its own name |
| `alice=coder-1` | `http://coder-1:7681` | `/coder-1` | a pane called *alice* showing an agent called *coder-1* |
| `alice=http://coder-1:7681` | `http://coder-1:7681` | `/coder-1` | the same thing, spelled out |
| `alice=https://agent.dev.initialed85.cc/coder-1` | `https://agent.dev.initialed85.cc` | `/coder-1` | any origin |
| `google=https://www.google.com` | `https://www.google.com` | (its own root) | any origin, framed as-is |

So: **no scheme means a slopyphus agent** (port `$AGENT_PORT`, base path `/<host>/`), and **a scheme means
an arbitrary origin** served at whatever path the URL names. An upstream whose port is `$AGENT_PORT` is
treated as a slopyphus agent either way, so `http://coder-1:7681` and `coder-1` mean the same thing.

A pane name must be `[A-Za-z0-9._-]`, may not be `healthz` (reserved by the front's own probe), and may
not appear in both `COLUMNS` and `ROWS`. Anything else — a bad `LAYOUT`, an empty desktop, an unsupported
scheme — stops the container with a message naming what it rejected.

Non-agent origins are proxied rather than framed directly, so every pane is same-origin with the front
and the keyboard relay below works in it. nginx is given the upstream's `Host` header, its SNI name for
https, and `X-Frame-Options` / `Content-Security-Policy` are stripped on the way back. That makes a
refusing site display, not much else: many sites break when their assets, redirects and cookies are
arranged around a path prefix they never asked for. Treat non-agent panes as best effort.

## Resolution

Upstream names are resolved **per request** (`resolver` + a `proxy_pass` built from a variable), using
the DNS server in the container's `/etc/resolv.conf` — `127.0.0.11` on a compose network, kube-dns in the
cluster. That is what lets the front come up at all: a missing agent 502s its own pane, and every other
pane, `/healthz` and the page itself keep serving. Set `RESOLVER=<ip>` to point it somewhere else, or
`RESOLVER=off` to resolve every upstream when nginx starts (then one unresolvable name takes the whole
front down).

## Kubernetes

Bare names do not work on their own, and it is worth knowing why. nginx's `resolver` is not a libc stub
resolver: it sends the name it was given and never tries the `search` domains in `/etc/resolv.conf`.
Measured in the dev cluster against the Service that always exists (`kubernetes`), with a pane for each
spelling:

| `COLUMNS` | result |
| --- | --- |
| `kubernetes` | 502, `kubernetes could not be resolved (3: Host not found)` |
| `kubernetes.default` | 502, same |
| `kubernetes.default.svc.cluster.local` | proxied (400 from the API server, which is what a resolved name gets here) |
| `kubernetes` + `SVC_SUFFIX=default.svc.cluster.local` | proxied (400) |

`SVC_SUFFIX` is the short way: it lengthens the *lookup* only, so `COLUMNS='coordinator'` reaches
`coordinator.<namespace>.svc.cluster.local` while the pane name, its label and the agent's own base path
stay short. Get the namespace from the downward API:

```yaml
env:
  - name: POD_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
  - name: SVC_SUFFIX
    value: $(POD_NAMESPACE).svc.cluster.local
  - name: COLUMNS
    value: coordinator,tester,deployer
  - name: ROWS
    value: coder-1,coder-2,coder-3,coder-4
```

Or spell the FQDN out and leave `SVC_SUFFIX` unset: `coordinator=coordinator.slopyphus.svc.cluster.local`.
Either way each agent Deployment sets `NAME` so its ttyd base path is the pane's name (`/coordinator`),
which is what the rewrite sends upstream. `GET /healthz` answers 200 from the front itself with no
upstream involved, so a probe measures this container rather than the desktop it fronts; an agent whose
Service does not resolve 502s its own pane and nothing else.

## Keyboard

| key | effect |
| --- | --- |
| pointer into a pane | that pane is the active one (green border) |
| `Alt+Shift+Enter` | expand the active pane to the whole viewport; again to put it back |
| `Alt+Shift+G` | broadcast: every keystroke goes to every pane at once (all panes turn red) |
| `Shift+Enter` in a pane | newline — translated to `Ctrl+J`, which is what pi accepts; ttyd/xterm eats `Shift+Enter` |
| `Ctrl+V` (Linux/Windows) or `Cmd+V` (macOS) in a pane | paste: a file clipboard is uploaded to the pane's `.slopyphus/uploads/` and its path is typed into the pane; a text clipboard goes to the pane as text |
| `Ctrl+Shift+V` in a pane | the literal `0x16` byte — the terminal's own "literal next" — sent by the client rather than swallowed by it |

`Ctrl+V` is the browser's paste on Linux and Windows and it used to be eaten: xterm.js answered the keydown by
writing `0x16` into the connection and preventing the default, so no paste ever happened. Cmd+V was already working,
which is why the bug looked like a Mac-only feature. `hack/keys-case.sh` measures the key path end to end by typing
real key events into a `cat` pane and recording what the pane's application reads from its own stdin.

## Panes and scrollbars

Nothing on the desktop shows a scrollbar, and there are two separate halves to that, because a scrollbar
on the desktop costs a strip of width from *every* pane at once while a scrollbar inside a pane costs part
of that one pane.

The desktop itself is a fixed grid, so it has nothing to scroll to and says so (`overflow: hidden` on
`html`/`body`). It used to overflow anyway, in two ways that are measured rather than guessed (see
**Checks**, and note the viewport: the deployed desktop is 20 columns wide, so at 800px a pane is 40px):

| viewport | overflow before | after | cause |
| --- | --- | --- | --- |
| 800x600 | 42px wide, 3px tall | 0, 0 | a label 78px wide in a pane 40px wide; the inline-iframe baseline |
| 1280x800 | 18px wide, 3px tall | 0, 0 | same label in a 64px pane |
| 1920x1080 | 3px tall | 0, 0 | label fits in a 96px pane |

- An `iframe` is `display: block`. By default an iframe is an *inline replaced* element, so it sits on a
  text baseline and the line box is the iframe plus the font's descent below it: 3px at 12px monospace, at
  every viewport size, which is a vertical scrollbar on the desktop.
- A pane's label is clipped to the pane (`max-width`, `text-overflow: ellipsis`), so a long name cannot
  produce overflow the grid has to accommodate: an absolutely positioned label is overflow its cell does
  not stop, and that overflow reaches the viewport, which is where a horizontal scrollbar comes from.

Inside a pane is a different problem, because the page above cannot style the document in an iframe. Every
upstream is framed through nginx under the front's own origin, so the pane is same-origin and the script
appends a `<style id="slopyphus-pane-scrollbars">` to it: `scrollbar-width: none` (standard, Firefox and
Chrome 121+) and `::-webkit-scrollbar` sized 0 rather than `display: none` (older Blink/WebKit, where
`display: none` hides the bar and leaves the gutter reserved). The case this exists for is ttyd: xterm's own
CSS is `.xterm .xterm-viewport{overflow-y:scroll}` with no scrollbar styling, i.e. a bar that exists on
every terminal pane whether or not there is any scrollback to show.

Two things that follow from this and are worth knowing before changing it:

- A pane whose content is taller than the pane is still scrollable: nothing here sets `overflow: hidden`
  inside a pane, so the wheel and the keyboard still reach the pane's own document (and in a terminal,
  whatever is running inside it). What is gone is the bar, and the area a bar used to occupy.
- A pane whose upstream leaves the front's origin - a redirect the proxy follows out to another host - is
  then genuinely a cross-origin document: the style cannot be injected into it and the desktop cannot help
  it. That is the one case where a pane can still show a bar.

## Examples


```sh
# The stack in docker-compose.yaml, and what it defaults to
docker run -p 80:80 \
  -e COLUMNS='coordinator,tester,deployer' \
  -e ROWS='coder-1,coder-2,coder-3,coder-4' \
  -e LAYOUT=columns_left \
  initialed85/slopyphus-nginx

# One agent, full screen, nothing else
docker run -p 80:80 -e COLUMNS='coordinator' initialed85/slopyphus-nginx

# Agents from elsewhere, plus a couple of sites, rows across the top
docker run -p 80:80 \
  -e ROWS='coordinator=https://agent.dev.initialed85.cc/coordinator,grafana=https://grafana.prod.initialed85.cc' \
  -e COLUMNS='coder-1=https://agent.dev.initialed85.cc/coder-1,coder-2=https://agent.dev.initialed85.cc/coder-2' \
  -e LAYOUT=rows_top \
  -e PAGE_TITLE='ed desktop' \
  initialed85/slopyphus-nginx
```

In Kubernetes the front is an ordinary Deployment + Service in the same namespace as the agents. Compose
needs no `SVC_SUFFIX`: a compose network answers bare names by itself.

# Publishing

Nothing here used to leave the build host, so the images were `:latest` at best and `slopyphus-nginx` was
never on the registry at all. `.woodpecker/build.yaml` is the publish path now: build both images on a
pinned CI node, push `:$CI_COMMIT_SHA` and `:latest` for each, then hand the sha to
`initialed85/wp-kustomize-deploy`, which stamps it into the manifest's `kustomization.yaml` and pushes -
Argo rolls, and `git revert` is the rollback. `build-tag-and-push.sh` does the same thing by hand
(`NO_PUSH=1` for a local-only build; a sha tag is only made from a clean worktree, because a sha tag on a
dirty one claims the image is bytes it was not built from).

The gate is a separate file on purpose: `.woodpecker/ci.yaml` decides whether a change is acceptable,
`.woodpecker/build.yaml` decides what is in the registry. On a push to `master` the gate always runs - a gate
that can be skipped is not a gate - and the publish runs unless every file in the commit is one the images
cannot contain (`PLAN.md`, `README.md`, `_AGENTS.md`, `docs/**`, `.slopyphus/**`, `hack/**`, `.woodpecker/**`
- derived from what the two Dockerfiles actually `COPY`, not from what a file is called). Without that filter
a commit that changed only prose still published a new tag, and stamping a tag into the manifest restarts
every agent pod, which kills every Pi session running in it. The first commit tested against the filter
changed `PLAN.md`, `.woodpecker/build.yaml` and six `hack/` probes: the CI node ended up with an image tagged
with that commit's sha, so a build ran, while home-ops' `kustomization.yaml` stayed on the previous sha and
no pod restarted. That is confirmed by the absence of a deploy commit and a rollout, not by reading the
pipeline - this pod cannot reach Woodpecker's API, which sits behind the same Google gate as its UI - so the
next commit that touches something an image contains is the check that the publish still runs.

# Deploying it

Manifests live in home-ops, not here: `clusters/dev/applications/slopyphus/` (+ its Application at
`clusters/dev/applications/slopyphus.yaml`), currently one agent called `home-ops` on
gated `slopyphus.dev.initialed85.cc`, columns-only. That directory's README is the bring-up document -
including the gitignored `___secret/slopyphus.yaml` skeleton holding `models.json`, `id_rsa`,
`id_rsa.pub`, `known_hosts` and the kubeconfig, none of which this repo has any business containing.

Two things that file documents rather than repeats:

- the agent sets `NAME=home-ops` explicitly, and the pane name in `COLUMNS`, the `Service` name and the
  agent's own `NAME` all have to be the same string, because ttyd's base path is `NAME` and the front
  derives the upstream base path from the first label of the Service name it looks up;
- the credentials are a Secret applied by hand, so nothing in the app starts until somebody brings it up,
  which is the deliberate gate on "are the credentials in yet".

`ttyd` here is built from `vendor/ttyd`, not installed from apt, and the reasons are in **Forks** below.
Two of its flags matter to this design and neither is currently used: `-b/--base-path` is what the
entrypoint relies on, and `-O/--check-origin` is *not* passed, so ttyd does not police the `Origin`
header - which is what lets a websocket handshake arriving over TLS at Traefik reach a plain-HTTP ttyd.
If that is ever tightened, `-H/--auth-header` is the flag that lets ttyd trust the identity headers the
gate injects instead of doing its own auth.

# Forks

The two programs the desktop is made of are vendored as submodules, on branches we own, because the work
ahead of this repo happens in them rather than around them:

| submodule | fork of | pinned at | branch |
| --- | --- | --- | --- |
| `vendor/ttyd` | `tsl0922/ttyd` | `1.7.7` | `slopyphus` |
| `vendor/xterm.js` | `xtermjs/xterm.js` | `5.4.0` (the version ttyd's client pins) | `slopyphus` |

- `Dockerfile` compiles the agent's `ttyd` in a `ttyd-builder` stage and `COPY`s the binary to
  `/usr/bin/ttyd`, the path apt would have used, so nothing that resolves `ttyd` by name knows the
  difference. The binary says what it is: `ttyd --version` is `1.7.7-slopyphus`, the suffix comes from a
  hunk in the fork's `CMakeLists.txt`, and both the builder stage and the CI gate fail if it is missing -
  a rebase onto upstream can drop that hunk without any other symptom.
- The browser client is not built by the image build at all. It is `vendor/ttyd/src/html.h`, a generated
  header holding the gzipped, inlined `index.html` that upstream commits, so the client is a *source file*
  of the binary. That is why the two forks are not enough on their own: `hack/build-ttyd-client.sh` is the
  thing that joins them. It builds `@xterm/xterm` from `vendor/xterm.js`, points ttyd's `package.json` at
  that build in a copy of the tree (never in the checkout, so ttyd stays buildable on its own), runs the
  webpack plus gulp build, and writes the header back into the fork. The header is then committed on the
  fork's `slopyphus` branch and the pin in this repo moves with it.
- `hack/build-ttyd-client.sh --check` answers "would this rebuild change anything?" by comparing the
  *decompressed* payload (`hack/html-h-payload.mjs`), because the gzip member stores an mtime and two
  builds of identical content do not hash the same. An unmodified fork reproduces the client upstream
  shipped, payload for payload - that is the baseline this repo is at, and it is what makes the first real
  patch to xterm.js a legible diff instead of a pile of build noise.
- The client build runs in a container on the CI node's dockerd, like the front testbed. ttyd's client is
  pinned to yarn 3.6.3 by its `packageManager` field and xterm.js wants yarn 1, and Ubuntu's `nodejs` plus
  `corepack` is what supplies both; the container also installs `ca-certificates`, because without a trust
  store corepack reports a TLS failure as a network error, which is a very misleading way to spell it.

Where the work lands, for the record: drag/drop and paste images belong in ttyd's client
(`html/src/components/terminal.tsx`), which already holds the terminal's websocket and can send bytes down
it; the `@xterm/xterm` fork is for what the terminal itself has to know about (rendering an image, and
xterm's own `.xterm .xterm-viewport{overflow-y:scroll}`, which is the bar every terminal pane carries and
that the front currently has to inject a style over - see **Panes and scrollbars**).

# Checks

The front's config is generated, so the check that matters is on the generator, not the image:

```sh
# render and validate a desktop without serving it
docker run --rm -e COLUMNS='a,b' -e ROWS='c' -e LAYOUT=rows_top \
  --entrypoint /docker-entrypoint.nginx.sh initialed85/slopyphus-nginx nginx -t

# look at what it rendered instead
docker run --rm -e COLUMNS='a,b' --entrypoint /docker-entrypoint.nginx.sh \
  initialed85/slopyphus-nginx sh -c 'cat /etc/nginx/conf.d/default.conf; echo; cat /usr/share/nginx/html/index.html'
```

The desktop the cluster actually runs is worth rendering on its own, because it is the one shape where
the upstream name is a cluster Service rather than a compose hostname:

```sh
docker run --rm -v "$PWD":/w:ro -w /w -e TEMPLATE_DIR=. \
  -e CONF_OUT=/tmp/default.conf -e HTML_OUT=/tmp/index.html -e RESOLVER=127.0.0.1 \
  nginx:alpine sh -c "COLUMNS='home-ops' ROWS= SVC_SUFFIX=slopyphus.svc.cluster.local \
    sh ./docker-entrypoint.nginx.sh true && grep -A4 'location /home-ops/' /tmp/default.conf"
```

`.woodpecker/ci.yaml` asserts the same render, including that single-group case (one iframe,
`grid-template-columns: 1fr`, upstream `home-ops.<namespace>.svc.cluster.local:7681` rewritten to the
base path `home-ops` was started with) and the rejections: a bad `LAYOUT`, a bad `SVC_SUFFIX`, an empty
desktop, a duplicated pane name and a reserved pane name.

## The live front testbed

A render check cannot say anything about how the desktop *looks*, so `hack/front-testbed.sh` runs the
working tree's templates as a real container on the CI node's daemon and `hack/front-cdp.mjs` looks at it
through the shared Chromium (`chromium.dev.initialed85.cc`) over CDP:

```sh
hack/front-testbed.sh up                       # renders the working tree; prints the URL to open
hack/front-testbed.sh push index.html.template # cp into the running container, no restart (a restart re-renders)
hack/front-testbed.sh probe hack/probe-scrollbars.js
hack/front-testbed.sh cdp --url http://<node>:<port>/ --expression-file hack/probe-terminal.js \
  --width 1280 --height 800 --shot /tmp/desktop.png
hack/front-testbed.sh logs
```

CDP rather than the one-shot `/render`, `/screenshot` and `/eval` routes, for two reasons those routes do
not cover: they evaluate before a pane's own script has run (xterm only exists once ttyd's websocket opens)
and they cannot show the result of what an expression did, which is what measuring a layout change needs.
`front-testbed.sh cdp` carries the bearer token in and passes the rest of its arguments through.

The probe files are the measurements quoted under **Panes and scrollbars**: `probe-scrollbars.js` (page
overflow, every label against its pane, whether the injected style landed in each pane), `probe-expand.js`
(expanding a pane to the viewport still works with the page clipped), `probe-terminal.js` (a real ttyd
pane's `.xterm-viewport`), `probe-scrollbox.js` with `scratch-scrollbox.html` (whether a bar takes layout
space in a given browser at all).

One trap in that environment, learned the hard way: a headless browser pointed at a *live* agent's pane
attaches a ttyd client to that agent's tmux, and tmux sizes a window to its smallest client - so probing
the deployed 20-pane desktop from an 800x600 headless tab resizes the terminals of every agent on it. Test
against `https://example.com` panes carrying the same *names*, which reproduce the narrow-pane layout with
no agent involved, and only point a pane at a real ttyd when it is your own agent.

The other thing that environment cannot measure: this Chromium renders overlay scrollbars, so a bar reserves
nothing there (a `::-webkit-scrollbar` forced to 15px reserves nothing, `scrollbar-gutter: stable` reserves
nothing, and no bar is drawn at all). Overflow - the thing a browser turns into a bar - is measurable, and
so is whether the injected rule landed and what the pane's own viewport computes; the width of the strip
that a desktop browser would have taken is not.

## Proving the forked terminal actually works

The gate asserts the build (`ttyd --version` names the fork, `ldd` resolves, a real ttyd from the shipped
image starts) and nothing about the client, because there is no browser in a CI step. This is the
sequence that closes that gap; it is what was run for `1.7.7-slopyphus`, against the CI node's daemon:

```sh
# 1. the client, from the forks, into the header the binary embeds
hack/build-ttyd-client.sh --check        # would a rebuild change anything? (payload compare)
hack/build-ttyd-client.sh               # write it, then commit in the fork and re-pin here

# 2. the agent image, and the ttyd it ships
DOCKER_HOST=tcp://192.168.1.213:2375 docker build --platform=linux/amd64 -t probe:local .
docker run --rm --entrypoint ttyd probe:local --version          # 1.7.7-slopyphus
docker run --rm --entrypoint ldd  probe:local /usr/bin/ttyd      # nothing 'not found'

# 3. serve it, and look at it in the shared Chromium
DOCKER_HOST=tcp://192.168.1.213:2375 docker run -d --name probe -p 0.0.0.0:38139:7681 \
  --entrypoint /usr/bin/ttyd probe:local -p 7681 -i 0.0.0.0 -b /test bash
CHROMIUM_TOKEN=$(kubectl -n auth get secret api-tokens -o jsonpath='{.data.API_TOKEN_EDWARD}' | base64 -d) \
  node hack/front-cdp.mjs --url http://192.168.1.213:38139/test/ \
    --expression-file hack/probe-fork-terminal.js --wait-ms 4000 --shot /tmp/terminal.png
```

The result that matters is `title` in the probe output and the prompt in the screenshot: the title is set
by ttyd's client from the shell's OSC sequence, which arrives over the websocket, so a real title is proof
that the forked client connected, negotiated, and rendered a live shell. The `--writable` flag is not
needed for that and its absence is why the probe container's terminal is read-only.
