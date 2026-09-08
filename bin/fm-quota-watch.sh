#!/usr/bin/env bash
# fm-quota-watch.sh - detect, record, and resume provider quota refusals.
#
# Usage:
#   fm-quota-watch.sh scan
#
# `scan` is an adjunct to the existing watcher poll loop, not a watcher, daemon,
# or vendor client of its own. It self-throttles to one evaluation per
# FM_QUOTA_SCAN_INTERVAL (default 300) per home. bin/fm-quota-lib.sh owns that
# cadence and its marker, so the watcher poll can ask whether a scan is due
# without paying to start one. That cadence is the only entry: there is no mode
# that bypasses it, so nothing invites a second scan alongside the poll's own.
#
# It prints one short line per event a supervisor must know about and prints
# NOTHING otherwise, exactly like bin/fm-inactive-reconcile.sh: a quiet fleet
# never wakes anyone. bin/fm-quota-lib.sh owns every contract this script
# applies - what counts as evidence, how a provider is attributed, what a wait
# record means, and why one nudge per reset is a property of the record.
#
# WHAT IT DOES, in the order it does it:
#
#   1. Attributes each recorded worker to a provider, and reads quota-axi once
#      for the whole set rather than once per worker.
#   2. For a worker whose provider is refusing service and whose own state shows
#      an unexplained idle pane behind a live agent, records a bounded wait
#      carrying that provider's reset time. bin/fm-watch.sh then absorbs that
#      pane on the bounded recheck cadence instead of escalating it as a possible
#      wedge.
#   3. When the reset time arrives, sends that worker EXACTLY ONE resume, and
#      then retires the wait so ordinary supervision owns the pane again.
#
# WHY THE RESUME IS DELIVERED HERE. The incident this exists for parked every
# worker AND every mate at once, because they all draw on one account. Anything
# that needs a firstmate turn to fire is parked with them, which is precisely
# how a quota window that reset in the morning still cost the fleet a day and a
# half. The poll loop is the one participant that keeps running when the models
# stop answering, so the resume is delivered from here.
#
# THE RESUME IS NEVER BLIND. A resume sent into a worker that is actually
# mid-task, or into one that is idle by design, is worse than sending nothing, so
# before any text is delivered the worker's state must be positively classified
# from three independent machine reads, all of which must agree: the endpoint
# reports an agent alive, the semantic busy contract reports exactly `idle`, and
# the authoritative crew state offers no explanation of its own for that idleness
# - not working, and equally not paused, parked at a decision, or done. Anything
# unreadable, ambiguous, or contradictory refuses the resume, retires the wait,
# and lets the ordinary stale path escalate the pane. That is also what keeps a
# remotely placed secondmate - an endpoint this home cannot probe at all - from
# ever being nudged from here.
#
# IT DOES NOT MAKE THE ALARM QUIETER. A recorded wait suppresses nothing except
# the wedge reading of one idle pane, it carries its own deadline, and it
# retires itself when that deadline passes whether or not anything improved. A
# worker that does not resume after its nudge is escalated by the ordinary stale
# path exactly as it would have been with none of this present.
#
# This script never interrupts, restarts, signals, or tears down a worker, and
# never touches a project worktree.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# The endpoint, busy-state, and crew-state owners this scan reads its three
# independent state signals from. Source analysis stops here, the same way
# bin/fm-watch.sh stops at its own transition owner: each of these is already a
# canonical, source-aware root of the same lint run, so following their combined
# graph from here can exceed the bounded lint worker while adding no uncovered
# file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-quota-lib.sh
. "$SCRIPT_DIR/fm-quota-lib.sh"

FM_QUOTA_TAB=$(printf '\t')
SEND_BIN="${FM_QUOTA_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
# The one resume text. A single line, plain English, and deliberately free of
# fleet vocabulary: it is read by a worker that has lost no context at all and
# only needs to be told the wait is over.
FM_QUOTA_RESUME_TEXT=${FM_QUOTA_RESUME_TEXT:-'The provider usage limit that stopped your last turn has reset - continue the task you were working on from where it stopped.'}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

# Every meta in this home that records an endpoint, as "<id>\t<meta>".
recorded_tasks() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ -n "$(fm_backend_target_of_meta "$meta")" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\t%s\n' "$id" "$meta"
  done
}

# 0 when the pane classifies EXACTLY idle through the semantic busy contract.
# unknown, busy, and dead all return 1, because this is the gate that decides
# whether a worker is sitting refused or is in the middle of a turn, and only a
# positive idle reading answers that question.
task_is_idle() {  # <id> <meta>
  local id=$1 meta=$2 verdict
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE" 2>/dev/null) || return 1
  [ "${verdict%% *}" = idle ]
}

