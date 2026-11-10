"""
Scroll queue bench: upstream tmux-smooth-scroll (one animation per wheel report) against this repo's queued
demand model, measured on a live tmux pane with a 6000-line scrollback.

Metrics that matter for a phone:
  first   ms from the first report until the pane actually moved  (responsiveness)
  settle  ms from the LAST report until the pane stopped moving   (the "still crawling after I stopped" fault)
  moved   lines the pane travelled
  anim    peak concurrent animator processes                       (thrash)
"""
import subprocess, time, shutil, os

SESS, TSS, OLD = "scrollbench", "/tmp/tss2", "/usr/local/share/tmux-smooth-scroll"
MAXPEND, STATE_DIR = 30, "/tmp/tmux-smooth-scroll"

def tm(*a):
    r = subprocess.run(["tmux"] + list(a), capture_output=True, text=True)
    if r.returncode:
        print("   tmux error:", r.stderr.strip())
    return r.stdout.strip()

def animators():
    """Animators actually alive, read from /proc: a `pgrep -f` also matches the shell that ran it."""
    n = 0
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as fh:
                argv = fh.read().split(b"\0")
        except OSError:
            continue
        if any(b"animator.pl" in a for a in argv[1:]) and not any(b"pgrep" in a for a in argv):
            n += 1
    return n

class Rig:
    def __init__(self):
        self.pane = tm("display", "-p", "-t", "%s:" % SESS, "#{pane_id}")

    def pos(self):
        v = tm("display", "-p", "-t", self.pane, "#{scroll_position}")
        return int(v) if v.lstrip("-").isdigit() else 0

    def prepare(self):
        tm("send-keys", "-t", self.pane, "-X", "cancel"); time.sleep(0.4)
        tm("copy-mode", "-t", self.pane); time.sleep(0.5)
        shutil.rmtree(STATE_DIR, ignore_errors=True)

    def fire(self, script, d="up"):
        tm("run-shell", "-b", "-t", self.pane, "TMUX_PANE=%s %s/src/scroll.sh %s normal" % (self.pane, script, d))

    def run(self, label, script, n=1, d="up", gap=0.0, reverse_at=None, window=15.0):
        """Fire n reports (optionally reversed partway) and sample the pane's position as it goes."""
        self.prepare()
        base, traj = self.pos(), []
        t_first = time.perf_counter()
        for i in range(n):
            if reverse_at is not None and i == reverse_at:
                d = "down"
            self.fire(script, d)
            if gap:
                time.sleep(gap)
        t_last = time.perf_counter()
        peak_procs = peak_anim = 0
        while time.perf_counter() - t_first < window:
            peak_procs = max(peak_procs, 0)
            peak_anim = max(peak_anim, animators())
            traj.append((time.perf_counter() - t_first, self.pos()))
            # settle = 500ms of no movement after the last report
            if len(traj) > 2 and traj[-1][1] == traj[-2][1] and traj[-1][0] > (t_last - t_first) + 0.5:
                break
            time.sleep(0.01)
        moved = traj[-1][1] - base
        first = next((t for t, p in traj if p != base), None)
        last_change = 0.0
        for i in range(len(traj) - 1, 0, -1):
            if traj[i][1] != traj[i - 1][1]:
                last_change = traj[i][0]
                break
        # The fault reported: the pane still crawling after the thumb stopped. Measured from the LAST report.
        crawl = max(0.0, last_change - (t_last - t_first))
        rev = None
        if reverse_at is not None:
            hi = max(traj, key=lambda x: x[1])
            later = [p for _, p in traj[traj.index(hi):]]
            drop = hi[1] - min(later)
            rev = "reversed %d lines" % drop if drop > 0 else "NO reversal"
        print("%-40s first %5s ms  moves %4s lines  crawls %5.0f ms after last report  total %5.0f ms  anim peak %d  %s"
              % (label, ("%.0f" % (first * 1000)) if first else "none", moved, crawl * 1000,
                 last_change * 1000, peak_anim, rev or ""))

def main():
    rig = Rig()
    tm("set", "-g", "@smooth-scroll-max-pending", str(MAXPEND))
    print("pane %s, cap %s, normal %s lines/report, speed %s"
          % (rig.pane, MAXPEND,
             tm("show-option", "-gqv", "@smooth-scroll-normal"),
             tm("show-option", "-gqv", "@smooth-scroll-speed")))
    print("=== upstream: one private animation per report ===")
    rig.run("old x1", OLD)
    rig.run("old x5  (one phone flick)", OLD, 5)
    rig.run("old x10 (two quick flicks)", OLD, 10)
    print("=== queued demand: merged, capped, single animator ===")
    rig.run("new x1", TSS)
    rig.run("new x5  (one phone flick)", TSS, 5)
    rig.run("new x10 (two quick flicks)", TSS, 10)
    rig.run("new x10 spaced 30ms", TSS, 10, gap=0.03)
    rig.run("new x20 spaced 20ms", TSS, 20, gap=0.02)
    print("=== steering: flick down while still crawling up ===")
    rig.run("old  6 up then 3 down", OLD, 9, reverse_at=6, gap=0.04)
    rig.run("new  6 up then 3 down", TSS, 9, reverse_at=6, gap=0.04)

main()
