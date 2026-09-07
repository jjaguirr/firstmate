#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared wait, either a paused:
# external wait or a verified captain-held transfer, is one separate idle absorb
# case and re-surfaces only on its long bounded cadence, although its initial
# no-verb status signal still surfaces in normal mode. A crew bin/fm-crew-state.sh
# reconciles as parked at a decision or done with its work finished is the other: its
# pane is idle by design, so after the one surface each distinct reconciled state
# earns, later redraws of that same state take the same bounded cadence.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause or verified captain-held transfer is
#                          absorbed instead with its own long re-surface cadence,
#                          never as a wedge, and that recheck reason names which
#                          human the wait is on. A reconciled parked or done state
#                          surfaces once and is then absorbed onto that same bounded
#                          cadence. Only when no absorb class applies does the log's
#                          last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active. A pane whose own task
#                          worktree was written during the quiet window is
#                          deferred rather than escalated (wedge_defer_writing),
#                          because files appearing there are liveness the pane and
#                          the run step cannot show; that deferral still
#                          re-surfaces once per PAUSE_RESURFACE_SECS, and a pane
#                          that writes nothing keeps the unchanged schedule.
#                          A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no completed turn
#                          (state/<id>.turn-ended, or the spawn record before any
#                          turn completes). Past that bound, a declared external
#                          wait or verified captain-held transfer uses the long
#                          pause recheck cadence; every other pane goes through
#                          the same wedge timer and surfaces with the identical
#                          "stale: ..." reason, escalation count, and
#                          demand-deep-inspection marker, for human inspection
#                          only - never an automatic interrupt, signal, or restart
#                          of the worker or its tool process.
#   check: <script>: <out> authenticated check output, always actionable
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
#   check: inactive-outcome bounded poll-loop reconciliation found a suspicious
#                          inactive terminal outcome that still lacks its durable
#                          upstream receipt
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# The shared transition owner is a canonical lint root itself. Stop duplicate
# source-graph expansion here: following its backend graph from this large
# runtime can exceed the bounded CI lint worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_DOWNTIME_MARKER="$STATE/.watcher-down"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# The size:mtime signal signature and .seen-* marker format are owned by
# bin/fm-wake-lib.sh (fm_wake_signal_sig, fm_wake_signal_seen_path), shared
# with the drain's annotation staleness check and this home's own bookkeeping
# writers' guarded self-announced append.

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go with no completed turn: once its task's
# state/<id>.turn-ended marker (or, before any turn has completed, the task's
# spawn record) is this old, busy_turn_over_age routes the pane through
# busy_turn_bound_check, which hands a crossed bound to the same
# STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale - so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only, never an
# automatic interrupt, signal, or restart - unless the crew declared the wait
# itself, which takes the long pause cadence instead. A completed turn touches
# turn-ended and resets the age. Set generously above any legitimate interval
# between completed turns, including long tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-3600}
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence; a live or ambiguously read agent surfaces its declaration once
# and then joins that same cadence, however often its idle pane redraws, because a
# new pane hash under a standing declaration is the same wait, not a new event; a
# secondmate earns the cadence on its declaration alone, because its endpoint
# liveness is deliberately never read (pause_state_class owns that split).
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is
# consumed only by the Grok-scoped fallback inside the contract.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta verdict
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  else
    verdict=$(fm_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ]
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

