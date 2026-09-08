#!/usr/bin/env bash
# tests/fm-quota-wait.test.sh - portable regression for the provider quota
# refusal path: bin/fm-quota-lib.sh, bin/fm-quota-watch.sh, and the absorb
# bin/fm-watch.sh gives a recorded quota wait.
#
# It runs REAL processes in a REAL tmux server on a private socket (`-L`), with
# a stub `quota-axi` and no harness and no credentials, so it runs everywhere CI
# runs tmux. The live per-harness counterpart is
# tests/fm-quota-banner-live-e2e.test.sh.
#
# The defect it exists for: a provider refuses a worker's turn on quota, the
# harness renders a limit notice and ends the turn exactly as a completed turn
# ends, and every signal supervision owns then reads identical to a worker that
# finished and is waiting - so the fleet parks with work half done and nothing
# escalates or resumes.
#
# The quota verdict is harness-dependent in the sense firstmate-coding-guidelines
# defines, so these cases DRIVE THE TWO SIGNALS APART on purpose rather than
# presenting both at once: the structural case renders no banner at all and
# asserts that absence, and the banner case removes `quota-axi` from PATH
# entirely and asserts that absence. Either signal alone must still reach the
# right verdict, so no single vendor string is load-bearing. Both constructions
# are platform-independent - one deletes a stub from PATH, the other writes
# different pane text - so unlike a process-name check there is no per-platform
# difference in which source a case blinds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# The meta reader bin/fm-quota-lib.sh attributes a provider through, sourced here
# for the same reason every production driver of that file sources it.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# The status predicates the suppression owner reads, sourced here for the same
# reason every production driver sources them.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-quota-lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-quota-$$"
SESSION=quota
QUOTA_WATCH="$ROOT/bin/fm-quota-watch.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-wait-tests)

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

# The banner text the reported incident showed, used verbatim wherever a case
# needs a rendered limit notice.
BANNER='You have hit your session limit, resets 8:50am'

iso_in() {  # <seconds-from-now>
  date -u -d "@$(( $(date +%s) + $1 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    date -u -r "$(( $(date +%s) + $1 ))" '+%Y-%m-%dT%H:%M:%SZ'
}

# A wall-clock time of day <hours> from now, in the shape the reported notice
# rendered it ("8:50am"). Local time, because that is what the notice states and
# what the production parser resolves against.
clock_in_hours() {  # <hours-from-now>
  local at formatted
  at=$(( $(date +%s) + $1 * 3600 ))
  # The status of a pipeline is its LAST command's, so the fallback has to guard
  # the date call itself rather than the tr that formats its output.
  formatted=$(date -d "@$at" '+%I:%M%p' 2>/dev/null) ||
    formatted=$(date -r "$at" '+%I:%M%p') || return 1
  [ -n "$formatted" ] || return 1
  printf '%s' "${formatted#0}" | tr 'APM' 'apm'
}

# quota-axi's provider report, with a runway status and a limiting window reset
# this test controls. Shaped after the live schema-5 snapshot recorded in
# docs/verification/dispatch-auth.md.
write_quota_json() {  # <file> <provider> <runway-status> <resets-at>
  cat > "$1" <<JSON
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "$2",
      "windows": [ { "id": "five_hour", "kind": "session", "resetsAt": "$4" } ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "limitingWindowIds": [ "five_hour" ],
            "runway": { "status": "$3" }
          }
        ]
      }
    }
  ]
}
JSON
}

# The same report for two providers at once, which is what a mixed fleet's one
# shared scan snapshot holds.
write_quota_json_pair() {  # <file> <runway-status> <resets-at>
  cat > "$1" <<JSON
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "windows": [ { "id": "five_hour", "kind": "session", "resetsAt": "$3" } ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known",
            "limitingWindowIds": [ "five_hour" ], "runway": { "status": "$2" } }
        ]
      }
    },
    {
      "provider": "codex",
      "windows": [ { "id": "five_hour", "kind": "session", "resetsAt": "$3" } ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known",
            "limitingWindowIds": [ "five_hour" ], "runway": { "status": "$2" } }
        ]
      }
    }
  ]
}
JSON
}

write_models_json() {  # <file>
  cat > "$1" <<'JSON'
{
  "schemaVersion": 1,
  "models": [
    { "provider": "claude", "id": "claude-opus-4-5" },
    { "provider": "codex", "id": "gpt-5.3-codex" }
  ]
}
JSON
}

# One case fixture: a private state dir, a fakebin with a stub quota-axi and a
# recording stand-in for fm-send, and a real tmux pane whose foreground process
# is a real binary named like an agent (so the endpoint reads alive) and whose
# rendered text is whatever the case asks for.
make_case() {  # <name> <pane-text> [harness]
  local name=$1 pane_text=$2 harness=${3:-claude} dir fakebin id
  id="task$name"
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin" "$dir/wt" "$dir/bin"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
  chmod +x "$fakebin/tmux"
  # A real long-running binary reached through an agent-shaped name: the kernel
  # records that name as the executable identity, which is what the endpoint
  # liveness classifier reads.
  ln -sf "$SLEEP_BIN" "$dir/bin/claude"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  [ -n "${FM_FAKE_QUOTA_MODELS:-}" ] && [ -r "$FM_FAKE_QUOTA_MODELS" ] || exit 1
  cat "$FM_FAKE_QUOTA_MODELS"
  exit 0
fi
[ -n "${FM_FAKE_QUOTA_JSON:-}" ] && [ -r "$FM_FAKE_QUOTA_JSON" ] || exit 1
# Every provider read is counted, so a case can assert how many vendor calls one
# scan actually spent.
n=0
if [ -n "${FM_FAKE_QUOTA_CALLS:-}" ]; then
  n=$(cat "$FM_FAKE_QUOTA_CALLS" 2>/dev/null || printf '0')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s\n' "$n" > "$FM_FAKE_QUOTA_CALLS"
fi
# A vendor call that stops answering partway through one scan, which is how a
# real 20s-bounded read times out under load.
if [ -n "${FM_FAKE_QUOTA_FAIL_AFTER:-}" ]; then
  [ "$n" -le "$FM_FAKE_QUOTA_FAIL_AFTER" ] || exit 1
fi
cat "$FM_FAKE_QUOTA_JSON"
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  cat > "$fakebin/fm-send-recorder.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
exit "${FM_FAKE_SEND_RC:-0}"
SH
  chmod +x "$fakebin/fm-send-recorder.sh"
  printf '%s\n' "$pane_text" > "$dir/pane.txt"
  PATH="$fakebin:$PATH" tmux new-session -d -s "$SESSION" -n "fm-$id" \
    "sh -c 'cat $dir/pane.txt; exec $dir/bin/claude 100000'" 2>/dev/null ||
    PATH="$fakebin:$PATH" tmux new-window -d -n "fm-$id" \
      "sh -c 'cat $dir/pane.txt; exec $dir/bin/claude 100000'"
  # tmux runs the pane command asynchronously; without settling for it the very
  # first capture can read an empty pane and blind the banner case by accident.
  local i=0
  while [ "$i" -lt 50 ]; do
    PATH="$fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$id" 2>/dev/null |
      grep -q . && break
    sleep 0.1
    i=$((i + 1))
  done
  fm_write_meta "$dir/state/$id.meta" \
    "window=$SESSION:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/wt" \
    "harness=$harness" \
    "kind=ship" \
    "model=default" \
    "effort=default"
  printf 'working: implementing the fix\n' > "$dir/state/$id.status"
  write_models_json "$dir/models.json"
  printf '%s\n' "$dir"
}

case_id() { printf 'task%s' "$1"; }

# Record a semantic busy state for the case's task, through the production
# writer, so the idle gate reads a real record rather than a guessed one.
set_busy_state() {  # <dir> <id> <busy|idle|unknown> [source]
  local dir=$1 id=$2 want=$3 source=${4:-claude-hook} gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/state" "$id" >/dev/null 2>&1; \
    cat "$dir/state/$id.busy-gen" 2>/dev/null) || return 1
  [ -n "$gen" ] || return 1
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" "$id" "$want" --gen "$gen" \
    --source "$source" --event test >/dev/null 2>&1
}

# Run one scan inside the case fixture. The production script has one entry, its
# own cadence, so a case that needs an immediate evaluation sets that cadence to
# zero rather than reaching for a second mode. Every quota read the scan makes
# goes through the stub on PATH; every send goes to the recorder.
run_scan() {  # <dir> <id> [extra env assignments...]
  local dir=$1
  shift 2
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_QUOTA_SEND_BIN="$dir/fakebin/fm-send-recorder.sh" \
    FM_FAKE_SEND_LOG="$dir/sent.log" \
    FM_FAKE_QUOTA_MODELS="$dir/models.json" \
    FM_FAKE_QUOTA_CALLS="$dir/quota-calls" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_QUOTA_SCAN_INTERVAL=0 \
    env "$@" "$QUOTA_WATCH" scan 2>&1
}

