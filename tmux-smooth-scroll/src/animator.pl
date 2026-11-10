#!/usr/bin/env perl
# Smooth scroll that drains a *queue* rather than animating one request.
#
# Upstream issues one fixed-length animation per wheel report: five reports from one phone swipe mean five
# bash+perl spawns and five animations competing for the same pane, so the pane is still crawling a second
# after the thumb stopped and a second swipe stacks fifty more lines behind it. Measured on a live pane: ten
# reports spawned eleven concurrent animations.
#
# Here a report only files a signed line count in the pane's ledger and this process drains it: the count is
# taken into memory, lines are moved against it, and the ledger is consulted again only when it has visibly
# grown, which can only mean fresh demand. Reports that land mid-animation are paid for on the next step; a
# report the other way can pull the count through zero so the very next step reverses. One animation serves any
# number of reports, and queued demand is capped at @smooth-scroll-max-pending so a pane is never left flushing
# a backlog the rider gave up on.
#
# Pacing keeps upstream's feel: the easing curve is keyed to the length of the pass and to how far that pass has
# travelled, and grouping lines into pairs saves tmux calls without moving any faster than one line at a time.
#
# Two ledgers are involved and they do different jobs:
#   `state` holds the demand. Producers append to it under the file's own lock and this process holds that lock
#     for microseconds at a time - never for the length of a pass.
#   `.lock` names the animator: claimed exclusively here, non-blocking, and released only when this pane's demand
#     is drained. Claiming here rather than in the shell removes the gap between testing for a runner and
#     becoming one.

use strict;
use warnings;
use Fcntl qw(:flock O_RDWR O_CREAT);
use Time::HiRes qw(usleep);
use POSIX qw(ceil);
use constant PI => 3.14159265359;

my ($base_delay, $mode, $target_pane, $state_path, $max_pending, $lock_path) = @ARGV;
$base_delay   = 10000 unless defined $base_delay   && $base_delay   =~ /^\d+$/ && $base_delay   > 0;
$mode         = 'sine' unless defined $mode        && $mode =~ /^(linear|sine|quad)$/;
$max_pending  = 30    unless defined $max_pending  && $max_pending  =~ /^\d+$/ && $max_pending  > 0;
$target_pane  = ''    unless defined $target_pane;
$state_path   = ''    unless defined $state_path;
$lock_path    = ''    unless defined $lock_path;

my @cmd = ("tmux", "send-keys");
push @cmd, "-t", $target_pane if length $target_pane;

my $st;
sysopen($st, $state_path, O_RDWR | O_CREAT) or exit 1;

my $lk;
if (length $lock_path) {
    sysopen($lk, $lock_path, O_RDWR | O_CREAT) or exit 1;
    # Somebody else is already animating this pane, and they will pick up what was just filed: nothing to do.
    flock($lk, LOCK_EX | LOCK_NB) or exit 0;
}

my $owed = 0;                            # the count in hand: only this process may take it down, in memory
my $written = 0;                         # the balance the ledger itself currently records
my ($travelled, $sign, $guard, $seen, $pass) = (0, 0, 0, -1, 0);

sub tlog {                              # an optional trail, only when TSS_DEBUG names a file
    return unless $ENV{TSS_DEBUG};
    return unless open(my $dh, ">>", $ENV{TSS_DEBUG});
    my $tag = shift;
    printf $dh "%-14s %7.1f %s\n", $tag, Time::HiRes::time() * 1000, join(" ", @_);
}
tlog("start", "pane=" . ($target_pane || "active") . " cap=$max_pending delay=$base_delay easing=$mode");

sub reconcile {                         # has demand arrived that this process has not yet taken into hand?
    my $seen_in = shift;                #   only producers append, so a ledger longer than our own last word is
    my @s = stat($state_path);          #   the one event worth reading it for
    my $size = @s ? $s[7] : 0;
    return ($owed, $seen_in) if $size == $seen_in;
    my ($sum, $saw) = (0, 0);
    flock($st, LOCK_EX);
    seek($st, 0, 0);
    while (my $l = <$st>) {
        $l =~ s/\s//g;
        next unless length $l;
        $saw = 1;
        $sum += $l if $l =~ /^-?\d+$/;
    }
    # The ledger's own balance is the number this process last wrote, so everything above that line is fresh
    # demand and only that much joins the count in hand. Summing the whole ledger instead - my first attempt -
    # restored lines already moved but not yet written down, and the pane travelled further than anyone asked:
    # eight reports demanding 80 lines moved 132.
    $owed += $sum - $written;
    if ($owed > $max_pending) { $owed = $max_pending }
    if ($owed < -$max_pending) { $owed = -$max_pending }
    if ($saw) {
        seek($st, 0, 0);
        print $st "$owed\n";
        truncate($st, length($owed) + 1);
        $seen_in = length($owed) + 1;
        $written = $owed;
    } else {
        $seen_in = 0;
        $written = 0;
    }
    flock($st, LOCK_UN);
    return ($owed, $seen_in);
}