# The ONE derivation of a window's per-window marker key: `:`, `/` and `.` become
# `_` so a window name is usable as a filename suffix. Every per-window file the
# watcher keeps is named by it (.hash-, .count-, .stale-, .stale-since-,
# .wedge-escalations-, .paused-*, .writing-*), and live homes hold those markers on
# disk under the current format, so the format lives here alone: a second copy is
# how a future change to it silently orphans a window's markers instead of clearing
# them. The helpers below take the derived key rather than re-deriving it, so one
# poll of one window derives it once.
window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# One bounded re-surface for a pane the watcher is deliberately absorbing, so no
# absorb can rot invisibly. <age> is how long the current absorb has held and
# <throttle> is the per-window marker whose mtime records the last re-surface, so
# once past PAUSE_RESURFACE_SECS the pane wakes once per window rather than every
# poll. Shared by the declared-pause absorb and the worktree-write deferral so the
# two cadences cannot drift apart; each caller owns its own marker and reason.
# Returns without waking while either the absorb or the throttle is inside the
# window; wake() itself exits the cycle, exactly as it does inline.
resurface_absorbed() {  # <window> <throttle-marker> <age> <reason>
  local win=$1 throttle=$2 age=$3 reason=$4
  [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] || return 0
  [ "$(age_of "$throttle")" -ge "$PAUSE_RESURFACE_SECS" ] || return 0   # 999999 when no prior re-surface
  fm_wake_append stale "$win" "$reason" || exit 1
  date +%s > "$throttle"
  wake "$reason"
}

# Defer ONE wedge escalation for a pane that went quiet while its own task
# worktree is demonstrably still being written (crew_worktree_written_since in
# fm-classify-lib.sh). The pane and the run step both say nothing is happening;
# the worktree says otherwise, and files appearing in it is the harder signal to
# fake, so the escalation is deferred rather than fired. Deliberately a DEFERRAL,
# not a cancellation: the idle timer restarts, so the next window probes again,
# and a .writing-since-<key> marker ages the whole deferral chain so the pane
# still re-surfaces once every PAUSE_RESURFACE_SECS through the shared
# resurface_absorbed above - literally the same bounded cadence a declared pause
# uses, throttled by its own .writing-resurfaced-<key> marker - and a crew whose
# worktree churns without real progress cannot stay invisible. The escalation
# counter is left alone: it is neither advanced (this is not an escalation) nor
# reset (a later genuine escalation must still carry the demand-deep-inspection
# history it had already earned).
wedge_defer_writing() {  # <window> <since-file> <triage-label> <idle-age>
  local win=$1 since_file=$2 label=$3 age=$4 key wsf wage
  key=$(window_key "$win")
  wsf="$STATE/.writing-since-$key"
  [ -e "$wsf" ] || date +%s > "$wsf"
  wage=$(age_of "$wsf")
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.writing-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s, writing its worktree for ${wage}s, rechecked on a long cadence not a wedge; confirm the writes are real progress)"
  triage_log "absorbed $label (worktree written since the idle window opened, idle ${age}s): $win"
}

# Drop a window's write-deferral chain wherever its stale bookkeeping resets, so
# the bounded re-surface cadence is measured from the CURRENT quiet stretch and a
# long-finished one cannot make the next deferral resurface immediately.
clear_write_tracking() {  # <window-key>
  local key=$1
  rm -f "$STATE/.writing-since-$key" "$STATE/.writing-resurfaced-$key"
}

# Drop a window's reconciled expected-idle chain wherever the crew is observed
# working again, so a crew that parks, resumes, and later parks a second time
# earns its own surface instead of inheriting the first one's, and so the bounded
# re-surface cadence is measured from the CURRENT expected-idle stretch.
#
# Two readings prove the crew left the wait, and both drop this chain: an
# authoritative working verdict on the stale path, and a pane actually RENDERING
# BUSY. A changed hash on an idle pane is neither, and deliberately does NOT drop
# it: an idle pane that merely redrew is the same reconciled wait, and dropping
# the record there would re-surface it on every redraw - the exact behavior this
# chain exists to stop. Keeping the busy reading in that exempt set was the
# original mistake, because a crew that parks, is answered, resumes behind a busy
# pane, and parks again at a SECOND gate appends nothing to its status log while a
# run owns it (AGENTS.md's sparse status-reporting contract), so the second park
# produced a digest identical to the first: it inherited the spent surface and the
# old age anchor, went unreported for up to PAUSE_RESURFACE_SECS, and then printed
# an age measured from the wrong park.
clear_reconciled_tracking() {  # <window-key>
  local key=$1
  rm -f "$STATE/.reconciled-$key" "$STATE/.reconciled-since-$key" \
    "$STATE/.reconciled-resurfaced-$key"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
# The worktree write probe runs ONLY here, inside the at-threshold branch that is
# about to escalate: at most one bounded walk per window per STALE_ESCALATE_SECS,
# never per poll.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <task>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 task=$5 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      clear_write_tracking "$(window_key "$win")"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        if crew_worktree_written_since "$task" "$STATE" "$since_file"; then
          wedge_defer_writing "$win" "$since_file" "$label" "$age"
          return 0
        fi
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        clear_write_tracking "$(window_key "$win")"
        wake "$reason"
      fi
      ;;
  esac
}

