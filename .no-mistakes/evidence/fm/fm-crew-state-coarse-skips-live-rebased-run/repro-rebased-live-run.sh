#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-07 false-FAILED report on task
# persea-scheduled-irrigation-inert, replayed against the firstmate code before
# and after the fix.
#
# Recorded facts being replayed:
#   run.status running, awaiting_agent parked 1h36m, gate.step ci,
#   gate.status awaiting_approval, PR open, branch_sync.relation diverged,
#   local.head d3db869f, pipeline current_head/pushed_head 5b08bdc7,
#   coarse runs listing (newest first): running <branch> 5b08bdc7
#                                       failed  <branch> d3db869f
set -u

REPO=${1:?repo checkout under test}
LABEL=${2:?label}
SCENARIO=${3:-rebased-live}   # rebased-live | genuinely-dead | diverged-failed-alone
WORK=$(mktemp -d)
HOME_DIR="$WORK/home"
WT="$WORK/worktree"
BRANCH=fm/persea-scheduled-irrigation-inert
ID=persea-scheduled-irrigation-inert

export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/config" "$WT"

# The crew's worktree: the pipeline rewrote history, so the local head and the
# pipeline head are siblings - neither is an ancestor of the other.
git -C "$WT" init -q
git -C "$WT" commit -q --allow-empty -m 'base'
BASE=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q -b "$BRANCH"
git -C "$WT" commit -q --allow-empty -m 'crew work the earlier run validated'
LOCAL_HEAD=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q -b tmp-pipeline "$BASE"
git -C "$WT" commit -q --allow-empty -m 'no-mistakes(document): rebased pipeline commit'
LIVE_HEAD=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q "$BRANCH"
git -C "$WT" merge-base --is-ancestor "$LIVE_HEAD" "$LOCAL_HEAD" 2>/dev/null \
  && { echo "fixture is not a rewrite"; exit 1; }
git -C "$WT" merge-base --is-ancestor "$LOCAL_HEAD" "$LIVE_HEAD" 2>/dev/null \
  && { echo "fixture is not a rewrite"; exit 1; }
LOCAL_SHORT=$(git -C "$WT" rev-parse --short=8 "$LOCAL_HEAD")
LIVE_SHORT=$(git -C "$WT" rev-parse --short=8 "$LIVE_HEAD")

cat > "$HOME_DIR/state/$ID.meta" <<META
window=firstmate:fm-$ID
worktree=$WT
project=persea
harness=claude
kind=ship
mode=ship
yolo=off
pr=https://github.com/kunchenguid/persea/pull/41
META
if [ "$SCENARIO" = diverged-failed-alone ]; then
  printf 'working: reworking after the rebased run failed\n' > "$HOME_DIR/state/$ID.status"
  BUSY_GEN=$("$REPO/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$ID")
  "$REPO/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$ID" idle --gen "$BUSY_GEN" \
    --source claude-hook --event stop >/dev/null
else
  printf 'needs-decision: ci gate\n' > "$HOME_DIR/state/$ID.status"
fi
cat > "$HOME_DIR/data/backlog.md" <<'BL'
## In flight
- [ ] persea-scheduled-irrigation-inert - Scheduled irrigation inert (repo: persea) (kind: ship) (since 2026-09-06)
BL

if [ "$SCENARIO" = diverged-failed-alone ]; then
# The boundary the requester fixed: `axi status` answers about ANOTHER crew, so
# the coarse listing alone decides, and the branch's only row is a terminal word
# on the rewritten head. Branch identity after a rewrite may not manufacture the
# one verdict recovery acts on, so the crew's own recorded state is read.
export FM_FAKE_AXI_STATUS="run:
  id: \"01RUNOTHER\"
  branch: fm/some-other-crew
  status: running
  head: \"$LIVE_HEAD\"
  pr: \"\"
  findings: none"
export FM_FAKE_RUNS_LIST="  failed     $BRANCH $LIVE_SHORT  2026-09-07 02:02"
elif [ "$SCENARIO" = genuinely-dead ]; then
# The other direction: the run really did fail, at the head this worktree holds,
# and the branch's newest row is a terminal word on the rewritten head. The
# rewrite must not talk the reader into calling a dead run alive.
export FM_FAKE_AXI_STATUS="run:
  id: \"01RUNPERSEA\"
  branch: $BRANCH
  status: completed
  head: \"$LOCAL_HEAD\"
  pr: \"\"
  findings: none
outcome: failed"
export FM_FAKE_RUNS_LIST="  failed     $BRANCH $LIVE_SHORT  2026-09-07 02:02
  failed     $BRANCH $LOCAL_SHORT  2026-09-06 20:55"
else
# The live parked run, exactly as `no-mistakes axi status` reported it.
export FM_FAKE_AXI_STATUS="run:
  id: \"01RUNPERSEA\"
  branch: $BRANCH
  status: running
  awaiting_agent: parked 1h36m
  head: \"$LIVE_HEAD\"
  pr: \"https://github.com/kunchenguid/persea/pull/41\"
  findings: none
gate:
  step: ci
  status: awaiting_approval
steps[4]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,completed,0,0
  push,completed,0,0
  ci,running,0,0"

# The coarse runs listing, newest first.
export FM_FAKE_RUNS_LIST="  running    $BRANCH $LIVE_SHORT  2026-09-07 02:02
  failed     $BRANCH $LOCAL_SHORT  2026-09-06 20:55"
fi

FB="$WORK/fakebin"
mkdir -p "$FB"
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift
    case "${1:-}" in
      status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
      logs) printf '\n' ;;
    esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) case "$*" in *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FB/no-mistakes" "$FB/tmux"

echo "=== $LABEL - scenario: $SCENARIO ==="
echo "worktree HEAD      : $LOCAL_SHORT   (the dead run's head)"
echo "pipeline run head  : $LIVE_SHORT   (rebased, live parked run)"
echo "relation           : diverged (neither head is an ancestor of the other)"
echo
echo "\$ no-mistakes axi status"
printf '%s\n' "$FM_FAKE_AXI_STATUS"
echo
echo "\$ no-mistakes runs --limit 20"
printf '%s\n' "$FM_FAKE_RUNS_LIST"
echo
echo "\$ fm-crew-state.sh $ID"
PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$REPO/bin/fm-crew-state.sh" "$ID"
echo
echo "\$ fm-fleet-view.sh   (crew row)"
PATH="$FB:$PATH" FM_HOME="$HOME_DIR" "$REPO/bin/fm-fleet-view.sh" 2>&1 \
  | grep -E "^\| *(id|-+|$ID)" | head -5
rm -rf "$WORK"
