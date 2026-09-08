#!/usr/bin/env bash
# quota-refusal-e2e-demo.sh - end-to-end demonstration of the reported incident
# and the change that fixes it, driven exactly as an operator's watcher drives it.
#
# ACT 1 reproduces the incident against the evaluation baseline (main @ 9930e68):
#   a real tmux pane, a real live foreground process named like the agent, and
#   the rendered limit notice from the report. The baseline watcher is run
#   unmodified from a pristine checkout of 9930e68.
#
# ACT 2 runs the SAME fixture against this branch: detection, the recorded wait,
#   the watcher's absorb, and the automatic one-shot resume once the limit resets.
set -u

ROOT=${ROOT:?set ROOT to the worktree}
BASE_REF=${BASE_REF:-9930e688b378af9944c79d9807cad6c9df4a5aea}
. "$ROOT/tests/lib.sh"
. "$ROOT/bin/fm-timeout-lib.sh"
. "$ROOT/bin/fm-wake-lib.sh"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-classify-lib.sh"
. "$ROOT/bin/fm-quota-lib.sh"

REAL_TMUX=$(command -v tmux)
SLEEP_BIN=$(command -v sleep)
SOCKET="fm-quota-demo-$$"
SESSION=quota
BANNER='You have hit your session limit, resets 8:50am'
TMP=$(fm_test_tmproot fm-quota-demo)
BASE_TREE="$TMP/base-$BASE_REF"

cleanup_demo() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; fm_test_cleanup; }
trap cleanup_demo EXIT

say() { printf '\n%s\n' "$*"; }
rule() { printf '%s\n' '--------------------------------------------------------------------------'; }

iso_in() { date -u -d "@$(( $(date +%s) + $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

write_quota_json() {  # <file> <provider> <runway> <resetsAt>
  cat > "$1" <<JSON
{ "schemaVersion": 5, "providers": [ { "provider": "$2",
    "windows": [ { "id": "five_hour", "kind": "session", "resetsAt": "$4" } ],
    "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known",
        "limitingWindowIds": [ "five_hour" ], "runway": { "status": "$3" } } ] } } ] }
JSON
}

