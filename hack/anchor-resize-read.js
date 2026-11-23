// Read side of the anchor resize measurement, run after the resize sequence.
//
// The counts that matter, and what each one proves:
//   anchorsVisible  - anchor lines on screen now, i.e. how many pictures a single frame has to draw
//   imageFetches    - GETs of /images/<name> the page made since load. A drag that re-fetches every picture on
//                     every render is a different bug from a drag that only redraws from cache, and this is the
//                     only line that tells the two apart.
//   canvases        - the backing-store size of every canvas in the pane. A canvas whose width/height is set on
//                     each render is reallocated by the browser on each render, which clears it and costs memory
//                     copies proportional to the pane's pixel area.
(() => {
    const m = window.__anchorPerf || {};
    if (m.raf) cancelAnimationFrame(m.raf);
    const ANCHOR = /\[\[img:([0-9a-f]+)\.(\w+):(\d+)\]\]/g;
    let anchorsVisible = 0;
    const anchorRows = [];
    for (const div of document.querySelectorAll(".xterm-rows > div")) {
        const t = div.textContent || "";
        if (ANCHOR.test(t)) {
            anchorsVisible += 1;
            anchorRows.push(t.trim().slice(0, 60));
        }
    }
    const res = performance.getEntriesByType("resource").filter((e) => /\/images\//.test(e.name));
    const canvases = Array.from(document.querySelectorAll("canvas")).map((c) => ({
        w: c.width,
        h: c.height,
        css: c.style.width + "x" + c.style.height,
    }));
    return {
        windowMs: Math.round(performance.now() - (m.installedAt ?? 0)),
        longTasks: m.longTasks ?? 0,
        longMs: Math.round(m.longMs ?? 0),
        frames: m.frames ?? 0,
        maxFrameMs: Math.round(m.maxFrameMs ?? 0),
        anchorsVisible,
        anchorRows,
        imageFetches: res.length,
        uniqueImageFetches: new Set(res.map((r) => r.name.split("/").pop())).size,
        fetchBytes: Math.round(res.reduce((n, r) => n + (r.transferSize ?? 0), 0)),
        canvases,
        longtaskObserver: m.longtaskObserver,
    };
})()