sub velocity {
    my ($t, $m) = @_;
    return 1.0 if $m eq 'linear';
    return 0.3 + 2.7 * sin($t * PI) if $m eq 'sine';
    my $v;
    if ($t < 0.5) { $v = 2 * $t * $t } else { $v = 1.0 - ((-2 * $t + 2) ** 2) / 2 }
    return 0.2 + 2.8 * $v;
}

sub settle_ledger {                     # leave one word in the ledger: what is still unpaid, which after a
    flock($st, LOCK_EX);                #   drained pass is nothing
    seek($st, 0, 0);
    print $st "$owed\n";
    truncate($st, length($owed) + 1);
    $written = $owed;
    flock($st, LOCK_UN);
}

sub drain {
    while (1) {
        ($owed, $seen) = reconcile($seen);
        return if $owed == 0;
        my $dir = $owed > 0 ? 1 : -1;
        if ($sign != $dir) { $sign = $dir; $travelled = 0; $pass = 0 }

        my $abs = abs($owed);
        # The length of this pass, which can only grow: demand landing mid-animation joins the pass already
        # under way rather than restarting the easing curve, so a second flick accelerates the pane instead of
        # making it stumble back into a slow start.
        $pass = $travelled + $abs if $travelled + $abs > $pass;
        my $t = $pass > 1 ? $travelled / ($pass - 1) : 0.5;
        my $v = velocity($t, $mode);

        # A big backlog moves in pairs and a small one line by line. tmux is the expensive part of a step
        # (upstream spends one call per line; my first attempt spent three) and pairs still read as a glide,
        # while the last lines of a pass always move singly so it never lands with a jump.
        my $batch = $abs > 20 ? 3 : ($abs > 6 ? 2 : 1);
        $batch = $abs if $batch > $abs;

        # Upstream's pacing, kept honest: $base_delay is the time for one line at speed 100, the easing curve is
        # keyed to the whole pass, and multiplying by the batch is what preserves the per-line feel - a pair of
        # lines is allotted the time of two lines. Dividing instead (my first attempt) moved 30 lines in 124 ms,
        # which is not a glide but a flick.
        my $scale = ($pass < 10) ? 1.0 + 2.0 * (10 - $pass) / 9 : 1.0;
        my $delay_us = ($base_delay * $scale * $batch) / $v;
        my $t0 = Time::HiRes::time() * 1000;
        tlog("step", "owed=$owed batch=$batch travelled=$travelled pass=$pass delay_us=" . int($delay_us));

        system(@cmd, "-X", "-N", $batch, ($dir > 0 ? "scroll-up" : "scroll-down"));
        return if $? != 0;                  # pane gone or server gone: stop rather than spin
        $owed -= $dir * $batch;
        $travelled += $batch;

        # Demand is capped, so a count that outruns this guard means a bug - and a bug should stop scrolling
        # rather than hang a pane forever.
        $guard++;
        return if $guard > 10 * $max_pending + 500;

        # The tmux call is already spent; only the remainder of the computed rest needs sleeping. In the fast
        # middle of a long pass the call itself is the rest, which is as it should be.
        my $spent_us = (Time::HiRes::time() * 1000 - $t0) * 1000;
        my $need_us = $delay_us - $spent_us;
        usleep(ceil($need_us)) if $need_us > 0;
    }
}

# The closing race, which is easy to miss: demand filed while this process was on its way out could find the
# claim still held, be left to "someone else" who has already stopped, and then be truncated away by this
# process's own final write. So the claim is released *before* the last look, and anything found there is
# reclaimed and drained here. Any report that failed to claim therefore appended before this process let go,
# and is necessarily visible in the look that follows.
my $respawns = 0;
while (1) {
    drain();
    settle_ledger();
    last unless $lk;
    last if $respawns++ > 4;                # a pane may be handed a fresh report, but not forever
    flock($lk, LOCK_UN);
    my ($left) = reconcile($seen);
    tlog("reclaim?", "left=$left");
    last if $left == 0;
    last unless flock($lk, LOCK_EX | LOCK_NB);   # someone else claimed the pane; they hold the demand now
    tlog("reclaim", "left=$left");
}

tlog("exit", "rest=$owed");
close($st);
exit 0;