task_agent_alive() {  # <meta>
  local target verdict
  target=$(fm_backend_target_of_meta "$1")
  [ -n "$target" ] || return 1
  verdict=$(fm_backend_agent_alive "$(fm_backend_of_meta "$1")" "$target" 2>/dev/null) || return 1
  [ "$verdict" = alive ]
}

# 0 when the worker's own authoritative state does NOT already explain why its
# pane is idle. A crew that declared an external-wait pause, is parked at a
# decision, is done, or is working was never refused a turn: it is idle by
# design. Recording a quota wait for such a worker would park something that was
# not stuck and, at the reset, push a resume past the very gate it was holding.
# Only `none` - no declared explanation at all - is the shape a refused turn
# leaves behind, so only `none` may be recorded as a refusal.
#
# The crew verdict alone is not that shape: crew_absorb_class collapses blocked
# and failed into `none` too, so the worker's own last status line is read as
# well. A declared blocker is an answer the worker is waiting for, not a turn the
# provider refused.
task_idleness_unexplained() {  # <id>
  [ "$(crew_absorb_class "$1")" = none ] || return 1
  ! fm_quota_status_owed_to_captain "$(last_status_line "$STATE/$1.status")"
}

task_capture() {  # <meta>
  local target
  target=$(fm_backend_target_of_meta "$1")
  [ -n "$target" ] || return 1
  fm_backend_capture "$(fm_backend_of_meta "$1")" "$target" 40 2>/dev/null
}

# --- detection --------------------------------------------------------------

# Record a structural wait for a worker whose provider is refusing service.
# An exhausted account does not mean THIS worker was refused, only that it would
# be if it asked, so the same three state gates the banner path uses are required
# here too: the endpoint must report a live agent (a dead one is the case
# bin/fm-watch.sh's demand-deep-inspection escalation owns, and a wait must never
# absorb it), the pane must classify exactly idle rather than mid-turn, and the
# worker's own state must not already explain that idleness.
detect_structural() {  # <id> <meta> <provider> <reset-epoch|unknown>
  local id=$1 meta=$2 provider=$3 reset=$4 harness fp
  case "$reset" in
    ''|unknown|*[!0-9]*)
      # quota-axi verified the refusal but named no reset this code can read:
      # the scope carried no limiting window, or that window carried no
      # resetsAt. The VERDICT stays structural - the account was machine-read as
      # refusing - and the rendered notice is consulted for the RESET TIME
      # ALONE, never for whether there is a refusal - a deliberate division,
      # because removing it returns to recording nothing for an account known to
      # be refused, which is the reported 38-hour park. When the notice states
      # none either, the wait is still recorded with an unknown reset and expires
      # on the short bound.
      reset=$(fm_quota_banner_reset_epoch "$(task_capture "$meta")") || reset=
      reset=${reset:-unknown}
      ;;
    *)
      # A refusal whose stated reset is already in the past is contradictory
      # evidence, not a wait: there is nothing left to wait for, so the pane
      # belongs to ordinary escalation rather than to a bounded wait that can
      # never clear.
      [ "$reset" -gt "$(date +%s)" ] || return 1
      ;;
  esac
  fp=$(fm_quota_fingerprint structural "$provider" "$reset")
  fm_quota_fingerprint_unspent "$STATE" "$id" "$fp" || return 1
  task_agent_alive "$meta" || return 1
  task_is_idle "$id" "$meta" || return 1
  task_idleness_unexplained "$id" || return 1
  harness=$(fm_meta_get "$meta" harness) || harness=
  fm_quota_wait_write "$STATE" "$id" "$provider" "$harness" "$reset" structural "$fp" || return 1
  case "$reset" in
    ''|unknown|*[!0-9]*)
      printf 'quota-limit: %s is waiting on %s, which states no reset time, so this worker is NOT resumed automatically\n' \
        "$id" "$provider"
      ;;
    *)
      printf 'quota-limit: %s is waiting on %s, resets %s\n' \
        "$id" "$provider" "$(fm_quota_format_reset "$reset")"
      ;;
  esac
}

