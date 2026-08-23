#!/usr/bin/env bash
# tests/fm-classify-decision-key.test.sh - decision-key position tolerance in
# the open-decisions fold (bin/fm-classify-lib.sh). A "[key=<slug>]" token is
# documented between the verb and the colon (needs-decision [key=x]: note), but
# workers commonly write the colon first (needs-decision: [key=x] note); that
# stated key must be honored, never silently folded into the shared "default"
# bucket where an answer can close the wrong record (issue #2109). Also covers
# status_line_verb's bracket-tag stripping: a remote secondmate reply prepends
# a "[corr=...]" correlation tag before (or without) "[key=...]", and every
# such tag before the colon must be stripped so the leading word is the bare
# verb, regardless of order or count. These tests drive the REAL
# status_line_verb / status_open_decisions / status_open_decisions_incremental
# functions over crafted status files and assert their folded output, never the
# fold's own source text. Also covers status_key_closing_verb, which reports how
# the status side currently reads one key so a consumer can tell a settled key
# from one handed to a durable captain-held task (bin/fm-captain-hold.sh
# diverged). Cross-drain cursor persistence and the incremental
# cost bound live in tests/fm-wake-drain-open-decisions-cursor.test.sh; the
# drain wiring lives in tests/fm-wake-drain-open-decisions.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-decision-key-tests)

# Fresh per-case dir so each case's incremental cursor sidecar cannot leak into
# another case.
case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Assert the whole-file fold of <status-file> equals <expected>, and that the
# incremental fold agrees with it on the exact same input - the two consumption
# strategies must never diverge on what is open.
assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
}

test_stated_key_is_honored_in_both_positions() {
  local dir before after expected
  dir=$(case_dir positions)
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/before.status"
  printf 'needs-decision: [key=api-shape] pick REST or RPC\n' > "$dir/after.status"
  expected=$(printf 'api-shape\tneeds-decision\tpick REST or RPC\n')

  assert_fold "$dir/before.status" "$expected" "documented before-colon form"
  assert_fold "$dir/after.status" "$expected" "colon-first form"

  # Equivalence is byte-for-byte: both positions yield the same key AND the
  # same note (a consumed note-head token is key metadata, not note text).
  before=$(status_open_decisions "$dir/before.status")
  after=$(status_open_decisions "$dir/after.status")
  [ "$before" = "$after" ] \
    || fail "the two key positions folded to different records: '$before' vs '$after'"
  pass "a stated [key=X] opens X whether it precedes or follows the verb colon"
}

test_bare_keyless_line_still_folds_to_default() {
  local dir
  dir=$(case_dir keyless)
  printf 'needs-decision: which color\n' > "$dir/bare.status"
  assert_fold "$dir/bare.status" "$(printf 'default\tneeds-decision\twhich color\n')" \
    "bare keyless line"

  # And a bare keyless resolution still closes it - the historical
  # one-open-decision-per-task behavior is unchanged.
  printf 'resolved: went with blue\n' >> "$dir/bare.status"
  assert_fold "$dir/bare.status" "" "bare keyless resolution"
  pass "a keyless needs-decision still opens and closes the default key"
}

test_resolution_closes_across_positions() {
  local dir
  dir=$(case_dir cross-close)
  # Opened colon-first, closed in the documented form (what fm-send's
  # --resolve-key writes): the exact failure from issue #2109.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$dir/a.status"
  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$dir/a.status"
  assert_fold "$dir/a.status" "" "documented resolution closing a colon-first open"

  # And the mirror: opened documented, closed colon-first.
  printf 'needs-decision [key=seam-max-bound]: pick the bound\n' > "$dir/b.status"
  printf 'resolved: [key=seam-max-bound] answered: use 4\n' >> "$dir/b.status"
  assert_fold "$dir/b.status" "" "colon-first resolution closing a documented open"
  pass "a resolution closes its decision regardless of either line's key position"
}

test_blocked_is_position_tolerant_like_needs_decision() {
  local dir expected
  dir=$(case_dir blocked)
  expected=$(printf 'creds\tblocked\twaiting on the deploy token\n')
  printf 'blocked [key=creds]: waiting on the deploy token\n' > "$dir/before.status"
  printf 'blocked: [key=creds] waiting on the deploy token\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "$expected" "documented blocked form"
  assert_fold "$dir/after.status" "$expected" "colon-first blocked form"
  pass "blocked [key=X] opens X in both key positions"
}

