/*
 * The desktop's own script: served as /slopyphus-desktop.js by the front container and loaded by every
 * page the entrypoint renders (index.html and the tab pages).
 *
 * It lives in a file rather than inline in a page because the front now renders more than one page - a
 * tab per group of panes - and everything this script does is identical for all of them. Two pages built
 * from one template with an inline script would be free to drift in the one place the desktop is judged
 * on: whether a pane's scrollbars, focus ring and keystrokes behave.
 *
 * What it does, in short:
 *   - tracks which pane the pointer is over, so the focus ring and the shortcuts know what is being
 *     looked at;
 *   - the Alt+Shift+Enter (expand one pane to the viewport) and Alt+Shift+G (broadcast keys to every
 *     pane on this page) chords, and the keystroke relay itself (keydown, keypress, keyup);
 *   - injects the scrollbar rule into each pane's own document, which is only possible because every
 *     upstream is proxied through this front and is therefore same-origin.
 *
 * What it does NOT do, and that is deliberate: it holds no state and knows nothing about tabs. Switching
 * a tab is a link to a static page. So the panes on the tab you left disconnect from their terminals
 * (tmux keeps the session; a new page attaches a new client), and broadcast and expand only ever see the
 * panes on the page you are on.
 *
 * Written for the browser only, with no build step, and served verbatim.
 */

const frames = Array.from(document.querySelectorAll("#wrap iframe"));
const boundDocuments = new WeakSet();
const styledDocuments = new WeakSet();
const relayedKeyEvents = new WeakSet();
let activeFrame = null;
let expandedFrame = null;
let broadcasting = false;

function focusFrame(frame) {
  try {
    frame.focus();
    frame.contentWindow.focus();
    const terminalInput = frame.contentDocument.querySelector(".xterm-helper-textarea");
    if (terminalInput) terminalInput.focus({ preventScroll: true });
  } catch (_) {
    // The frame may not have finished loading yet.
  }
}

function setActiveFrame(frame) {
  if (!frame || activeFrame === frame) return;
  if (activeFrame) activeFrame.classList.remove("focused");
  activeFrame = frame;
  activeFrame.classList.add("focused");
  focusFrame(frame);
}

function clearActiveFrame() {
  if (!activeFrame) return;
  if (activeFrame) activeFrame.classList.remove("focused");
  try {
    activeFrame.contentDocument.activeElement.blur();
  } catch (_) {
    // The frame may have navigated while losing focus.
  }
  activeFrame = null;
}

function isChord(event, key) {
  return event.altKey && event.shiftKey && !event.ctrlKey && !event.metaKey && event.key.toLowerCase() === key;
}

function handleBroadcastShortcut(event) {
  if (!isChord(event, "g")) return false;
  event.preventDefault();
  event.stopImmediatePropagation();
  if (event.type === "keydown" && !event.repeat) {
    broadcasting = !broadcasting;
    document.body.classList.toggle("broadcasting", broadcasting);
  }
  return true;
}

function handleShortcut(event, sourceFrame) {
  if (!isChord(event, "enter")) return false;
  event.preventDefault();
  event.stopImmediatePropagation();
  if (event.type !== "keydown" || event.repeat) return true;

  const targetFrame = activeFrame ?? sourceFrame;
  if (!targetFrame) return true;
  if (expandedFrame) {
    expandedFrame.classList.remove("expanded");
    document.body.classList.remove("iframe-expanded");
    expandedFrame = null;
  } else {
    expandedFrame = targetFrame;
    expandedFrame.classList.add("expanded");
    document.body.classList.add("iframe-expanded");
  }
  focusFrame(targetFrame);
  return true;
}

function dispatchKeyboard(frame, type, init, relayed = false) {
  try {
    const target = frame.contentDocument.querySelector(".xterm-helper-textarea");
    if (!target) return;
    const event = new KeyboardEvent(type, init);
    // charCode is the one field a keypress is read out of and the constructor cannot carry it: it is a
    // deprecated read-only attribute, not a member of KeyboardEventInit, so a plain init is silently
    // ignored. xterm's _keyPress then falls through every branch (charCode 0, which set but charCode 0)
    // and returns false, and the character is lost. keyCode and which do not need this because the
    // browser derives them from key+code.
    if (type === "keypress" && typeof init.charCode === "number" && init.charCode > 0) {
      Object.defineProperty(event, "charCode", { value: init.charCode });
    }
    if (relayed) relayedKeyEvents.add(event);
    target.dispatchEvent(event);
  } catch (_) {
    // The target frame may not have finished loading or may have navigated.
  }
}

/*
 * Shift+Enter is not handled here any more, and the reason is worth keeping.
 *
 * xterm.js evaluates Enter without consulting Shift (src/common/input/Keyboard.ts, case 13:
 * `ev.altKey ? ESC+CR : CR`), so a pane cannot tell Shift+Enter from Enter, and this page used to
 * intercept the keystroke and inject a synthesised Ctrl+J into the focused pane's textarea instead. That
 * fixed the panes this page framed and left every pane reached directly - a node port, an agent's own
 * URL - broken, which is the complaint the fix is measured against.
 *
 * The translation now happens inside ttyd's client (vendor/ttyd/html/src/components/terminal/xterm, the
 * onKey handler), so it applies to a pane however the pane was opened, and this page is not in the
 * business of rewriting keys it is only relaying.
 */

