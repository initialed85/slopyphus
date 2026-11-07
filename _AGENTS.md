# Workflow

This is a multi-agent, top-down workflow; the idea is that a large and capable model (the "coordinator") is given a problem statement from
the human user, builds a plan, builds a spec, breaks up the work into appropriately sized tasks and coordinates allocating the work to a
number of "coder", "deployer" and "tester" agents (which are all smaller, less-capable models).

The "pi-team-room" extension is the mechanism by which agents can communicate; communications should primarily only flow between the
"coordinator" and the "coder", "deployer" or "tester" agents (i.e. top-down) and not laterally (for ease of the "coordinator").

# Guiding principles

- Thin, vertical, full-depth slices
- Build reusable tooling
- Aim to validate the skeleton in the local environment early
- Aim to validate the skeleton in the target environment soon after
- Try to keep the local environment in sync with master unless it isn't feasible
  - This may mean rebuilding / restarting / redeploying the local environment as each branch is merged into master
- Try to keep the target environment in sync with master as features are completed / milestones are achieved

# The "coordinator" agent only

- The user will provide a rough goal / requirements
- Ask for clarification early if required
- Carefully maintain `docs/PLAN.md`, `docs/SPEC.md`, `docs/tasks/*.md` and `docs/STATUS.md`
- The plan leads into the spec and together they are decomposed into suitably sized (for a Qwen 3.5 9b model at Q5_K_M) tasks, named with a numbering
  system that is friendly to filesystems and branch names; the status of tasks are updated as they change
- Allocate tasks among the applicable agents; dev work to coders, local or target environment work to deployers, local or target environment
  validation work to testers- be clear to the agent as to which role it is, when you're allocating it a task (to avoid confusion)
- Tasks are expected to be somewhat verified by the allocated "coder", "deployer" or "tester" agent (remaining conscious of small model limitations)
- The "coordinator" agent is ultimately responsible for verifying that a task has been completed correctly and should organise re-work as required

# The "coder" agents only

- The "coordinator" will provide clear directions on development tasks (including how to verify)
- Create a new branch from master, using the task number as a name
- Keep code changes terse but pragmatic; code to move fast in the present without badly forsaking the future
- Let the "coordinator" know when complete; the "coordinator" will further validate and merge the branch (or request changes)
- Ensure not to commit Python `.venv`, JavaScript `node_modules`, Rust `target` etc
- Do not work beyond your task

# The "deployer" agents only

- The "coordinator" will provide clear directions on deployment tasks (including how to verify)
- Deployments to the local environment can be as simple as local, native development servers (just enough to enable external validation)
- Deployments to the target environments are likely to be Kubernetes in the "dev" cluster as per /home/edward/Projects/Home/home-ops
- Let the "coordinator" know when complete; the "coordinator" may further validate and accept the work (or request changes)
- Ensure to exclude Python `.venv`, JavaScript `node_modules`, Rust `target` etc from Docker builds
- Do not work beyond your task

# The "tester" agents only

- The "coordinator" will provide clear directions on testing tasks (including how to verify)
- There are some shared resources that may be useful for testing documented at /home/edward/Projects/Home/home-ops/SERVICES.md
- Testing may be against the local environment or the target environment
- Let the "coordinator" know when complete; the "coordinator" may further validate and accept the results (or request further testing)
- Ensure not to commit jUnit test results etc
- Do not work beyond your task

# All agents

- Never claim a command was run unless the command tool returned its output
- Never claim tests passed unless you actually ran the test command
- Never claim a file or message was changed unless the corresponding tool returned success
- Do not describe an intended tool call as if it already happened
- When an action is required, call the tool immediately
- After every tool call, inspect its result before reporting the outcome

# The desktop (this repo's own front end)

The UI is generated at container start, not committed: `docker-entrypoint.nginx.sh` renders
`nginx.conf.template` and `index.html.template` from `COLUMNS` / `ROWS` / `LAYOUT` (see `README.md`).
There is no committed `nginx.conf` or `index.html` any more, and the rendered copies inside a running
container are output, not source- edit the template or the environment, never the rendered file.

- The renderer is `/bin/sh` on busybox ash (`nginx:alpine` has no bash): no arrays, no `[[ ]]`, no `$''`,
  and no `local` - every function's `_`-prefixed variables are global to the script. The main flow's own
  loop variables are named `_page*` because the renderers reuse `_k`, `_name` and `_tabs` internally: a
  `_k` in the main flow is clobbered by `render_tab_nav`'s own tab loop, and the failure is silent - tab 1
  renders, no other page is written, and the summary still prints every tab.