# 0 when an existing wedge timer has reached STALE_ESCALATE_SECS and so is one
# poll away from escalating. Callers use it to re-read the authoritative crew state
# at that single moment rather than every poll, so a run that parked at a gate or
# went checks-green while its pane never changed a byte cannot escalate as a wedge.
# The timestamp CONTENT, not the file mtime, is the timer contract, because a
# repair or a test deliberately writes an older epoch into a freshly modified
# sidecar. A missing or malformed timestamp reads as due so it reaches
# wedge_timer_check's existing self-repair path.
wedge_timer_is_due() {  # <since-file>
  local since
  since=$(cat "$1" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*) return 0 ;;
    *) [ "$(( $(date +%s) - since ))" -ge "$STALE_ESCALATE_SECS" ] ;;
  esac
}

# busy_turn_over_age: 0 iff <task>'s latest completed-turn marker is at least
# BUSY_TURN_MAX_SECS old. Ages the per-task turn-ended marker, the harness-neutral
# signal every verified harness's turn-end hook touches; before any turn has
# completed, ages the task's spawn record instead so a fresh task still gets a
# bound. The caller checks that the pane is busy and routes a crossed bound
# through busy_turn_bound_check, never anything that touches the worker itself.
busy_turn_over_age() {  # <task>
  local task=$1 f
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. The bounded re-surface itself is the shared resurface_absorbed
# above, throttled by this window's own .paused-resurfaced-<key> marker. Advances
# the stale suppressor to <hash> and arms the key's bounded cadence (.paused-<key>).
# That flag records the CADENCE only, never that the declaration was surfaced: this
# absorber is also reached from busy_turn_bound_check, which arms it on a busy pane
# that has surfaced nothing at all. surface_nonterminal_stale owns the separate
# .paused-surfaced-<key> record, because it is the only site that actually surfaces.
#
# The recheck names WHICH human the declared wait is on, because that is the whole
# point of a recheck the captain reads: an external dependency for paused:, and the
# captain themself for a verified hold. Only the captain-held verb takes the second
# wording; a caller that reached the bounded cadence off pause tracking alone, with
# no declaring verb left on the log, keeps the external-wait wording it always had.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age detail reason
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  clear_write_tracking "$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  if status_is_captain_held "$(last_status_line "$statusf")"; then
    detail="captain-held, awaiting the captain"
    reason="captain-held ${age}s, awaiting the captain - verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold"
  else
    detail="paused, awaiting external"
    reason="paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds"
  fi
  resurface_absorbed "$win" "$STATE/.paused-resurfaced-$key" "$age" "stale: $win ($reason)"
  triage_log "absorbed stale ($detail, age ${age}s): $win"
}

# Apply the busy-pane completed-turn bound to a window whose bound has already
# crossed, honoring the worker's OWN declared external wait. Prints/queues
# nothing itself; it only chooses which absorber owns the crossed bound.
#
# A busy pane past BUSY_TURN_MAX_SECS is normally a wedge suspect because a hung
# foreground call can hide behind a busy signature. A `paused:` declaration or
# verified captain-held transfer instead identifies that live foreground call as
# the expected external wait. The caller has already confirmed liveness through
# the busy verdict, so this exception does not suppress undeclared wedges or
# alter the separate non-busy classification. handle_paused_stale keeps the
# exception bounded by re-surfacing it once per PAUSE_RESURFACE_SECS. Away mode
# remains daemon-owned and receives the undecorated wake identity for its own
# classification.
busy_turn_bound_check() {  # <window> <task> <hash> <since-file> <escalation-file>
  local win=$1 task=$2 h=$3 since_file=$4 escalation_file=$5
  if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
    handle_paused_stale "$win" "$task" "$h"
    return 0
  fi
  wedge_timer_check "$win" "$since_file" "busy (no completed turn)" "$escalation_file" "$task"
  return 1
}