# Record a banner-corroborated wait for a worker whose provider could not be
# read structurally. Several signals must agree, and all but one of them are
# machine reads rather than rendered text, so no single vendor string carries
# this.
detect_banner() {  # <id> <meta> <provider>
  local id=$1 meta=$2 provider=$3 text reset harness fp
  text=$(task_capture "$meta") || return 1
  fm_quota_banner_matches "$text" || return 1
  fp=$(fm_quota_fingerprint banner "${provider:-unattributed}" "$(fm_quota_banner_signature "$text")")
  fm_quota_fingerprint_unspent "$STATE" "$id" "$fp" || return 1
  task_agent_alive "$meta" || return 1
  task_is_idle "$id" "$meta" || return 1
  task_idleness_unexplained "$id" || return 1
  reset=$(fm_quota_banner_reset_epoch "$text")
  harness=$(fm_meta_get "$meta" harness) || harness=
  fm_quota_wait_write "$STATE" "$id" "${provider:-unattributed}" "$harness" \
    "${reset:-unknown}" banner "$fp" || return 1
  printf 'quota-limit: %s reports a provider limit on the %s runtime and account headroom could not be read; %s\n' \
    "$id" "${harness:-unknown}" \
    "$(if [ -n "$reset" ]; then printf 'resets %s' "$(fm_quota_format_reset "$reset")"; else printf 'no reset time was stated, so this waits without an automatic resume'; fi)"
}

# --- resume -----------------------------------------------------------------

# Print the reason a resume must not be delivered, or nothing when all three
# independent state reads agree the worker is parked and safe to nudge.
resume_refusal() {  # <id> <meta>
  local id=$1 meta=$2
  task_agent_alive "$meta" || { printf 'its endpoint no longer reports a live agent'; return 0; }
  task_is_idle "$id" "$meta" || { printf 'its current state could not be read as idle'; return 0; }
  case "$(crew_absorb_class "$id")" in
    none) ;;
    working) printf 'it is working again already'; return 0 ;;
    # A worker that has since declared a pause, reached a decision gate, or
    # finished is idle by design. Whatever it is holding, it is not this wait.
    *) printf 'its own recorded state already explains why it is idle'; return 0 ;;
  esac
  ! fm_quota_status_owed_to_captain "$(last_status_line "$STATE/$id.status")" ||
    { printf 'it is holding a declaration the captain has not answered'; return 0; }
}

# Deliver the one resume for this reset, or explain why it was not delivered.
# Either way the wait retires: the pane goes back to ordinary supervision, so a
# resume that does not restart real progress still escalates as a stale pane.
# End a wait: spend its evidence fingerprint so the same evidence cannot record
# a second one, then retire the record so ordinary supervision owns the pane.
end_wait() {  # <id>
  fm_quota_spend_fingerprint "$STATE" "$1" "$(fm_quota_wait_field "$STATE" "$1" fp)" || true
  fm_quota_wait_clear "$STATE" "$1"
}

resume_task() {  # <id> <meta> <reset-epoch>
  local id=$1 meta=$2 reset=$3 provider probe_dir status current_status refusal rc
  provider=$(fm_quota_wait_field "$STATE" "$id" provider)
  # Re-read the account before resuming. An account still refusing at its own
  # stated reset ends this wait rather than moving its deadline: a record carries
  # ONE deadline and retires at it whether or not anything improved, and if the
  # refusal is real the next detection records a new wait on fresh evidence.
  if [ -n "$provider" ] && [ "$provider" != unattributed ]; then
    # The one moment where a cached headroom reading is not good enough. Every
    # other caller can tolerate an answer up to FM_QUOTA_PROBE_TTL old, but this
    # one decides whether to send text into a live worker, and a cached refusal
    # here would defer a resume that is actually due by a whole interval.
    #
    # It reads into a snapshot of its own. The scan's shared snapshot is what
    # every later worker in this same scan reads its account from, and a forced
    # re-read that times out discards the snapshot it was asked to replace - so
    # writing this answer there would cost those workers the structural evidence
    # that was already read for them seconds earlier.
    probe_dir=$(mktemp -d "$STATE/.quota-probe-resume.XXXXXX" 2>/dev/null) || probe_dir=
    status='unknown	unknown'
    if [ -n "$probe_dir" ]; then
      FM_QUOTA_PROBE_TTL=0 fm_quota_probe_refresh "$probe_dir" "$provider" >/dev/null 2>&1 || true
      status=$(fm_quota_provider_status "$probe_dir" "$provider")
      rm -rf "$probe_dir"
    fi
    current_status=$(printf '%s' "$status" | cut -f1)
    if [ "$current_status" = exhausted ]; then
      end_wait "$id"
      printf 'quota-limit: %s is still refused by %s after its stated reset; the ordinary check is back on this worker\n' \
        "$id" "$provider"
      return 0
    fi
  fi
  refusal=$(resume_refusal "$id" "$meta")
  if [ -n "$refusal" ]; then
    end_wait "$id"
    printf 'quota-limit: %s was not resumed automatically because %s; the ordinary check is back on this worker\n' \
      "$id" "$refusal"
    return 0
  fi
  # Claim the spend BEFORE delivering it. A crash between the two costs one
  # missed resume, which the ordinary stale path escalates; the other order
  # would cost an unbounded resend loop into a live worker.
  fm_quota_nudge_claim "$STATE" "$id" "$reset"
  rc=$?
  case "$rc" in
    0) ;;
    1) end_wait "$id"; return 0 ;;
    *) return 0 ;;
  esac
  end_wait "$id"
  rc=0
  # Delivered to the recorded backend target rather than the task selector. A
  # resume is not a request and no reply is owed for it, and bin/fm-send.sh
  # arms a durable parent pending-reply expectation - with its own recovery
  # resend and escalation - for a SELECTOR that resolves to a secondmate. The
  # explicit target is that file's documented unmarked form, so one nudge stays
  # one nudge for a mate exactly as it does for a worker.
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SEND_BIN" "$(fm_backend_target_of_meta "$meta")" "$FM_QUOTA_RESUME_TEXT" \
    >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'quota-limit: %s was resumed automatically now that its provider limit has reset\n' "$id"
  else
    printf 'quota-limit: %s could not be resumed automatically after its provider limit reset; check that worker\n' "$id"
  fi
}