# A hermetic fm-crew-state.sh so the resume gate's third read is controlled by
# the case rather than by a real worktree.
# Rewrite a wait record's detection time, which is what every bound measured
# from detection is read against. Portable across GNU and BSD sed.
set_detected() {  # <dir> <id> <epoch>
  local record="$1/state/$2.quota-wait"
  sed -i.bak "s/detected=[0-9]*/detected=$3/" "$record" 2>/dev/null ||
    sed -i '' "s/detected=[0-9]*/detected=$3/" "$record"
  rm -f "$record.bak"
}

make_fake_crew_state() {  # <dir> <verdict>
  cat > "$1/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "$2"
exit 0
SH
  chmod +x "$1/fakebin/fm-crew-state.sh"
}

# --- the suppression owner --------------------------------------------------

# bin/fm-quota-lib.sh owns one decision - may this recorded wait stand in front
# of a supervision reading - and every site asks it rather than composing its own
# preconditions. These cases pin the two guards that decision carries, so a site
# that stopped asking would take the record's benefit without them.
test_the_suppression_owner_honours_both_guards() {
  local dir id
  dir=$(make_case suppression "the worker stopped mid-task")
  id=$(case_id suppression)
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) + 3600 ))" structural ||
    fail "suppression: could not write the wait record"

  fm_quota_wait_suppresses "$dir/state" "$id" 'working: implementing the fix' admit-alive ||
    fail "suppression: a current wait behind a nonterminal status was not suppressed on the idle-stale path"
  fm_quota_wait_suppresses "$dir/state" "$id" 'working: implementing the fix' unknown ||
    fail "suppression: a current wait was not suppressed where no liveness reading exists"

  # A pane past the busy-turn bound renders a harness busy footer, so a hung
  # foreground call there looks like a worker still being served.
  ! fm_quota_wait_suppresses "$dir/state" "$id" 'working: implementing the fix' refuse-alive ||
    fail "suppression: a wait suppressed the busy-turn-bound path, which is how a long hang hides"

  # A worker that reported a terminal state still owes the captain that reading.
  local line
  for line in 'blocked: cannot reach the staging DB' 'done: opened the PR' 'failed: the build will not run'; do
    ! fm_quota_wait_suppresses "$dir/state" "$id" "$line" admit-alive ||
      fail "suppression: a wait swallowed the terminal status '$line' on the idle-stale path"
    ! fm_quota_wait_suppresses "$dir/state" "$id" "$line" unknown ||
      fail "suppression: a wait swallowed the terminal status '$line' where no liveness reading exists"
  done

  fm_quota_wait_clear "$dir/state" "$id"
  ! fm_quota_wait_suppresses "$dir/state" "$id" 'working: implementing the fix' admit-alive ||
    fail "suppression: a retired wait still suppressed a supervision reading"
  pass "suppression: the one owner refuses a terminal status and refuses the busy-turn-bound path"
}

# --- provider attribution ---------------------------------------------------

test_provider_attribution() {
  local dir id state
  dir=$(make_case attribution "idle pane")
  id=$(case_id attribution)
  state="$dir/state"
  export FM_FAKE_QUOTA_MODELS="$dir/models.json"
  export FM_QUOTA_AXI_BIN="$dir/fakebin/quota-axi"

  [ "$(fm_quota_provider_for_meta "$state" "$state/$id.meta")" = claude ] ||
    fail "a single-vendor harness did not attribute its provider"

  # A multi-provider harness with no concrete model is NOT attributed. The
  # harness name is not evidence of an account, and guessing one would park a
  # worker on some other vendor's quota window.
  fm_write_meta "$state/multi.meta" "window=$SESSION:fm-multi" "harness=opencode" "model=default"
  [ -z "$(fm_quota_provider_for_meta "$state" "$state/multi.meta")" ] ||
    fail "a multi-provider harness was attributed a provider from its name alone"

  # A concrete model resolves through quota-axi's own published provider/model
  # join, which is authoritative data rather than a name prefix.
  fm_write_meta "$state/bymodel.meta" "window=$SESSION:fm-bymodel" "harness=opencode" "model=gpt-5.3-codex"
  [ "$(fm_quota_provider_for_meta "$state" "$state/bymodel.meta")" = codex ] ||
    fail "a catalogued model id did not attribute its provider"

  # Two sources that disagree are two sources that cannot be trusted.
  fm_write_meta "$state/conflict.meta" "window=$SESSION:fm-conflict" "harness=claude" "model=gpt-5.3-codex"
  [ -z "$(fm_quota_provider_for_meta "$state" "$state/conflict.meta")" ] ||
    fail "contradictory harness and model evidence still produced a provider"

  unset FM_FAKE_QUOTA_MODELS FM_QUOTA_AXI_BIN
  pass "provider attribution: single-vendor harness, catalogued model, no guess, no contradiction"
}

# --- detection --------------------------------------------------------------

test_structural_detection_without_a_banner() {
  local dir id out reset
  dir=$(make_case structural "the worker stopped mid-task")
  id=$(case_id structural)
  set_busy_state "$dir" "$id" idle || fail "structural: could not record an idle busy state"
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"

  # Prove the rendered signal is absent, so this case cannot pass on it.
  PATH="$dir/fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$id" 2>/dev/null |
    grep -qiE 'limit' && fail "structural: the pane rendered a limit notice, so this case proves nothing"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_contains "$out" "quota-limit:" "structural: an exhausted account was not reported"
  assert_present "$dir/state/$id.quota-wait" "structural: no wait was recorded for an exhausted account"
  [ "$(fm_quota_wait_field "$dir/state" "$id" evidence)" = structural ] ||
    fail "structural: the recorded wait did not name the structural evidence"
  reset=$(fm_quota_wait_field "$dir/state" "$id" reset)
  case "$reset" in ''|*[!0-9]*) fail "structural: the wait carries no usable reset time" ;; esac
  [ "$reset" -gt "$(date +%s)" ] || fail "structural: the wait's reset time is not in the future"
  pass "structural: an exhausted account records a bounded wait with its reset time, with no banner present"
}

test_banner_detection_without_quota_axi() {
  local dir id out
  dir=$(make_case banner "$BANNER")
  id=$(case_id banner)
  set_busy_state "$dir" "$id" idle || fail "banner: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"

  # Blind the structural signal completely: the stub is removed and the quota
  # binary is pointed at a name that exists nowhere, so every structural read
  # fails the way a missing or unusable quota-axi fails. The verdict must still
  # be reached from the rendered notice alone.
  rm -f "$dir/fakebin/quota-axi"
  command -v quota-axi-absent-for-test >/dev/null 2>&1 &&
    fail "banner: the stand-in for an absent quota binary unexpectedly exists"
  out=$(run_scan "$dir" "$id" FM_QUOTA_AXI_BIN=quota-axi-absent-for-test)

  assert_contains "$out" "quota-limit:" "banner: a rendered limit notice was not reported"
  assert_present "$dir/state/$id.quota-wait" "banner: no wait was recorded from a rendered limit notice"
  [ "$(fm_quota_wait_field "$dir/state" "$id" evidence)" = banner ] ||
    fail "banner: the recorded wait did not name the banner evidence"
  pass "banner: a rendered limit notice alone records a wait when account headroom cannot be read"
}

test_available_headroom_outranks_a_banner() {
  local dir id out
  dir=$(make_case outranked "$BANNER")
  id=$(case_id outranked)
  set_busy_state "$dir" "$id" idle || fail "outranked: could not record an idle busy state"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_absent "$dir/state/$id.quota-wait" \
    "outranked: a rendered limit notice overrode machine-readable headroom"
  assert_not_contains "$out" "quota-limit:" "outranked: a wait was reported against a healthy account"
  pass "outranked: a rendered limit notice never overrides an account the vendor reports as having headroom"
}

test_a_busy_worker_is_never_parked() {
  local dir id out
  dir=$(make_case busy "the worker stopped mid-task")
  id=$(case_id busy)
  set_busy_state "$dir" "$id" busy || fail "busy: could not record a busy state"
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"
  make_fake_crew_state "$dir" "state: working · source: run-step · review"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_absent "$dir/state/$id.quota-wait" \
    "busy: a worker in the middle of a turn was recorded as parked on quota"
  assert_not_contains "$out" "$id is waiting" "busy: a mid-turn worker was reported as waiting"
  pass "busy: an exhausted account never parks a worker whose pane is still rendering a turn"
}

test_an_unreadable_pane_is_never_parked() {
  local dir id
  dir=$(make_case unreadable "the worker stopped mid-task")
  id=$(case_id unreadable)
  # No busy record at all: the semantic contract classifies that unknown, never
  # idle, and unknown must not be read as "parked".
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"

  run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" >/dev/null
  assert_absent "$dir/state/$id.quota-wait" \
    "unreadable: a worker whose state could not be classified was recorded as parked"
  pass "unreadable: a worker whose current state cannot be positively classified is never recorded as parked"
}

# --- resume -----------------------------------------------------------------