test_two_colon_form_decisions_stay_distinct() {
  local dir expected
  dir=$(case_dir distinct)
  # The concrete hazard behind the silent collapse: two colon-form decisions on
  # one task used to share the default bucket, so answering one could close the
  # other. They must stay independently open and independently closable.
  printf 'needs-decision: [key=alpha] first question\n' > "$dir/t.status"
  printf 'needs-decision: [key=beta] second question\n' >> "$dir/t.status"
  expected=$(printf 'alpha\tneeds-decision\tfirst question\nbeta\tneeds-decision\tsecond question\n')
  assert_fold "$dir/t.status" "$expected" "two colon-form decisions"

  printf 'resolved [key=alpha]: answered: yes\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "$(printf 'beta\tneeds-decision\tsecond question\n')" \
    "closing one of two colon-form decisions"
  pass "two colon-form keyed decisions never collapse into one shared bucket"
}

test_mid_note_prose_mention_is_not_a_stated_key() {
  local dir
  dir=$(case_dir prose)
  # Only a token at the head of the note states a key; a summary merely
  # mentioning "[key=x]" deeper in must neither open nor close that key.
  printf 'needs-decision: pick a [key=red] or [key=blue] theme\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\n')" \
    "mid-note prose mention"

  printf 'needs-decision [key=red]: which shade\n' >> "$dir/t.status"
  printf 'working: still thinking about [key=red] here\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\nred\tneeds-decision\twhich shade\n')" \
    "prose mention leaves the open set untouched"
  pass "a [key=x] mentioned mid-note is prose, never an opened or closed key"
}

test_malformed_stated_key_never_collapses_to_default() {
  local dir
  dir=$(case_dir malformed)
  # A stated-but-invalid slug is rejected in BOTH positions - identically,
  # and never rewritten into the shared default bucket.
  printf 'needs-decision [key=bad key]: before-colon malformed\n' > "$dir/before.status"
  printf 'needs-decision: [key=bad key] colon-first malformed\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "" "malformed before-colon key"
  assert_fold "$dir/after.status" "" "malformed colon-first key"
  pass "a malformed stated key is rejected in both positions, never folded as default"
}

