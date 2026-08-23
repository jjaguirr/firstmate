#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'done: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_active_run_step_suppresses_only_a_decision_the_crew_progressed_past() {
  local dir state out fakebin
  dir=$(make_case active-run-supersession)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/drain.out"
  fm_write_meta "$state/task9.meta" "window=sess:fm-task9" "kind=ship"
  {
    printf 'needs-decision [key=rollout]: choose the deployment path\n'
    printf 'needs-decision [key=schema]: pick the schema\n'
    printf 'working [key=rollout]: resumed validation after the rollout answer\n'
    printf 'working [key=tests]: adding coverage while waiting\n'
    printf 'working: keyless routine note\n'
    printf 'blocked [key=creds]: need the staging secret\n'
  } > "$state/task9.status"

  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" \
    || fail "drain failed while reconciling an active run-step"
  if grep -F '[key=rollout]' "$out" >/dev/null; then
    fail "a decision the crew progressed past still surfaced under an active run-step: $(cat "$out")"
  fi
  grep -F 'task9 [key=creds] blocked: need the staging secret' "$out" >/dev/null \
    || fail "a blocker raised mid-run was hidden by the active run-step: $(cat "$out")"
  grep -F 'task9 [key=schema] needs-decision: pick the schema' "$out" >/dev/null \
    || fail "unrelated or keyless progress lines superseded an untouched key: $(cat "$out")"

  FM_FAKE_CREW_STATE='state: working · source: pane · rendered activity only' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" \
    || fail "drain failed while checking pane-only activity"
  grep -F 'task9 [key=rollout] needs-decision: choose the deployment path' "$out" >/dev/null \
    || fail "pane activity incorrectly closed a decision: $(cat "$out")"
  grep -F 'task9 [key=creds] blocked: need the staging secret' "$out" >/dev/null \
    || fail "pane activity hid the mid-run blocker: $(cat "$out")"
  pass "OPEN DECISIONS hides only a key an authoritative active run-step superseded, never a mid-run blocker"
}

# The drain's own presentation reads run before the OPEN DECISIONS fold, so
# the fake span reader below serves those honestly and fails only the
# reconciliation's re-read (the third and last span read of a drain); the
# surfaced warning proves that read, not an earlier one, is what failed.
test_reserved_key_stays_presented_under_a_foreign_progress_line_and_empty_sets_skip_the_state_read() {
  local dir state out reader calls
  dir=$(make_case active-run-reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  reader="$dir/counting-crew-state.sh"
  calls="$dir/crew-state-calls"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FAKE_CREW_STATE_CALLS"
printf 'state: working · source: run-step · ci running\n'
SH
  chmod +x "$reader"
  fm_write_meta "$state/task11.meta" "window=sess:fm-task11" "kind=ship"
  {
    printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n'
    printf 'working [key=pending-reply-abcdef0123456789]: retrying delivery\n'
  } > "$state/task11.status"
  fm_write_meta "$state/task12.meta" "window=sess:fm-task12" "kind=ship"
  printf 'needs-decision [key=gone]: pick one\nresolved [key=gone]: picked\n' > "$state/task12.status"

  FM_FAKE_CREW_STATE_CALLS="$calls" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$reader" "$DRAIN" > "$out" \
    || fail "drain failed over a reserved key and an empty durable set"
  grep -F 'task11 [key=pending-reply-abcdef0123456789] blocked: pending-reply-missed:' "$out" >/dev/null \
    || fail "a foreign same-key progress line superseded a reserved key in OPEN DECISIONS: $(cat "$out")"
  if grep -F 'task12' "$out" >/dev/null; then
    fail "a durably resolved key surfaced: $(cat "$out")"
  fi
  [ "$(cat "$calls")" = task11 ] \
    || fail "the current-state read ran for a task with an empty durable set, or not for the open one: $(cat "$calls")"
  pass "OPEN DECISIONS keeps a reserved key open against foreign progress and reads state only for non-empty sets"
}

test_reconcile_re_read_failure_keeps_the_decision_presented() {
  local dir state out err fakebin span calls
  dir=$(make_case active-run-read-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/drain.out"
  err="$dir/drain.err"
  span="$dir/flaky-span-reader"
  calls="$dir/span-calls"
  fm_write_meta "$state/task10.meta" "window=sess:fm-task10" "kind=ship"
  printf 'needs-decision [key=rollout]: choose the deployment path\nworking [key=rollout]: resumed\n' > "$state/task10.status"
  cat > "$span" <<'SH'
#!/usr/bin/env bash
set -u
n=$(( $(cat "$FM_FAKE_SPAN_CALLS" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$FM_FAKE_SPAN_CALLS"
[ "$n" -ne "${FM_FAKE_SPAN_FAIL_CALL:-1}" ] || exit 1
tail -c +$(( $2 + 1 )) "$1" | head -c "$3"
SH
  chmod +x "$span"

  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" \
    || fail "seeding drain failed"
  grep -F 'task10 [key=rollout]' "$out" >/dev/null || fail "precondition: the durable decision did not surface: $(cat "$out")"

  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_STATUS_SPAN_READER="$span" FM_FAKE_SPAN_CALLS="$calls" FM_FAKE_SPAN_FAIL_CALL=3 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" 2>"$err" \
    || fail "drain failed instead of keeping the decision when its re-read failed"
  [ "$(cat "$calls")" = 3 ] || fail "the reconciliation re-read was not the failing read: $(cat "$calls") span read(s)"
  grep -F 'task10 [key=rollout] needs-decision: choose the deployment path' "$out" >/dev/null \
    || fail "a failed re-read dropped a durable decision under an active run: $(cat "$out")"
  grep -F 'could not re-read' "$err" >/dev/null || fail "the re-read failure was not surfaced: $(cat "$err")"

  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" \
    || fail "drain after the re-read recovered failed"
  if grep -F '[key=rollout]' "$out" >/dev/null; then
    fail "a witnessed key stayed presented once the re-read recovered: $(cat "$out")"
  fi
  pass "a status re-read failure keeps the decision presented and reports itself"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_active_run_step_suppresses_only_a_decision_the_crew_progressed_past
test_reserved_key_stays_presented_under_a_foreign_progress_line_and_empty_sets_skip_the_state_read
test_reconcile_re_read_failure_keeps_the_decision_presented
test_status_symlink_is_not_followed