test_resume_sends_exactly_one_nudge_per_reset() {
  local dir id reset out sends
  dir=$(make_case resume "the worker stopped mid-task")
  id=$(case_id resume)
  set_busy_state "$dir" "$id" idle || fail "resume: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  reset=$(( $(date +%s) - 600 ))
  fm_quota_wait_write "$dir/state" "$id" claude claude "$reset" structural ||
    fail "resume: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_contains "$out" "was resumed automatically" "resume: no resume was reported"
  sends=$(wc -l < "$dir/sent.log" 2>/dev/null | tr -d ' ')
  [ "$sends" = 1 ] || fail "resume: expected exactly 1 delivered resume, got ${sends:-0}"
  assert_grep "$id" "$dir/sent.log" "resume: the resume did not name the parked worker"
  # Delivered to the recorded backend target. bin/fm-send.sh arms a durable
  # parent pending-reply expectation - with its own recovery resend and
  # escalation - for a SELECTOR that resolves to a secondmate, and a resume is
  # not a request, so one nudge would stop being one nudge.
  assert_grep "$SESSION:fm-$id" "$dir/sent.log" \
    "resume: the resume was delivered to a task selector rather than the recorded backend target"
  assert_absent "$dir/state/$id.quota-wait" \
    "resume: the wait was not retired, so ordinary supervision never takes the pane back"

  # A second scan must not resend, and neither must a wait re-created for the
  # SAME reset - the durable spend record, not the caller's control flow, is
  # what makes this one nudge per reset.
  run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" >/dev/null
  fm_quota_wait_write "$dir/state" "$id" claude claude "$reset" structural
  run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" >/dev/null
  sends=$(wc -l < "$dir/sent.log" 2>/dev/null | tr -d ' ')
  [ "$sends" = 1 ] || fail "resume: a repeated scan resent the nudge ($sends deliveries)"
  pass "resume: exactly one nudge per reset, and the wait retires so ordinary supervision resumes"
}

test_resume_reads_the_account_fresh_rather_than_from_cache() {
  local dir id out
  dir=$(make_case cachedresume "the worker stopped mid-task")
  id=$(case_id cachedresume)
  set_busy_state "$dir" "$id" idle || fail "cachedresume: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # Warm the cache with a refusal, exactly as an earlier scan would have.
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"
  run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" >/dev/null
  # The account recovers, and a wait comes due while that cached refusal is
  # still inside its reuse window. Reading the cache here would defer a resume
  # that is actually due by a whole interval, so this read must be fresh.
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 18000)"
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" structural \
    "$(fm_quota_fingerprint structural claude cached)" ||
    fail "cachedresume: could not write the wait record"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_contains "$out" "was resumed automatically" \
    "cachedresume: a cached refusal deferred a resume that was due"
  [ "$(wc -l < "$dir/sent.log" 2>/dev/null | tr -d ' ')" = 1 ] ||
    fail "cachedresume: expected exactly 1 delivered resume"
  pass "cachedresume: the account is re-read fresh before a resume, never from the reuse window"
}

test_one_account_is_re_read_once_per_scan_not_once_per_worker() {
  local dir a b out calls i
  dir=$(make_case oneprobe "the worker stopped mid-task")
  a=$(case_id oneprobe)
  b="${a}z"
  # The founding incident's shape: one account refuses every endpoint at once,
  # so every wait comes due in the same pass. A vendor read per worker would
  # spend one bounded call each and hold the supervision loop that launched this
  # scan for the sum of them, under exactly the load that caused the incident.
  ln -sf "$SLEEP_BIN" "$dir/bin/claude"
  PATH="$dir/fakebin:$PATH" tmux new-window -d -n "fm-$b" \
    "sh -c 'cat $dir/pane.txt; exec $dir/bin/claude 100000'"
  i=0
  while [ "$i" -lt 50 ]; do
    PATH="$dir/fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$b" 2>/dev/null |
      grep -q . && break
    sleep 0.1
    i=$((i + 1))
  done
  fm_write_meta "$dir/state/$b.meta" \
    "window=$SESSION:fm-$b" "endpoint_task_id=$b" "worktree=$dir/wt" "project=$dir/wt" \
    "harness=claude" "kind=ship" "model=default" "effort=default"
  printf 'working: implementing the fix\n' > "$dir/state/$b.status"
  set_busy_state "$dir" "$a" idle || fail "oneprobe: could not record an idle busy state"
  set_busy_state "$dir" "$b" idle || fail "oneprobe: could not record the second idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"
  fm_quota_wait_write "$dir/state" "$a" claude claude "$(( $(date +%s) - 600 ))" structural \
    "$(fm_quota_fingerprint structural claude oneprobea)" ||
    fail "oneprobe: could not write the first wait record"
  fm_quota_wait_write "$dir/state" "$b" claude claude "$(( $(date +%s) - 600 ))" structural \
    "$(fm_quota_fingerprint structural claude oneprobeb)" ||
    fail "oneprobe: could not write the second wait record"

  rm -f "$dir/quota-calls"
  out=$(run_scan "$dir" "$a" FM_FAKE_QUOTA_JSON="$dir/quota.json")

  # Both resumes still happen, and both still rest on an account re-read during
  # THIS scan rather than on the reuse window.
  [ "$(wc -l < "$dir/sent.log" 2>/dev/null | tr -d ' ')" = 2 ] ||
    fail "oneprobe: expected both due workers to be resumed"
  assert_contains "$out" "was resumed automatically" "oneprobe: no resume was reported"
  # One shared read for the scan, one forced re-read for the account. A third
  # would be the per-worker fan-out.
  calls=$(cat "$dir/quota-calls" 2>/dev/null || printf '0')
  [ "$calls" = 2 ] ||
    fail "oneprobe: one scan spent $calls vendor reads on one account, expected 2"
  pass "oneprobe: one account is re-read once per scan, however many workers come due in it"
}

test_resume_refuses_an_unclassifiable_endpoint() {
  local dir id out
  dir=$(make_case norresume "the worker stopped mid-task")
  id=$(case_id norresume)
  # No busy record: the pane's current state is unknown, not idle.
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" structural ||
    fail "norresume: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_contains "$out" "was not resumed automatically" "norresume: the refusal was not reported"
  [ ! -s "$dir/sent.log" ] || fail "norresume: text was delivered into an endpoint that could not be classified"
  assert_absent "$dir/state/$id.quota-wait" \
    "norresume: the wait outlived a refused resume instead of returning the pane to ordinary supervision"
  pass "norresume: a resume is never delivered into an endpoint whose state cannot be positively classified"
}

test_resume_refuses_a_worker_that_is_working_again() {
  local dir id out
  dir=$(make_case working "the worker stopped mid-task")
  id=$(case_id working)
  set_busy_state "$dir" "$id" idle || fail "working: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: working · source: run-step · review"
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" structural ||
    fail "working: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_contains "$out" "working again already" "working: the refusal reason was not reported"
  [ ! -s "$dir/sent.log" ] || fail "working: a resume was delivered into a worker that had resumed on its own"
  pass "working: a worker that is already working again is never sent a resume"
}

test_a_still_refused_account_is_not_resumed() {
  local dir id out
  dir=$(make_case stillrefused "the worker stopped mid-task")
  id=$(case_id stillrefused)
  set_busy_state "$dir" "$id" idle || fail "stillrefused: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" structural ||
    fail "stillrefused: could not write the wait record"
  # The account is still refusing at this wait's own stated reset, and names a
  # later window. One record carries ONE deadline: it retires here rather than
  # moving that deadline forward, or a vendor that keeps restating a later reset
  # would hold the pane out of wedge aging indefinitely.
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 1800)"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  [ ! -s "$dir/sent.log" ] || fail "stillrefused: a resume was sent into an account still out of headroom"
  assert_absent "$dir/state/$id.quota-wait" \
    "stillrefused: a wait outlived its own deadline instead of returning the pane to ordinary escalation"
  assert_contains "$out" "is still refused" "stillrefused: the retirement was not reported"
  assert_not_contains "$out" "was resumed automatically" "stillrefused: a resume was reported"
  pass "stillrefused: an account still refusing at the wait's own deadline retires it rather than extending it"
}

test_a_wait_with_no_readable_reset_expires_itself() {
  local dir id out detected
  dir=$(make_case expiry "$BANNER")
  id=$(case_id expiry)
  set_busy_state "$dir" "$id" idle || fail "expiry: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  fm_quota_wait_write "$dir/state" "$id" claude claude unknown banner ||
    fail "expiry: could not write the wait record"
  detected=$(( $(date +%s) - 7200 ))
  sed -i.bak "s/detected=[0-9]*/detected=$detected/" "$dir/state/$id.quota-wait" 2>/dev/null ||
    sed -i '' "s/detected=[0-9]*/detected=$detected/" "$dir/state/$id.quota-wait"
  rm -f "$dir/state/$id.quota-wait.bak"

  fm_quota_wait_active "$dir/state" "$id" &&
    fail "expiry: a banner wait older than its own bound still reads as current"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_contains "$out" "expired without a usable reset time" "expiry: the expiry was not reported"
  assert_absent "$dir/state/$id.quota-wait" "expiry: an expired wait was not retired"
  [ ! -s "$dir/sent.log" ] || fail "expiry: a wait with no readable reset still produced a resume"
  pass "expiry: a wait with no readable reset retires on its own bound and is never resumed blindly"
}

