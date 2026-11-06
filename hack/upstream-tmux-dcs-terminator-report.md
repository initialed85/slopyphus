# tmux 3.6: tmux(1)'s passthrough DCS closing sequence is wrong, and following it silently destroys pane output

Draft for filing against https://github.com/tmux/tmux. Written from measurements, not from reading the page.
Probe that produces these numbers: `hack/tmux-manpage-dcs-close.sh` in this repository (needs no slopyphus
component - it drives plain tmux, `pipe-pane`, and `script(1)`).

## Environment

- tmux 3.6 (the build in the slopyphus agent image, Debian bookworm), and independently reproduced on a second
  machine running tmux 3.6 by a colleague who got a different byte count and the same failure.
- No slopyphus, ttyd, or xterm.js involved in the reproducer below.

## The text under dispute

`tmux.1` at tag `3.6`, the `allow-passthrough` pane option:

```
.It Xo Ic allow-passthrough
.Op Ic on | off | all
.Xc
Allow programs in the pane to bypass
.Nm
using a terminal escape sequence (\eePtmux;...\ee\e\e).
If set to
.Ic on ,
passthrough sequences will be allowed only if the pane is visible.
If set to
.Ic all ,
they will be allowed even if the pane is invisible.
```

That sequence is read as: open with ESC `P` `tmux` `;`, and close with **ESC ESC backslash**. The closing is the
part that is wrong, and the paragraph never says that only the payload's own escapes are doubled.

## What tmux actually accepts

From tmux 3.6 `input.c`:

- `input_state_dcs_handler_table`: `0x1b` → `input_state_dcs_escape`, with no `input_input`, so the ESC is
  consumed rather than stored.
- `input_state_dcs_escape_table`: `0x5c` → `input_dcs_dispatch`, back to `input_state_ground`; `0x00-0x5b` →
  `input_input` (store the byte), back to `input_state_dcs_handler`; `0x5d-0xff` likewise.

So `ESC ESC` inside a DCS stores one literal ESC, and the backslash that follows it is then handled in
`dcs_handler`, where `0x5c` falls in `0x40-0x7e` and is stored as ordinary data. Nothing dispatches. A single
ESC followed by backslash is what dispatches.

The consequence, in bytes: the wrapper's terminator is **single** `ESC \` (1b 5c), while every ESC *inside* the
payload - including the payload's own terminator - is doubled. Writing the documented doubled terminator leaves
the wrapper open.

## Measured

Each case: a tmux session, `pipe-pane` capturing the pane's output as tmux receives it, a client attached with
`script(1)` capturing everything that client is sent, then the pane printing `PLAINBEFORE`, one wrapped
`OSC 1337` image (`size=8;width=1;height=1`), and `PLAINAFTER`. `client_after` is the number that matters: it
is 2 when the client was sent the text printed after the image, and 0 when tmux was still inside the wrapper.

| terminator written | `allow-passthrough` | attached when printed | wrapper reached tmux | image reached client | `PLAINAFTER` at client |
|---|---|---|---|---|---|
| `ESC \` (single) | `on` | yes | 1 | **1** | **2** |
| `ESC \` (single) | `all` | yes | 1 | **1** | **2** |
| `ESC ESC \` (as documented) | `on` | yes | 1 | **0** | **0** |
| `ESC ESC \` (as documented) | `all` | yes | 1 | **0** | **0** |
| no wrapper at all | `on` | yes | 0 | **0** | 2 |
| `ESC \` (single) | `all` | **no**, client attaches after | 1 | **0** | 2 |

Read off that table:

1. The documented spelling does not merely lose the image. `PLAINAFTER` reaches the client in the healthy rows
   and never arrives in the documented rows, so a program that follows the page loses the image and everything
   it prints afterwards. That is the report: it is not a documentation cosmetic, it is a silent data-loss
   failure mode reachable by doing what the manual says.
2. `on` and `all` behave identically in every case measured here. `all` does not rescue an unwatched print (last
   row), and it changes nothing when a client is attached. If `all` has a distinct effect it is not visible in
   this experiment, which is worth a sentence in the page as well.
3. An unwrapped `OSC 1337` never reaches the client (`allow-passthrough` does not forward sequences tmux does
   not parse), which is why the wrapper is the only route for inline-image protocols through tmux.

## Suggested wording

State the payload rule and the terminator rule separately, in bytes, for example: the sequence is ESC `P`
`tmux` `;`, followed by the payload with **every ESC in it doubled**, followed by a single ESC backslash
(`1b 5c`). And give a worked example, because the failure mode is exactly the case the current text misleads.

## Reproducer

```sh
tmux -L w new-session -d -s w bash
tmux -L w set -g allow-passthrough all
tmux -L w pipe-pane -t w 'cat > /tmp/pane.bin'
TERM=xterm-256color script -q -a /tmp/client.log -c 'timeout -s TERM 8 tmux -L w attach -t w' </dev/null &
sleep 2
tmux -L w send-keys -t w "printf 'PLAINBEFORE\n'; printf '\033Ptmux;\033\033]1337;File=inline=1;size=8;width=1;height=1;preserveAspectRatio=0:AAAA\007\033\\'; printf '\nPLAINAFTER\n'" Enter
wait
python3 -c "
c=open('/tmp/client.log','rb').read()
print('image', c.count(b'\x1b]1337'), 'PLAINAFTER', c.count(b'PLAINAFTER'))"
```

Expected: `image 1  PLAINAFTER 2`. Change only the closing to `\033\033\\` - the spelling tmux(1) shows - and it
becomes `image 0  PLAINAFTER 0`.

Two traps in writing a reproducer for this, both of which cost a first attempt a table of zeros: `script(1)`
inherits the script's stdin and will consume the rest of the reproducer as terminal input unless stdin is
redirected, and killing the attach by pattern also kills `script` itself, because its own command line contains
the attach command, closing the capture before it holds anything.