# A remote secondmate reply routinely prepends a "[corr=<hex>]" correlation
# tag ahead of "[key=...]" (issue: a remote reply's "needs-decision
# [corr=d448ea86afa4bf67] [key=x]: ..." folded to no open decision at all,
# because the verb parser only stripped a leading "[key=...]" token and left
# the corr tag glued onto the returned verb word). These cases drive the real
# status_line_verb directly, over every bracket-tag shape that precedes the
# colon, to pin the general fix: strip EVERY "[name=value]" tag there, not
# just "[key=...]", regardless of order or count.
test_status_line_verb_strips_every_bracket_tag_before_colon() {
  local v

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-then-key tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [key=loan-installment-cadence-amount] [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "key-then-corr tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-only tag: got '$v'"

  v=$(status_line_verb 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token')
  [ "$v" = "blocked" ] || fail "blocked with corr+key: got '$v'"

  v=$(status_line_verb 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated')
  [ "$v" = "resolved" ] || fail "resolved with corr+key: got '$v'"

  pass "status_line_verb strips every bracket tag before the colon, in any order, and recovers the bare verb"
}

test_corr_and_key_tags_open_and_close_under_the_stated_key() {
  local dir expected
  dir=$(case_dir corr-and-key)
  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' \
    > "$dir/t.status"
  expected=$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')
  assert_fold "$dir/t.status" "$expected" "corr-then-key opens under the stated key"

  printf 'resolved [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: answered: monthly\n' \
    >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "corr-then-key resolution closes the same stated key"
  pass "a [corr=...] tag ahead of [key=...] no longer swallows the verb: opens and closes under the stated key"
}

test_corr_only_tag_opens_as_default_like_a_bare_line() {
  local dir bare corred
  dir=$(case_dir corr-only)
  printf 'needs-decision: which vendor\n' > "$dir/bare.status"
  printf 'needs-decision [corr=d448ea86afa4bf67]: which vendor\n' > "$dir/corred.status"

  bare=$(status_open_decisions "$dir/bare.status")
  corred=$(status_open_decisions "$dir/corred.status")
  [ "$corred" = "$bare" ] \
    || fail "a corr-only tag folded differently than the bare line: '$corred' vs '$bare'"
  assert_fold "$dir/corred.status" "$(printf 'default\tneeds-decision\twhich vendor\n')" "corr-only tag"
  pass "a [corr=...] tag with no stated key opens under 'default', exactly like a bare needs-decision line"
}

test_key_only_before_colon_still_opens_no_regression() {
  local dir
  dir=$(case_dir key-only-no-corr)
  printf 'needs-decision [key=loan-installment-cadence-amount]: pick the cadence\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')" \
    "key-only before colon, no corr tag"
  pass "a [key=x] tag alone (no corr tag) still opens x - no regression from the tag-stripping fix"
}

test_blocked_and_resolved_are_tag_order_independent() {
  local dir
  dir=$(case_dir blocked-tag-order)
  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/a.status"
  assert_fold "$dir/a.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked corr-then-key"

  printf 'blocked [key=creds] [corr=aaaa1111bbbb2222]: waiting on the deploy token\n' > "$dir/b.status"
  assert_fold "$dir/b.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked key-then-corr"

  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/c.status"
  printf 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated\n' >> "$dir/c.status"
  assert_fold "$dir/c.status" "" "blocked/resolved corr+key close together regardless of tag order"
  pass "blocked/resolved parse their bare verb with any bracket-tag order preceding the colon"
}

test_incremental_agrees_with_full_fold_across_appends() {
  local dir f expected
  dir=$(case_dir incremental)
  f="$dir/t.status"
  # assert_fold already pins incremental==full per snapshot; this case pins the
  # agreement ACROSS appends, where the incremental path folds only the new
  # bytes on top of its persisted open set while the full fold re-reads
  # everything from scratch.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\n')
  assert_fold "$f" "$expected" "colon-first open, first read"

  printf 'working: routine progress note\n' >> "$f"
  printf 'needs-decision: [key=other] a second colon-form question\n' >> "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\nother\tneeds-decision\ta second colon-form question\n')
  assert_fold "$f" "$expected" "colon-first opens buried under later appends"

  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$f"
  printf 'resolved: [key=other] cleared on its own\n' >> "$f"
  assert_fold "$f" "" "cross-position resolutions close both"
  pass "the incremental fold matches the full fold across appends in both key positions"
}

# An active no-mistakes run supersedes a task-local decision only per key: the
# key must be followed in the log by the crew's own progress line, so a blocker
# raised mid-run (after that progress, while the run is still working) stays
# open. A busy pane supersedes nothing. The current answerability wrappers must
# agree in their whole and cursor-backed forms while retaining every durable
# key so a superseded one can reappear if the run later parks.
test_active_run_step_reconciles_both_decision_folds_per_key_without_using_pane_text() {
  local dir f reader full incremental raw
  dir=$(case_dir run-step-supersession)
  f="$dir/task.status"
  reader="$dir/fake-crew-state.sh"
  fm_write_meta "$dir/task.meta" "window=sess:fm-task" "kind=ship"
  {
    printf 'needs-decision [key=rollout]: choose the deployment path\n'
    printf 'needs-decision [key=schema]: pick the schema\n'
    printf 'working [key=rollout]: resumed validation after the rollout answer\n'
    printf 'working [key=tests]: adding coverage while waiting\n'
    printf 'working: keyless routine note\n'
    printf 'blocked [key=creds]: need the staging secret\n'
  } > "$f"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_DECISION_CURRENT:-state: unknown · source: none}"
SH
  chmod +x "$reader"

  FM_FAKE_DECISION_CURRENT='state: working · source: run-step · ci running'
  FM_CREW_STATE_BIN="$reader"
  export FM_FAKE_DECISION_CURRENT FM_CREW_STATE_BIN
  full=$(status_open_decisions_for_task task "$f")
  incremental=$(status_open_decisions_incremental_for_task task "$f")
  [ "$full" = "$(printf 'schema\tneeds-decision\tpick the schema\ncreds\tblocked\tneed the staging secret\n')" ] \
    || fail "active run-step did not supersede exactly the key with its own later progress line in the whole verdict: '$full'"
  [ "$incremental" = "$full" ] \
    || fail "incremental verdict diverged from the whole verdict under run supersession: '$incremental' vs '$full'"

  raw=$(status_open_decisions "$f")
  assert_contains "$raw" $'rollout\tneeds-decision' \
    "run supersession rewrote the durable decision instead of reconciling it"
  assert_contains "$(status_open_decisions_superseded "$raw" "$full")" $'rollout\tneeds-decision' \
    "the superseded explanation did not name the key the verdict removed"

  FM_FAKE_DECISION_CURRENT='state: parked · source: run-step · parked at review'
  export FM_FAKE_DECISION_CURRENT
  full=$(status_open_decisions_for_task task "$f")
  [ "$full" = "$raw" ] \
    || fail "a parked run did not restore the whole durable set: '$full' vs '$raw'"

  FM_FAKE_DECISION_CURRENT='state: working · source: pane · rendered activity only'
  export FM_FAKE_DECISION_CURRENT
  full=$(status_open_decisions_for_task task "$f")
  incremental=$(status_open_decisions_incremental_for_task task "$f")
  [ "$full" = "$raw" ] \
    || fail "pane text incorrectly suppressed part of the decision verdict: '$full' vs '$raw'"
  [ "$incremental" = "$full" ] \
    || fail "pane-safe incremental verdict diverged from the whole verdict: '$incremental' vs '$full'"
  unset FM_FAKE_DECISION_CURRENT FM_CREW_STATE_BIN
  pass "active run-step supersession needs a same-key progress witness, is shared by both folds, and never trusts pane text"
}

# The one-shot whole-file verdict re-reads the log to build its witness set, so
# a read failure there must keep every durable key open and say so, never
# reconcile against an empty witness set. The incremental verdict has no such
# re-read - its witness set rides the same cursor as its durable set - but it
# must fail the same way: the cursor stays put, every durable key is kept open
# (nothing may be called run-superseded on evidence the call could not read),
# the failure is announced, and the held-back bytes fold once a read succeeds.
test_reconcile_re_read_failure_keeps_every_key_open() {
  local dir f reader span full incremental raw err grown
  dir=$(case_dir run-step-read-failure)
  f="$dir/task.status"
  reader="$dir/fake-crew-state.sh"
  span="$dir/fail-span-reader"
  err="$dir/stderr.log"
  fm_write_meta "$dir/task.meta" "window=sess:fm-task" "kind=ship"
  printf 'needs-decision [key=rollout]: choose the deployment path\nworking [key=rollout]: resumed\n' > "$f"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "state: working · source: run-step · ci running"\n' > "$reader"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$span"
  chmod +x "$reader" "$span"
  raw=$(status_open_decisions "$f")
  full=$(FM_CREW_STATE_BIN="$reader" status_open_decisions_for_task task "$f")
  [ -z "$full" ] || fail "precondition: a readable log did not supersede the witnessed key: '$full'"
  full=$(FM_CREW_STATE_BIN="$reader" FM_STATUS_SPAN_READER="$span" status_open_decisions_for_task task "$f" 2>"$err")
  [ "$full" = "$raw" ] || fail "a failed re-read dropped durable keys from the whole verdict: '$full' vs '$raw'"
  grep -F 'could not re-read' "$err" >/dev/null || fail "the whole verdict hid the re-read failure: $(cat "$err")"
  incremental=$(FM_CREW_STATE_BIN="$reader" status_open_decisions_incremental_for_task task "$f")
  [ -z "$incremental" ] || fail "precondition: the incremental verdict did not supersede the witnessed key: '$incremental'"
  printf 'blocked [key=creds]: need the staging secret\n' >> "$f"
  incremental=$(FM_CREW_STATE_BIN="$reader" FM_STATUS_SPAN_READER="$span" status_open_decisions_incremental_for_task task "$f" 2>"$err")
  assert_contains "$incremental" $'rollout\tneeds-decision' \
    "a failed read still reported a key as run-superseded on evidence it could not read"
  grep -F 'could not read' "$err" >/dev/null \
    || fail "a failed incremental read was silent, so a wedged reader is indistinguishable from a quiet fleet: $(cat "$err")"
  grown=$(FM_CREW_STATE_BIN="$reader" status_open_decisions_incremental_for_task task "$f")
  assert_contains "$grown" $'creds\tblocked' \
    "the append held back by the failed read never folded once the read recovered"
  case "$grown" in
    *$'rollout\t'*) fail "the witnessed key resurfaced after the read recovered: '$grown'" ;;
  esac
  pass "a read failure keeps every durable key open in both verdicts and says so"
}

