/*
 * Press keys in a ttyd pane from the browser, and prove what the application behind the pane received.
 *
 * The evidence is not in this page: it is the file the pane's command writes (see the containers this is
 * pointed at, which run `cat > /tmp/k.bin`). This script only types, and reports what the browser could
 * see while doing it. The comparison is then `od -An -c /tmp/k.bin` inside the container.
 *
 * Two things here are load bearing:
 *
 *  - keyCode has to be forced onto the event. xterm.js 5.4 evaluates keys with a switch on
 *    `ev.keyCode` (src/common/input/Keyboard.ts), and the DOM constructor ignores a `keyCode` member of
 *    KeyboardEventInit because the property is deprecated. Without defineProperty, Enter is not Enter.
 *  - text goes in as an `insertText` input event rather than as letter keydowns, because the point of the
 *    measurement is which *control* byte a key produces; markers just label which case a byte belongs to.
 *    xterm passes an insertText event straight through to the pty (browser/Terminal.ts, the
 *    `inputType === 'insertText'` branch).
 *
 * The cases are chosen to tell the forked client's Shift+Enter mapping apart from xterm's own behaviour,
 * which is documented in Keyboard.ts as `ev.altKey ? ESC+CR : CR` for keyCode 13 - Shift is not consulted
 * there at all, so an unmapped Shift+Enter is indistinguishable from pressing Enter.
 */
(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const warns = [];
  const origWarn = console.warn;
  console.warn = (...a) => {
    warns.push(a.map((x) => (typeof x === 'string' ? x : String(x))).join(' '));
    origWarn(...a);
  };
  const logs = [];
  const origLog = console.log;
  console.log = (...a) => {
    const s = a.map((x) => (typeof x === 'string' ? x : String(x))).join(' ');
    if (s.includes('[ttyd]')) logs.push(s);
    origLog(...a);
  };

  const textarea = document.querySelector('.xterm-helper-textarea');
  if (!textarea) return { error: 'no .xterm-helper-textarea: the pane never finished opening' };
  textarea.focus();

  async function marker(text) {
    textarea.dispatchEvent(new InputEvent('input', { inputType: 'insertText', data: text, bubbles: true, composed: true }));
    await sleep(250);
  }

  function press(init) {
    const down = new KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init });
    const up = new KeyboardEvent('keyup', { bubbles: true, cancelable: true, ...init });
    // Deprecated fields the constructor will not accept, and xterm.js 5.4 reads anyway.
    for (const ev of [down, up]) {
      Object.defineProperty(ev, 'keyCode', { value: init.keyCode });
      Object.defineProperty(ev, 'which', { value: init.keyCode });
    }
    textarea.dispatchEvent(down);
    textarea.dispatchEvent(up);
  }

  const ENTER = { key: 'Enter', code: 'Enter', keyCode: 13 };
  const cases = [
    ['plain Enter (the reference an unmapped Shift+Enter behaves like)', () => press({ ...ENTER })],
    ['Shift+Enter (the forked client should send LF here, xterm sends CR)', () => press({ ...ENTER, shiftKey: true })],
    ['Ctrl+J (what the front page used to fake Shift+Enter as)', () => press({ key: 'j', code: 'KeyJ', keyCode: 74, ctrlKey: true })],
    ['Alt+Enter (xterm sends ESC+CR; the mapping must not swallow it)', () => press({ ...ENTER, altKey: true })],
    ['Shift+Enter while typing on the same line', async () => {
      await marker('mid');
      press({ ...ENTER, shiftKey: true });
    }],
  ];

  const ran = [];
  for (const [label, run] of cases) {
    await marker(`[${label.slice(0, 4)}]`);
    await run();
    await sleep(350);
    ran.push(label);
  }

  await sleep(800);
  // Ctrl+D closes the pane's command, which is what ends the capture file cleanly.
  press({ key: 'd', code: 'KeyD', keyCode: 68, ctrlKey: true });
  await sleep(400);

  return {
    url: location.href,
    title: document.title,
    secureContext: window.isSecureContext,
    ran,
    ttydLogs: logs,
    warns,
    screen: (document.querySelector('.xterm-rows')?.textContent ?? '').replace(/\s+/g, ' ').slice(0, 400),
  };
})()
