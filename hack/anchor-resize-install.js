// Installed with front-cdp.mjs --measure-file, before any resize happens.
//
// Two measurements, deliberately independent of each other:
//   - Chrome's own long tasks (>= 50 ms of main thread in one task) via PerformanceObserver
//   - requestAnimationFrame gaps, which is how a pane user feels it: a frame that takes 400 ms is a pane that
//     freezes for 400 ms, whether the browser logged it as a long task or not.
// Both accumulate from install time, so the run reads a delta across the resize sequence.
(() => {
    const m = (window.__anchorPerf = { longTasks: 0, longMs: 0, frames: 0, maxFrameMs: 0, installedAt: performance.now() });
    try {
        const po = new PerformanceObserver((list) => {
            for (const e of list.getEntries()) {
                m.longTasks += 1;
                m.longMs += e.duration;
            }
        });
        po.observe({ entryTypes: ["longtask"] });
        m.longtaskObserver = "yes";
    } catch (err) {
        m.longtaskObserver = String(err);
    }
    let last = performance.now();
    const tick = (t) => {
        const gap = t - last;
        last = t;
        m.frames += 1;
        if (gap > m.maxFrameMs) m.maxFrameMs = gap;
        window.__anchorPerf.raf = requestAnimationFrame(tick);
    };
    m.raf = requestAnimationFrame(tick);
    const term = document.querySelector(".xterm");
    return { installed: true, xtermPresent: !!term, rowsRendered: document.querySelectorAll(".xterm-rows > div").length };
})()