test_a_worker_parked_by_design_is_never_recorded_as_refused() {
  local dir id out
  dir=$(make_case parked "the worker stopped mid-task")
  id=$(case_id parked)
  set_busy_state "$dir" "$id" idle || fail "parked: could not record an idle busy state"
  # Idle BY DESIGN: this worker is holding a decision, so the provider never
  # refused it a turn. Recording a wait would park something that was not stuck,
  # and the resume at reset would push it past the gate it is holding.
  make_fake_crew_state "$dir" "state: parked · source: decision · awaiting a captain decision"
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_absent "$dir/state/$id.quota-wait" \
    "parked: a worker idle by design was recorded as parked on a provider limit"
  assert_not_contains "$out" "is waiting on" \
    "parked: a worker holding a decision was reported as waiting on quota"
  [ ! -s "$dir/sent.log" ] || fail "parked: a resume was delivered into a worker holding a decision"
  pass "parked: an exhausted account never records a wait for a worker whose own state explains its idleness"
}

test_a_dead_endpoint_never_earns_a_quota_wait() {
  local dir id out
  dir=$(make_case deadendpoint "the worker stopped mid-task")
  id=$(case_id deadendpoint)
  set_busy_state "$dir" "$id" idle || fail "deadendpoint: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"
  # The agent is gone while the semantic busy record still reads idle. That is
  # the shape the watcher escalates as demand-deep-inspection, and a quota wait
  # over it would absorb that escalation for as long as the reset is away.
  PATH="$dir/fakebin:$PATH" tmux kill-window -t "$SESSION:fm-$id" 2>/dev/null || true

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_absent "$dir/state/$id.quota-wait" \
    "deadendpoint: a pane with no live agent was recorded as waiting on a provider limit"
  assert_not_contains "$out" "is waiting on" \
    "deadendpoint: an endpoint with no live agent was reported as a quota wait"
  pass "deadendpoint: an exhausted account never parks a pane whose endpoint reports no live agent"
}

test_a_wait_inside_the_reset_grace_window_survives() {
  local dir id out
  dir=$(make_case grace "the worker stopped mid-task")
  id=$(case_id grace)
  set_busy_state "$dir" "$id" idle || fail "grace: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # A scan that lands between the stated reset and the moment the resume becomes
  # due. A wait that retires inside that window takes its worker's one automatic
  # resume with it, and the account now reports headroom, so nothing re-detects.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 10 ))" structural \
    "$(fm_quota_fingerprint structural claude grace)" ||
    fail "grace: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"

  fm_quota_wait_resume_due "$dir/state" "$id" &&
    fail "grace: the resume is already due, so this case is not exercising the grace window"
  fm_quota_wait_active "$dir/state" "$id" ||
    fail "grace: a wait stopped being current before the resume it is owed became due"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_present "$dir/state/$id.quota-wait" \
    "grace: the wait was retired inside its own grace window, so its resume can never be delivered"
  assert_not_contains "$out" "expired without a usable reset time" \
    "grace: a wait carrying a usable reset time was reported as having none"
  [ ! -s "$dir/sent.log" ] || fail "grace: a resume was delivered before it was due"
  pass "grace: a wait whose reset has passed but whose resume is not yet due survives to deliver it"
}

test_a_banner_that_states_its_reset_runs_to_it_and_resumes() {
  local dir id out reset detected
  dir=$(make_case bannerreset "You have hit your session limit, resets $(clock_in_hours 3)")
  id=$(case_id bannerreset)
  set_busy_state "$dir" "$id" idle || fail "bannerreset: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # A home with no quota-axi at all, which is the only kind of home this fallback
  # exists for. The reported incident is this exact shape: a notice at 06:05
  # stating a reset at 08:50, nearly three hours out.
  rm -f "$dir/fakebin/quota-axi"

  out=$(run_scan "$dir" "$id" FM_QUOTA_AXI_BIN=quota-axi-absent-for-test)
  assert_present "$dir/state/$id.quota-wait" "bannerreset: no wait was recorded from the stated notice"
  assert_contains "$out" "this worker is resumed automatically" \
    "bannerreset: a reset inside the ceiling was not announced as one that resumes itself"
  reset=$(fm_quota_wait_field "$dir/state" "$id" reset)
  case "$reset" in ''|*[!0-9]*) fail "bannerreset: the reset the notice stated was not recorded" ;; esac

  # Age the record past the bound a banner wait that states NO reset carries. A
  # wait that retires here never delivers the resume it was recorded for.
  detected=$(( $(date +%s) - 3600 ))
  set_detected "$dir" "$id" "$detected"
  fm_quota_wait_active "$dir/state" "$id" ||
    fail "bannerreset: a banner wait retired before the reset its own notice stated"

  # The stated reset arrives, and the fleet recovers itself with no quota-axi
  # anywhere and no human in the loop.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" banner \
    "$(fm_quota_fingerprint banner claude "$id stated reset")" notice ||
    fail "bannerreset: could not restate the wait at its stated reset"
  case "$(fm_quota_wait_resume_outcome "$dir/state" "$id")" in
    *"this worker is resumed automatically"*) ;;
    *) fail "bannerreset: a reachable resume was not reported as one" ;;
  esac
  out=$(run_scan "$dir" "$id" FM_QUOTA_AXI_BIN=quota-axi-absent-for-test)
  assert_contains "$out" "was resumed automatically" \
    "bannerreset: a banner wait whose stated reset arrived was never resumed"
  [ "$(wc -l < "$dir/sent.log" 2>/dev/null | tr -d ' ')" = 1 ] ||
    fail "bannerreset: expected exactly 1 delivered resume"
  pass "bannerreset: a notice that states its reset waits until then and resumes on a home with no quota-axi"
}

# The ceiling on a reset read from rendered text, in both directions. It arrived
# after the review stage of the run that built this path closed, from the
# observation that a notice-derived wait was otherwise bounded only by whatever
# the notice said - so a transcript quoting someone else's limit notice could
# hold one pane out of ordinary escalation for most of a day.
test_a_notice_stated_reset_within_the_ceiling_waits_as_stated() {
  local dir id detected
  dir=$(make_case noticeinside "the worker is idle")
  id=$(case_id noticeinside)
  # The founding incident's own shape: a notice at 06:05 stating 08:50, 2h45m.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) + 9900 ))" banner \
    "$(fm_quota_fingerprint banner claude noticeinside)" notice ||
    fail "noticeinside: could not write the wait record"
  detected=$(( $(date +%s) - 3600 ))
  set_detected "$dir" "$id" "$detected"
  fm_quota_wait_active "$dir/state" "$id" ||
    fail "noticeinside: a notice-stated reset inside the ceiling retired early"
  case "$(fm_quota_wait_resume_outcome "$dir/state" "$id")" in
    *"this worker is resumed automatically"*) ;;
    *) fail "noticeinside: a wait that runs to its stated reset stopped promising that resume" ;;
  esac
  pass "noticeinside: a reset a notice states below the ceiling still governs the wait"
}

# The ceiling's boundary itself, in both directions. It is measured on the RESET
# the notice states, not on the deadline that reset produces, so the grace added
# afterwards can never eat into the six hours the constant and the documentation
# both name. A comparison made one term out costs a wait its one resume in a band
# nothing else would notice.
test_a_notice_stated_reset_at_the_ceiling_is_measured_on_the_reset() {
  local dir id now ceiling
  dir=$(make_case noticeboundary "the worker is idle")
  id=$(case_id noticeboundary)
  now=$(date +%s)
  ceiling=$FM_QUOTA_NOTICE_RESET_MAX_SECS_DEFAULT
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( now + ceiling ))" banner \
    "$(fm_quota_fingerprint banner claude noticeboundary)" notice ||
    fail "noticeboundary: could not write the wait record"
  set_detected "$dir" "$id" "$now"
  fm_quota_wait_resume_reachable "$dir/state" "$id" ||
    fail "noticeboundary: a reset exactly at the ceiling lost the resume it was recorded for"
  [ "$(fm_quota_wait_deadline "$dir/state" "$id")" = "$(( now + ceiling + FM_QUOTA_RESET_GRACE_SECS ))" ] ||
    fail "noticeboundary: a reset at the ceiling did not keep the grace its resume is delivered in"

  # One second past the ceiling is truncated, so the comparison cannot drift the
  # other way either.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( now + ceiling + 1 ))" banner \
    "$(fm_quota_fingerprint banner claude noticepastboundary)" notice ||
    fail "noticeboundary: could not write the past-ceiling record"
  set_detected "$dir" "$id" "$now"
  fm_quota_wait_resume_reachable "$dir/state" "$id" &&
    fail "noticeboundary: a reset one second past the ceiling was not truncated"
  pass "noticeboundary: the ceiling is measured on the reset itself, with the grace added after it"
}

