// Reads the boxes in hack/scratch-scrollbox.html: what each scrollbar rule leaves the content in this
// browser. Synchronous, no Promises (chromium.dev's /eval does not await).
//
//   hack/front-testbed.sh probe hack/probe-scrollbox.js /scrollbox.html
JSON.stringify(
  Array.prototype.map.call(document.querySelectorAll(".box"), function (box) {
    return {
      cls: box.className.replace("box", "").trim() || "baseline",
      ow: box.offsetWidth,
      oh: box.offsetHeight,
      cw: box.clientWidth,
      ch: box.clientHeight,
      takenW: box.offsetWidth - box.clientWidth,
      takenH: box.offsetHeight - box.clientHeight,
    };
  }),
  null,
  1,
);
