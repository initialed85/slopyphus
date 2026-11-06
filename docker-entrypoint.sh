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

if ! bash /docker-entrypoint-hook.sh; then
	echo "error: failed to run /docker-entrypoint-hook.sh"
	exit 1
fi

bash -lic 'pi update'
bash -lic 'pi update --extensions'

# Pi writes to the local (X11/xclip) clipboard when it can, which a container has no use for. OSC 52 is
# what actually reaches a browser: Pi sends the copied text to the terminal, tmux passes it through
# (allow-passthrough), and ttyd's client writes it into the browser clipboard.
export PI_CLIPBOARD_OSC52=1

# shellcheck disable=SC2016
tmux new-session -d -s "${NAME}" -c "/workspace/${NAME}" -- bash -lic "pi -c --name ${NAME} --model ${MODEL?MODEL env var empty or unset} || sleep 10" &

# ttyd serves its UI under -b, and the front depends on that base path matching the agent's name:
# /coordinator/ is rewritten to /coordinator/ on the upstream only because ttyd listens there.
# The inner `tmux attach` runs in a shell ttyd spawns later, so it reads NAME from the environment
# (exported above) rather than from this script's quoting.
# shellcheck disable=SC2016
exec ttyd -p 7681 -w "/workspace/${NAME}" -W -b "/${NAME}" -t fontSize=12 -t enableResize=true -t enableTrzsz=true -t enableSixel=true -t scrollback=0 bash -c 'tmux attach -t "$NAME" || kill -SIGINT 1'