test_a_notice_stated_reset_beyond_the_ceiling_is_capped() {
  local dir id now
  dir=$(make_case noticebeyond "the worker is idle")
  id=$(case_id noticebeyond)
  now=$(date +%s)
  # A notice claiming a reset a full day out, which is the outlier the ceiling
  # exists for rather than a window any vendor of this shape publishes.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( now + 86400 ))" banner \
    "$(fm_quota_fingerprint banner claude noticebeyond)" notice ||
    fail "noticebeyond: could not write the wait record"
  set_detected "$dir" "$id" "$(( now - 100 ))"
  fm_quota_wait_active "$dir/state" "$id" ||
    fail "noticebeyond: the wait retired before its ceiling was reached"
  set_detected "$dir" "$id" "$(( now - FM_QUOTA_NOTICE_RESET_MAX_SECS_DEFAULT - 60 ))"
  ! fm_quota_wait_active "$dir/state" "$id" ||
    fail "noticebeyond: a notice-stated reset past the ceiling still suppressed the pane"

  # The same reset, stated by the ACCOUNT rather than by rendered text, is not
  # capped: that evidence is the vendor's own accounting.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( now + 86400 ))" structural \
    "$(fm_quota_fingerprint structural claude noticebeyond)" vendor ||
    fail "noticebeyond: could not write the vendor-stated wait record"
  set_detected "$dir" "$id" "$(( now - FM_QUOTA_NOTICE_RESET_MAX_SECS_DEFAULT - 60 ))"
  fm_quota_wait_active "$dir/state" "$id" ||
    fail "noticebeyond: a vendor-stated reset was truncated by the rendered-text ceiling"
  pass "noticebeyond: a reset only a notice claims is capped, while the account's own reset is not"
}

# The ceiling's other half. Capping a wait short of the reset its notice stated
# creates a second class of wait that is never resumed, so the promise a surface
# makes and the resume the scan delivers must both read the DEADLINE rather than
# the mere presence of a reset. Otherwise the captain is told a worker resumes
# itself while the record dies hours earlier, and the scan later delivers text
# into a pane whose wait expired most of a day ago.
test_a_capped_notice_reset_is_never_reported_or_delivered_as_a_resume() {
  local dir id out now
  dir=$(make_case noticecapped "the worker stopped mid-task")
  id=$(case_id noticecapped)
  set_busy_state "$dir" "$id" idle || fail "noticecapped: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  now=$(date +%s)
  # A notice detected a day ago that stated a reset nearly 24h out, truncated by
  # the ceiling to six hours after detection. That stated reset has just arrived,
  # about eighteen hours after the wait itself expired.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( now - 100 ))" banner \
    "$(fm_quota_fingerprint banner claude noticecapped)" notice ||
    fail "noticecapped: could not write the wait record"
  set_detected "$dir" "$id" "$(( now - 86500 ))"

  fm_quota_wait_resume_due "$dir/state" "$id" &&
    fail "noticecapped: a resume came due for a wait that expired at its cap"
  case "$(fm_quota_wait_resume_outcome "$dir/state" "$id")" in
    *"NOT resumed automatically"*) ;;
    *) fail "noticecapped: a capped wait was reported as one that resumes itself" ;;
  esac

  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_not_contains "$out" "was resumed automatically" \
    "noticecapped: a wait capped hours earlier still delivered its notice's resume"
  [ ! -s "$dir/sent.log" ] ||
    fail "noticecapped: text was delivered into a pane whose wait had already expired"
  assert_contains "$out" "capped short of the reset its rendered notice stated" \
    "noticecapped: the capped expiry was not reported as one"
  assert_not_contains "$out" "expired without a usable reset time" \
    "noticecapped: a capped reset that parsed fine was reported as unreadable"
  assert_absent "$dir/state/$id.quota-wait" "noticecapped: the capped wait was not retired"
  pass "noticecapped: a wait the ceiling caps neither promises nor delivers an automatic resume"
}

# The same promise, at the FIRST line an operator sees. Detection is where a
# wait is announced, so a reset the ceiling will cap must not be stated there as
# one this fleet waits for: the record dies at the cap, hours before that reset,
# and nothing resumes the worker.
test_a_capped_notice_reset_is_never_promised_at_detection() {
  local dir id out
  dir=$(make_case noticedetect "You have hit your session limit, resets $(clock_in_hours 8)")
  id=$(case_id noticedetect)
  set_busy_state "$dir" "$id" idle || fail "noticedetect: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # No quota-axi anywhere, which is the only home the notice fallback runs on.
  rm -f "$dir/fakebin/quota-axi"

  out=$(run_scan "$dir" "$id" FM_QUOTA_AXI_BIN=quota-axi-absent-for-test)
  assert_present "$dir/state/$id.quota-wait" "noticedetect: no wait was recorded from the stated notice"
  fm_quota_wait_resume_reachable "$dir/state" "$id" &&
    fail "noticedetect: the stated reset was not capped, so this case proves nothing"
  assert_contains "$out" "NOT resumed automatically" \
    "noticedetect: detection announced a resume the ceiling will never deliver"
  assert_not_contains "$out" "this worker is resumed automatically" \
    "noticedetect: a capped wait was announced as one that resumes itself"
  pass "noticedetect: a notice stating a reset past the ceiling is never announced as self-resuming"
}

# The structural path borrows a rendered reset when the account names none, so
# it announces capped waits too and must answer the same question.
test_a_structural_wait_on_a_capped_borrowed_reset_is_never_promised() {
  local dir id out
  dir=$(make_case structcapped "You have hit your session limit, resets $(clock_in_hours 8)")
  id=$(case_id structcapped)
  set_busy_state "$dir" "$id" idle || fail "structcapped: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # Machine-verified refusal that names no limiting window, so the reset time -
  # and only the reset time - comes from the pane.
  cat > "$dir/quota.json" <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known", "runway": { "status": "exhausted_now" } }
        ]
      }
    }
  ]
}
JSON

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_present "$dir/state/$id.quota-wait" "structcapped: the verified refusal recorded nothing at all"
  [ "$(fm_quota_wait_field "$dir/state" "$id" evidence)" = structural ] ||
    fail "structcapped: a structurally verified refusal was recorded as weaker evidence"
  fm_quota_wait_resume_reachable "$dir/state" "$id" &&
    fail "structcapped: the borrowed reset was not capped, so this case proves nothing"
  assert_contains "$out" "NOT resumed automatically" \
    "structcapped: detection announced a resume the ceiling will never deliver"
  pass "structcapped: a structural wait whose borrowed reset is capped is never announced as self-resuming"
}

test_a_wait_whose_agent_died_is_retired_by_the_scan() {
  local dir id out
  dir=$(make_case deadwait "the worker stopped mid-task")
  id=$(case_id deadwait)
  set_busy_state "$dir" "$id" idle || fail "deadwait: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # A current wait whose reset is hours away. The watcher absorbs this pane
  # ahead of its own liveness read on purpose, so if the agent dies mid-wait
  # nothing else in the fleet can notice until the reset arrives.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) + 7200 ))" structural \
    "$(fm_quota_fingerprint structural claude deadwait)" ||
    fail "deadwait: could not write the wait record"
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 7200)"
  PATH="$dir/fakebin:$PATH" tmux kill-window -t "$SESSION:fm-$id" 2>/dev/null || true

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_absent "$dir/state/$id.quota-wait" \
    "deadwait: a wait kept absorbing the stale path after its agent died"
  assert_contains "$out" "no longer reports a live agent" \
    "deadwait: the retired wait was not reported"
  # The refusal was never resolved, so its evidence must stay unspent and the
  # pane must be able to earn a wait again if the endpoint comes back.
  assert_absent "$dir/state/$id.quota-spent" \
    "deadwait: a wait retired for a dead endpoint spent its evidence fingerprint"
  pass "deadwait: a wait whose endpoint stops reporting a live agent is retired instead of absorbing the wedge path"
}