# The declaration a surface was spent on, as a stable digest of the status line
# itself. The surfaced record is keyed to the DECLARATION and not merely to the
# window, so a second, different declaration under the same key - `paused:`
# becoming `captain-held`, or a new pause reason - is a new event that earns its
# own surface rather than inheriting the previous one's.
pause_declaration_digest() {  # <status-line>
  printf '%s' "$1" | hash_pane
}

# 0 iff <declaration> is a declared wait AND is the exact declaration this window's
# one surface was already spent on. The single predicate every stale-triage `none`
# reading asks, so the two branches that ask it - a first-sighted hash and a hash
# already classified - cannot drift into answering it differently. Never true for a
# cadence armed without surfacing (busy_turn_bound_check), which is what keeps that
# declaration's own surface owed.
pause_declaration_surfaced() {  # <window-key> <declaration>
  local key=$1 decl=$2
  status_is_paused_or_captain_held "$decl" || return 1
  [ "$(cat "$STATE/.paused-surfaced-$key" 2>/dev/null || true)" = "$(pause_declaration_digest "$decl")" ]
}

clear_pause_state() {  # <window-key>
  local key=$1
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" \
    "$STATE/.paused-resurfaced-$key" "$STATE/.paused-surfaced-$key"
}

clear_pause_tracking() {  # <window-key>
  local key=$1
  clear_pause_state "$key"
  clear_write_tracking "$key"
  clear_reconciled_tracking "$key"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# After fm-crew-state has fallen back to stopped or unknown, paused classification is
# recovered only for a confidently dead ordinary crew, or for a secondmate, whose
# endpoint liveness this function deliberately never reads.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive kind
  key=$(window_key "$win")
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  # Read once past the declared-wait gate and reused by both liveness gates below,
  # so a mate's stale poll costs one metadata scan rather than one per gate, and the
  # far more common no-declaration path above still costs none.
  kind=$(window_kind "$win")
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$kind" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$kind" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  # Recover paused classification for a declared wait that authoritative crew state
  # could not name. Reaching here already proves the only two admissible cases: an
  # ordinary crew whose agent the gate above confirmed dead, so no live decision gate
  # is being silenced, or a secondmate, whose endpoint liveness is deliberately never
  # read and so cannot supply that confirmation. Without the mate case a mate's
  # captain hold - which has no current-state mapping and so arrives as `none` -
  # would be silenced by every caller rather than taking the bounded re-surface
  # cadence, and a forgotten hold would rot invisibly.
  # A crew that already DECLARED its wait keeps the declared-pause cadence for
  # every expected-idle verdict, so widening crew_absorb_class cannot change what
  # this arm returns. The reconciled parked/done absorber owns only crews that have
  # no declaration of their own on the log.
  case "$class" in none|parked|done) class=paused ;; esac
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(window_key "$win")
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  clear_write_tracking "$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  # This is the ONE site that actually surfaces a declaration to firstmate, so it
  # is the only site allowed to record that the surface was spent - and it records
  # WHICH declaration, so the record cannot be read as covering a later, different
  # one. Every other pause marker here is cadence bookkeeping.
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    pause_declaration_digest "$last" > "$STATE/.paused-surfaced-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" \
      "$STATE/.paused-resurfaced-$key" "$STATE/.paused-surfaced-$key"
  fi
  wake "stale: $win"
}

# The reconciled expected-idle state a surface was spent on, as a stable digest of
# the class, the declaration standing on the log, and that log's own mtime. Keyed
# to the STATE and not merely to the window, so a crew that moves from parked to
# done, raises a second decision, or resumes and finishes again, is a new event that
# earns its own surface rather than inheriting the previous one's. The mtime is what
# separates "the same wait, redrawn" from "the crew wrote something new": a pane
# redraw changes the hash and leaves the log untouched, while any fresh append
# changes this digest even when the appended text repeats.
reconciled_idle_digest() {  # <class> <status-line> <status-mtime>
  printf '%s\n%s\n%s' "$1" "$2" "$3" | hash_pane
}