# A reserved key (bin/fm-pending-reply-lib.sh's pending-reply-<id>) may only be
# witnessed by a progress line that speaks its owner's vocabulary, exactly as
# the durable fold requires of its open and close transitions; a foreign
# same-key progress line leaves it open in both verdicts under an active run.
test_reserved_key_is_not_superseded_by_a_foreign_progress_line() {
  local dir f reader full incremental raw
  dir=$(case_dir run-step-reserved-key)
  f="$dir/task.status"
  reader="$dir/fake-crew-state.sh"
  fm_write_meta "$dir/task.meta" "window=sess:fm-task" "kind=ship"
  {
    printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n'
    printf 'working [key=pending-reply-abcdef0123456789]: retrying delivery\n'
    printf 'needs-decision [key=plain]: pick one\n'
    printf 'working [key=plain]: went ahead\n'
  } > "$f"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "state: working · source: run-step · ci running"\n' > "$reader"
  chmod +x "$reader"
  raw=$(status_open_decisions "$f")
  full=$(FM_CREW_STATE_BIN="$reader" status_open_decisions_for_task task "$f")
  incremental=$(FM_CREW_STATE_BIN="$reader" status_open_decisions_incremental_for_task task "$f")
  assert_contains "$full" $'pending-reply-abcdef0123456789\tblocked' \
    "a foreign same-key progress line superseded a reserved key in the whole verdict"
  if printf '%s' "$full" | grep -F $'plain\t' >/dev/null; then
    fail "an ordinary key with its own progress line was not superseded: '$full'"
  fi
  [ "$incremental" = "$full" ] \
    || fail "incremental verdict diverged from the whole verdict on a reserved key: '$incremental' vs '$full'"
  [ "$raw" != "$full" ] || fail "precondition: the durable set should still hold the plain key: '$raw'"
  pass "a reserved key is witnessed only by its owner's vocabulary, in both folds"
}

