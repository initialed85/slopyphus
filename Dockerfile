# syntax=docker/dockerfile:1
#
# ttyd comes from vendor/ttyd, not from apt. That submodule is initialed85/ttyd, a fork of tsl0922/ttyd
# pinned to 1.7.7 — the same release apt installs — and the point of owning it is the browser client:
# ttyd embeds its whole UI as a generated header (src/html.h) whose xterm.js half is built from
# vendor/xterm.js, also a fork, by hack/build-ttyd-client.sh. The image build therefore needs no node
# toolchain at all: it compiles the header that is already committed in the fork. See README.md.
FROM ubuntu:26.04 AS ttyd-builder

RUN apt update && \
    apt install -y --no-install-recommends build-essential cmake libwebsockets-dev libjson-c-dev libuv1-dev zlib1g-dev

COPY vendor/ttyd /src/ttyd
WORKDIR /src/ttyd

RUN cmake -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --parallel "$(nproc)" && \
    install -m 0755 build/ttyd /usr/local/bin/ttyd && \
    /usr/local/bin/ttyd --version | grep -q slopyphus

FROM ubuntu:26.04

SHELL ["/bin/bash", "-lic"]

# ttyd is deliberately absent here: the binary is COPY'd from the builder stage above. What is installed
# are the libraries that binary needs, and `ldd` is not enough to answer that: libwebsockets loads its
# libuv event loop plugin by dlopen (`lws_create_context: failed to load evlib_uv` is how it complains,
# at start, in a way that looks like a ttyd bug and not a missing package), so the .so is a runtime
# dependency that no linker output mentions. libuv1t64 and friends are the t64-renamed runtime packages
# Ubuntu 26.04 uses; the names come from `dpkg -S` on the .so paths, not from guessing.
RUN apt update && \
    apt install -y tmux curl unzip ca-certificates ripgrep fd-find libatomic1 locales software-properties-common \
        zlib1g libjson-c5 libuv1t64 libssl3t64 libcap2 libzstd1 libwebsockets19t64 libwebsockets-evlib-uv tzdata && \
        locale-gen en_US.UTF-8 && \
        update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TZ=Australia/Perth

RUN add-apt-repository ppa:trzsz/ppa
RUN apt update && apt install -y trzsz libsixel-bin

RUN install -m 0755 -d /etc/apt/keyrings
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
RUN chmod a+r /etc/apt/keyrings/docker.asc

RUN echo "Types: deb" >> /etc/apt/sources.list.d/docker.sources
RUN echo "URIs: https://download.docker.com/linux/ubuntu" >> /etc/apt/sources.list.d/docker.sources
RUN echo "Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")" >> /etc/apt/sources.list.d/docker.sources
RUN echo "Components: stable" >> /etc/apt/sources.list.d/docker.sources
RUN echo "Architectures: $(dpkg --print-architecture)" >> /etc/apt/sources.list.d/docker.sources
RUN echo "Signed-By: /etc/apt/keyrings/docker.asc" >> /etc/apt/sources.list.d/docker.sources

RUN apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN echo 'export PATH=$PATH:/root/.local/bin' >> /root/.bashrc
RUN . /root/.bashrc && uv python install --default python3.12

RUN curl -fsSL https://bun.sh/install | bash

RUN curl -L https://go.dev/dl/go1.27.3.linux-amd64.tar.gz -O

RUN tar -C /usr/local -xzf go1.27.3.linux-amd64.tar.gz
RUN echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.bashrc

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh | PROFILE="${BASH_ENV}" bash
RUN . /root/.nvm/nvm.sh && nvm install --lts
RUN . /root/.nvm/nvm.sh && npm install -g typescript

RUN . /root/.nvm/nvm.sh && yes | curl -fsSL https://pi.dev/install.sh | sh

RUN echo 'export PATH=$PATH:/root/.pi/agent/bin' >> /root/.bashrc
RUN echo 'export PATH=$PATH:/usr/bin/versions/node/v24.22.1/bin' >> /root/.bashrc

RUN bash -c 'curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && mv kubectl /usr/local/bin/ && chmod +x /usr/local/bin/kubectl'

COPY .tmux.conf /root/.tmux.conf
# tmux-smooth-scroll (github.com/azorng/tmux-smooth-scroll), vendored with one patch to src/init.sh - see
# the comment there. It is in the repo rather than cloned at build time because the build must be
# reproducible without a network fetch of a third party's main branch, and there is no TPM in this image.
COPY tmux-smooth-scroll /usr/local/share/tmux-smooth-scroll
COPY docker-entrypoint.sh /docker-entrypoint.sh