# Surface-or-absorb a stale pane whose authoritative current state
# bin/fm-crew-state.sh has reconciled as `parked` (held at a decision) or `done`
# (work finished, whether or not it has landed). Such a pane is idle BY DESIGN -
# the decision record and the PR merge poll own what happens next - so its hash
# carries no wedge evidence at all.
#
# Expected-idle is NOT invisible. The FIRST sight of each distinct reconciled state
# surfaces exactly as the ordinary stale paths would, because a crew parked at a
# gate it never announced, or finished with nothing yet watching it, must still
# reach firstmate once. Only after that surface is spent does a later hash under the
# SAME reconciled state count as the same wait redrawn - a token counter, a clock, a
# footer - and take the shared bounded re-surface cadence instead of costing a whole
# supervision turn per redraw. That is the same shape pause_declaration_surfaced
# gives a declared wait, for the states a crew never has to declare.
#
# The absorb RE-ARMS the wedge timer rather than dropping it. Two things follow, and
# both are the point: the next expiry re-reads the authoritative state, so a pane
# that stops being parked or done while it stays frozen escalates as the wedge it
# has become; and an absorbed pane costs one crew-state read per STALE_ESCALATE_SECS
# rather than one per poll. The re-surface age is anchored on .reconciled-since-<key>
# - the moment this expected-idle stretch began - not on the status file, because a
# crew can be parked at a gate for hours without writing a single status line.
handle_reconciled_idle_stale() {  # <window> <task> <hash> <parked|done>
  local win=$1 task=$2 h=$3 class=$4 key statusf last mtime digest since age detail reason
  key=$(window_key "$win")
  statusf="$STATE/$task.status"
  last=$(last_status_line "$statusf")
  mtime=$(stat_mtime "$statusf" || true)
  digest=$(reconciled_idle_digest "$class" "$last" "$mtime")
  since="$STATE/.reconciled-since-$key"
  if [ "$(cat "$STATE/.reconciled-$key" 2>/dev/null || true)" != "$digest" ]; then
    fm_wake_append stale "$win" "stale: $win" || exit 1
    printf '%s' "$h" > "$STATE/.stale-$key"
    rm -f "$STATE/.stale-since-$key"
    clear_write_tracking "$key"
    printf '%s' "$digest" > "$STATE/.reconciled-$key"
    date +%s > "$since"
    date +%s > "$STATE/.reconciled-resurfaced-$key"
    mark_surfaced "$statusf"
    wake "stale: $win"
    return
  fi
  printf '%s' "$h" > "$STATE/.stale-$key"
  date +%s > "$STATE/.stale-since-$key"
  rm -f "$STATE/.wedge-escalations-$key"
  clear_pause_state "$key"
  clear_write_tracking "$key"
  [ -e "$since" ] || date +%s > "$since"
  age=$(age_of "$since")
  if [ "$class" = parked ]; then
    detail="parked, awaiting a decision"
    reason="parked ${age}s, awaiting a decision - reconciled expected idle, rechecked on a long cadence not a wedge; answer the open decision or restart the work"
  else
    # `done` covers a PR that is merely green and one that already merged
    # (bin/fm-crew-state.sh maps checks-passed, passed and completed onto the same
    # token), so this recheck states only what is certainly true - the work is
    # finished and the crew is still sitting there - and asks which it is. Naming
    # an unfinished landing would hand the captain the wrong next action for half
    # the crews that reach it.
    detail="done, not yet cleaned up"
    reason="done ${age}s, finished and not yet cleaned up - reconciled expected idle, rechecked on a long cadence not a wedge; confirm whether this work has landed"
  fi
  resurface_absorbed "$win" "$STATE/.reconciled-resurfaced-$key" "$age" "stale: $win ($reason)"
  triage_log "absorbed stale ($detail, age ${age}s): $win"
}