# A decision raised with no later progress line has no ordering witness, so an
# active run-step leaves it open in both folds even when it is the only line.
test_mid_run_decision_without_later_progress_stays_open_under_active_run() {
  local dir f reader full incremental expected
  dir=$(case_dir run-step-mid-run)
  f="$dir/task.status"
  reader="$dir/fake-crew-state.sh"
  fm_write_meta "$dir/task.meta" "window=sess:fm-task" "kind=ship"
  printf 'working: validating\nblocked [key=creds]: need the staging secret\nworking [key=other]: unrelated phase\n' > "$f"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "state: working · source: run-step · ci running"\n' > "$reader"
  chmod +x "$reader"
  expected=$(printf 'creds\tblocked\tneed the staging secret\n')
  full=$(FM_CREW_STATE_BIN="$reader" status_open_decisions_for_task task "$f")
  incremental=$(FM_CREW_STATE_BIN="$reader" status_open_decisions_incremental_for_task task "$f")
  [ "$full" = "$expected" ] || fail "a mid-run blocker was superseded by the whole verdict: '$full'"
  [ "$incremental" = "$expected" ] || fail "a mid-run blocker was superseded by the incremental verdict: '$incremental'"
  pass "a blocker with no same-key progress line stays open under an active run"
}

# Only a local ship task can own an attributed run, so the current-state read
# is skipped for every other task kind and for a remote mate; the durable set
# is the verdict there and the reader is never executed.
test_current_state_read_is_gated_to_local_ship_tasks() {
  local dir reader calls kind f full expected
  dir=$(case_dir run-step-gating)
  reader="$dir/fake-crew-state.sh"
  calls="$dir/calls.log"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FAKE_DECISION_CALLS"
printf 'state: working · source: run-step · validating\n'
SH
  chmod +x "$reader"
  expected=$(printf 'rollout\tneeds-decision\tchoose the deployment path\n')
  for kind in scout secondmate remote absent; do
    f="$dir/$kind.status"
    printf 'needs-decision [key=rollout]: choose the deployment path\nworking [key=rollout]: resumed\n' > "$f"
    case "$kind" in
      remote) fm_write_meta "$dir/$kind.meta" "window=sess:fm-$kind" "kind=ship" "remote_host=mate.example" ;;
      absent) ;;
      *) fm_write_meta "$dir/$kind.meta" "window=sess:fm-$kind" "kind=$kind" ;;
    esac
    full=$(FM_FAKE_DECISION_CALLS="$calls" FM_CREW_STATE_BIN="$reader" status_open_decisions_for_task "$kind" "$f")
    [ "$full" = "$expected" ] || fail "$kind task verdict diverged from its durable set: '$full'"
  done
  [ ! -s "$calls" ] || fail "the current-state reader ran for a task that can never own a run: $(cat "$calls")"

  f="$dir/ship.status"
  printf 'needs-decision [key=rollout]: choose the deployment path\nworking [key=rollout]: resumed\n' > "$f"
  fm_write_meta "$dir/ship.meta" "window=sess:fm-ship" "kind=ship"
  full=$(FM_FAKE_DECISION_CALLS="$calls" FM_CREW_STATE_BIN="$reader" status_open_decisions_for_task ship "$f")
  [ -z "$full" ] || fail "a local ship task with a later progress line kept a superseded key: '$full'"
  [ "$(cat "$calls")" = ship ] || fail "the current-state reader was not consulted exactly once for the ship task: $(cat "$calls")"
  pass "the current-state read runs only for a local ship task and fails open elsewhere"
}

