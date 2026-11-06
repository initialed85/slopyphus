(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const copyLog = [];
  const warns = [];
  const scratchTextareas = [];

  // Evidence collectors.
  const origWarn = console.warn;
  console.warn = (...args) => {
    warns.push(args.map((a) => (typeof a === 'string' ? a : String(a))).join(' '));
    origWarn(...args);
  };
  // The client's non-secure-context fallback builds a scratch textarea to copy through. Watching the
  // DOM proves that path ran even when headless Chromium refuses execCommand('copy').
  new MutationObserver((records) => {
    for (const r of records) {
      for (const node of r.addedNodes) {
        if (node.tagName === 'TEXTAREA') {
          scratchTextareas.push({
            ariaHidden: node.getAttribute('aria-hidden'),
            value: node.value,
            opacity: node.style.opacity,
          });
        }
      }
    }
  }).observe(document.body, { childList: true });

  if (navigator.clipboard && navigator.clipboard.writeText) {
    const orig = navigator.clipboard.writeText.bind(navigator.clipboard);
    navigator.clipboard.writeText = (text) => {
      copyLog.push({ via: 'navigator.clipboard', text });
      return orig(text);
    };
  }
  const origExec = document.execCommand.bind(document);
  document.execCommand = (cmd, showDefault, promptText) => {
    const last = scratchTextareas[scratchTextareas.length - 1];
    const ok = origExec(cmd, showDefault, promptText);
    copyLog.push({ via: 'execCommand', cmd, ok, scratchValue: last ? last.value : null });
    return ok;
  };

  const term = window.term;
  const b64 = (s) => btoa(unescape(encodeURIComponent(s)));

  // 1. Pi's path (PI_CLIPBOARD_OSC52=1): the app inside the pane writes OSC 52 to its own tty, tmux
  //    passes it through (allow-passthrough on) and xterm parses it. BEL stays inside the quotes.
  term.input(`printf '\\033]52;c;${b64('pi copy me to the browser\\n')}\\007'\n`);
  await sleep(700);

  // 2. tmux's own path: the commands a released mouse selection triggers through MouseDragEnd1Pane.
  term.input("printf 'line tmux selected\\n'\n");
  await sleep(500);
  term.input(
    "tmux copy-mode -t test:0 && tmux send-keys -t test: -X cursor-up &&" +
      " tmux send-keys -t test: -X select-line && tmux send-keys -t test: -X copy-pipe-and-cancel\n"
  );
  await sleep(1500);

  const scissors = [...document.querySelectorAll('div')]
    .map((d) => d.textContent)
    .filter((t) => t && t.includes('\u2702'));

  return {
    url: location.href,
    title: document.title,
    secureContext: window.isSecureContext,
    hasClipboardApi: !!(navigator.clipboard && navigator.clipboard.writeText),
    termHasInput: !!(term && typeof term.input === 'function'),
    termHasParser: !!(term && term.parser),
    scratchTextareas,
    copyLog,
    warns,
    scissorsOverlay: scissors,
  };
})()