# Re-read the authoritative crew state for an ALREADY-classified stale hash whose
# wedge timer has come due, and hand it to the reconciled-idle absorber when that
# state is expected idle. A no-mistakes run can park at an approval gate, or go
# checks-green, while the pane it renders never changes a byte; the timer armed
# while that run WAS working would otherwise escalate the transition as a wedge.
# Every other verdict stays on the existing timer, so a genuinely frozen crew
# escalates exactly as it did before.
wedge_timer_due_check() {  # <window> <task> <hash> <since-file> <escalation-file> <triage-label>
  local win=$1 task=$2 h=$3 since_file=$4 escalation_file=$5 label=$6 class
  class=$(crew_absorb_class "$task")
  case "$class" in
    parked|done) handle_reconciled_idle_stale "$win" "$task" "$h" "$class" ;;
    *)           wedge_timer_check "$win" "$since_file" "$label" "$escalation_file" "$task" ;;
  esac
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(fm_wake_signal_sig "$f") || continue
    [ -n "$sig" ] || continue
    sf=$(fm_wake_signal_seen_path "$STATE" "$f")
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
  done < <(fm_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check: process-event result captured:$PROCEVENT_SURFACED"
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
WATCHER_RECOVERY_PENDING=0
if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
  WATCHER_RECOVERY_PENDING=1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ]; then
  if ! fm_recovery_marker_reopen_announced "$WATCHER_DOWNTIME_MARKER"; then
    echo "watcher: recovery state could not be reopened safely; retaining stale lock evidence" >&2
    exit 1
  fi
fi
if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
  echo "watcher: recovery state could not be consumed safely; retaining stale lock evidence" >&2
  exit 1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  WATCHER_RECOVERY_PENDING=0
elif [ "$FM_RECOVERY_MARKER_ACTION" = recover ]; then
  WATCHER_RECOVERY_PENDING=1
fi
watcher_cleanup() {
  local cleanup_status=0 owns_lock=0 transition=release-lock
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "${WATCHER_PID:-}" ]; then
    owns_lock=1
    if [ "${WATCHER_RECOVERY_PENDING:-0}" -eq 1 ] \
      && [ "${FM_WATCH_DELIVERED_REASON:-}" = "check: rearm-resurface" ]; then
      transition=release-lock-existing
    fi
  fi
  fm_active_check_stop || cleanup_status=1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  if [ "$owns_lock" -eq 1 ] \
    && ! fm_recovery_transition "$WATCHER_DOWNTIME_MARKER" "$transition" "$WATCH_LOCK" downtime; then
    echo "watcher: recovery state could not be persisted; retaining stale lock evidence" >&2
    cleanup_status=1
  fi
  return "$cleanup_status"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