function relayKeyboard(event, sourceFrame) {
  if (!broadcasting) return;
  if (!sourceFrame) event.preventDefault();
  const init = {
    key: event.key,
    code: event.code,
    location: event.location,
    ctrlKey: event.ctrlKey,
    shiftKey: event.shiftKey,
    altKey: event.altKey,
    metaKey: event.metaKey,
    repeat: event.repeat,
    isComposing: event.isComposing,
    keyCode: event.keyCode,
    which: event.which,
    // Read from the source event and set by hand on the way out (see dispatchKeyboard). Without it the
    // broadcast delivers every key but the ones xterm only resolves from a keypress: a plain space
    // (keyCode 32, below the >= 48 gate in Keyboard.ts's printable fallback) and uppercase A-Z (which
    // Terminal.ts deliberately defers to keypress for a macOS IME bug). That is the whole of the
    // "broadcast loses the space bar" report.
    charCode: event.charCode,
    bubbles: true,
    cancelable: true,
    composed: true,
  };
  for (const frame of frames) {
    if (frame !== sourceFrame) dispatchKeyboard(frame, event.type, init, true);
  }
}

function handleFrameKeyboard(event, sourceFrame) {
  if (relayedKeyEvents.has(event)) return;
  if (handleBroadcastShortcut(event)) return;
  if (handleShortcut(event, sourceFrame)) return;
  relayKeyboard(event, sourceFrame);
}

/*
 * The pane half of the scrollbar problem.
 *
 * A pane's scrollbars belong to the document inside the iframe, which the page above cannot style, so
 * they have to be hidden from inside. That is possible because every upstream is framed through nginx
 * under this page's own origin (/name/), which makes the pane same-origin (except a site that answers
 * with a redirect: the browser then leaves the front and the pane really is cross-origin).
 *
 * The case that matters is ttyd, which is what a pane usually shows here. xterm's own CSS is
 * `.xterm .xterm-viewport{...overflow-y:scroll...}`: a scroll container that always asks for a bar, and
 * in a browser where a scrollbar takes layout space that is a strip down the right of every terminal on
 * the desktop, whether or not the terminal has any scrollback to show.
 *
 * Both spellings are emitted because they are not interchangeable. `scrollbar-width` is the standard
 * property (Firefox, Chrome 121+); `::-webkit-scrollbar` is what older Blink and WebKit have, and in that
 * mode `display: none` hides the bar but leaves the gutter reserved while `width: 0` collapses it. Hiding
 * a bar without giving its area back is the whole complaint, so the webkit half uses 0.
 *
 * Nothing here sets overflow: hidden on a pane. A pane whose content is taller than the pane is still
 * scrollable by wheel or keyboard; it just no longer pays for the privilege in layout.
 */
const PANE_SCROLLBAR_CSS = "::-webkit-scrollbar{width:0!important;height:0!important}*{scrollbar-width:none!important}";

function styleFrameDocument(frame) {
  try {
    const frameDocument = frame.contentDocument;
    if (!frameDocument || !frameDocument.head || styledDocuments.has(frameDocument)) return;
    styledDocuments.add(frameDocument);
    const style = frameDocument.createElement("style");
    // Appended last, so this wins a tie against whatever the upstream ships; !important covers the rest,
    // because an upstream is entitled to style its own scrollbars and the desktop disagrees.
    style.id = "slopyphus-pane-scrollbars";
    style.textContent = PANE_SCROLLBAR_CSS;
    frameDocument.head.appendChild(style);
  } catch (_) {
    // A cross-origin frame cannot be styled from here either.
  }
}

function bindFrameDocument(frame) {
  try {
    const frameDocument = frame.contentDocument;
    if (!frameDocument || boundDocuments.has(frameDocument)) return;
    boundDocuments.add(frameDocument);
    ["pointerover", "pointermove", "pointerdown"].forEach((type) => {
      frameDocument.addEventListener(type, () => setActiveFrame(frame), true);
    });
    // keypress is relayed rather than synthesised because the browser itself decides which keys get
    // one: xterm preventDefaults the keydown of anything it can translate there (lowercase letters,
    // digits, punctuation), and no keypress fires for those. Relaying only the keypresses that really
    // happen is what keeps the space and uppercase fixes from double-sending the rest of the alphabet.
    ["keydown", "keypress", "keyup"].forEach((type) => {
      frameDocument.addEventListener(type, (event) => handleFrameKeyboard(event, frame), true);
    });
    styleFrameDocument(frame);
  } catch (_) {
    // A cross-origin frame cannot be inspected for its pointer or keyboard events.
  }
}

frames.forEach((frame) => {
  frame.addEventListener("pointerenter", () => setActiveFrame(frame));
  frame.addEventListener("pointerdown", () => setActiveFrame(frame));
  frame.addEventListener("focus", () => setActiveFrame(frame));
  frame.addEventListener("load", () => {
    bindFrameDocument(frame);
    // Not every pane fires load the way the front expects (a proxied page that navigates itself, or one
    // that was already bound by a pointer event before load), so the style is asked for again here.
    // styleFrameDocument is idempotent per document.
    styleFrameDocument(frame);
    if (activeFrame === frame) focusFrame(frame);
  });
  bindFrameDocument(frame);
});

document.addEventListener(
  "pointermove",
  (event) => {
    if (frames.includes(event.target)) setActiveFrame(event.target);
    else clearActiveFrame();
  },
  true
);
["keydown", "keypress", "keyup"].forEach((type) => {
  document.addEventListener(type, (event) => handleFrameKeyboard(event, null), true);
});
