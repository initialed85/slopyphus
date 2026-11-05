// Does the "expand one pane to the whole viewport" mechanism (Alt+Shift+Enter) still work once the page
// itself is overflow:hidden? It pulls the pane out with position:fixed, whose containing block is the
// viewport rather than the grid, so an ancestor clipping its overflow must not clip it. Measured, not
// assumed: the rect below is the proof, and the screenshot taken after this expression is the visual one.
(function () {
  var frame = document.querySelector("#wrap iframe");
  var before = frame.getBoundingClientRect();
  frame.classList.add("expanded");
  document.body.classList.add("iframe-expanded");
  var after = frame.getBoundingClientRect();
  var siblings = Array.prototype.map.call(document.querySelectorAll("#wrap > *"), function (g) {
    return getComputedStyle(g).visibility;
  });
  return JSON.stringify(
    {
      viewport: innerWidth + "x" + innerHeight,
      bodyOverflow: getComputedStyle(document.body).overflow,
      before: { x: before.x, y: before.y, w: before.width, h: before.height },
      after: { x: after.x, y: after.y, w: after.width, h: after.height },
      groupVisibility: siblings,
      pageOverflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      pageOverflowY: document.documentElement.scrollHeight - document.documentElement.clientHeight,
    },
    null,
    1,
  );
})();
