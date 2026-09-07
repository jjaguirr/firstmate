#!/usr/bin/env bash
# End-to-end demonstration of the reconciled parked/done absorb in bin/fm-watch.sh.
# Drives the REAL watcher against a hermetic fake tmux pane and a fake
# fm-crew-state.sh, and prints what the captain actually sees: the watcher's own
# surface line, the payload fm-wake-drain.sh hands the captain's session, and the
# absorbed-event triage log.
#
# Usage: WT=<worktree> bash reconciled-park-demo.sh
set -u
WT=${WT:?set WT to the firstmate worktree path}
# shellcheck source=/dev/null
. "$WT/tests/wake-helpers.sh"
# shellcheck source=/dev/null
. "$WT/bin/fm-classify-lib.sh"   # brings in fm_run_timed via fm-timeout-lib.sh
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-park-demo)
BOUND=120

file_mtime() { stat -c %Y "$1" 2>/dev/null; }
seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
reap() { stop_pid "$1"; }
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"; rm -f "$beat"; first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat"); [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
# Deliver the queued wake the way firstmate does. show=1 prints the payload the
# captain's session receives; then acknowledge it so the next round starts clean.
deliver() {  # <state> <show>
  local state=$1 show=$2 err sequence generation
  err="$state/.demo-drain.err"
  if [ "$show" = 1 ]; then
    FM_STATE_OVERRIDE="$state" fm_run_timed "$BOUND" "$DRAIN" 2> "$err" | sed 's/^/  captain session receives> /'
  else
    FM_STATE_OVERRIDE="$state" fm_run_timed "$BOUND" "$DRAIN" >/dev/null 2> "$err"
  fi
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 0
  FM_STATE_OVERRIDE="$state" fm_run_timed "$BOUND" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1 || true
}

dir=$(make_case park-demo); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; pane="$dir/pane.txt"; statusf="$state/gate.status"
window="test:fm-gate"; key=$(printf '%s' "$window" | tr ':/.' '___')
printf 'awaiting approval: 2 findings, pick one\n' > "$pane"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
# The park was never announced: the standing status line is NON-terminal, so no
# status signal, decision record or PR poll would ever report this gate.
printf 'working: implementing the fix\n' > "$statusf"
printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-gate_status"
printf '%s' "$(hash_text "$(cat "$pane")")" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"

PARKED='state: parked · source: run-step · awaiting_approval (2 findings)'
DONE='state: done · source: run-step · checks-passed'
STOPPED='state: unknown · source: none · no current-state source available'

say() { printf '\n=== %s\n' "$*"; }
expire_timer() {  # pin the pane as already-classified stale, timer past threshold
  local h; h=$(hash_text "$(cat "$pane")")
  printf '%s' "$h" > "$state/.hash-$key"; printf '1\n' > "$state/.count-$key"
  printf '%s' "$h" > "$state/.stale-$key"
  printf '%s' "$(( $(date +%s) - 500 ))" > "$state/.stale-since-$key"
}
run_round() {  # <label> <crew-state> <resurface-secs> <escalate-secs>
  local label=$1 cs=$2 resurface=$3 escalate=$4 pid
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE="$cs" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="$resurface" FM_STALE_ESCALATE_SECS="$escalate" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  if wait_for_exit "$pid" 100; then
    printf '%s -> captain sees:\n' "$label"
    sed 's/^/  watcher> /' "$out"
    deliver "$state" 1
  else
    reap "$pid"
    printf '%s -> captain sees NOTHING this round (absorbed)\n' "$label"
    deliver "$state" 0   # clear the recovery announcement a reaped watcher leaves
  fi
}

say 'PHASE 1 - a no-mistakes run parks at an approval gate it never announced'
run_round 'first sight of the park' "$PARKED" 999 999

say 'PHASE 2 - the pane stays frozen and the stale timer expires twice'
for r in 1 2; do expire_timer; run_round "expired timer, round $r" "$PARKED" 999 240; done
printf 'triage log:\n'; sed 's/^/  /' "$state/.watch-triage.log" | grep -F 'absorbed stale' | tail -2

say 'PHASE 3 - the bounded recheck cadence comes due (never silenced)'
expire_timer; run_round 'bounded recheck' "$PARKED" 1 240

say 'PHASE 4 - the captain answers; the crew resumes behind a BUSY pane'
# The pane renders grok's verified busy signature. The status log stays frozen
# while the run owns the branch, so this pane IS the only "no longer waiting"
# evidence. Drop the stale pins first: a busy pane is not a stale pane.
printf 'running the fix round\nCtrl+c:cancel\n' > "$pane"
rm -f "$state/.stale-$key" "$state/.stale-since-$key"
printf '%s' "$(hash_text "$(cat "$pane")")" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
: > "$out"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$pane" \
  FM_FAKE_TMUX_CURRENT_COMMAND=grok \
  FM_FAKE_CREW_STATE='state: working · source: run-step · run in progress' \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_PAUSE_RESURFACE_SECS=999 FM_STALE_ESCALATE_SECS=999 \
  FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$WATCH" > "$out" &
pid=$!; c=0
while [ "$c" -lt 3 ]; do wait_poll_cycle "$state" "$pid" || break; c=$((c + 1)); done
reap "$pid"; deliver "$state" 0
printf 'reconciled record still held after the busy resume: '
if ls "$state"/.reconciled-* >/dev/null 2>&1; then
  printf 'YES - park #2 would be absorbed against park #1\n'
else
  printf 'no - park #2 gets its own surface\n'
fi

say 'PHASE 5 - the crew parks at a SECOND gate; status log unchanged since park #1'
printf 'awaiting approval: risky migration, confirm?\n' > "$pane"
printf '%s' "$(hash_text "$(cat "$pane")")" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
run_round 'second park' "$PARKED" 999 999

say 'PHASE 6 - the crew genuinely stops while the pane stays frozen'
expire_timer; run_round 'frozen, no longer parked' "$STOPPED" 999 240

say 'PHASE 7 - a crew reconciled as done: one surface, then the reworded recheck'
printf 'checks passed, PR is green\n' > "$pane"
expire_timer; run_round 'first sight of done' "$DONE" 999 240
expire_timer; run_round 'done bounded recheck' "$DONE" 1 240
printf '\n'
