#!/usr/bin/env bash
# Captain-facing evidence harness for the "one authoritative open-decision
# answer" change.
#
# Usage: decision-agreement-harness.sh <repo-root> <scratch-dir> <label>
#
# It builds ONE firstmate home whose durable status log never changes across the
# checks, then drives the real captain-facing executables over it:
#   bin/fm-wake-drain.sh        (the fleet-wide OPEN DECISIONS fold)
#   bin/fm-send.sh --resolve-key (the answer path)
#   bin/fm-fleet-snapshot.sh    (the triage surface the captain reads)
#   bin/fm-afk-return.sh        (the away-catch-up blocker list)
# and prints exactly what a captain would see. Nothing here inspects source
# text; every line of the transcript is real program output.
set -u

ROOT=$1
SCRATCH=$2
LABEL=$3

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

hr() { printf '\n===== %s =====\n' "$1"; }
sub() { printf '\n--- %s\n' "$1"; }

# ---------------------------------------------------------------- stubs -----
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\u256d\u2500\u2500\u2500\u2500\u256e\n\u2502    \u2502\n\u2570\u2500\u2500\u2500\u2500\u256f\n'; exit 0 ;;
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    exit 0 ;;
esac
exit 0
SH

cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/sleep"

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH

# The classifier's public crew-state reader, stubbed so this harness can move
# one task between "its run is actively working" and "its run parked" without a
# live no-mistakes daemon. The status log bytes stay identical across both.
cat > "$FAKEBIN/fake-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none}"
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes" "$FAKEBIN/fake-crew-state.sh"

READER="$FAKEBIN/fake-crew-state.sh"

# ------------------------------------------------------------------ home ----
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" \
  "$HOME_DIR/projects/resumed" "$HOME_DIR/projects/pane-task"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF

write_meta() {  # <id> <extra kv...>
  local id=$1
  shift
  : > "$HOME_DIR/state/$id.meta"
  printf 'window=firstmate:fm-%s\n' "$id" >> "$HOME_DIR/state/$id.meta"
  printf 'worktree=%s/projects/%s\n' "$HOME_DIR" "$id" >> "$HOME_DIR/state/$id.meta"
  printf 'project=alpha\nharness=claude\nkind=ship\nmode=ship\n' >> "$HOME_DIR/state/$id.meta"
}

write_meta resumed
write_meta pane-task

# One durable status log for the run-lifecycle task. No resolved line anywhere:
# every difference below comes from the run lifecycle, not from new bytes.
cat > "$HOME_DIR/state/resumed.status" <<'EOF'
needs-decision [key=rollout]: choose the deployment path
needs-decision [key=schema]: pick the schema
working [key=rollout]: resumed validation after the rollout answer
working: keyless routine note
blocked [key=creds]: need the staging secret
EOF

# The triage task: one keyed decision, and a pane that is rendering activity.
printf 'needs-decision [key=rollout]: choose the deployment path\n' > "$HOME_DIR/state/pane-task.status"
"$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" pane-task >"$SCRATCH/gen" 2>/dev/null || true
if [ -s "$SCRATCH/gen" ]; then
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" pane-task busy \
    --gen "$(cat "$SCRATCH/gen")" --source claude-hook --event user-prompt-submit >/dev/null 2>&1 || true
fi