test_a_failed_resume_read_keeps_the_scan_snapshot() {
  local dir a b out
  dir=$(make_case sharedsnapshot "the worker stopped mid-task")
  a=$(case_id sharedsnapshot)
  # A second worker in the same home, on a different provider, iterated AFTER
  # the one whose resume is due. It reads its account from the snapshot that one
  # scan shares, so a forced re-read that fails must not take that snapshot with
  # it. Its provider comes from quota-axi's published catalog rather than its
  # harness name, which is the only shape a second provider can take in a home
  # whose semantic busy contract can classify the pane.
  b="${a}z"
  ln -sf "$SLEEP_BIN" "$dir/bin/opencode"
  PATH="$dir/fakebin:$PATH" tmux new-window -d -n "fm-$b" \
    "sh -c 'cat $dir/pane.txt; exec $dir/bin/opencode 100000'"
  local i=0
  while [ "$i" -lt 50 ]; do
    PATH="$dir/fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$b" 2>/dev/null |
      grep -q . && break
    sleep 0.1
    i=$((i + 1))
  done
  fm_write_meta "$dir/state/$b.meta" \
    "window=$SESSION:fm-$b" "endpoint_task_id=$b" "worktree=$dir/wt" "project=$dir/wt" \
    "harness=opencode" "kind=ship" "model=gpt-5.3-codex" "effort=default"
  printf 'working: implementing the fix\n' > "$dir/state/$b.status"
  set_busy_state "$dir" "$a" idle || fail "sharedsnapshot: could not record an idle busy state"
  set_busy_state "$dir" "$b" idle opencode-plugin ||
    fail "sharedsnapshot: could not record the second idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  write_quota_json_pair "$dir/quota.json" exhausted_now "$(iso_in 3600)"
  fm_quota_wait_write "$dir/state" "$a" claude claude "$(( $(date +%s) - 600 ))" structural \
    "$(fm_quota_fingerprint structural claude sharedsnapshot)" ||
    fail "sharedsnapshot: could not write the wait record"

  # The scan's own read succeeds; the forced re-read the resume makes does not.
  rm -f "$dir/quota-calls"
  out=$(run_scan "$dir" "$a" FM_FAKE_QUOTA_JSON="$dir/quota.json" FM_FAKE_QUOTA_FAIL_AFTER=1)

  assert_present "$dir/state/$b.quota-wait" \
    "sharedsnapshot: a failed resume-time read cost a later worker the structural evidence already read for it"
  [ "$(fm_quota_wait_field "$dir/state" "$b" evidence)" = structural ] ||
    fail "sharedsnapshot: the later worker fell back to weaker evidence than the scan had already read"
  pass "sharedsnapshot: a resume reads its account into a snapshot of its own, never the one the scan shares"
}

test_an_exhausted_account_with_no_banner_and_no_reset_still_records() {
  local dir id out
  dir=$(make_case noresetnobanner "the worker stopped mid-task")
  id=$(case_id noresetnobanner)
  set_busy_state "$dir" "$id" idle || fail "noresetnobanner: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # The vendor verified the refusal and named no window, and the pane renders no
  # notice either, so there is nothing anywhere to read a reset time from. The
  # verdict is still machine-read, so the wait is still recorded - bounded, and
  # never resumed automatically.
  PATH="$dir/fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$id" 2>/dev/null |
    grep -qiE 'limit' && fail "noresetnobanner: the pane rendered a limit notice, so this case proves nothing"
  cat > "$dir/quota.json" <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known", "runway": { "status": "exhausted_now" } }
        ]
      }
    }
  ]
}
JSON

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_present "$dir/state/$id.quota-wait" \
    "noresetnobanner: a machine-verified refusal with no reset anywhere recorded nothing at all"
  [ "$(fm_quota_wait_field "$dir/state" "$id" evidence)" = structural ] ||
    fail "noresetnobanner: a structurally verified refusal was recorded as weaker evidence"
  [ "$(fm_quota_wait_field "$dir/state" "$id" reset)" = unknown ] ||
    fail "noresetnobanner: a reset time was recorded that nothing could have read"
  assert_contains "$out" "NOT resumed automatically" \
    "noresetnobanner: a wait nothing can resume was not reported as one"
  # A wait with no reset has no time to state, so the line must not render one.
  assert_not_contains "$out" "resets" \
    "noresetnobanner: a wait carrying no reset was reported as if it had one"
  assert_not_contains "$out" "headroom could not be read" \
    "noresetnobanner: a machine-read exhausted account was reported as unreadable"
  pass "noresetnobanner: an exhausted account with no reset anywhere still records a bounded structural wait"
}

test_an_exhausted_account_with_no_readable_reset_still_records() {
  local dir id out
  dir=$(make_case noreset "$BANNER")
  id=$(case_id noreset)
  set_busy_state "$dir" "$id" idle || fail "noreset: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # The vendor says the account is exhausted but names no limiting window, so
  # nothing carries a resetsAt. Ending the arm there would leave a worker parked
  # exactly as in the reported incident, on a home that does have quota-axi.
  cat > "$dir/quota.json" <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known", "runway": { "status": "exhausted_now" } }
        ]
      }
    }
  ]
}
JSON

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_present "$dir/state/$id.quota-wait" \
    "noreset: a machine-verified refusal with no readable reset recorded nothing at all"
  assert_contains "$out" "quota-limit:" "noreset: the refusal was not reported"
  [ "$(fm_quota_wait_field "$dir/state" "$id" provider)" = claude ] ||
    fail "noreset: the wait did not carry the provider the vendor named"
  # The verdict came from quota-axi, so the record must say so; the notice was
  # read for its reset time alone. Reporting this as unreadable headroom would
  # tell the captain the opposite of what the machine read.
  [ "$(fm_quota_wait_field "$dir/state" "$id" evidence)" = structural ] ||
    fail "noreset: a structurally verified refusal was recorded as weaker evidence"
  case "$(fm_quota_wait_field "$dir/state" "$id" reset)" in
    ''|*[!0-9]*) fail "noreset: the reset the notice stated was not taken from it" ;;
  esac
  assert_not_contains "$out" "headroom could not be read" \
    "noreset: a machine-read exhausted account was reported as unreadable"
  pass "noreset: an exhausted account takes its reset from the notice while the verdict stays structural"
}

test_a_worker_holding_a_blocker_is_never_parked_or_nudged() {
  local dir id out
  dir=$(make_case blockedworker "the worker stopped mid-task")
  id=$(case_id blockedworker)
  set_busy_state "$dir" "$id" idle || fail "blockedworker: could not record an idle busy state"
  # A declared blocker reads `none` through the crew verdict, exactly like a
  # worker that simply stopped, so the crew read alone cannot tell them apart.
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  printf 'blocked: cannot reach the staging DB\n' > "$dir/state/$id.status"
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_absent "$dir/state/$id.quota-wait" \
    "blockedworker: a worker awaiting an answer to its own blocker was recorded as quota-parked"
  assert_not_contains "$out" "is waiting on" "blockedworker: a blocked worker was reported as quota-parked"

  # And the resume refuses it too, for a wait recorded before the blocker was
  # declared: a nudge here restarts a worker past the answer it asked for.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" structural \
    "$(fm_quota_fingerprint structural claude blockedworker)" ||
    fail "blockedworker: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  [ ! -s "$dir/sent.log" ] || fail "blockedworker: a resume was delivered into a worker holding an open blocker"
  assert_contains "$out" "was not resumed automatically" "blockedworker: the refusal was not reported"
  assert_absent "$dir/state/$id.quota-wait" \
    "blockedworker: the refused wait was not retired back to ordinary supervision"
  pass "blockedworker: a worker holding a declared blocker is never quota-parked and never nudged"
}

test_a_non_numeric_bound_degrades_to_the_documented_default() {
  local dir id out
  dir=$(make_case badbound "$BANNER")
  id=$(case_id badbound)
  set_busy_state "$dir" "$id" idle || fail "badbound: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # A wait recorded just now, well inside the bound it is supposed to carry.
  fm_quota_wait_write "$dir/state" "$id" claude claude unknown banner ||
    fail "badbound: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"

  # The tunable set to something this code cannot read as a number. Bash fails
  # the arithmetic outright, and the deadline read is the ONE thing standing
  # between a recorded wait and being treated as expired, so an unguarded knob
  # silently drops every reset-less wait the moment it is mistyped.
  FM_QUOTA_BANNER_WAIT_MAX_SECS=30m fm_quota_wait_active "$dir/state" "$id" ||
    fail "badbound: a wait inside its own bound read as expired under a non-numeric knob"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" \
    FM_QUOTA_BANNER_WAIT_MAX_SECS=30m)
  assert_present "$dir/state/$id.quota-wait" \
    "badbound: a non-numeric bound retired a wait that was still inside its own bound"
  assert_not_contains "$out" "expired without a usable reset time" \
    "badbound: a current wait was reported as expired under a non-numeric bound"
  pass "badbound: a bound this code cannot read as a number degrades to the documented default"
}

