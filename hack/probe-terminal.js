// A real terminal pane (this pod's own ttyd, proxied through the testbed's nginx so the pane is
// same-origin) rather than a stand-in, because the claim to check is about xterm's own markup.
//
// ttyd's CSS is `.xterm .xterm-viewport{position:absolute;inset:0;overflow-y:scroll...}` with no
// scrollbar styling of its own, i.e. a scroll container that asks for a bar whether or not there is any
// scrollback. `scrollbarWidth` is the computed value the front's injected style produces there, and the
// gutter pair is the control experiment: scrollbar-gutter: stable is defined to reserve the space a bar
// would need, so if stable reserves and none reclaims, this browser can and does take the space and the
// numbers are the size of the strip the fix gives back. If both are zero, this browser is in overlay mode
// and its measurements say nothing about a desktop browser's strip.
(function () {
  var frame = document.querySelector("#wrap iframe");
  var d = frame.contentDocument;
  var viewport = d.querySelector(".xterm-viewport");
  var term = d.querySelector(".xterm");
  if (!viewport) return JSON.stringify({ error: "no .xterm-viewport: the pane is not a live terminal", paneUri: frame.contentWindow.location.href, paneHtml: d.body.innerHTML.slice(0, 200) });

  function read(label, css) {
    var before = { cw: viewport.clientWidth, ch: viewport.clientHeight, ow: viewport.offsetWidth, oh: viewport.offsetHeight };
    viewport.setAttribute("style", css);
    var after = { cw: viewport.clientWidth, ch: viewport.clientHeight, ow: viewport.offsetWidth, oh: viewport.offsetHeight };
    viewport.removeAttribute("style");
    return { label: label, css: css, before: before, after: after, takenW: after.ow - after.cw, takenH: after.oh - after.ch };
  }

  return JSON.stringify(
    {
      paneUri: frame.contentWindow.location.href,
      sameOrigin: true,
      injected: (d.getElementById("slopyphus-pane-scrollbars") || {}).textContent || null,
      viewportComputedScrollbarWidth: getComputedStyle(viewport).scrollbarWidth,
      overflowYOfViewport: getComputedStyle(viewport).overflowY,
      viewportClasses: viewport.className,
      scrollArea: (function () {
        var area = d.querySelector(".xterm-scroll-area");
        return area ? { ow: area.offsetWidth, oh: area.offsetHeight } : null;
      })(),
      termSize: { ow: term.offsetWidth, oh: term.offsetHeight },
      paneBodyOverflow: getComputedStyle(d.body).overflow,
      experiments: [
        read("control: nothing added", ""),
        read("gutter stable", "scrollbar-gutter: stable"),
        read("gutter stable + scrollbar-width none", "scrollbar-gutter: stable; scrollbar-width: none"),
        read("forced 15px classic bar", "scrollbar-width: thin"),
      ],
    },
    null,
    1,
  );
})();
