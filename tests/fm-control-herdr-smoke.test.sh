#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent on a plain
# shell pane exercises exactly the classification the control plane gates on.
#
# The last section is the live guard for recovering a worker whose endpoint is
# gone: it closes a real task pane, confirms the adapter classifies it
# `missing`, and drives the supported recovery interface
# (`bin/fm-spawn.sh <id> --relaunch`) against the real binary. A stub cannot
# prove this, because both the classification and the workspace placement come
# from Herdr's own responses. Run this file after every Herdr upgrade and
# refresh docs/verification/runtime-backends.md from what it prints.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent: classification flips, and the verbs follow ---------

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true

# --- recovering a task whose pane is gone ------------------------------------
# A closed pane is the stranded shape: the worktree and its commits survive
# while the endpoint does not. The recovery must create ONE replacement pane in
# the same named session and the same home workspace, keep the recorded
# worktree, and never allocate a second one.

RECOVER_WT="$SCRATCH/wt-recover"
git -C "$PROJ" worktree add --quiet -b hrecover "$RECOVER_WT"
printf 'work the replacement must inherit\n' > "$RECOVER_WT/landed.txt"
git -C "$RECOVER_WT" add landed.txt
git -C "$RECOVER_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm 'work that must survive recovery'
RECOVER_HEAD=$(git -C "$RECOVER_WT" rev-parse HEAD)

mkdir -p "$HOME_DIR/data/hrecover" "$SCRATCH/fakebin"
printf '# brief\n' > "$HOME_DIR/data/hrecover/brief.md"
# A harness and a Treehouse the spawn dependency check can see. The recovery
# path never allocates a worktree, so a `treehouse get` here would itself be
# the defect: this stub fails loudly if one is ever requested.
cat > "$SCRATCH/fakebin/claude" <<'SH'
#!/usr/bin/env bash
exec sleep 120
SH
cat > "$SCRATCH/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) echo 'treehouse get must never run on the recovery path' >&2; exit 1 ;;
esac
exit 0
SH
chmod +x "$SCRATCH/fakebin/claude" "$SCRATCH/fakebin/treehouse"

# The fixture pane must live in the workspace THIS home owns, because that is
# the container the recovery re-resolves. Both calls are made under the same
# FM_HOME the recovery will run with, exactly as bin/fm-spawn.sh makes them.
RECOVER_CONTAINER_RAW=$(FM_HOME="$HOME_DIR" fm_backend_herdr_container_ensure "$RECOVER_WT" launcher-home) \
  || fail "could not ensure this home's own herdr workspace for the recovery fixture"
RECOVER_CONTAINER=${RECOVER_CONTAINER_RAW%%$'\t'*}
RECOVER_SEEDED_TAB_ID=${RECOVER_CONTAINER_RAW#*$'\t'}
RECOVER_WORKSPACE_ID=${RECOVER_CONTAINER#*:}
RECOVER_TASK_IDS=$(FM_HOME="$HOME_DIR" fm_backend_herdr_create_task \
  "$RECOVER_CONTAINER" "fm-hrecover" "$RECOVER_WT" "$RECOVER_SEEDED_TAB_ID") \
  || fail "could not create the recovery fixture's task pane"
read -r RECOVER_TAB_ID RECOVER_PANE_ID <<EOF
$RECOVER_TASK_IDS
EOF
[ -n "$RECOVER_PANE_ID" ] || fail "create_task did not return a recovery fixture pane id"
{
  echo "window=$SESSION:$RECOVER_PANE_ID"
  echo "endpoint_task_id=hrecover"
  echo "worktree=$RECOVER_WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$RECOVER_WORKSPACE_ID"
  echo "herdr_tab_id=$RECOVER_TAB_ID"
  echo "herdr_pane_id=$RECOVER_PANE_ID"
} > "$HOME_DIR/state/hrecover.meta"

fm_backend_herdr_kill "$SESSION:$RECOVER_PANE_ID" 2>/dev/null || true
STATE=$(fm_backend_agent_state herdr "$SESSION:$RECOVER_PANE_ID")
[ "$STATE" = missing ] \
  || fail "a closed herdr pane must classify missing before recovery is exercised, got '$STATE'"

OUT=$(env PATH="$SCRATCH/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hrecover --relaunch --harness claude 2>&1) \
  || fail "recovering a missing herdr endpoint failed: $OUT"

NEW_WINDOW=$(sed -n 's/^window=//p' "$HOME_DIR/state/hrecover.meta")
NEW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/hrecover.meta")
NEW_WORKSPACE=$(sed -n 's/^herdr_workspace_id=//p' "$HOME_DIR/state/hrecover.meta")
[ -n "$NEW_PANE" ] && [ "$NEW_PANE" != "$RECOVER_PANE_ID" ] \
  || fail "recovery must publish a distinct replacement pane, got '${NEW_PANE:-none}'"
[ "$NEW_WINDOW" = "$SESSION:$NEW_PANE" ] \
  || fail "the published endpoint must name the recorded session and the new pane, got '$NEW_WINDOW'"
[ "$NEW_WORKSPACE" = "$RECOVER_WORKSPACE_ID" ] \
  || fail "recovery must stay in the recorded home workspace, got '$NEW_WORKSPACE'"
[ "$(fm_backend_herdr_pane_presence_state "$SESSION" "$NEW_PANE")" = present ] \
  || fail "the published replacement pane must actually exist"
[ "$(grep -c '^worktree=' "$HOME_DIR/state/hrecover.meta")" = 1 ] \
  || fail "recovery must publish exactly one recorded worktree"
grep -Fqx "worktree=$RECOVER_WT" "$HOME_DIR/state/hrecover.meta" \
  || fail "recovery must keep the worktree the task already recorded"
[ "$(git -C "$RECOVER_WT" rev-parse HEAD)" = "$RECOVER_HEAD" ] \
  || fail "recovery must not move the committed work"
pass "real herdr: a closed task pane is recovered into a new pane in the same session, workspace, and worktree"

fm_backend_herdr_kill "$SESSION:$NEW_PANE" 2>/dev/null || true