resurface_after_downtime() {
  # Handling successors already have a predecessor-delivered wake on the way.
  # Re-announcing from this cycle is what turned a lost handshake into an
  # unbounded recovery loop; stay in the poll loop and supervise instead.
  if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
    return 0
  fi
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ]; then
    if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  wake "check: rearm-resurface"
}

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered.
  if [ -d "$STATE/procevent" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # A process-event result carries richer adapter-owned wake context than the
  # generic recovery reason, so give that owner first refusal.
  resurface_after_downtime

  # The existing poll loop also owns the bounded inactive-outcome cadence.
  # This is mechanical and silent unless a durable terminal-outcome obligation
  # was created, so quiet cycles never wake firstmate or consume model tokens.
  inactive_out=
  if inactive_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-inactive-reconcile.sh" scan 2>/dev/null); then
    if [ -n "$inactive_out" ]; then
      wake "check: inactive-outcome"
    fi
  else
    triage_log "inactive-outcome reconciliation unavailable"
  fi

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" "$out"; then
            fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
              || triage_log "merged PR poll retirement remains recoverable for $id"
          else
            triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
          fi
        fi
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=$(window_key "$w")
    last=$(last_status_line "$STATE/$task.status")
    # The declaration ending is one of the two authorities that drop pause
    # bookkeeping. It tests EVERY pause marker, not the cadence flag alone: away
    # mode's own reconciliation (bin/fm-supervise-daemon.sh) drops the cadence flag
    # without knowing about the surfaced record, and a surfaced record outliving
    # its declaration would silently absorb the first sight of a later identical
    # declaration.
    if ! status_is_paused_or_captain_held "$last" \
      && { [ -e "$STATE/.paused-$key" ] || [ -e "$STATE/.paused-surfaced-$key" ]; }; then
      clear_pause_tracking "$key"
    fi
    # An idle secondmate endpoint is healthy by design, so a mate is admitted to
    # the pane-stale path ONLY to serve a declared wait's bounded re-surface -
    # the same declarations pause_state_class reconciles below, which is why this
    # gate reads the shared predicate rather than the pause verb alone. Narrowing
    # it to `paused` would leave a mate's captain hold rotting invisibly: the
    # clear above already spares its pause tracking, but nothing would ever
    # re-surface it.
    if [ "$kind" = secondmate ] && ! status_is_paused_or_captain_held "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$key" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            class=$(crew_absorb_class "$task")
            case "$class" in
              working)
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                clear_write_tracking "$key"
                clear_reconciled_tracking "$key"
                triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
                ;;
              parked|done)
                # The log's captain-relevant line and the reconciled state agree
                # that this pane is waiting, not wedged. That agreement is exactly
                # what makes a redraw uninformative, so the first sight still
                # surfaces and only the repeats are absorbed.
                handle_reconciled_idle_stale "$w" "$task" "$h" "$class"
                ;;
              *)
                fm_wake_append stale "$w" "stale: $w" || exit 1
                printf '%s' "$h" > "$sf"
                rm -f "$ssf"
                clear_write_tracking "$key"
                mark_surfaced "$STATE/$task.status"
                wake "stale: $w"
                ;;
            esac
          elif [ -e "$ssf" ] && wedge_timer_is_due "$ssf"; then
            # The timer this hash has been riding is about to escalate, so spend
            # one authoritative read before calling a wait a wedge.
            wedge_timer_due_check "$w" "$task" "$h" "$ssf" "$ewf" "stale (overridden terminal status)"
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" "$task"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight and at an expiring wedge timer, never every poll) via
          # pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: a declared wait pause_state_class admits (its header owns which
          #     liveness evidence each kind of crew must supply), so absorb on the long
          #     PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - parked/done: the crew never declared a wait, but its authoritative state
          #     is held at a decision or finished with its work done, so the idleness is
          #     expected: surface each distinct reconciled state once, then absorb its
          #     redraws onto that same bounded cadence (handle_reconciled_idle_stale);
          #   - none: no running pipeline, no exact busy verdict, no admitted declared wait.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer - UNLESS this key already surfaced the very
          #     declaration still on the log, in which case a new hash is the same
          #     wait redrawn, not a new event (see the surfaced-record case below).
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            class=$(pause_state_class "$w" "$task")
            case "$class" in
              working)
                clear_pause_tracking "$key"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              parked|done)
                # No declaration on the log, so nothing else here is throttling
                # this pane - but the reconciled state says the idleness is
                # expected. Surface the state once, then absorb its redraws.
                handle_reconciled_idle_stale "$w" "$task" "$h" "$class"
                ;;
              *)
                # A live agent's first-sighted declaration still surfaces once, so
                # an external-decision gate is never hidden behind the cadence. But
                # once THIS declaration has actually been surfaced, every later hash
                # under it is the same wait: an idle pane redraw - a token counter, a
                # clock, a footer - changes the hash without changing anything the
                # captain can act on. A crew that finished and declared `paused:
                # awaiting captain merge` reads `none` for as long as it waits (its run
                # is authoritatively done, never paused, and its agent is alive), so
                # without this every redraw would cost a full supervision turn that
                # ends in nothing to do.
                #
                # The gate is the surfaced record, NOT the pf cadence flag: pf is armed
                # by handle_paused_stale from busy_turn_bound_check too, on a busy pane
                # that surfaced nothing, and keying off the wrong marker is the exact
                # shape of the bug this change exists to fix. Reading pf here would
                # leave a declaration first armed while its pane read busy silent until
                # PAUSE_RESURFACE_SECS. Comparing the digest also means a second,
                # different declaration under the same key surfaces on its own merits.
                # Undeclared stale is untouched: with no declaration on the log the top
                # of this loop has already dropped every pause marker, so a genuine
                # wedge still surfaces on every fresh hash.
                if pause_declaration_surfaced "$key" "$(last_status_line "$STATE/$task.status")"; then
                  handle_paused_stale "$w" "$task" "$h"
                else
                  surface_nonterminal_stale "$w" "$h"
                fi
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              # Reaching here means a declaration stands (the loop top drops the
              # cadence flag the moment one ends), and pause_state_class maps every
              # expected-idle verdict under a declaration onto that declaration's own
              # cadence - so parked and done never arrive here and the reconciled
              # absorber owns only undeclared waits.
              class=$(pause_state_class "$w" "$task")
              case "$class" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$key"
                         clear_reconciled_tracking "$key"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" "$task"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       # A pane whose text never changed across the busy-to-idle
                         # flip reaches its declaration's FIRST idle classification
                         # here, not above: the busy-turn bound already advanced the
                         # stale suppressor to this same hash. The surface is owed to
                         # the declaration, not to a hash the pane happened to change,
                         # so this asks the same question the first-sight branch does.
                         if pause_declaration_surfaced "$key" "$(last_status_line "$STATE/$task.status")"; then
                           handle_paused_stale "$w" "$task" "$h"
                         else
                           surface_nonterminal_stale "$w" "$h"
                         fi ;;
              esac
            elif [ -e "$ssf" ] && wedge_timer_is_due "$ssf"; then
              wedge_timer_due_check "$w" "$task" "$h" "$ssf" "$ewf" "non-terminal stale"
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" "$task"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through busy_turn_bound_check, which hands the crossed
        # bound to the same wedge timer unless the crew declared the wait itself.
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf"
        else
          rm -f "$ssf" "$ewf"
          clear_write_tracking "$key"
        fi
        # A pane rendering busy is the crew working, not the same wait redrawn, so
        # it ends any reconciled expected-idle stretch and the NEXT park earns its
        # own surface. Unlike the pause bookkeeping below there is no declaration to
        # weigh against the busy reading: a reconciled state is read from the crew,
        # never declared by it, so the crew rendering busy is the whole of the
        # evidence. Keyed to the busy verdict alone, so a merely changed hash on a
        # still-idle pane is untouched.
        if [ "$busy_now" -eq 0 ]; then
          clear_reconciled_tracking "$key"
        fi
        # Pause bookkeeping is NOT dropped here. A busy reading is one poll's
        # rendered verdict, while the declaration on the log is the crew's own
        # standing statement of why it is idle; dropping the cadence (and with it
        # the re-surface throttle) on a busy flap is what let a declared wait
        # re-surface as a bare stale minutes later. A declaration that ends drops
        # it at the top of this loop, and an authoritative working verdict drops it
        # on the stale path - the two places that actually know.
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf"
      else
        rm -f "$ssf" "$ewf"
        clear_write_tracking "$key"
      fi
      # Same rule as the unchanged-hash reset above: the busy verdict ends the
      # reconciled stretch, the changed hash on its own does not.
      if [ "$busy_now" -eq 0 ]; then
        clear_reconciled_tracking "$key"
      fi
      task=$(window_to_task "$w" "$STATE")
      # A new hash under a standing declaration is reclassified, never cleared on
      # the busy reading alone: an idle pane that merely redrew is the same
      # declared wait, and only an authoritative working verdict proves the crew
      # left it. The reclassification itself stays behind the idle reading so a
      # busy pane never pays a crew-state read every poll; a busy pane's own
      # declaration is reclassified on the stale path once it goes quiet.
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" \
        && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused)  handle_paused_stale "$w" "$task" "$h" ;;
          working) clear_pause_tracking "$key" ;;
          *)       : ;;
        esac
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
