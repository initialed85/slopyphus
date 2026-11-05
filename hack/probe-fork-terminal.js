// Measures whether a ttyd built from the vendored forks actually runs a terminal in a browser.
//
// The gate in .woodpecker/ci.yaml can say the image builds, that `ttyd --version` names the fork, that
// `ldd` resolves and that the libuv event loop plugin loads. It cannot say anything about the client,
// because there is no browser in a CI step. This is the expression that closes that gap, run through
// hack/front-cdp.mjs against a ttyd started from the image under test:
//
//   node hack/front-cdp.mjs --url http://<node>:<port>/test/ \
//     --expression-file hack/probe-fork-terminal.js --wait-ms 4000 --shot /tmp/terminal.png
//
// What each field is evidence for:
//
//   title          ttyd's client sets document.title from the shell's OSC sequence, which arrives over
//                  the websocket - so a real title means the socket carried bytes and xterm parsed them.
//                  This is the single strongest field in the result.
//   hasXterm       the terminal mounted at all (xterm only exists after the client's own script runs).
//   viewport       .xterm-viewport is there, which is the element carrying `overflow-y: scroll` in
//                  xterm's own CSS - the bar the front currently has to inject a style over.
//   canvas         the renderer that actually drew. ttyd loads the canvas and webgl addons, so rows are
//                  drawn to a canvas and `.xterm-rows` is empty (rows: 0 is expected, not a failure);
//                  a non-null canvas size means the renderer attached to a real grid.
//   scripts        the client is inlined into the served document, so this is ["inline"] - the generated
//                  header, not a CDN, which is what makes the fork's build the thing under test.
//
// Point it at a ttyd you own (a container from the image you are checking), never at a live agent: a
// headless browser attaching a ttyd client resizes that agent's tmux window, which is sized to its
// smallest client.

(() => {
  const q = (s) => document.querySelector(s);
  const rows = q('.xterm-rows');
  const canvas = q('.xterm-screen canvas');
  return {
    url: location.href,
    title: document.title,
    hasXterm: !!q('.xterm'),
    viewport: !!q('.xterm-viewport'),
    rows: rows ? rows.children.length : 0,
    canvas: canvas ? `${canvas.width}x${canvas.height}` : null,
    helperTextarea: !!q('.xterm-helper-textarea'),
    scripts: [...document.querySelectorAll('script')].map((s) => s.src || 'inline'),
    sheets: [...document.querySelectorAll('link[rel=stylesheet]')].map((l) => l.href),
    bodyLen: document.body.innerHTML.length,
  };
})();
