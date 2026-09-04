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

# The per-drain path carries its witness set in the same cursor as its durable
# set, so the active-run verdict is answered from folded state instead of a
# whole-log re-read. This pins the consequence: a span read that fails outright
# advances neither set, is announced on stderr rather than leaving a wedged
# reader indistinguishable from a quiet fleet, and the unread delta is still
# folded once the read recovers.
test_carried_witness_state_survives_a_read_failure() {
  local dir state out err fakebin reader cursor before after
  dir=$(make_case active-run-read-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/drain.out"
  reader="$dir/fail-reader"
  cursor="$state/.task10.open-decisions-cursor"
  fm_write_meta "$state/task10.meta" "window=sess:fm-task10" "kind=ship"
  printf 'needs-decision [key=rollout]: choose the deployment path\nworking [key=rollout]: resumed\n' > "$state/task10.status"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" \
    || fail "seeding drain failed"
  grep -F 'task10 [key=rollout]' "$out" >/dev/null || fail "precondition: the durable decision did not surface: $(cat "$out")"

  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" \
    || fail "drain under an active run failed"
  [ ! -s "$out" ] || fail "precondition: the witnessed key was not superseded: $(cat "$out")"
  before=$(LC_ALL=C cksum "$cursor")

  printf 'blocked [key=creds]: need the staging secret\n' >> "$state/task10.status"
  err="$dir/drain.err"
  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_STATUS_SPAN_READER="$reader" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" 2>"$err" \
    || fail "drain failed instead of preserving carried fold state when its read failed"
  [ ! -s "$out" ] || fail "a failed read emitted a partial presentation: $(cat "$out")"
  grep -F 'could not read' "$err" >/dev/null \
    || fail "the drain froze its open-decisions fold silently: $(cat "$err")"
  after=$(LC_ALL=C cksum "$cursor")
  [ "$after" = "$before" ] || fail "a failed read advanced or rewrote the carried fold state"

  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" \
    || fail "drain after the read recovered failed"
  grep -F 'task10 [key=creds] blocked: need the staging secret' "$out" >/dev/null \
    || fail "the mid-run blocker held back by the failed read never surfaced: $(cat "$out")"
  if grep -F '[key=rollout]' "$out" >/dev/null; then
    fail "the witnessed key resurfaced once the read recovered: $(cat "$out")"
  fi

  FM_FAKE_CREW_STATE='state: parked · source: run-step · awaiting captain decision' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$DRAIN" > "$out" \
    || fail "drain after the run parked failed"
  grep -F 'task10 [key=rollout] needs-decision: choose the deployment path' "$out" >/dev/null \
    || fail "the durable decision did not return once the run parked: $(cat "$out")"
  pass "carried witness state survives a read failure and keeps the verdict stable"
}

# fm-crew-state.sh is NOT a pure read (a bounded no-mistakes call, git reads, a
# pane capture), and $STATE/.status-presentation-lock is fleet-wide and acquired
# by an unbounded spin, so running that reader under it would let one wedged
# no-mistakes daemon stall every other drain in this home. The drain warms every
# verdict it can need before taking that lock and then seals the memo, so the
# reader can never run under it - including on the FIRST drain that sees a newly
# opened decision, which is exactly when the section matters. The stub below
# reports whether the lock symlink existed at the moment it ran.
test_current_state_read_is_hoisted_out_of_the_presentation_lock() {
  local dir state out reader log
  dir=$(make_case state-read-outside-lock)
  state="$dir/state"
  out="$dir/drain.out"
  reader="$dir/lock-probing-crew-state.sh"
  log="$dir/lock-held.log"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
if [ -L "$FM_STATE_OVERRIDE/.status-presentation-lock" ]; then
  printf '%s\theld\n' "$1" >> "$FM_LOCK_PROBE_LOG"
else
  printf '%s\tfree\n' "$1" >> "$FM_LOCK_PROBE_LOG"
fi
printf 'state: working · source: run-step · ci running\n'
SH
  chmod +x "$reader"
  fm_write_meta "$state/task20.meta" "window=sess:fm-task20" "kind=ship"
  printf 'needs-decision [key=rollout]: choose the deployment path\n' > "$state/task20.status"

  # First sighting: no cursor exists yet, so this is the case an
  # already-persisted open set could not have warmed.
  FM_LOCK_PROBE_LOG="$log" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$reader" "$DRAIN" > "$out" \
    || fail "first-sighting drain failed"
  grep -F 'task20 [key=rollout] needs-decision: choose the deployment path' "$out" >/dev/null \
    || fail "precondition: the open decision did not surface: $(cat "$out")"
  [ "$(cat "$log")" = "$(printf 'task20\tfree')" ] \
    || fail "the first-sighting drain read the crew state inside the presentation lock: $(cat "$log")"

  # A decision opened AFTER a drain that saw nothing open: the persisted cursor
  # says the set is empty, so only a gate that folds the new appends can warm it.
  fm_write_meta "$state/task21.meta" "window=sess:fm-task21" "kind=ship"
  printf 'working: nothing open yet\n' > "$state/task21.status"
  FM_LOCK_PROBE_LOG="$log" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$reader" "$DRAIN" > "$out" \
    || fail "drain over a task with no open decision failed"
  : > "$log"
  printf 'needs-decision [key=schema]: pick the schema\n' >> "$state/task21.status"
  FM_LOCK_PROBE_LOG="$log" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$reader" "$DRAIN" > "$out" \
    || fail "drain over a newly opened decision failed"
  grep -F 'task21 [key=schema] needs-decision: pick the schema' "$out" >/dev/null \
    || fail "the newly opened decision did not surface: $(cat "$out")"
  if grep -F $'\theld' "$log" >/dev/null; then
    fail "a newly opened decision read the crew state inside the presentation lock: $(cat "$log")"
  fi
  [ "$(grep -Fc 'task21' "$log")" = 1 ] \
    || fail "the newly opened decision's verdict was not read exactly once: $(cat "$log")"
  pass "the drain reads a crew's current state once per drain and never inside the presentation lock"
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

test_default_key_is_disclosed_and_a_mid_note_key_token_is_neutralised() {
  local dir state out line
  dir=$(make_case default-key-disclosure)
  state="$dir/state"
  out="$dir/drain.out"
  # A crewmate wrote its key token mid-note instead of a documented key
  # position, so the fold reads it as an unkeyed ("default") decision. The
  # note still carries the stray "[key=...]" token verbatim. The presented
  # entry must disclose the real, answerable key ("default") and must not
  # leave the stray token in a key-shaped form, or an operator answering with
  # the only key-shaped text visible gets refused by bin/fm-send.sh.
  printf 'needs-decision: two findings [key=persea-irrigation-sse-robustness]. (1) terminal-after-61s: retry\n' \
    > "$state/task-stray.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a mid-note key token"

  line=$(grep -F 'task-stray' "$out")
  case "$line" in
    *'[key=default]'*) : ;;
    *) fail "the default key was not disclosed: $line" ;;
  esac
  case "$line" in
    *'[key=persea-irrigation-sse-robustness]'*) fail "the stray mid-note token still reads as a key: $line" ;;
  esac
  case "$line" in
    *'(key=persea-irrigation-sse-robustness)'*) : ;;
    *) fail "the stray mid-note token's information was dropped rather than neutralised: $line" ;;
  esac
  # Answerable: bin/fm-send.sh must accept the exact key the listing disclosed.
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "the answerer-closes hint is missing"
  pass "a default-keyed decision discloses its answerable key and neutralises a stray mid-note key token"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_default_key_is_disclosed_and_a_mid_note_key_token_is_neutralised
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_active_run_step_suppresses_only_a_decision_the_crew_progressed_past
test_reserved_key_stays_presented_under_a_foreign_progress_line_and_empty_sets_skip_the_state_read
test_carried_witness_state_survives_a_read_failure
test_status_symlink_is_not_followed
test_current_state_read_is_hoisted_out_of_the_presentation_lock