# Hold a claim from a separate live process, which is what a concurrent scan is.
# Sets HOLD_CLAIM_PID for the caller to kill.
hold_claim() {  # <dir> <lock>
  local dir=$1 claim_lock=$2 i=0
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    . "$ROOT/bin/fm-wake-lib.sh"
    FM_STATE_OVERRIDE="$dir/state" fm_lock_try_acquire "$claim_lock" || exit 1
    sleep 60
  ) &
  HOLD_CLAIM_PID=$!
  while [ "$i" -lt 100 ]; do
    if [ -e "$claim_lock" ] || [ -L "$claim_lock" ]; then
      return 0
    fi
    kill -0 "$HOLD_CLAIM_PID" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_one_reset_is_claimed_by_exactly_one_scan() {
  local dir id lock out rc
  dir=$(make_case oneclaim "the worker stopped mid-task")
  id=$(case_id oneclaim)
  set_busy_state "$dir" "$id" idle || fail "oneclaim: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  lock="$dir/state/$id.quota-nudged.lock"

  # Two scans can be in flight at once: a watcher displaced by the stale-lock
  # steal still overlaps the one that replaced it, and both sit in the forced
  # re-probe for seconds before either would write. The claim is what makes the
  # reset one reset rather than two nudges.
  rc=0; fm_quota_nudge_claim "$dir/state" "$id" 1000 || rc=$?
  [ "$rc" = 0 ] || fail "oneclaim: the first claim on an unspent reset was refused (rc=$rc)"
  rc=0; fm_quota_nudge_claim "$dir/state" "$id" 1000 || rc=$?
  [ "$rc" = 1 ] || fail "oneclaim: a spent reset was claimed a second time (rc=$rc)"

  # A scan that cannot take the claim delivers nothing and leaves the wait for a
  # later scan rather than racing the holder. The holder is a separate live
  # process, which is what a concurrent scan actually is.
  hold_claim "$dir" "$lock" || fail "oneclaim: could not hold the claim from another process"
  rc=0; fm_quota_nudge_claim "$dir/state" "$id" 2000 || rc=$?
  [ "$rc" = 2 ] || fail "oneclaim: a contended claim was granted anyway (rc=$rc)"

  # And end to end: a scan whose claim another process holds delivers no text.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" structural \
    "$(fm_quota_fingerprint structural claude oneclaim)" ||
    fail "oneclaim: could not write the wait record"
  rm -f "$dir/state/$id.quota-nudged"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  [ ! -s "$dir/sent.log" ] || fail "oneclaim: a scan delivered a resume whose claim another scan held"
  assert_present "$dir/state/$id.quota-wait" \
    "oneclaim: a scan that could not claim the reset retired the wait anyway"
  assert_not_contains "$out" "was resumed automatically" "oneclaim: an unclaimed resume was reported"

  # A scan KILLED mid-claim must not block every later resume forever.
  kill "$HOLD_CLAIM_PID" 2>/dev/null || true
  wait_for_exit "$HOLD_CLAIM_PID" || fail "oneclaim: the holding process did not exit"
  [ -e "$lock" ] || [ -L "$lock" ] || fail "oneclaim: the abandoned hold did not persist"
  rc=0; fm_quota_nudge_claim "$dir/state" "$id" 3000 || rc=$?
  [ "$rc" = 0 ] || fail "oneclaim: a hold left by a dead scan blocked a legitimate later resume (rc=$rc)"
  pass "oneclaim: one reset is claimed by exactly one scan, and a dead holder never blocks a later one"
}

# The fingerprint gate, reached directly. A reset-less wait is the case that
# needs it: its evidence is byte-identical on the very next scan after it
# expires, and nothing else stops the pane oscillating forever between an
# absorbed wait and an escalating stale pane. A stated reset that has already
# passed is refused by the contradiction guard BEFORE this gate is consulted,
# so that shape cannot prove the gate works.
test_spent_evidence_cannot_record_a_second_wait() {
  local dir id out detected
  dir=$(make_case respendunknown "the worker stopped mid-task")
  id=$(case_id respendunknown)
  set_busy_state "$dir" "$id" idle || fail "respendunknown: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # Machine-verified refusal, no limiting window, and no notice in the pane, so
  # the wait carries no readable reset and its fingerprint never changes.
  PATH="$dir/fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$id" 2>/dev/null |
    grep -qiE 'limit' && fail "respendunknown: the pane rendered a limit notice, so the evidence is not reset-less"
  cat > "$dir/quota.json" <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          { "scope": "all_models", "status": "known", "runway": { "status": "exhausted_now" } }
        ]
      }
    }
  ]
}
JSON

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_present "$dir/state/$id.quota-wait" "respendunknown: no wait was recorded from the refusal"
  [ "$(fm_quota_wait_field "$dir/state" "$id" reset)" = unknown ] ||
    fail "respendunknown: the wait carried a reset time nothing could have read"

  # Age it past its own bound so the next scan retires it, which is what spends
  # the evidence. The account is still refusing and the pane still renders
  # nothing, so the evidence the next scan reads is unchanged.
  detected=$(( $(date +%s) - 7200 ))
  sed -i.bak "s/detected=[0-9]*/detected=$detected/" "$dir/state/$id.quota-wait" 2>/dev/null ||
    sed -i '' "s/detected=[0-9]*/detected=$detected/" "$dir/state/$id.quota-wait"
  rm -f "$dir/state/$id.quota-wait.bak"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" FM_QUOTA_PROBE_TTL=0)
  assert_contains "$out" "expired without a usable reset time" \
    "respendunknown: the wait did not retire on its own bound"
  assert_present "$dir/state/$id.quota-spent" "respendunknown: retiring the wait did not spend its evidence"

  # The gate itself: same account, same silent pane, same fingerprint.
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" FM_QUOTA_PROBE_TTL=0)
  assert_absent "$dir/state/$id.quota-wait" \
    "respendunknown: evidence that already produced a wait produced a second one"
  assert_not_contains "$out" "is waiting on" \
    "respendunknown: the same spent evidence was reported as a new refusal"

  # And the gate is not a blanket refusal: a reset the vendor can now name is
  # different evidence and records normally.
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" FM_QUOTA_PROBE_TTL=0)
  assert_present "$dir/state/$id.quota-wait" \
    "respendunknown: a refusal the vendor can now date did not record a new wait"
  pass "respendunknown: spent evidence cannot record a second wait, while changed evidence still can"
}

test_evidence_that_already_made_a_wait_never_makes_another() {
  local dir id out stale_reset
  dir=$(make_case respend "the worker stopped mid-task")
  id=$(case_id respend)
  set_busy_state "$dir" "$id" idle || fail "respend: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # An account that is out of headroom and whose stated reset never moves. The
  # first scan records the wait; the reset then arrives while the account is
  # still refusing, which ends the wait. Nothing may record it a second time
  # from that same unchanged evidence, or the pane would oscillate forever
  # between an absorbed wait and an escalating stale pane.
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 900)"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_contains "$out" "quota-limit:" "respend: the first refusal was not recorded"
  assert_present "$dir/state/$id.quota-wait" "respend: no wait was recorded"

  # The stated reset arrives while the account is still refusing. Reached by
  # moving both the record and the vendor's answer to the same past instant
  # rather than by sleeping, so the case is deterministic.
  stale_reset=$(( $(date +%s) - 300 ))
  fm_quota_wait_write "$dir/state" "$id" claude claude "$stale_reset" structural \
    "$(fm_quota_fingerprint structural claude "$stale_reset")" ||
    fail "respend: could not restate the wait at its stated reset"
  write_quota_json "$dir/quota.json" claude exhausted_now \
    "$(date -u -d "@$stale_reset" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$stale_reset" '+%Y-%m-%dT%H:%M:%SZ')"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" \
    FM_QUOTA_RESET_GRACE_SECS=0 FM_QUOTA_PROBE_TTL=0)
  assert_contains "$out" "still refused" "respend: the unresolvable wait did not end"
  assert_absent "$dir/state/$id.quota-wait" "respend: the unresolvable wait was not retired"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" FM_QUOTA_PROBE_TTL=0 \
    FM_QUOTA_RESET_GRACE_SECS=0)
  assert_absent "$dir/state/$id.quota-wait" \
    "respend: the same unchanged evidence recorded a second wait"
  assert_not_contains "$out" "is waiting on" "respend: the same unchanged evidence was reported again"
  [ ! -s "$dir/sent.log" ] || fail "respend: an unresolvable refusal still produced a resume"

  # New evidence - the account now names a reset it can actually reach - is a
  # different refusal and records normally.
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 3600)"
  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json" FM_QUOTA_PROBE_TTL=0)
  assert_present "$dir/state/$id.quota-wait" "respend: a moved reset did not record a new wait"
  pass "respend: evidence that already produced a wait cannot produce another, while a moved reset can"
}

test_a_local_secondmate_is_treated_like_any_other_worker() {
  local dir id out sends
  dir=$(make_case mate "the mate stopped mid-task")
  id=$(case_id mate)
  # Same endpoint, recorded as a persistent mate rather than a task worker.
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$dir/state/$id.meta" 2>/dev/null ||
    sed -i '' 's/^kind=ship$/kind=secondmate/' "$dir/state/$id.meta"
  rm -f "$dir/state/$id.meta.bak"
  set_busy_state "$dir" "$id" idle || fail "mate: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" structural ||
    fail "mate: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  assert_contains "$out" "was resumed automatically" "mate: a local mate was not resumed after its limit reset"
  sends=$(wc -l < "$dir/sent.log" 2>/dev/null | tr -d ' ')
  [ "$sends" = 1 ] || fail "mate: expected exactly 1 delivered resume, got ${sends:-0}"
  # A secondmate selector is exactly what bin/fm-send.sh marks, so this is the
  # case where delivering to the selector would arm a pending-reply expectation
  # and cost the mate a second, unrelated injection.
  assert_grep "$SESSION:fm-$id" "$dir/sent.log" \
    "mate: a mate's resume was delivered to the marked task selector"
  pass "mate: a persistent mate whose endpoint this home can read is resumed on the same terms as any worker"
}

