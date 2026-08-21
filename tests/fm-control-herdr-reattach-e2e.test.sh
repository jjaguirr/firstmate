#!/usr/bin/env bash
# fm-control Herdr missing-endpoint reattach - real isolated-lab evidence.
#
# This test drives the supported fm-spawn --relaunch recovery interface against
# a real named Herdr session after the recorded pane is closed. It never calls
# Herdr directly: every test-owned Herdr operation passes through
# fm-herdr-lab.sh, whose default-session tripwire is part of the assertion.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper is not executable: $HERDR_LAB_HELPER"; exit 0; }

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-control-reattach)
SCRATCH=
cleanup() {
  status=$?
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
  return "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr-reattach.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
PROJ="$SCRATCH/project"
WT="$SCRATCH/worktree"
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$HOME_DIR/data/reattach" "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf '# recovery brief\n' > "$HOME_DIR/data/reattach/brief.md"

git init -q "$PROJ"
printf '# project\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
git -C "$PROJ" worktree add --quiet -b fm-reattach "$WT"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
record="$(dirname "$0")/.lease"
log=${FM_REATTACH_LOG:?FM_REATTACH_LOG unset}
case "${1:-}" in
  get)
    holder=
    previous=
    for arg in "$@"; do
      if [ "$previous" = --lease-holder ]; then holder=$arg; fi
      previous=$arg
    done
    [ -n "$holder" ] || exit 1
    printf 'get\n' >> "$log"
    printf '%s\tlease-reattach\t%s\n' "$FM_REATTACH_WT" "$holder" > "$record"
    printf '{"path":"%s","lease_id":"lease-reattach","lease_holder":"%s"}\n' "$FM_REATTACH_WT" "$holder"
    ;;
  status)
    printf 'status\n' >> "$log"
    IFS=$'\t' read -r path lease_id holder < "$record"
    printf '[{"path":"%s","status":"leased","lease_id":"%s","lease_holder":"%s"}]\n' "$path" "$lease_id" "$holder"
    ;;
  return) exit 0 ;;
  *) exit 1 ;;
esac
SH
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
exec sleep 120
SH
chmod +x "$FAKEBIN/treehouse" "$FAKEBIN/claude"

run_spawn() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_REATTACH_WT="$WT" FM_REATTACH_LOG="$SCRATCH/treehouse.log" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

OUT=$(run_spawn reattach "$PROJ" --mode no-mistakes --yolo off) \
  || fail "fresh Herdr fixture spawn failed: $OUT"
META="$HOME_DIR/state/reattach.meta"
PANE=$(sed -n 's/^herdr_pane_id=//p' "$META")
OLD_WINDOW=$(sed -n 's/^window=//p' "$META")
[ -n "$PANE" ] && [ -n "$OLD_WINDOW" ] || fail 'fresh spawn did not publish one Herdr endpoint'
printf 'preserved dirty work\n' > "$WT/dirty.txt"
BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD)

"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane close "$PANE" >/dev/null \
  || fail 'could not close the fixture pane through the isolated lab helper'
if "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$PANE" >/dev/null 2>&1; then
  fail 'the closed fixture pane is still present, so missing-endpoint recovery was not exercised'
fi

OUT=$(run_spawn reattach --relaunch --harness claude) \
  || fail "missing-endpoint Herdr reattach failed: $OUT"
NEW_WINDOW=$(sed -n 's/^window=//p' "$META")
NEW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$META")
[ "$NEW_WINDOW" != "$OLD_WINDOW" ] && [ -n "$NEW_PANE" ] \
  || fail 'reattach did not publish a distinct replacement Herdr endpoint'
case "$NEW_WINDOW" in "$HERDR_LAB_SESSION":*) ;; *) fail 'reattach moved to a different Herdr session' ;; esac
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$NEW_PANE" >/dev/null \
  || fail 'reattach metadata does not name a live replacement pane'
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] \
  || fail 'reattach changed the recorded worktree branch'
[ "$(cat "$WT/dirty.txt")" = 'preserved dirty work' ] \
  || fail 'reattach discarded uncommitted work'
if [ "$(grep -c '^worktree=' "$META")" != 1 ] || ! grep -Fqx "worktree=$WT" "$META"; then
  fail 'reattach allocated or published a different worktree'
fi
# The stub's lease record appears only after the original fresh spawn. Reattach
# may inspect status but must not acquire another worktree.
[ "$(grep -c '^get$' "$SCRATCH/treehouse.log")" = 1 ] \
  || fail 'reattach allocated a second Treehouse worktree'
[ "$(grep -c 'lease-reattach' "$META")" -ge 1 ] \
  || fail 'reattach did not preserve the durable Treehouse lease metadata'
pass 'real Herdr lab: a missing pane reattaches the exact dirty leased worktree in its recorded named session'
