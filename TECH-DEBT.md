# Tech debt

Things this repo knowingly carries, with what they cost, where the evidence is, and what paying them off
looks like. Written so that the next session does not have to re-derive them from a transcript.

Nothing here is a bug. A bug is fixed; these are costs that were accepted because paying them now buys
something else. Where a claim is measured it says what was measured. Where it is argued from the code and
has no case covering it, it says that too, because an untested rule is a different kind of debt from a
known one.

Order is by what I would fix next, not by size.

## 1. An anchored picture is drawn at its reservation, and the reservation is a guess

`tools/tmux-osc-wrap.py` turns an image's pixels into reserved rows using `OSC_WRAP_CELL_HEIGHT_PX`
(default 15) and `OSC_WRAP_CELL_RATIO`. A pty reports cells, not pixels, so the relay cannot measure the
cell the browser will actually draw. The client never draws a picture larger than its reservation, because
larger would cover someone's text.

Measured on 07/11 in the live `slopyphus` pane: a 1088x356 dashboard produced
`[[img:54e2748171.png:10]]` with exactly ten blank rows under it. The pane's ttyd runs at `fontSize 12`,
which is a cell about 17px tall, so ten rows is about 170px and the picture draws near 520x170 - roughly
half the pixels that were pasted.

Paying it off: the client knows the real cell and the picture's natural pixels, so it could draw at
natural size whenever the rows under the anchor are blank, instead of the relay guessing a cell height it
cannot see. `image-anchor.ts` `paint()` is where this belongs, and the harness
(`hack/image-anchor-cases.sh`) already measures the gap it would close: it currently reports a picture
10.7 cells short of its reservation as a measurement rather than a failure.

Cost until then: screenshots are legible-ish, not sharp. Text-heavy dashboard shots are the worst case.

## 2. Files land in a pane's workdir and only one of them is bounded

Two directories accumulate under `.slopyphus/`, both gitignored (`.gitignore:9`), so neither is repo
pollution - both are disk in the pod holding whatever was pasted.

`images/` is bounded, and the bound is a count rather than an age: `tools/tmux-osc-wrap.py` keeps the
newest `OSC_WRAP_IMAGE_KEEP` files (default 200) and prunes oldest-first, only ever touching names the
relay wrote, with a refresh counting as use (`os.utime` on a re-saved picture). It is pruned from inside
the relay, which means a pane that only ever anchors three pictures never prunes at all - harmless, but it
means the bound is "per relay", not "per pod".

`uploads/` is not bounded at all. It is where a browser paste or drag-and-drop lands (this repo's ttyd
fork, `vendor/ttyd/src/protocol.c`), which limits the size of a single upload (`--upload-max-bytes`) and
says nothing about how many there are. Measured on 07/11 in the `slopyphus` pod: 2.3M of uploads against
448K of anchored pictures - the unbounded one is bigger. A private screenshot pasted once survives in that
pod until the pod is replaced, which for a long-lived agent pod means never.

Related shape that is not fixed by either bound: delete a picture file and its anchor stays, so the pane
shows a token that draws nothing and the browser logs a 404 fetch for it.

Paying it off: give `uploads/` the same shape of retention the relay already implements for `images/`, and
pick the number with whoever looks at the desktop rather than by default.

## 3. An anchor token alone on a row summons a picture

`image-anchor.ts` draws from a row whose only content is `[[img:<name>:<rows>]]`, and the picture comes
off disk by name. That is the feature. It is also a way to draw any file in `.slopyphus/images/` by
printing one line of text, and a way to draw a picture nobody intended: a shell `echo`, a log line, or a
transcript that quotes a bare token.

Mitigation that already exists and is doing the work: a token's row is refused if it carries any other
text. The `slopyphus` pane's own history at the time of writing holds about twenty anchor-shaped strings
from this session's messages and none of them draw, because each sits inside a sentence.

Not a security boundary. It is a same-origin GET of a file that is already in the pane's workdir, served
by `vendor/ttyd/src/http.c` (which rejects traversal - `GET /slopyphus/images/../../etc/passwd` answered
404 measured on 07/11, real names answered 200 with the right content type). If anchored pictures ever
become something to trust less, this is the entry point to reconsider.

## 4. Anchoring makes pictures invisible to terminals that cannot read a token

