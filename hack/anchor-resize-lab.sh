#!/bin/sh
# A lab for "reflowing images is slow": two panes with the same row count, one holding anchored pictures and one
# holding plain rows, both served by ttyd, both driven by a headless browser through a resize sequence.
#
#   hack/anchor-resize-lab.sh up      [images] [text]     default 12 pictures, 120 filler rows
#   hack/anchor-resize-lab.sh bench                        the measurement, both panes, one table
#   hack/anchor-resize-lab.sh status                       what is running and at which URL
#   hack/anchor-resize-lab.sh down                         kill the lab
#
# Why a lab and not the live agent pane: a tmux client sizes a window to the smallest client attached to it, and
# a headless tab is a client. Pointing a measurement browser at a live agent resizes that agent's terminal, so the
# lab runs in throwaway tmux sessions inside my own pod, served by two ttyds on ports 7682/7683 that nothing else
# publishes. The browser reaches them over the pod's own cluster IP.
#
# The pair is the whole design: every server-side number (tmux reflow, the relay's own CPU) was already measured
# and came out in milliseconds, so the claim "images reflow slowly" can only be about the client. A control pane
# with the same grid volume and no pictures is what makes that a measurement instead of an opinion.

set -eu

PROG=${0##*/}
CONTEXT=${CONTEXT:-home-dev}
NAMESPACE=${NAMESPACE:-slopyphus}
DEPLOY=${DEPLOY:-quake}
IMG_SESSION=lab-img
BYT_SESSION=lab-byt
TXT_SESSION=lab-txt
IMG_PORT=${IMG_PORT:-7682}
BYT_PORT=${BYT_PORT:-7684}
TXT_PORT=${TXT_PORT:-7683}
LAB=/tmp/anchorlab
REPO=${REPO:-/workspace/slopyphus}
RELAY=/usr/local/share/slopyphus/tmux-osc-wrap.py
# The chromium service is behind the bearer-token gate (home-ops SERVICES.md); same source front-testbed.sh uses.
CHROMIUM_TOKEN=${CHROMIUM_TOKEN:-$(kubectl --context "$CONTEXT" -n auth get secret api-tokens \
  -o jsonpath='{.data.API_TOKEN_EDWARD}' 2>/dev/null | base64 -d || true)}

kexec() { kubectl --context "$CONTEXT" -n "$NAMESPACE" exec "deploy/$DEPLOY" -- bash -c "$1"; }

case "${1:-up}" in
  up)
    IMAGES=${2:-12}
    TEXT=${3:-120}
    kexec "mkdir -p $LAB/img $LAB/txt"
    kexec "tmux kill-session -t $IMG_SESSION 2>/dev/null; tmux kill-session -t $BYT_SESSION 2>/dev/null; tmux kill-session -t $TXT_SESSION 2>/dev/null; true"
    kexec "mkdir -p $LAB/byt"
    # -c sets the pane's working directory, which is where the relay writes the pictures and where ttyd's
    # /images/<name> route looks for them (http.c builds getcwd() + image_dir + name).
    kexec "tmux new-session -d -s $IMG_SESSION -x 120 -y 60 -c $LAB/img -- python3 $RELAY --anchor python3 $REPO/hack/anchor-lab-emit.py --images $IMAGES --text 20"
    kexec "tmux new-session -d -s $TXT_SESSION -x 120 -y 60 -c $LAB/txt -- python3 $RELAY python3 $REPO/hack/anchor-lab-emit.py --images 0 --text $TEXT"
    sleep 3
    kexec "pkill -f '[t]tyd -p $IMG_PORT' 2>/dev/null; pkill -f '[t]tyd -p $BYT_PORT' 2>/dev/null; pkill -f '[t]tyd -p $TXT_PORT' 2>/dev/null; true"
    # ttyd's cwd must match the pane's cwd or the /images route serves nothing. The bracket in the pkill
    # pattern is what keeps pkill from matching the shell that carries it (that self-kill is why an earlier
    # run of this script died with 143). setsid plus redirecting every fd is what keeps `kubectl exec` from
    # holding the pipe open on a server that is meant to outlive the exec.
    kexec "tmux new-session -d -s $BYT_SESSION -x 120 -y 60 -c $LAB/byt -- python3 $RELAY python3 $REPO/hack/anchor-lab-emit.py --images 12 --text 20"
    kexec "mkdir -p $LAB/byt; cd $LAB/byt && setsid ttyd -p $BYT_PORT -W -w $LAB/byt -b /$BYT_SESSION -t fontSize=12 -t scrollback=0 bash -c 'tmux attach -t $BYT_SESSION' > /tmp/ttyd-byt.log 2>&1 </dev/null & true"
    kexec "cd $LAB/img && setsid ttyd -p $IMG_PORT -W -w $LAB/img -b /$IMG_SESSION -t fontSize=12 -t scrollback=0 bash -c 'tmux attach -t $IMG_SESSION' > /tmp/ttyd-img.log 2>&1 </dev/null & cd $LAB/txt && setsid ttyd -p $TXT_PORT -W -w $LAB/txt -b /$TXT_SESSION -t fontSize=12 -t scrollback=0 bash -c 'tmux attach -t $TXT_SESSION' > /tmp/ttyd-txt.log 2>&1 </dev/null & sleep 2; exit 0"
    IP=$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get pod -l app="$DEPLOY" -o jsonpath='{.items[0].status.podIP}')
    echo "lab up:"
    kexec "tmux list-sessions -F '  #{session_name} #{window_width}x#{window_height}' | grep lab; echo '  anchor files written: '\$(ls $LAB/img 2>/dev/null | wc -l)'; echo '  byte-path cwd (must stay empty for the byte pane): '\$(ls $LAB/byt 2>/dev/null | wc -l)"
    echo "  anchored pictures : http://$IP:$IMG_PORT/$IMG_SESSION   (relay --anchor: text token + GET /images/<name>)"
    echo "  inline pictures   : http://$IP:$BYT_PORT/$BYT_SESSION   (relay as agents run it today: base64 through tmux)"
    echo "  control, no pictures: http://$IP:$TXT_PORT/$TXT_SESSION"
    ;;
  status)
    kexec "tmux list-sessions -F '  #{session_name} #{window_width}x#{window_height} #{pane_pid}' | grep lab"
    kexec "ps -eo pid,args | grep -E '[t]tyd -p (7682|7683|7684)' | sed 's/^/  /'"
    kexec "echo '  anchored cwd:'; ls $LAB/img 2>/dev/null | sed 's/^/    /' | head -4; echo '  byte cwd:'; ls $LAB/byt 2>/dev/null | sed 's/^/    /' | head -4"
    kexec "echo '  anchor files:'; ls -la $LAB/img 2>/dev/null | tail -n +2 | awk '{print \"    \", \$5, \$9}' | head -5"
    ;;
  bench)
    IP=$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get pod -l app="$DEPLOY" -o jsonpath='{.items[0].status.podIP}')
    # 12 viewport sizes, 250 ms apart: what a user dragging a window edge hands the terminal.
    SEQ="1180x720,1160x710,1140x700,1120x690,1100x680,1080x670,1060x660,1040x650,1020x640,1000x630,980x620,960x610"
    for pane in "$IMG_SESSION:$IMG_PORT" "$BYT_SESSION:$BYT_PORT" "$TXT_SESSION:$TXT_PORT"; do
      name=${pane%%:*}; port=${pane##*:}
      echo "=== $name (http://$IP:$port/$name)"
      CHROMIUM_TOKEN="$CHROMIUM_TOKEN" node "$REPO/hack/front-cdp.mjs" --url "http://$IP:$port/$name" --wait-ms 8000 \
        --measure-file "$REPO/hack/anchor-resize-install.js" \
        --resize-seq "$SEQ" --resize-gap-ms 250 --perf-metrics \
        --post-measure-file "$REPO/hack/anchor-resize-read.js" --capture-console 2>&1 | tail -40
    done
    ;;
  down)
    kexec "pkill -f '[t]tyd -p $IMG_PORT' 2>/dev/null; pkill -f '[t]tyd -p $BYT_PORT' 2>/dev/null; pkill -f '[t]tyd -p $TXT_PORT' 2>/dev/null; tmux kill-session -t $IMG_SESSION 2>/dev/null; tmux kill-session -t $BYT_SESSION 2>/dev/null; tmux kill-session -t $TXT_SESSION 2>/dev/null; true"
    echo "lab down"
    ;;
  *)
    echo "usage: $PROG [up|bench|status|down]" >&2
    exit 2
    ;;
esac