drain() {
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CREW_STATE_BIN="$READER" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

send_resolve() {  # <task> <key> <answer>
  local task=$1 key=$2 answer=$3 rc
  : > "$SCRATCH/send.log"
  set +e
  env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_SEND_LOG="$SCRATCH/send.log" FM_SEND_SETTLE=0 \
    FM_CREW_STATE_BIN="$READER" FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-send.sh" "$task" --resolve-key "$key" "$answer" >"$SCRATCH/send.out" 2>"$SCRATCH/send.err"
  rc=$?
  set -e
  printf '$ bin/fm-send.sh %s --resolve-key %s "%s"\n' "$task" "$key" "$answer"
  printf 'exit=%s\n' "$rc"
  [ -s "$SCRATCH/send.err" ] && grep -v 'WARNING: watcher' "$SCRATCH/send.err" | sed 's/^/stderr: /'
  :
  if [ -s "$SCRATCH/send.log" ]; then
    printf 'delivered to worker: %s\n' "$(cat "$SCRATCH/send.log")"
  else
    printf 'delivered to worker: (nothing)\n'
  fi
  printf 'closing line appended: %s\n' \
    "$(grep -F "resolved [key=$key]" "$HOME_DIR/state/$task.status" 2>/dev/null || printf '(none)')"
}

printf '################ %s ################\n' "$LABEL"
printf 'repo root: %s\n' "$ROOT"
printf '\ndurable status log for task "resumed" (identical for every check below):\n'
sed 's/^/  | /' "$HOME_DIR/state/resumed.status"

# ---------------------------------------------------- 1. run is working -----
hr "1. task resumed: its no-mistakes run is ACTIVELY WORKING (state: working - source: run-step)"
export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

sub "captain surface A - bin/fm-wake-drain.sh OPEN DECISIONS"
drain | sed 's/^/  /'

sub "captain surface B - bin/fm-send.sh --resolve-key rollout (the key whose SAME-key progress line the run wrote)"
send_resolve resumed rollout "phase it" | sed 's/^/  /'

sub "captain surface B - bin/fm-send.sh --resolve-key creds (a blocker raised mid-run: must stay answerable)"
send_resolve resumed creds "use the vault secret" | sed 's/^/  /'

sub "captain surface A again - OPEN DECISIONS after the mid-run answer"
drain | sed 's/^/  /'

# ------------------------------------------------------- 2. run parked ------
hr "2. same bytes, run PARKED (state: parked - source: run-step)"
export FM_FAKE_CREW_STATE='state: parked · source: run-step · awaiting captain decision'

sub "captain surface A - OPEN DECISIONS"
drain | sed 's/^/  /'

sub "captain surface B - --resolve-key rollout is answerable again"
send_resolve resumed rollout "phase it" | sed 's/^/  /'

sub "captain surface A - OPEN DECISIONS after the answer"
drain | sed 's/^/  /'

sub "captain surface B - answering the same key twice"
send_resolve resumed rollout "phase it again" | sed 's/^/  /'

sub "resulting durable status log"
sed 's/^/  | /' "$HOME_DIR/state/resumed.status"

# --------------------------------------------------- 3. busy pane task ------
hr "3. task pane-task: ONE keyed decision, pane rendering live activity"
unset FM_FAKE_CREW_STATE

sub "captain surface C - bin/fm-fleet-snapshot.sh --json (triage hints)"
if command -v jq >/dev/null 2>&1; then
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null \
    | jq '.tasks[] | select(.id == "pane-task") | {id, current_state, pending_decision: .hints.pending_decision, open_decisions: .hints.open_decisions}' \
    | sed 's/^/  /'
else
  printf '  (jq not available)\n'
fi

sub "captain surface A - OPEN DECISIONS for the same task"
env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null | sed 's/^/  /'

sub "captain surface B - --resolve-key rollout on the same task"
READER="$ROOT/bin/fm-crew-state.sh"
send_resolve pane-task rollout "go with the blue path" | sed 's/^/  /'

# --------------------------------------------- 4. AFK catch-up blockers -----
# bin/fm-afk-return.sh is the "here is what waited for you while you were away"
# gate. It must present exactly the blockers --resolve-key would accept.
hr "4. bin/fm-afk-return.sh catch-up list vs --resolve-key, one durable blocker"

AFK="$SCRATCH/afk"
mkdir -p "$AFK/bin" "$AFK/home/state" "$AFK/home/data" "$AFK/home/config"
for f in fm-afk-return.sh fm-wake-lib.sh fm-classify-lib.sh fm-timeout-lib.sh; do
  cp "$ROOT/bin/$f" "$AFK/bin/" 2>/dev/null || true
done
cat > "$AFK/bin/fm-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
rm -f "$FM_HOME/state/.afk" "$FM_HOME/state/.afk-daemon-terminal"
SH
cat > "$AFK/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
file="$FM_HOME/state/.fake-drain"
if [ "${1:-}" = --ack-through ]; then
  : > "$file"
  exit 0
fi
[ -s "$file" ] && cat "$file"
exit 0
SH
chmod +x "$AFK/bin/"*.sh
cat > "$AFK/home/state/repair-task.meta" <<'EOF'
window=synthetic:fm-repair-task
backend=tmux
kind=ship
EOF
cat > "$AFK/home/state/repair-task.status" <<'EOF'
blocked [key=creds]: firstmate can refresh the synthetic token
working [key=creds]: retrying with the cached token
EOF

printf '\ndurable status log for task "repair-task" (identical for both checks below):\n'
sed 's/^/  | /' "$AFK/home/state/repair-task.status"

afk_begin() {
  date +%s > "$AFK/home/state/.afk"
  printf '1784074271\t%s\tsignal\trepair-task.status\tsignal: synthetic status\n' "$RANDOM" \
    > "$AFK/home/state/.fake-drain"
  rm -f "$AFK/home/state/.afk-return-catchup"
  set +e
  env PATH="$FAKEBIN:$PATH" FM_HOME="$AFK/home" FM_STATE_OVERRIDE="$AFK/home/state" \
    FM_CREW_STATE_BIN="$READER" FM_GATE_REFUSE_BYPASS=1 \
    "$AFK/bin/fm-afk-return.sh" begin 2>&1
  printf 'exit=%s\n' "$?"
  set -e
}

afk_send() {  # <key> <answer>
  local rc
  : > "$SCRATCH/send.log"
  set +e
  env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$AFK/home" \
    FM_STATE_OVERRIDE="$AFK/home/state" FM_SEND_LOG="$SCRATCH/send.log" FM_SEND_SETTLE=0 \
    FM_CREW_STATE_BIN="$READER" FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-send.sh" repair-task --resolve-key "$1" "$2" >/dev/null 2>"$SCRATCH/send.err"
  rc=$?
  set -e
  printf '$ bin/fm-send.sh repair-task --resolve-key %s "%s"\nexit=%s\n' "$1" "$2" "$rc"
  grep -v 'WARNING: watcher' "$SCRATCH/send.err" | sed 's/^/stderr: /'
}

READER="$FAKEBIN/fake-crew-state.sh"
export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
sub "run ACTIVELY WORKING - catch-up list"
afk_begin | sed 's/^/  /'
sub "run ACTIVELY WORKING - --resolve-key creds"
afk_send creds "use the vault secret" | sed 's/^/  /'

export FM_FAKE_CREW_STATE='state: parked · source: run-step · awaiting captain decision'
sub "same bytes, run PARKED - catch-up list"
afk_begin | sed 's/^/  /'
sub "same bytes, run PARKED - --resolve-key creds"
afk_send creds "use the vault secret" | sed 's/^/  /'
sub "resulting durable status log"
sed 's/^/  | /' "$AFK/home/state/repair-task.status"

printf '\n################ end %s ################\n' "$LABEL"
