# slopyphus

A browser terminal for a [pi](https://pi.dev) agent, and a desktop that composes many of them.

Two images:

| image | built from | what it is |
| --- | --- | --- |
| `initialed85/slopyphus` | `Dockerfile` | one agent: ubuntu, tmux, ttyd, pi, trzsz, docker-cli, uv, go, node, kubectl |
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
`.woodpecker/build.yaml` decides what is in the registry. On a push to `master` both run, the second one
against the same node and mostly `CACHED`.

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

`ttyd` 1.7.7 is stock here. Two of its flags matter to this design and neither is currently used:
`-b/--base-path` is what the entrypoint relies on, and `-O/--check-origin` is *not* passed, so ttyd does
not police the `Origin` header - which is what lets a websocket handshake arriving over TLS at Traefik
reach a plain-HTTP ttyd. If that is ever tightened, `-H/--auth-header` is the flag that lets ttyd trust
the identity headers the gate injects instead of doing its own auth.

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
