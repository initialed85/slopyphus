#!/bin/sh
# Show an image as SIXEL in the pane you are running this from, and print what tmux would do with it.
#
# Run it from a slopyphus pane (that is, a shell inside tmux under ttyd) with no arguments and it takes the
# newest file in .slopyphus/uploads/, which is where pasting or dropping a file in the browser puts it:
#
#   hack/sixel-show.sh
#   hack/sixel-show.sh some/other.png
#   hack/sixel-show.sh some/other.png -w 400        # -w resizes to 400 px wide; extra args go to img2sixel
#   hack/sixel-show.sh upload.jpg -p 32             # 32 colours, much smaller payload
#
# With no -w the script caps the image at 720 px wide, because a desktop screenshot is usually several thousand
# and tmux clamps it to the pane only after the whole payload has been generated and sent.
#
# tmux 3.6a needs two things before it will carry a sixel to a client, and both are readable from inside the
# pane (tty.c:2306-2311):
#
#   1. the client terminal must be sixel-capable - either the `sixel` terminal feature or the terminfo `Sxl`
#      capability - and the server must have sixel compiled in at all, which `#{sixel_support}` reports;
#   2. tmux must know the client's cell size in *pixels*, which it gets from TIOCGWINSZ's ws_xpixel/ws_ypixel
#      and, when those come back zero, by asking the terminal with `ESC[18t ESC[14t` (tty.c:145-152). A terminal
#      that answers gets a scaled image; a pty chain that never answers gets zero.
#
# If either fails, tmux does not silently drop the image - it substitutes a text placeholder built by
# image.c:56, which is the string "SIXEL IMAGE (WxH)" followed by lines of '+'. Seeing that box instead of a
# picture means the gate failed, not that the sixel was lost.
#
# Note the difference between this and what tmux does with the two protocols Pi actually emits: tmux has no
# handler for OSC 1337 or for kitty graphics at all, so those are parsed and discarded with no placeholder and
# no trace. Sixel is the one image format this tmux understands natively.
set -u

if [ -f "${1:-}" ]; then img=$1; shift; else
  img=$(ls -t .slopyphus/uploads/*.png .slopyphus/uploads/*.jpg .slopyphus/uploads/*.jpeg 2>/dev/null | head -1)
fi
[ -f "${img:-}" ] || { echo "no image: pass a path, or drop one in .slopyphus/uploads/"; exit 2; }

command -v img2sixel >/dev/null || { echo "img2sixel is not installed here"; exit 3; }

echo "== file: $(ls -l "$img" | awk '{print $5" bytes"}') $img"
echo "== tmux $(tmux -V) ${TMUX:+(this shell is inside a tmux pane)}${TMUX:-  <- WARNING: not inside tmux, so this tests the terminal, not tmux}"

if [ -n "${TMUX:-}" ]; then
  echo "== what tmux reports about this client (the two gates, plus the pane it has to fit in)"
  tmux display -p '  sixel compiled in .. #{sixel_support}
  client terminal .... #{client_termname}
  client cell px ..... #{client_cell_width} x #{client_cell_height}
  window cell px ..... #{window_cell_width} x #{window_cell_height}
  pane ............... #{pane_width}x#{pane_height}'
  echo "  If 'client cell px' is 0 x 0, tmux has no pixel geometry for this client and will draw the text"
  echo "  placeholder instead of the image, whatever the other numbers say."
fi

echo "== emitting sixel"
# A screenshot off a desktop is often 2000-3000 px wide. tmux will clamp it to the pane, but the payload is
# still generated at full size first and has to cross ttyd's websocket, so a width cap is the default here and
# not an afterthought. Give -w explicitly to override it.
case " $* " in *" -w "*) ;; *) set -- -w 720 "$@";; esac
img2sixel "$@" "$img"

if [ -n "${TMUX:-}" ]; then
  n=$(tmux capture-pane -p 2>/dev/null | grep -c "SIXEL IMAGE")
  echo "== after: tmux's text placeholder appears $n time(s) in this pane's captured text"
  echo "  A non-zero count means tmux took the fallback path and the client saw a box of '+' rather than the"
  echo "  image. Zero means either tmux drew the image or capture-pane simply does not surface image cells -"
  echo "  look at the pane, not at this number."
fi