test_stated_key_is_honored_in_both_positions
test_bare_keyless_line_still_folds_to_default
test_resolution_closes_across_positions
test_blocked_is_position_tolerant_like_needs_decision
test_two_colon_form_decisions_stay_distinct
test_mid_note_prose_mention_is_not_a_stated_key
test_malformed_stated_key_never_collapses_to_default
test_status_line_verb_strips_every_bracket_tag_before_colon
test_corr_and_key_tags_open_and_close_under_the_stated_key
test_corr_only_tag_opens_as_default_like_a_bare_line
test_key_only_before_colon_still_opens_no_regression
test_blocked_and_resolved_are_tag_order_independent
test_incremental_agrees_with_full_fold_across_appends

# status_key_closing_verb reports HOW the status side currently reads one key,
# which is what lets a consumer tell a settled key from a key handed to a
# durable captain-held task. The two closing verbs must stay distinguishable:
# `resolved` claims the question is settled outright, while `captain-held` is
# the verified transfer to that task, so treating them alike would either lose
# the record-divergence signal or invent one on every correct transfer.
test_closing_verb_separates_resolution_from_durable_transfer() {
  local dir f
  dir=$(case_dir closing-verb)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
working: started
needs-decision [key=route]: north or south
resolved [key=route]: answered: north
needs-decision [key=access]: open or restricted
captain-held [key=access]: tracked by sample-access-call
blocked [key=creds]: need the deploy token
done: everything else shipped
EOF
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a resolved key did not report the resolve verb: '$(status_key_closing_verb "$f" route)'"
  [ "$(status_key_closing_verb "$f" access)" = captain-held ] \
    || fail "a durable-transfer close reported the wrong verb: '$(status_key_closing_verb "$f" access)'"
  [ "$(status_key_closing_verb "$f" creds)" = blocked ] \
    || fail "a still-open key must report its opening verb: '$(status_key_closing_verb "$f" creds)'"
  [ -z "$(status_key_closing_verb "$f" never-mentioned)" ] \
    || fail "a key with no transition line reported a verb"
  [ -z "$(status_key_closing_verb "$dir/absent.status" route)" ] \
    || fail "an absent status file reported a verb"
  pass "status_key_closing_verb separates resolution, durable transfer, and still-open"
}

# The reported verb is the LAST transition, read through the same fold rule as
# everything else: the colon-first key position counts, a re-opened key reports
# open again, and a prose mention is never a transition.
test_closing_verb_tracks_the_last_transition_in_both_positions() {
  local dir f
  dir=$(case_dir closing-verb-last)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
needs-decision: [key=route] colon-first open
resolved: [key=route] colon-first close
EOF
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a colon-first resolution was not seen: '$(status_key_closing_verb "$f" route)'"

  printf 'needs-decision [key=route]: re-opened after a bad answer\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = needs-decision ] \
    || fail "a re-opened key still reported closed: '$(status_key_closing_verb "$f" route)'"

  printf 'resolved [key=route]: answered: south after all\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "the last of several transitions was not reported: '$(status_key_closing_verb "$f" route)'"

  printf 'working: a later append that only mentions [key=route] as prose\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a prose mention changed the reported verb: '$(status_key_closing_verb "$f" route)'"
  pass "status_key_closing_verb reports the last real transition, in either key position"
}

test_closing_verb_separates_resolution_from_durable_transfer
test_closing_verb_tracks_the_last_transition_in_both_positions
test_active_run_step_reconciles_both_decision_folds_per_key_without_using_pane_text
test_mid_run_decision_without_later_progress_stays_open_under_active_run
test_reserved_key_is_not_superseded_by_a_foreign_progress_line
test_reconcile_re_read_failure_keeps_every_key_open
test_current_state_read_is_gated_to_local_ship_tasks