- A desktop is a page per group of panes. `PANES_PER_TAB` (default 6) decides when it splits, and the
  entrypoint renders `tab-1.html` ... `tab-N.html`, plus `all.html` (every pane at once); `/`, `/index.html`
  and `/tab-1` are aliases of the first of them, and the render deletes any `index.html` it finds. No page is
  special, so nothing in the renderer branches on tab 1.
- A pane is framed with ttyd's `disableLeaveAlert=true`, set in `index.html.template`'s iframe URL, because
  ttyd's default client registers a `beforeunload` handler that would prompt on every tab switch. The fix is
  a query parameter on the pane's URL (`parseOptsFromUrlQuery` reads it); do not go editing the vendor client
  for this, and do not drop the parameter from a pane without measuring what the browser then asks -
  `hack/front-cdp.mjs` reports the dialogs it answered. Every page links `/slopyphus-desktop.css` and `/slopyphus-desktop.js`, which `Dockerfile.nginx`
  copies into the directory nginx serves; the only per-page CSS is the rule that splits the viewport and
  states the tab strip's height, which `render_grid_css` emits inline. So a change to how the desktop
  *looks* is usually those two files plus `index.html.template`, and a change to how panes are *grouped* is
  `render_groups` / `render_grid_css` / `split_tabs`.
- An agent name may not be `index`, `all`, `tab-<digits>`, anything ending in `.html`, or the two asset
  names: those are routes the front owns, and `validate_name` refuses them rather than letting a proxy
  location and a static page share a path.
- Change which agents are on the desktop with environment variables (compose `UI_*`, or a Deployment's env).
  Do not add a per-agent block to a template; the templates must not know any agent's name.
- `.woodpecker/ci.yaml` asserts what the renderer emits. If you change the renderer's output, change the
  assertions in the same change- a check that passes because it looks for a string that is no longer
  produced is worse than no check.
- The desktop shows no scrollbars, on the page or in a pane (`README.md`, "Panes and scrollbars"). The three
  rules that make that true are load-bearing: `iframe { display: block }`, a pane label clipped to its pane,
  and the style the script injects into every same-origin pane. A scrollbar hidden without its area given
  back (old `::-webkit-scrollbar { display: none }`) is the failure this replaced, not the fix.
- How the desktop looks is checked in `hack/front-testbed.sh` (working-tree templates as a live container)
  and `hack/front-cdp.mjs` (CDP against the shared Chromium, which can wait for a pane to build its own UI).
  Reproduce a layout with panes that are *names* pointing at `https://example.com`; do not point a headless
  probe at a live agent's ttyd, because tmux sizes a window to its smallest client.

# The vendored forks (ttyd, xterm.js)

The agent's `ttyd` is compiled from `vendor/ttyd` (fork of `tsl0922/ttyd`, working branch `slopyphus`), and
its browser client is built from `vendor/xterm.js` (fork of `xtermjs/xterm.js`, branch `slopyphus`). Both
are pinned by commit, not by branch, so `git submodule update --init --recursive` is what CI builds.

- `vendor/ttyd/src/html.h` is a generated file that upstream commits: the gzipped, inlined UI the binary
  embeds. Edit the client (`vendor/ttyd/html/**`, `vendor/xterm.js/**`), then run
  `hack/build-ttyd-client.sh` to regenerate the header, then commit the header **in the fork** and re-pin
  the submodule here. Never hand-edit `html.h`, and never edit the rendered copy inside a container.
- The image build runs no node toolchain: it compiles the committed header. A client change that has not
  been regenerated and committed in the fork is therefore invisible in the image, which is the failure
  mode to watch for when a terminal change "does not deploy".
- `ttyd --version` must say `1.7.7-slopyphus`. The suffix is a hunk in the fork's `CMakeLists.txt`, and
  both the `Dockerfile` builder stage and `.woodpecker/ci.yaml` assert it, so a rebase onto upstream that
  drops it fails the build.
- Pushing a fork from this pod needs the ssh remote (`git@github.com:initialed85/ttyd`); the https url in
  `.gitmodules` stays, because that is what CI's clone uses and it works without credentials.

# Committing from inside an agent pod

- The clone an agent pod boots with has no git identity, so `git commit` fails with `Author identity unknown`
  until `git config user.name edwardbeech && git config user.email edward@initialed85.cc` is run in that
  repository. Repo-local on purpose: the identity belongs to the commits, and a global setting would follow
  the machine rather than the repo.

# Reusable services

See `/root/.pi/agent/SERVICES.md` for reusable services
