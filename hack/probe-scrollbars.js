// The measuring stick for the front's scrollbar question. Synchronous (chromium.dev's /eval does not
// await anything), and returns one JSON string:
//
//   engine    - what this Chrome does with a forced scrollbar, with each of the candidate CSS rules
//               applied to a 200x100 overflow:scroll box. cw/ch is the space the content actually gets.
//               cw < 200 means the scrollbar takes layout space; cw = 200 means it is an overlay.
//   page      - the front's own document: does it overflow, and by how much, and where from.
//   panes     - each iframe: the frame element's own box vs its content box (offsetWidth - clientWidth
//               - border = layout space a pane's scrollbars are eating right now), and whether the
//               document inside it overflows (which is what makes a scrollbar appear in that pane).
//
// Load it with: hack/front-testbed.sh probe hack/probe-scrollbars.js

(function () {
  var out = {};

  // Chrome/Edge/Safari vs Firefox spelling of the same rule, both applied by the current template.
  var variants = {
    none: "",
    "webkit-display-none": "::-webkit-scrollbar { display: none; }",
    "webkit-zero": "::-webkit-scrollbar { width: 0; height: 0; }",
    "standard-none": "* { scrollbar-width: none; }",
    "classic-forced": "::-webkit-scrollbar { width: 15px; height: 15px; background: #f00; }",
  };

  out.engine = {};
  Object.keys(variants).forEach(function (name) {
    var d = document;
    var style = d.createElement("style");
    style.textContent = variants[name];
    d.head.appendChild(style);

    var box = d.createElement("div");
    // overflow: scroll rather than auto: a bar that is certain to exist, so the measurement is about the
    // space it takes rather than about whether this particular page needs one.
    box.style.cssText = "position:fixed;top:0;left:0;width:200px;height:100px;overflow:scroll;visibility:hidden";
    box.innerHTML = '<div style="width:400px;height:400px"></div>';
    d.body.appendChild(box);

    // A forced classic bar is also the only way to see one in a headless Chrome, which otherwise uses
    // overlay bars that reserve nothing and do not appear in screenshots at all.
    var forced = name === "classic-forced";
    out.engine[name] = {
      ow: box.offsetWidth,
      cw: box.clientWidth,
      oh: box.offsetHeight,
      ch: box.clientHeight,
      takenW: box.offsetWidth - box.clientWidth,
      takenH: box.offsetHeight - box.clientHeight,
      rendered: forced ? "red 15px bar, visible in the screenshot" : "n/a",
    };

    box.remove();
    style.remove();
  });

  var de = document.documentElement;
  out.page = {
    viewport: innerWidth + "x" + innerHeight,
    html: { sw: de.scrollWidth, cw: de.clientWidth, sh: de.scrollHeight, ch: de.clientHeight },
    body: { sw: document.body.scrollWidth, cw: document.body.clientWidth, sh: document.body.scrollHeight, ch: document.body.clientHeight },
    overflowX: de.scrollWidth - de.clientWidth,
    overflowY: de.scrollHeight - de.clientHeight,
    htmlOverflow: getComputedStyle(de).overflow,
    bodyOverflow: getComputedStyle(document.body).overflow,
    // The two rules the template relies on today, as the browser actually resolved them for this document.
    scrollbarWidth: getComputedStyle(de).scrollbarWidth,
    bodyScrollbarWidth: getComputedStyle(document.body).scrollbarWidth,
  };

  var wrap = document.getElementById("wrap");
  out.page.wrap = wrap ? {
    display: getComputedStyle(wrap).display,
    height: getComputedStyle(wrap).height,
    rect: wrap.getBoundingClientRect().height,
  } : "no #wrap (this is a scratch page)";

  // The labels are absolutely positioned inside their cell, and an absolutely positioned descendant
  // contributes its own overflow to the nearest scroll container above it. With narrow panes, the label
  // is wider than the pane: that is where the desktop's horizontal overflow comes from.
  out.tags = Array.prototype.map.call(document.querySelectorAll("#wrap .tag"), function (t) {
    var cell = t.parentElement;
    return {
      text: t.textContent,
      tagW: t.offsetWidth,
      cellW: cell.getBoundingClientRect().width,
      right: Math.round(t.getBoundingClientRect().right),
      font: getComputedStyle(t).font,
    };
  }).sort(function (a, b) {
    return b.right - a.right;
  });

  out.panes = Array.prototype.map.call(document.querySelectorAll("#wrap iframe"), function (f) {
    var pane = {
      id: f.id,
      display: getComputedStyle(f).display,
      border: getComputedStyle(f).borderTopWidth,
      ow: f.offsetWidth,
      cw: f.clientWidth,
      oh: f.offsetHeight,
      ch: f.clientHeight,
      // 2 = the 1px border on each side. Anything above 2 is a scrollbar taking layout space in the pane.
      takenW: f.offsetWidth - f.clientWidth - 2,
      takenH: f.offsetHeight - f.clientHeight - 2,
      scrolling: f.getAttribute("scrolling"),
    };
    try {
      var d = f.contentDocument;
      pane.inner = {
        uri: d.documentURI,
        overflowX: d.documentElement.scrollWidth - d.documentElement.clientWidth,
        overflowY: d.documentElement.scrollHeight - d.documentElement.clientHeight,
        overflow: getComputedStyle(d.documentElement).overflow,
        // Chrome maps the deprecated scrolling="no" attribute here; if it is not hidden, the pane is a
        // scroll container that can produce bars regardless of what the attribute says.
        iframeOverflowOfFrame: getComputedStyle(f).overflow,
        // Did the front's injected style land in this pane, and did the browser accept it?
        injected: (function () {
          var el = d.getElementById("slopyphus-pane-scrollbars");
          return {
            present: !!el,
            css: el ? el.textContent : null,
            htmlScrollbarWidth: getComputedStyle(d.documentElement).scrollbarWidth,
          };
        })(),
      };
    } catch (e) {
      pane.inner = { crossOrigin: String(e) };
    }
    return pane;
  });

  return JSON.stringify(out, null, 1);
})();
