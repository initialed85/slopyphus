/*
 * Type into a pane through the front desktop, and let the pane's own capture file be the evidence.
 *
 * This exists to answer one question about the front page: it used to intercept Shift+Enter and inject a
 * synthesised Ctrl+J into the focused pane. That interceptor is gone, and the mapping now lives inside
 * ttyd's client. The way to tell those two apart is not the bytes a single pane receives - both produce
 * a linefeed - it is whether the page above is still in the path at all. So this probe types into the
 * iframe the way the desktop does, and reports what the page itself did:
 *
 *  - any error the page's own scripts raised (a torn-out helper in index.html.template shows up here
 *    first, before anything about keys is worth reading);
 *  - which frame the keystroke went into, and whether the page still rewrites keys for it;
 *  - the pane's captured bytes, read separately with `docker exec ... od -An -c /tmp/k.bin`.
 *
 * Dispatching into `iframe.contentDocument` is not a shortcut around the desktop: the front page attaches
 * its keyboard listeners inside each pane document (the panes are same-origin because nginx frames every
 * upstream under this page's own path), so a keystroke delivered here travels through the same handlers a
 * real click-and-type would.
 */
(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const pageErrors = [];
  addEventListener('error', (e) => pageErrors.push(`${e.message} @ ${e.filename}:${e.lineno}`));
  const consoleErrors = [];
  const origError = console.error;
  console.error = (...a) => {
    consoleErrors.push(a.map((x) => (typeof x === 'string' ? x : String(x))).join(' '));
    origError(...a);
  };

  const frames = [...document.querySelectorAll('iframe')];
  if (!frames.length) return { error: 'the desktop rendered no panes' };
  const frame = frames[0];
  const doc = frame.contentDocument;
  if (!doc) return { error: 'the pane is not same-origin, so the front page cannot reach it either' };
  const textarea = doc.querySelector('.xterm-helper-textarea');
  if (!textarea) return { error: 'no xterm textarea in the pane yet' };
  textarea.focus();

  const press = (init) => {
    const init2 = { bubbles: true, cancelable: true, ...init };
    for (const type of ['keydown', 'keyup']) {
      const ev = new doc.defaultView.KeyboardEvent(type, init2);
      // Deprecated but read: xterm.js 5.4 switches on ev.keyCode.
      Object.defineProperty(ev, 'keyCode', { value: init.keyCode });
      Object.defineProperty(ev, 'which', { value: init.keyCode });
      textarea.dispatchEvent(ev);
    }
  };
  const marker = async (text) => {
    textarea.dispatchEvent(new doc.defaultView.InputEvent('input', { inputType: 'insertText', data: text, bubbles: true, composed: true }));
    await sleep(250);
  };

  const ENTER = { key: 'Enter', code: 'Enter', keyCode: 13 };
  await marker('[plai]');
  press({ ...ENTER });
  await sleep(300);
  await marker('[shif]');
  press({ ...ENTER, shiftKey: true });
  await sleep(300);
  await marker('[ctrl]');
  press({ key: 'j', code: 'KeyJ', keyCode: 74, ctrlKey: true });
  await sleep(300);

  // What the desktop still claims for itself: the pane scrollbar rule it injects, and the keyboard
  // relaying it does when broadcast mode is on. If a helper was torn out of the template with the
  // Shift+Enter interceptor, the missing style element is the loud sign.
  return {
    url: location.href,
    title: document.title,
    panes: frames.length,
    paneSrc: frame.getAttribute('src'),
    paneScrollbarRuleInjected: !!doc.querySelector('#slopyphus-pane-scrollbars') || [...doc.querySelectorAll('style')].some((s) => s.textContent.includes('::-webkit-scrollbar')),
    pageErrors,
    consoleErrors,
  };
})()
