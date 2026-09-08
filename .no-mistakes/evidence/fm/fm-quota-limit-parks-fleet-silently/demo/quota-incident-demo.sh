#!/usr/bin/env bash
# Manual end-to-end walkthrough of the reported incident, printed as the
# operator sees it. Not part of the repository test suite: it reuses the test
# suite's fixture builders (real tmux panes on a private socket, a stub
# quota-axi, a recording fm-send stand-in) and then drives the production
# scripts bin/fm-quota-watch.sh and bin/fm-watch.sh, echoing every operator
# facing line and every persisted record.
#
# Scenario, in order:
#   1. A worker on Claude is refused on quota. Its pane renders the incident
#      banner and its account reads exhausted_now with a reset 2h45m out.
#   2. The scan detects and records a bounded wait.
#   3. The watcher absorbs that wait instead of raising a wedge alarm.
#   4. The reset arrives; the scan delivers exactly one resume nudge, and a
#      second scan delivers none.
#   5. A second worker matches a notice that states no reset time. It is
#      recorded, reported with no time at all, and reported as one a human has
#      to pick up.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/quota-fixture-helpers.sh"

hr() { printf '\n=== %s ===\n' "$1"; }
show() { printf '%s\n' "$1"; }

hr "1. the incident: a refused worker whose pane and status look like a finished turn"
DIR=$(make_case incident "$BANNER")
ID=$(case_id incident)
set_busy_state "$DIR" "$ID" idle || { echo "could not record an idle busy state"; exit 1; }
make_fake_crew_state "$DIR" "state: unknown · source: none · idle"
write_quota_json "$DIR/quota.json" claude exhausted_now "$(iso_in 9900)"
show "worker id:        $ID (harness=claude, kind=ship)"
show "last status line: $(cat "$DIR/state/$ID.status")"
show "pane renders:     $(PATH="$DIR/fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$ID" | head -1)"
show "account reads:    exhausted_now, resets $(iso_in 9900) (2h45m out, as the incident stated)"
show "quota wait record: $([ -e "$DIR/state/$ID.quota-wait" ] && echo present || echo "none yet")"

hr "2. bin/fm-quota-watch.sh scan - what the operator sees"
run_scan "$DIR" "$ID" FM_FAKE_QUOTA_JSON="$DIR/quota.json"
hr "the record the scan persisted (state/$ID.quota-wait)"
cat "$DIR/state/$ID.quota-wait"
show "reset, rendered:  $(date -u -d "@$(fm_quota_wait_field "$DIR/state" "$ID" reset)" '+%Y-%m-%dT%H:%M:%SZ')"

hr "3. bin/fm-watch.sh supervision round - absorbed, not escalated as a wedge"
OUT="$DIR/watch.out"
: > "$OUT"
round=0
while [ "$round" -lt 8 ]; do
  watch_round "$DIR" "$OUT" || break
  grep -q 'usage limit' "$OUT" && break
  grep -q 'possible wedge' "$OUT" && break
  round=$((round + 1))
done
grep -E 'stale:|wedge|usage limit' "$OUT" | sed 's/^/  /' | head -5
show "wedge alarms raised: $(grep -c 'possible wedge' "$OUT" || true)"

hr "4. the reset arrives - exactly one resume nudge, and only one"
write_quota_json "$DIR/quota.json" claude through_reset "$(iso_in 3600)"
sed -i.bak "s/reset=[0-9]*/reset=$(( $(date +%s) - 120 ))/" "$DIR/state/$ID.quota-wait"
rm -f "$DIR/state/$ID.quota-wait.bak"
show "wait record now carries a reset already past; account reads through_reset"
run_scan "$DIR" "$ID" FM_FAKE_QUOTA_JSON="$DIR/quota.json"
show "nudges delivered (fm-send stand-in log):"
sed 's/^/  /' "$DIR/sent.log" 2>/dev/null || show "  (none)"
show "second scan over the same reset:"
run_scan "$DIR" "$ID" FM_FAKE_QUOTA_JSON="$DIR/quota.json" | sed 's/^/  /'
show "total nudges after the second scan: $(wc -l < "$DIR/sent.log" | tr -d ' ')"
show "wait record after the resume: $([ -e "$DIR/state/$ID.quota-wait" ] && echo present || echo "retired, ordinary supervision owns this pane again")"

hr "5. a notice that states no reset time - recorded, never described with a time"
DIR2=$(make_case noclock "Usage limit reached")
ID2=$(case_id noclock)
set_busy_state "$DIR2" "$ID2" idle || { echo "could not record an idle busy state"; exit 1; }
make_fake_crew_state "$DIR2" "state: unknown · source: none · idle"
rm -f "$DIR2/fakebin/quota-axi"
show "pane renders:     $(PATH="$DIR2/fakebin:$PATH" tmux capture-pane -p -t "$SESSION:fm-$ID2" | head -1)"
show "account:          unreadable (no quota-axi on this home)"
run_scan "$DIR2" "$ID2" FM_QUOTA_AXI_BIN=quota-axi-absent-for-test
hr "the record that detection persisted"
cat "$DIR2/state/$ID2.quota-wait"

hr "the same wait on the away-mode digest surface (bin/fm-supervise-daemon.sh)"
FM_TEST_DAEMON_SOURCED=1 . "$ROOT/bin/fm-supervise-daemon.sh"
printf '%s\n' "$(FM_STATE_OVERRIDE="$DIR2/state" classify_stale "$SESSION:fm-$ID2" "$DIR2/state")"
printf '\ndone\n'