# The fork's binary, at the same path apt would have used, so anything that resolves `ttyd` by name
# (docker-entrypoint.sh, an agent's own shell) finds it without knowing the difference.
COPY --from=ttyd-builder /usr/local/bin/ttyd /usr/bin/ttyd
RUN ttyd --version && ttyd --version | grep -q slopyphus

# No Pi extensions are baked into this image. They come from the pi-ed package, installed per pod by the
# entrypoint hook (`pi install git:github.com/initialed85/pi-ed`, see home-ops
# clusters/dev/applications/slopyphus/configmap-credentials.yaml), which writes /root/.pi/agent/settings.json
# and whose package.json declares `extensions: ["./extensions"]`. Four copies used to be COPYed here as
# .ts files, and that was a second source rather than a safety net: Pi loaded both and disambiguated the
# duplicates in /v1/commands (`queue-reload:1`), and the copies here were frozen at 2026-10-29 while the
# package had moved on (compaction-summary-guard 2026-11-03, queue-reload 2026-11-20), so the stale one
# loaded alongside the current one.
#
# That hook declares an unpinned git source, which resolves to the repo's default branch, so the tag that is
# supposed to be a roll boundary constrained nothing. The pin is applied in docker-entrypoint.sh (see the
# PI_ED_REF block there) after the hook runs, because re-installing the same source unpinned replaces a
# pinned declaration. This Dockerfile pins nothing: there is no package source in it to pin.
#
# The trade being signed: if a pod's hook fails, that pod now has no extensions at all rather than four
# leftovers. That fails loudly, not silently - docker-entrypoint.sh exits 1 on a failed hook (see its
# line 23), so the pod crash-loops and Argo keeps the last healthy revision.

# Inline images for a pane. tmux discards a bare OSC 1337 and Pi's fullscreen TUI switches its own image output
# off before it starts, so neither half of the problem is fixed by the other: tools/pi-images.sh runs Pi in the
# mode where images are emitted at all, and tools/tmux-osc-wrap.py wraps whatever the program writes into the DCS
# tmux is willing to carry. Neither is wired into the pane command; `pi-images` is a command a person runs.
RUN mkdir -p /usr/local/share/slopyphus
COPY tools/tmux-osc-wrap.py /usr/local/share/slopyphus/tmux-osc-wrap.py
COPY tools/pi-images.sh /usr/local/bin/pi-images
RUN chmod 0755 /usr/local/share/slopyphus/tmux-osc-wrap.py /usr/local/bin/pi-images

# git, and the ssh client it drives, are hard runtime requirements of a pod, not build-time niceties:
# docker-entrypoint-hook.sh does `git clone ssh://git@github.com/...` and `git pull` on the agent's own repo,
# and `pi install git:github.com/...` shells out to git ("Error: spawn git ENOENT"). Without them every agent
# pod fails the hook, and docker-entrypoint.sh exits 1 on a failed hook, so the whole namespace crash-loops
# and the only symptom in the log is line 12: git: command not found.
#
# They used to be here by accident rather than by request: `apt install -y docker-ce ...` pulled a Recommends
# closure (git, git-man, liberror-perl, perl, openssh-client, less, patch, xauth and the X11 libs ssh drags
# in), and Docker 29.10.0 dropped that closure -- compare /var/log/apt/history.log in the two images built
# from the same Dockerfile: 29.9.3 installed 290 packages with git marked `automatic`, 29.10.0 installed 269
# and git is simply absent. Nothing in this Dockerfile mentioned git either time. That is the whole reason
# this is stated explicitly and asserted below: a dependency that arrives through a third party's Recommends
# can vanish in a mirror refresh, and it fails at boot in every pod rather than at build.
#
# A separate layer, deliberately placed after the download layers rather than as one more word in the apt
# line above: editing that line invalidates everything below it (uv, go, nvm, the pi installer, kubectl),
# which turns a two-minute rebuild into a ten-minute one for a package that nothing else depends on.
# --no-install-recommends so this layer is exactly these three and the closure is ours to change.
RUN apt update && \
    apt install -y --no-install-recommends git openssh-client less && \
    rm -rf /var/lib/apt/lists/*

# The assertion is the point of the layer, not decoration: if the package ever stops installing, the image
# build fails and Argo keeps the last good tag, instead of fourteen agents crash-looping on a :latest nobody
# read.
RUN git --version && ssh -V

WORKDIR /workspace

# Deliberately not the place where the package ref is pinned: at this point in the build no package is
# configured yet (the per-pod hook is what writes settings.json), so this reconciles nothing and there is no
# source string here to pin. The pin lives in docker-entrypoint.sh, where the declaration actually exists.
RUN pi update && pi update --extensions

ENTRYPOINT [ "/docker-entrypoint.sh" ]
CMD []
