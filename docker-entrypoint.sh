#!/bin/bash

set -e

# The agent's own name. In compose the container's hostname is already the agent name, so this stays
# unset; in Kubernetes a pod's hostname is its pod name, which is a generated suffix, not "coordinator".
# NAME is what everything here is keyed on: the workspace directory, the tmux session, the pi identity,
# and ttyd's base path, which the nginx front proxies to. Set NAME in the pod spec and the pod name stops
# mattering.
NAME="${NAME:-$(hostname)}"
export NAME

# shellcheck disable=SC1091
source /root/.bashrc

mkdir -p "/workspace/${NAME}"
pushd "/workspace/${NAME}"

touch /docker-entrypoint-hook.sh >/dev/null 2>&1 || true

bash -lic 'pi update'

if ! bash -lic "/docker-entrypoint-hook.sh"; then
	echo "error: failed to run /docker-entrypoint-hook.sh"
	exit 1
fi

bash -lic 'pi update --extensions'

# Pi writes to the local (X11/xclip) clipboard when it can, which a container has no use for. OSC 52 is
# what actually reaches a browser: Pi sends the copied text to the terminal, tmux passes it through
# (allow-passthrough), and ttyd's client writes it into the browser clipboard.
export PI_CLIPBOARD_OSC52=1

# Inline images in a pane need three things at once, and `pi-images` (tools/pi-images.sh, installed by the
# Dockerfile) supplies all three: Pi in its non-alt-screen UI, because Pi's fullscreen TUI switches its own
# image output off (beforeTerminalStart nulls capabilities.images); the iterm2 protocol, because a terminal
# behind tmux does not answer Pi's capability probe the way Pi expects and the detected answer is none; and
# tmux's passthrough DCS around every OSC 1337, because tmux discards a bare OSC 1337 rather than carrying it.
#
# The cost is real and is the reason the choice is a switch: --tui-mode regular is not Pi's fullscreen UI, so
# the pane loses the alternate-screen interface and gets Pi's scrolling transcript instead. Pi's fullscreen mode
# cannot draw inline images in this stack at all -- in alt-screen it emits the kitty graphics protocol, xterm.js
# has no decoder for it, and a pane painted 0 pixels with it under tmux and without (measured, see PLAN.md).
# Set PI_PANE_MODE=fullscreen in the pod spec to have the fullscreen UI back and no inline images.
PI_PANE_MODE=${PI_PANE_MODE:-images}
case "$PI_PANE_MODE" in
	images | pi-images) PI_COMMAND=pi-images ;;
	fullscreen | plain | pi) PI_COMMAND=pi ;;
	*)
	echo "error: PI_PANE_MODE must be images or fullscreen, got '$PI_PANE_MODE'" >&2
	exit 1
	;;
esac

# shellcheck disable=SC2016
tmux new-session -d -s "${NAME}" -c "/workspace/${NAME}" -- bash -lic "${PI_COMMAND} -c --name ${NAME} --model ${MODEL?MODEL env var empty or unset} || sleep 10" &

# ttyd serves its UI under -b, and the front depends on that base path matching the agent's name:
# /coordinator/ is rewritten to /coordinator/ on the upstream only because ttyd listens there.
# The inner `tmux attach` runs in a shell ttyd spawns later, so it reads NAME from the environment
# (exported above) rather than from this script's quoting.
# shellcheck disable=SC2016
exec ttyd -p 7681 -w "/workspace/${NAME}" -W -b "/${NAME}" -t fontSize=12 -t enableResize=true -t enableTrzsz=true -t enableSixel=true -t scrollback=0 bash -c 'tmux attach -t "$NAME" || kill -SIGINT 1'
