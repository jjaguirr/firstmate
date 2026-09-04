#!/usr/bin/env bash
# E2E: a captain-held task whose TITLE carries a stray [key=...] token, resolved
# in the status log while still held. RECORD DIVERGENCE line at base vs target.
set -u
ROOT=${ROOT:?}; BASE=${BASE:?}
. "$ROOT/tests/lib.sh"
TASKS_AXI_BIN=$(command -v tasks-axi)
TMP=$(mktemp -d /tmp/fm-e2e-divergence.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
home="$TMP/home"; mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fakebin=$(fm_fakebin "$home"); fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
id=sample-route-review
(cd "$home" && tasks-axi add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null) || { echo "fixture add failed"; exit 1; }
fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" "project=$home/projects/sample" "harness=codex" "kind=scout" "mode=scout"
PATH="$fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  "$ROOT/bin/fm-captain-hold.sh" hold sample-route-call --title "Choose route [key=north-or-south] before Friday" --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null || { echo "hold failed"; exit 1; }
cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
EOF
drain() { PATH="$fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_ROOT_OVERRIDE="$1" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$1/bin/fm-wake-drain.sh" 2>/dev/null | grep -F 'RECORD DIVERGENCE' -A1 | head -2; }
echo '=== held task title: "Choose route [key=north-or-south] before Friday"; status resolved [key=sample-route-call] ==='
echo; echo "=== BEFORE FIX (base): RECORD DIVERGENCE entry ==="; drain "$BASE"
echo; echo "=== AFTER FIX (target): RECORD DIVERGENCE entry ==="; drain "$ROOT"