# --- scan -------------------------------------------------------------------

scan_once() {
  local id meta provider providers='' status state_token reset entry
  local -a rows=()
  while IFS=$(printf '\t') read -r id meta; do
    [ -n "$id" ] || continue
    provider=$(fm_quota_provider_for_meta "$STATE" "$meta")
    rows+=("$id$FM_QUOTA_TAB$meta$FM_QUOTA_TAB$provider")
    [ -n "$provider" ] || continue
    case ",$providers," in *",$provider,"*) continue ;; esac
    providers="${providers:+$providers,}$provider"
  done < <(recorded_tasks)
  [ "${#rows[@]}" -gt 0 ] || return 0
  [ -z "$providers" ] || fm_quota_probe_refresh "$STATE" "$providers" >/dev/null 2>&1 || true

  for entry in "${rows[@]}"; do
    id=${entry%%"$FM_QUOTA_TAB"*}
    meta=${entry#*"$FM_QUOTA_TAB"}
    provider=${meta#*"$FM_QUOTA_TAB"}
    meta=${meta%%"$FM_QUOTA_TAB"*}
    if [ -s "$(fm_quota_wait_path "$STATE" "$id")" ]; then
      if fm_quota_wait_resume_due "$STATE" "$id"; then
        resume_task "$id" "$meta" "$(fm_quota_wait_field "$STATE" "$id" reset)"
      elif ! task_agent_alive "$meta"; then
        # The absorb in bin/fm-watch.sh runs ahead of that loop's liveness read
        # on purpose, so this scan is the only place a wait that started over a
        # live agent can notice the agent has since died. Without this, the
        # dead-endpoint demand-deep-inspection escalation stays absorbed until
        # the reset, which is hours. The evidence fingerprint is deliberately NOT
        # spent: nothing about the refusal was resolved, so an endpoint that
        # comes back can earn its wait again.
        fm_quota_wait_clear "$STATE" "$id"
        printf 'quota-limit: the recorded wait on %s was retired because its endpoint no longer reports a live agent; the ordinary check is back on this worker\n' "$id"
      elif ! fm_quota_wait_active "$STATE" "$id"; then
        end_wait "$id"
        printf 'quota-limit: the recorded wait on %s expired without a usable reset time; the ordinary check is back on this worker\n' "$id"
      fi
      continue
    fi
    state_token=unknown
    reset=unknown
    if [ -n "$provider" ]; then
      status=$(fm_quota_provider_status "$STATE" "$provider")
      state_token=$(printf '%s' "$status" | cut -f1)
      reset=$(printf '%s' "$status" | cut -f2)
    fi
    case "$state_token" in
      exhausted)
        detect_structural "$id" "$meta" "$provider" "$reset" || true
        ;;
      available)
        # The vendor says this account has headroom. A rendered limit notice is
        # not allowed to override that; the banner is a fallback for missing
        # evidence, never a second opinion about evidence that exists.
        :
        ;;
      *)
        detect_banner "$id" "$meta" "$provider" || true
        ;;
    esac
  done
}

cmd_scan() {
  mkdir -p "$STATE" 2>/dev/null || true
  fm_quota_scan_due "$STATE" || return 0
  fm_quota_scan_defer "$STATE"
  scan_once
}

case "${1:-}" in
  scan) cmd_scan ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