test_an_unreachable_endpoint_is_never_nudged() {
  local dir id out
  dir=$(make_case remote "the mate stopped mid-task")
  id=$(case_id remote)
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # A remotely placed mate records an endpoint this home cannot probe at all.
  fm_write_meta "$dir/state/$id.meta" \
    "window=remote:$id" "endpoint_task_id=$id" "worktree=$dir/wt" "project=$dir/wt" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "model=default"
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) - 600 ))" structural ||
    fail "remote: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"

  out=$(run_scan "$dir" "$id" FM_FAKE_QUOTA_JSON="$dir/quota.json")
  [ ! -s "$dir/sent.log" ] || fail "remote: text was delivered into an endpoint this home cannot probe"
  assert_contains "$out" "was not resumed automatically" "remote: the refusal was not reported"
  pass "remote: an endpoint this home cannot probe is reported rather than nudged blind"
}

# --- the absorb bin/fm-watch.sh gives a recorded wait -----------------------

# Wait up to <limit> 0.1s ticks for <pid> to exit; 0 if it exited.
wait_for_exit() {  # <pid> [limit]
  local pid=$1 limit=${2:-150} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Drain and acknowledge the durable queue the way a handling turn does, so the
# next watcher arms cleanly instead of re-announcing an unhandled queue forever.
drain_and_ack() {  # <dir>
  local dir=$1 err sequence generation
  err="$dir/drain.err"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || true
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 0
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1 || true
}

# One supervision round against the case's real pane: arm the real watcher,
# wait for it to surface something, then drain and acknowledge like a handling
# turn. 0 while the watcher exited on its own.
watch_round() {  # <dir> <out>
  local dir=$1 out=$2 pid rc=0
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_QUOTA_SEND_BIN="$dir/fakebin/fm-send-recorder.sh" \
    FM_FAKE_SEND_LOG="$dir/sent.log" \
    FM_FAKE_QUOTA_JSON="$dir/quota.json" FM_FAKE_QUOTA_MODELS="$dir/models.json" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=2 FM_PAUSE_RESURFACE_SECS=3 \
    "$WATCH" >> "$out" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 300 || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=1; }
  drain_and_ack "$dir"
  return "$rc"
}

test_watcher_absorbs_a_recorded_wait_instead_of_escalating() {
  local dir id out key affirmative round
  dir=$(make_case absorb "the worker stopped mid-task")
  id=$(case_id absorb)
  set_busy_state "$dir" "$id" idle || fail "absorb: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # A current wait whose reset is far off: the scan has nothing to do, so the
  # only thing under test is what the stale path does with the record.
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) + 7200 ))" structural ||
    fail "absorb: could not write the wait record"
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 7200)"
  out="$dir/watch.out"
  : > "$out"

  # Several rounds: the first wakes surface this task's own unseen status line
  # and the recovery re-announcement, and the stale recheck under test comes
  # after them. The loop stops as soon as either verdict has been printed.
  round=0
  while [ "$round" -lt 8 ]; do
    watch_round "$dir" "$out" || break
    grep -q 'usage limit to reset' "$out" && break
    grep -q 'possible wedge' "$out" && break
    round=$((round + 1))
  done

  assert_grep "usage limit to reset" "$out" \
    "absorb: the stale recheck did not name the provider limit the worker is waiting on"
  assert_no_grep "possible wedge" "$out" \
    "absorb: a worker parked on a known provider limit was still escalated as a possible wedge"
  # The absorb runs before the liveness read, so 48b3ea3's affirmative-liveness
  # chain is neither advanced nor cleared by a pane whose idleness is already
  # explained: that backoff keeps deciding only the cases it was built for.
  key=$(printf '%s' "$SESSION:fm-$id" | tr ':/.' '___')
  affirmative="$dir/state/.wedge-affirmative-$key"
  assert_absent "$affirmative" \
    "absorb: a recorded quota wait still spent an affirmative-liveness reading"
  pass "absorb: a recorded quota wait is rechecked on the bounded cadence, never escalated as a wedge"
}

test_the_watcher_never_absorbs_a_terminal_status_behind_a_wait() {
  local dir id out round
  dir=$(make_case absorbterminal "the worker stopped mid-task")
  id=$(case_id absorbterminal)
  set_busy_state "$dir" "$id" idle || fail "absorbterminal: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # The worker reported blocked BEFORE the account was exhausted. It is still
  # blocked, and the wait explains an idle pane, never a reading the captain is
  # still owed.
  printf 'blocked: cannot reach the staging DB\n' > "$dir/state/$id.status"
  fm_quota_wait_write "$dir/state" "$id" claude claude "$(( $(date +%s) + 7200 ))" structural ||
    fail "absorbterminal: could not write the wait record"
  write_quota_json "$dir/quota.json" claude exhausted_now "$(iso_in 7200)"
  out="$dir/watch.out"
  : > "$out"

  round=0
  while [ "$round" -lt 8 ]; do
    watch_round "$dir" "$out" || break
    grep -q 'usage limit to reset' "$out" && break
    grep -q "stale: quota:fm-$id" "$out" && break
    round=$((round + 1))
  done

  assert_no_grep "usage limit to reset" "$out" \
    "absorbterminal: the watcher absorbed a blocked worker behind its quota wait"
  assert_grep "stale: quota:fm-$id" "$out" \
    "absorbterminal: a blocked worker behind a quota wait never reached the ordinary stale path"
  pass "absorbterminal: the watcher's absorb refuses a terminal status exactly as the owner does"
}

test_a_wait_with_no_reset_is_never_reported_as_self_resuming() {
  local dir id out round
  dir=$(make_case absorbunknown "the worker stopped mid-task")
  id=$(case_id absorbunknown)
  set_busy_state "$dir" "$id" idle || fail "absorbunknown: could not record an idle busy state"
  make_fake_crew_state "$dir" "state: unknown · source: none · idle"
  # The one wait the design says a human must pick up: a rendered notice matched,
  # but it stated no reset time, so nothing will ever resume this worker.
  fm_quota_wait_write "$dir/state" "$id" unattributed claude unknown banner ||
    fail "absorbunknown: could not write the wait record"
  write_quota_json "$dir/quota.json" claude through_reset "$(iso_in 3600)"
  out="$dir/watch.out"
  : > "$out"

  round=0
  while [ "$round" -lt 8 ]; do
    watch_round "$dir" "$out" || break
    grep -q 'usage limit to reset' "$out" && break
    grep -q 'possible wedge' "$out" && break
    round=$((round + 1))
  done

  assert_grep "usage limit to reset" "$out" \
    "absorbunknown: the stale recheck did not name the provider limit the worker is waiting on"
  assert_grep "NOT resumed automatically" "$out" \
    "absorbunknown: a wait with no readable reset was not reported as needing a human"
  assert_no_grep "this worker is resumed automatically" "$out" \
    "absorbunknown: a wait that can never be resumed promised an automatic resume"
  assert_no_grep "the unattributed usage limit" "$out" \
    "absorbunknown: the internal unattributed token was rendered as a provider name"
  pass "absorbunknown: a wait with no readable reset is surfaced as one nothing will resume"
}

test_the_suppression_owner_honours_both_guards
test_provider_attribution
test_structural_detection_without_a_banner
test_banner_detection_without_quota_axi
test_available_headroom_outranks_a_banner
test_a_busy_worker_is_never_parked
test_an_unreadable_pane_is_never_parked
test_resume_sends_exactly_one_nudge_per_reset
test_resume_reads_the_account_fresh_rather_than_from_cache
test_one_account_is_re_read_once_per_scan_not_once_per_worker
test_resume_refuses_an_unclassifiable_endpoint
test_resume_refuses_a_worker_that_is_working_again
test_a_still_refused_account_is_not_resumed
test_a_wait_with_no_readable_reset_expires_itself
test_a_wait_inside_the_reset_grace_window_survives
test_a_banner_that_states_its_reset_runs_to_it_and_resumes
test_a_worker_parked_by_design_is_never_recorded_as_refused
test_a_dead_endpoint_never_earns_a_quota_wait
test_a_notice_stated_reset_within_the_ceiling_waits_as_stated
test_a_notice_stated_reset_at_the_ceiling_is_measured_on_the_reset
test_a_notice_stated_reset_beyond_the_ceiling_is_capped
test_a_capped_notice_reset_is_never_reported_or_delivered_as_a_resume
test_a_capped_notice_reset_is_never_promised_at_detection
test_a_structural_wait_on_a_capped_borrowed_reset_is_never_promised
test_a_wait_whose_agent_died_is_retired_by_the_scan
test_a_failed_resume_read_keeps_the_scan_snapshot
test_an_exhausted_account_with_no_readable_reset_still_records
test_an_exhausted_account_with_no_banner_and_no_reset_still_records
test_a_worker_holding_a_blocker_is_never_parked_or_nudged
test_a_non_numeric_bound_degrades_to_the_documented_default
test_one_reset_is_claimed_by_exactly_one_scan
test_evidence_that_already_made_a_wait_never_makes_another
test_spent_evidence_cannot_record_a_second_wait
test_a_local_secondmate_is_treated_like_any_other_worker
test_an_unreachable_endpoint_is_never_nudged
test_watcher_absorbs_a_recorded_wait_instead_of_escalating
test_a_wait_with_no_reset_is_never_reported_as_self_resuming
test_the_watcher_never_absorbs_a_terminal_status_behind_a_wait
