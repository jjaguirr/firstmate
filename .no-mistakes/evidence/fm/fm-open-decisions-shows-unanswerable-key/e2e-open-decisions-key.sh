#!/usr/bin/env bash
# E2E: crewmate writes [key=...] mid-note. Compare OPEN DECISIONS at base vs
# target, then prove the disclosed key is the one fm-send.sh --resolve-key accepts.
set -u
ROOT=${ROOT:?}; BASE=${BASE:?}
. "$ROOT/tests/lib.sh"
TMP=$(mktemp -d /tmp/fm-e2e-open-decisions.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

fb="$TMP/fakebin"; mkdir -p "$fb"
cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) shift; lit=0; while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) lit=1; shift;; *) break;; esac; done
    [ "$lit" = 1 ] && printf '%s' "${1:-}" >> "$FM_SEND_LOG"; exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0;; esac; done; echo fakepane; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"; chmod +x "$fb/tmux" "$fb/sleep"

home="$TMP/home"; mkdir -p "$home/state"
fm_write_meta "$home/state/persea.meta" "window=sess:fm-persea" "kind=ship"
printf 'working: reviewing SSE reconnect findings\n' > "$home/state/persea.status"
printf 'needs-decision: two findings [key=persea-irrigation-sse-robustness]. (1) terminal-after-61s: retry or surface? (2) keepalive gap\n' >> "$home/state/persea.status"

drain() { FM_STATE_OVERRIDE="$home/state" "$1/bin/fm-wake-drain.sh" 2>/dev/null | grep -E 'OPEN DECISIONS|persea'; }
send() { : > "$TMP/send.log"; PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$TMP/send.log" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$@"; }

echo '=== status log the crewmate wrote (key token mid-note) ==='
cat "$home/state/persea.status"
echo; echo "=== BEFORE FIX (base $(git -C "$ROOT" rev-parse --short a1a5354)): OPEN DECISIONS as the captain sees it ==="
drain "$BASE"
echo; echo '--- captain answers with the only key-shaped token visible ---'
echo '$ bin/fm-send.sh persea --resolve-key persea-irrigation-sse-robustness "retry"'
send persea --resolve-key persea-irrigation-sse-robustness "retry"; echo "exit=$?"

echo; echo "=== AFTER FIX (target $(git -C "$ROOT" rev-parse --short HEAD)): OPEN DECISIONS as the captain sees it ==="
drain "$ROOT"
echo; echo '--- stray token (now non-key-shaped) is still refused ---'
echo '$ bin/fm-send.sh persea --resolve-key persea-irrigation-sse-robustness "retry"'
send persea --resolve-key persea-irrigation-sse-robustness "retry"; echo "exit=$?"
echo; echo '--- answering with the disclosed key [key=default] ---'
echo '$ bin/fm-send.sh persea --resolve-key default "retry with backoff"'
send persea --resolve-key default "retry with backoff"; echo "exit=$?"
echo "typed to worker: $(cat "$TMP/send.log")"
echo; echo '=== status log after the answer ==='
cat "$home/state/persea.status"
echo; echo '=== OPEN DECISIONS after the answer (expect empty) ==='
out=$(drain "$ROOT"); [ -z "$out" ] && echo '(no OPEN DECISIONS section - decision closed)' || printf '%s\n' "$out"
