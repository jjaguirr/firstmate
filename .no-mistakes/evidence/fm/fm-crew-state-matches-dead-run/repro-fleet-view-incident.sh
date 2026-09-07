#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-06 report, rendered through the real
# human fleet view (bin/fm-fleet-view.sh -> bin/fm-fleet-snapshot.sh ->
# bin/fm-crew-state.sh) plus the raw crew-state line supervision reads.
#
# Usage: repro-fleet-view-incident.sh <path-to-firstmate-checkout> [scenario]
#
# Scenarios:
#   incident  (default) the reported case: local HEAD is an EARLIER run's head
#             that DIED; the pipeline pushed its own housekeeping commit so the
#             LIVE run's head is a descendant this local copy does not have.
#             `axi status` answers with the ACTIVE run (running, parked at the
#             review gate); `no-mistakes runs` lists running@live, failed@dead,
#             cancelled@older.
#   unknown   the same unreadable head, but nothing live corroborates it: the
#             record is a terminal FAILURE and no `running` row owns the branch.
#             The honest verdict is an explicit unknown naming the head it could
#             not read - never a failed, and never a cheerful working.
#   diverged  the refusal that must NOT widen: the record names this crew's own
#             branch, but its head is resolvable here and provably foreign
#             history, and no other row attributes. It must never be attributed,
#             so no run-step state and no gate detail from it.
#   dead      the other direction: the failed run genuinely IS the branch's
#             newest attributable run, so it must still read failed.
set -u

CHECKOUT=${1:?usage: repro-fleet-view-incident.sh <checkout> [incident|unknown|diverged|dead]}
SCENARIO=${2:-incident}
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-incident.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

HOME_DIR="$SANDBOX/home"
WT="$SANDBOX/wt"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

# --- the crew worktree ------------------------------------------------------
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" commit -q --allow-empty -m init
OLDEST=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q -b fm/fleet-incident
git -C "$WT" commit -q --allow-empty -m 'crew work the earlier run validated'
DEAD_HEAD=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" commit -q --allow-empty -m 'no-mistakes(document): pipeline housekeeping'
LIVE_HEAD=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" reset -q --hard "$DEAD_HEAD"

RECORD_HEAD=$LIVE_HEAD
case "$SCENARIO" in
  incident|unknown)
    # The pipeline pushed from its own copy: the live tip is not here yet.
    git -C "$WT" reflog expire --expire=now --all
    git -C "$WT" gc -q --prune=now 2>/dev/null || true
    if git -C "$WT" rev-parse --verify -q "${LIVE_HEAD}^{commit}" >/dev/null 2>&1; then
      echo "FIXTURE BROKEN: live run head is still resolvable locally" >&2
      exit 1
    fi
    if [ "$SCENARIO" = unknown ]; then
      HEAD_NOTE="record head: ${LIVE_HEAD:0:8}  (a CONCLUDED record on a head this copy cannot read; no live row corroborates it)"
    else
      HEAD_NOTE="live run:   ${LIVE_HEAD:0:8}  (running, parked at review - NOT an object this copy has)"
    fi
    ;;
  diverged)
    git -C "$WT" checkout -q -b tmp-diverge "$OLDEST"
    git -C "$WT" commit -q --allow-empty -m 'sibling history the crew never had'
    RECORD_HEAD=$(git -C "$WT" rev-parse HEAD)
    git -C "$WT" checkout -q fm/fleet-incident
    git -C "$WT" rev-parse --verify -q "${RECORD_HEAD}^{commit}" >/dev/null \
      || { echo "FIXTURE BROKEN: diverged head must stay resolvable" >&2; exit 1; }
    ! git -C "$WT" merge-base --is-ancestor "$RECORD_HEAD" HEAD 2>/dev/null \
      || { echo "FIXTURE BROKEN: head is an ancestor, not diverged" >&2; exit 1; }
    ! git -C "$WT" merge-base --is-ancestor HEAD "$RECORD_HEAD" 2>/dev/null \
      || { echo "FIXTURE BROKEN: head is a descendant, not diverged" >&2; exit 1; }
    HEAD_NOTE="record head: ${RECORD_HEAD:0:8}  (resolvable here, provably foreign history)"
    ;;
  dead)
    RECORD_HEAD=$DEAD_HEAD
    HEAD_NOTE="record head: ${DEAD_HEAD:0:8}  (the branch's newest attributable run, and it really failed)"
    ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac

# --- crew registration + its (still unresolved) status log ------------------
cat > "$HOME_DIR/state/crew-1.meta" <<META
window=fm:fm-crew-1
worktree=$WT
kind=ship
harness=claude
branch=fm/fleet-incident
META
if [ "$SCENARIO" = diverged ]; then
  printf 'working: stage 2 setup complete\n' > "$HOME_DIR/state/crew-1.status"
  # An idle, readable harness record, so the refusal falls through to the crew's
  # own current status log rather than to an unreadable-pane unknown.
  BUSY_GEN=$("$CHECKOUT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" crew-1)
  "$CHECKOUT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" crew-1 idle \
    --gen "$BUSY_GEN" --source claude-hook --event stop >/dev/null
else
  printf 'needs-decision: review gate has 2 finding(s)\n' > "$HOME_DIR/state/crew-1.status"
fi

cat > "$HOME_DIR/data/backlog.md" <<'BACKLOG'
# Backlog

## In flight

## Queued

## Done
BACKLOG

# --- fake no-mistakes CLI serving this scenario's records -------------------
FB="$SANDBOX/fakebin"
mkdir -p "$FB"
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        if [ "${FM_SCENARIO:-}" = dead ] || [ "${FM_SCENARIO:-}" = unknown ]; then
          cat <<TOON
run:
  id: "01RUNDEAD"
  branch: fm/fleet-incident
  status: completed
  head: "${FM_RECORD_HEAD:0:8}"
  pr: ""
  findings: none
outcome: failed
TOON
        else
          # Bare `axi status` returns the ACTIVE run (verified against the real
          # CLI in the incident's own worktree): the live, parked one.
          cat <<TOON
run:
  id: "01RUNLIVE"
  branch: fm/fleet-incident
  status: awaiting_approval
  awaiting_agent: parked 1h6m
  head: "${FM_RECORD_HEAD:0:8}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
TOON
        fi ;;
      logs) : ;;
    esac ;;
  runs)
    if [ "${FM_SCENARIO:-}" = dead ]; then
      cat <<LIST
  failed     fm/fleet-incident ${FM_DEAD_HEAD:0:8}  2026-09-06 20:49
  cancelled  fm/fleet-incident ${FM_OLDEST_HEAD:0:8}  2026-09-04 11:02
LIST
    elif [ "${FM_SCENARIO:-}" = unknown ]; then
      # Nothing live owns the branch: only the older, concluded rows.
      cat <<LIST
  failed     fm/fleet-incident ${FM_DEAD_HEAD:0:8}  2026-09-05 06:01
  cancelled  fm/fleet-incident ${FM_OLDEST_HEAD:0:8}  2026-09-04 11:02
LIST
    elif [ "${FM_SCENARIO:-}" = diverged ]; then
      # No row attributes this worktree, so only the detailed record can, and
      # it must be refused.
      cat <<LIST
  running    fm/fleet-incident ${FM_RECORD_HEAD:0:8}  2026-09-06 20:49
LIST
    else
      cat <<LIST
  running    fm/fleet-incident ${FM_LIVE_HEAD:0:8}  2026-09-06 20:49
  failed     fm/fleet-incident ${FM_DEAD_HEAD:0:8}  2026-09-05 06:01
  cancelled  fm/fleet-incident ${FM_OLDEST_HEAD:0:8}  2026-09-04 11:02
LIST
    fi ;;
esac
exit 0
SH
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane)    printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FB/no-mistakes" "$FB/tmux"

export FM_SCENARIO="$SCENARIO" FM_RECORD_HEAD="$RECORD_HEAD" \
       FM_LIVE_HEAD="$LIVE_HEAD" FM_DEAD_HEAD="$DEAD_HEAD" FM_OLDEST_HEAD="$OLDEST"

run_fm() {
  PATH="$FB:$PATH" \
    FM_ROOT_OVERRIDE="$CHECKOUT" \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    "$@"
}

echo "scenario:   $SCENARIO"
echo "checkout:   $CHECKOUT"
echo "branch:     fm/fleet-incident"
echo "local HEAD: $(git -C "$WT" rev-parse --short=8 HEAD)"
echo "$HEAD_NOTE"
echo
echo "\$ no-mistakes runs --limit 200"
PATH="$FB:$PATH" no-mistakes runs --limit 200
echo
echo "\$ bin/fm-crew-state.sh crew-1"
run_fm "$CHECKOUT/bin/fm-crew-state.sh" crew-1
echo
echo "\$ bin/fm-fleet-view.sh"
run_fm "$CHECKOUT/bin/fm-fleet-view.sh" | sed -n '/^## Under Way/,/^$/p'