make_case() {  # <name> <pane-text>
  local name=$1 pane_text=$2 dir fakebin id i=0
  id="task$name"; dir="$TMP/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin" "$dir/wt" "$dir/bin"
  printf '#!/usr/bin/env bash\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCKET" > "$fakebin/tmux"
  ln -sf "$SLEEP_BIN" "$dir/bin/claude"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then cat "$FM_FAKE_QUOTA_MODELS"; exit 0; fi
[ -n "${FM_FAKE_QUOTA_JSON:-}" ] && [ -r "$FM_FAKE_QUOTA_JSON" ] || exit 1
cat "$FM_FAKE_QUOTA_JSON"
SH
  cat > "$fakebin/fm-send-recorder.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
SH
  printf '#!/usr/bin/env bash\nprintf "state: unknown \xc2\xb7 source: none \xc2\xb7 idle\\n"\n' > "$fakebin/fm-crew-state.sh"
  chmod +x "$fakebin"/*
  printf '%s\n' "$pane_text" > "$dir/pane.txt"
  PATH="$fakebin:$PATH" tmux new-session -d -s "$SESSION" -n "fm-$id" \
    "sh -c 'cat $dir/pane.txt; exec $dir/bin/claude 100000'" 2>/dev/null ||
    PATH="$fakebin:$PATH" tmux new-window -d -n "fm-$id" \
      "sh -c 'cat $dir/pane.txt; exec $dir/bin/claude 100000'"
  while [ "$i" -lt 50 ]; do
    PATH="$fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$id" 2>/dev/null | grep -q . && break
    sleep 0.1; i=$((i + 1))
  done
  fm_write_meta "$dir/state/$id.meta" "window=$SESSION:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/wt" "project=$dir/wt" "harness=claude" "kind=ship" \
    "model=claude-opus-4-5" "effort=default"
  printf 'working: implementing the fix\n' > "$dir/state/$id.status"
  cat > "$dir/models.json" <<'JSON'
{ "schemaVersion": 1, "models": [ { "provider": "claude", "id": "claude-opus-4-5" } ] }
JSON
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/state" "$id" >/dev/null 2>&1; cat "$dir/state/$id.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" "$id" idle --gen "$gen" \
    --source claude-hook --event demo >/dev/null 2>&1
  printf '%s\n' "$dir"
}

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

watch_round() {  # <dir> <out> <watch-binary>
  local dir=$1 out=$2 bin=$3 pid rc=0 i=0
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_QUOTA_SEND_BIN="$dir/fakebin/fm-send-recorder.sh" \
    FM_FAKE_SEND_LOG="$dir/sent.log" \
    FM_FAKE_QUOTA_JSON="$dir/quota.json" FM_FAKE_QUOTA_MODELS="$dir/models.json" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=2 FM_PAUSE_RESURFACE_SECS=3 \
    "$bin" >> "$out" 2>&1 &
  pid=$!
  while [ "$i" -lt 300 ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && { kill "$pid" 2>/dev/null; rc=1; }
  wait "$pid" 2>/dev/null
  drain_and_ack "$dir"
  return "$rc"
}

run_scan() {  # <dir> [extra env...]
  local dir=$1; shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_QUOTA_SEND_BIN="$dir/fakebin/fm-send-recorder.sh" \
    FM_FAKE_SEND_LOG="$dir/sent.log" FM_FAKE_QUOTA_MODELS="$dir/models.json" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_QUOTA_SCAN_INTERVAL=0 \
    env "$@" "$ROOT/bin/fm-quota-watch.sh" scan 2>&1
}

# --------------------------------------------------------------------------
say "SETUP - the reported incident, staged for real"
rule
mkdir -p "$BASE_TREE"
git -C "$ROOT" archive "$BASE_REF" | tar -x -C "$BASE_TREE"
printf 'baseline checkout: main @ %s (evaluation baseline from the intent)\n' "${BASE_REF:0:7}"
printf 'this branch:       %s\n' "$(git -C "$ROOT" rev-parse --short HEAD)"

DIR_A=$(make_case incident "$BANNER")
ID_A=taskincident
printf '\nthe worker pane, as an operator sees it (tmux capture-pane):\n'
PATH="$DIR_A/fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$ID_A" | sed '/^$/d' | sed 's/^/  | /'
printf '\nits foreground process is genuinely alive:\n'
PATH="$DIR_A/fakebin:$PATH" tmux list-panes -t "$SESSION:fm-$ID_A" -F '  | pane #{pane_pid} command=#{pane_current_command} dead=#{pane_dead}'
printf '  | last status line the worker wrote: %s' "$(cat "$DIR_A/state/$ID_A.status")"
write_quota_json "$DIR_A/quota.json" claude exhausted_now "$(iso_in 7200)"
printf '  | quota-axi says for provider claude: runway=exhausted_now, five_hour window resets %s\n' "$(iso_in 7200)"

say "ACT 1 - BASELINE main @ ${BASE_REF:0:7}: what actually happened on 2026-09-05"
rule
OUT_A="$DIR_A/watch.out"; : > "$OUT_A"
round=0
while [ "$round" -lt 8 ]; do
  watch_round "$DIR_A" "$OUT_A" "$BASE_TREE/bin/fm-watch.sh" || break
  grep -q 'possible wedge' "$OUT_A" && break
  round=$((round + 1))
done
grep -E 'stale:|possible wedge|quota' "$OUT_A" | sed 's/^/  | /'
printf '\n  quota wait recorded by the baseline?  %s\n' \
  "$(ls "$DIR_A/state" | grep -c 'quota-wait' | sed 's/^0$/NO - nothing records a reset time/')"
printf '  resume nudge ever delivered?          %s\n' \
  "$([ -s "$DIR_A/sent.log" ] && cat "$DIR_A/sent.log" || printf 'NO - the worker parks until a human notices')"

say "ACT 2 - THIS BRANCH: same pane, same account, same banner"
rule
DIR_B=$(make_case fixed "$BANNER")
ID_B=taskfixed
write_quota_json "$DIR_B/quota.json" claude exhausted_now "$(iso_in 7200)"

printf 'step 1 - the watcher poll loop runs its own quota scan cadence:\n'
run_scan "$DIR_B" FM_FAKE_QUOTA_JSON="$DIR_B/quota.json" | sed 's/^/  | /'
printf '\nstep 2 - the durable wait record it wrote (state/%s.quota-wait):\n' "$ID_B"
sed 's/^/  | /' "$DIR_B/state/$ID_B.quota-wait"
printf '  | reset renders as: %s\n' \
  "$(fm_quota_format_reset "$(sed -n 's/.*reset=\([^ ]*\).*/\1/p' "$DIR_B/state/$ID_B.quota-wait")")"

printf '\nstep 3 - the same watcher that escalated in ACT 1, now on this branch:\n'
OUT_B="$DIR_B/watch.out"; : > "$OUT_B"
round=0
while [ "$round" -lt 8 ]; do
  watch_round "$DIR_B" "$OUT_B" "$ROOT/bin/fm-watch.sh" || break
  grep -q 'usage limit to reset' "$OUT_B" && break
  grep -q 'possible wedge' "$OUT_B" && break
  round=$((round + 1))
done
grep -E 'stale:|possible wedge|usage limit' "$OUT_B" | sed 's/^/  | /'
key=$(printf '%s' "$SESSION:fm-$ID_B" | tr ':/.' '___')
printf '  | affirmative-liveness reading spent by the parked pane (48b3ea3): %s\n' \
  "$([ -e "$DIR_B/state/.wedge-affirmative-$key" ] && printf 'YES' || printf 'none - the absorb runs before the liveness read')"

printf '\nstep 4 - the quota window turns over; the account reports headroom again:\n'
write_quota_json "$DIR_B/quota.json" claude through_reset "$(iso_in 3600)"
fm_quota_wait_write "$DIR_B/state" "$ID_B" claude claude "$(( $(date +%s) - 600 ))" structural \
  "$(sed -n 's/.*fp=\(.*\)$/\1/p' "$DIR_B/state/$ID_B.quota-wait")"
printf '  | quota-axi for claude: runway=through_reset (limit has reset)\n'
run_scan "$DIR_B" FM_FAKE_QUOTA_JSON="$DIR_B/quota.json" | sed 's/^/  | /'
printf '\n  text actually delivered into the worker (target<TAB>message):\n'
sed 's/^/  | /' "$DIR_B/sent.log"

printf '\nstep 5 - the loop keeps polling. One nudge per reset, never a retry loop:\n'
run_scan "$DIR_B" FM_FAKE_QUOTA_JSON="$DIR_B/quota.json" >/dev/null 2>&1
run_scan "$DIR_B" FM_FAKE_QUOTA_JSON="$DIR_B/quota.json" >/dev/null 2>&1
printf '  | total resume nudges delivered after 3 scans: %s\n' "$(wc -l < "$DIR_B/sent.log" | tr -d ' ')"
printf '  | wait record after the resume: %s\n' \
  "$([ -e "$DIR_B/state/$ID_B.quota-wait" ] && printf 'still held' || printf 'retired - the pane is back on ordinary supervision')"
rule