Default is now anchor-only (`tools/pi-images.sh` sets `OSC_WRAP_ANCHOR=1` and no inline bytes are sent).
`ssh` in and `tmux attach` in iTerm2 shows one dim line of text where a picture used to be.

Escape hatches, per pane: `OSC_WRAP_INLINE=on` sends the byte stream as well; `OSC_WRAP_ANCHOR=0` restores
the old behaviour entirely. Both are documented in `tools/pi-images.sh` and in `PLAN.md`. Neither appears
in `README.md`, which documents the front's variables and not a pane's - so the knobs exist for whoever
already knows they exist, and for nobody else.

Debt shape: two renderers exist in the code (`@xterm/addon-image` for the byte stream, `image-anchor` for
the token) and only one of them is exercised by default. `hack/image-cases.sh` tests the byte path, which
now reads like the main path when it is the fallback. Relabelling it as the fallback test is part of
paying this off.

## 5. The tmux padding rule is argued, not seen

`image-anchor.ts` `paddingColumn()` finds where tmux draws chrome (a `│` or `┃` followed only by padding
to the end of the line, on at least half the viewport's rows) and takes the smallest such column, then
judges emptiness and caps picture width before it. It fixed a measured failure - a 50-column client on a
40-column window put `│·········` on every row including a picture's reserved rows, and the honest guard
refused to draw the picture.

Unmeasured consequence: a Pi markdown table is a wall of `│` that most rows agree on, ending at the
table's right edge, which is exactly the column this rule picks. A picture above such a table would be
narrowed to it. The half-the-viewport threshold usually saves it, because a picture's own reserved rows are
blank and do not match. Argued from the code, with no case covering it.

Paying it off: an `anchor-table` case in `hack/image-anchor-cases.sh` that puts a markdown table above an
anchor and asserts the picture's width is the pane's, not the table's.

## 6. Reserved rows are visible emptiness in the pane

The mechanism, not an accident: to keep space for a picture, the relay prints blank rows and pushes
everything after them down. A 30-row picture in a 70-row pane is a third of the pane given to a picture
that has already been drawn once.

Consequence nobody has measured: how often the reservation is *larger* than the picture ends up being
(that is debt 1, seen from the other side - a wrong cell guess wastes rows rather than shrinking the
picture), and whether a human would rather have the space back. Both are judgement calls about a desktop,
not a technical question.

## 7. `hack/` is the test surface, and CI does not run most of it

CI (`.woodpecker/ci.yaml`) asserts the front's rendered config and page, the ttyd client bundle is not
stale, and the relay's own unit checks. The browser-behaviour harnesses - `hack/image-anchor-cases.sh`
(9 looks over 5 cases, run twice = 18 looks, 0 failures at the time of writing),
`hack/pane-persistence.sh`, `hack/tmux-passthrough-cases.sh`, `hack/upload-gate.sh`,
`hack/front-testbed.sh` - need a node, a browser, a private registry pull and a `DOCKER_HOST`, so they are
run by hand by whoever is in the repo.

Cost: those harnesses rot silently. Evidence of how that feels: `hack/image-cases.sh` asserted a client
marker that lived only in a local bundle and would have failed a run that was otherwise healthy.

Paying it off is not "put a browser in CI". It is picking the two or three harnesses whose failure a
push should not be allowed to survive, and saying which ones are hand-run on purpose.

## 8. `vendor/` is four forks with a re-pin ritual

`vendor/ttyd`, `vendor/xterm.js`, `vendor/tmux`, `vendor/trzsz`. A client change is: edit the fork, run
`hack/build-ttyd-client.sh`, commit the generated `src/html.h` in the fork, push the fork, bump the
submodule pin here. CI has a check specifically for the step people miss (a source marker present in the
TypeScript and absent from the shipped header).

Cost: two commits and a pin per client change, and a fork whose upstream drift is not tracked anywhere in
this repo. Nothing here says which upstream commit each fork is based on or how far behind it is.

## 9. PLAN.md is a log, not a spec

`PLAN.md` records this feature across five iterations, each superseding the last - inline byte streams,
row reservation, an anchor alongside the bytes, an anchor replacing them, top-left anchoring, tmux padding.
Several earlier claims are superseded rather than wrong, and a reader cannot tell which section describes
what the code does today without reading all of it.

Paying it off: mark superseded sections as superseded, or split "how it works now" from "how we got here".
Not urgent, and worth doing before the next big change to this feature rather than after.
