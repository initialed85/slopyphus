"""
Scroll queue audit: does the queued scroll model move the pane exactly as far as it was asked to?

Upstream can afford sloppiness here - each report owns its own animation, so over-travel is invisible. A shared
queue cannot: a balance restored from a stale ledger, or a report swallowed by a retiring animator, shows up as
the pane travelling further than the finger asked (measured once: 80 lines demanded, 132 moved) or less than it
asked. So the arithmetic is asserted, not eyeballed.

Regimes are chosen so the expected number is exact:
  spaced reports  - each demand drains before the next lands, so nothing is capped and moved == demanded
  burst reports   - all land at once, so outstanding demand hits @smooth-scroll-max-pending and moved == the cap
Run against a scratch pane with a 6000-line scrollback, in copy-mode, with no clients attached.
"""
import subprocess, time, shutil, sys, os

SESS, TSS, STATE_DIR = "scrollbench", "/tmp/tss2", "/tmp/tmux-smooth-scroll"
CAP = 30
NORMAL = 10

def tm(*a):
    r = subprocess.run(["tmux"] + list(a), capture_output=True, text=True)
    # Cancelling copy-mode on a pane that is not in it is a normal part of resetting the rig, not a fault.
    if r.returncode and "not in a mode" not in r.stderr:
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

PANE = tm("display", "-p", "-t", "%s:" % SESS, "#{pane_id}")
LEDGER = "%s/%s/state" % (STATE_DIR, PANE.lstrip("%"))

def pos():
    v = tm("display", "-p", "-t", PANE, "#{scroll_position}")
    return int(v) if v.lstrip("-").isdigit() else 0

def prepare():
    tm("send-keys", "-t", PANE, "-X", "cancel"); time.sleep(0.4)
    tm("copy-mode", "-t", PANE); time.sleep(0.5)
    shutil.rmtree(STATE_DIR, ignore_errors=True)

def fire(d="up", n=NORMAL):
    tm("run-shell", "-b", "-t", PANE, "TMUX_PANE=%s %s/src/scroll.sh %s normal" % (PANE, TSS, d))

def drain_quiet(limit=12.0):
    """Wait until the pane stops moving and no animator is left holding the pane."""
    last, t0, still = pos(), time.perf_counter(), 0
    while time.perf_counter() - t0 < limit:
        p = pos()
        still = 0 if p != last else still + 1
        last = p
        if still > 60:
            break
        time.sleep(0.01)
    time.sleep(0.4)
    return last, animators()

def ledger_sum():
    try:
        return sum(int(l) for l in open(LEDGER) if l.strip())
    except OSError:
        return 0

results = []
def check(label, got, want, note=""):
    ok = (got == want)
    results.append(ok)
    print("%-52s got %4s want %4s  %s %s" % (label, got, want, "PASS" if ok else "FAIL", note))

tm("set", "-g", "@smooth-scroll-max-pending", str(CAP))
tm("set", "-g", "@smooth-scroll-normal", str(NORMAL))
print("pane %s, cap %s, %s lines per report\n" % (PANE, CAP, NORMAL))

# A. Spaced reports: nothing is capped, so every line demanded must be travelled, no more and no less.
prepare()
base = pos()
for _ in range(6):
    fire(); time.sleep(0.25)
end, anims = drain_quiet()
check("A spaced 6x10 up: exact travel", end - base, 60, "over-travel means a stale balance was restored")
check("A no animator left holding the pane", anims, 0)
check("A ledger left paid up", ledger_sum(), 0)

# B. Burst: all six land at once, so outstanding demand is capped and the pane travels exactly the cap.
prepare()
base = pos()
for _ in range(6):
    fire()
end, anims = drain_quiet()
check("B burst 6x10 up: capped travel", end - base, CAP, "more than the cap means the cap is not enforced")
check("B ledger left paid up", ledger_sum(), 0)

# C. Equal and opposite, spaced: the pane must end where it began.
prepare()
base = pos()
for _ in range(4):
    fire("up"); time.sleep(0.25)
for _ in range(4):
    fire("down"); time.sleep(0.25)
end, anims = drain_quiet()
check("C spaced 4 up then 4 down: net zero", end - base, 0)
check("C ledger left paid up", ledger_sum(), 0)

# D. Steering: reverse while the pane is still crawling. The cap decides the exact number, but the pane must
#    visibly change direction and must not over-travel beyond what was filed.
prepare()
base, peak = pos(), 0
for _ in range(4):
    fire("up")
t0 = time.perf_counter()
while time.perf_counter() - t0 < 0.12:
    peak = max(peak, pos()); time.sleep(0.01)
for _ in range(4):
    fire("down")
end, anims = drain_quiet(14.0)
check("D reversal mid-crawl actually reverses", 1 if peak - end > 0 else 0, 1,
      "peak %d, ended %d" % (peak, end))
check("D no over-travel past what was filed", 1 if peak - base <= 4 * NORMAL else 0, 1,
      "travelled %d of 40 filed" % (peak - base))

# E. A report filed while the animator is retiring must still be honoured - this is what the post-release
#    re-check in animator.pl exists for. Filed 60-90ms into a 10-line pass, i.e. while it is running.
prepare()
base = pos()
fire("up")
time.sleep(0.07)
fire("up")
end, anims = drain_quiet()
check("E report filed mid-pass is not orphaned", end - base, 20, "less means demand was swallowed")

# F. The pane must begin moving promptly: the finger should not wait on a queue.
prepare()
base = pos()
t0 = time.perf_counter()
fire("up")
first = None
while time.perf_counter() - t0 < 3.0:
    if pos() != base:
        first = (time.perf_counter() - t0) * 1000
        break
    time.sleep(0.005)
check("F first movement latency under 250 ms", 1 if first is not None and first < 250 else 0, 1,
      "first move %.0f ms" % (first if first is not None else -1))

print("\n%d/%d checks passed" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
