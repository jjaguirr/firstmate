#!/usr/bin/env bash
# tests/fm-quota-banner-live-e2e.test.sh - the live guard for the provider
# quota refusal check (bin/fm-quota-lib.sh).
#
# Opt-in and on-demand: standard CI has neither harness binaries nor vendor
# credentials, so this is env-gated and self-skips. Run it after every harness
# or quota-axi upgrade, and before trusting refreshed evidence in
# docs/verification/quota-refusal.md.
#
#   FM_QUOTA_LIVE=1 tests/fm-quota-banner-live-e2e.test.sh
#
# The quota verdict rests on two signals that fail for different reasons, and
# this guard exercises the parts of each that only a real installation can
# prove. The portable regression is tests/fm-quota-wait.test.sh, which pins the
# logic against stubs everywhere CI runs tmux.
#
# WHAT IT PROVES
#
#   1. The structural signal is still reachable. quota-axi's live report is
#      parsed by the same production code the watcher runs, and the field the
#      exhaustion verdict depends on is still where that code looks for it. A
#      vendor schema change that silently moved `runway.status` would otherwise
#      turn the structural verdict into a permanent "unknown" and quietly demote
#      every worker to the rendered-text fallback.
#   2. Every INSTALLED harness still attributes the way the production path says
#      it should: a single-vendor harness names a provider, and a multi-provider
#      one names none, both read through that path rather than a copy of its
#      table. Which provider tokens quota-axi accepts is not asserted here: the
#      report only carries rows for vendors this machine is authenticated to, so
#      an unauthenticated vendor is missing evidence rather than a fault.
#   3. The banner patterns do not match ordinary vendor output. Real rendered
#      text from each installed harness is fed to the production matcher, which
#      must not claim a limit notice. A pattern that started matching a normal
#      footer would park healthy workers, which is the more damaging direction
#      of this check's two failure modes.
#
# WHAT IT CANNOT PROVE. Provoking a genuine quota refusal would mean exhausting
# a real account, so no automated guard can confirm that a CURRENT vendor limit
# notice still matches the pattern set. That direction is covered by keeping the
# patterns plural and independent and by the structural signal carrying the
# verdict wherever it is available; the observed wordings and the date they were
# observed live in docs/verification/quota-refusal.md.
#
# Every failure names the harness and the version string it reported, and an
# absent harness is reported explicitly rather than passed over in silence. A
# run that checked nothing at all FAILS.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

[ "${FM_QUOTA_LIVE:-}" = 1 ] ||
  { echo "skip: set FM_QUOTA_LIVE=1 to run the installed-harness quota guard"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-quota-lib.sh"

CHECKED=0
LIVE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-live.XXXXXX") || fail "could not create a temp dir"
trap 'rm -rf "$LIVE_DIR"' EXIT

harness_version() {  # <binary>
  "$1" --version 2>&1 </dev/null | head -1 | tr -d '\r'
}

# Every provider token the production single-vendor table can produce, as the
# comma list quota-axi takes. Derived from the table rather than restated, so
# this guard cannot drift into checking a vocabulary the code no longer uses.
table_providers() {
  local entry
  for entry in $FM_QUOTA_HARNESS_PROVIDERS; do printf '%s\n' "${entry#*:}"; done |
    sort -u | tr '\n' ',' | sed 's/,$//'
}

# --- 1. the structural signal is still reachable -----------------------------

test_structural_signal_reachable() {
  local tmp report rows
  if ! command -v quota-axi >/dev/null 2>&1; then
    note "quota-axi is not installed, so the structural signal is unverified here"
    return 0
  fi
  tmp="$LIVE_DIR/probe"
  mkdir -p "$tmp" || fail "could not create a temp dir"
  # Refresh through the production path, for every provider the production table
  # can attribute a worker to.
  FM_QUOTA_PROBE_TTL=0 fm_quota_probe_refresh "$tmp" "$(table_providers)" ||
    fail "quota-axi $(quota-axi --version 2>&1 | head -1): the production probe could not read a report"
  report=$(fm_quota_probe_report "$tmp") ||
    fail "quota-axi $(quota-axi --version 2>&1 | head -1): the production report parser produced nothing; the effective-availability shape it reads has changed"
  rows=$(printf '%s\n' "$report" | grep -c . || true)
  [ "${rows:-0}" -gt 0 ] ||
    fail "quota-axi $(quota-axi --version 2>&1 | head -1): the report parsed to zero provider rows"
  # Every row must carry one of the three verdicts this code knows. A fourth
  # token would mean the parser is producing something no caller handles.
  printf '%s\n' "$report" | awk -F'\t' '$2 != "exhausted" && $2 != "available" && $2 != "unknown" { exit 1 }' ||
    fail "quota-axi $(quota-axi --version 2>&1 | head -1): the report produced a verdict outside exhausted/available/unknown"
  CHECKED=$((CHECKED + 1))
  pass "structural: quota-axi $(quota-axi --version 2>&1 | head -1) still reports through the production probe and parser ($rows providers)"
}

# --- 2 and 3. every installed harness ---------------------------------------

test_installed_harnesses() {
  local harness bin version provider text
  for harness in claude codex opencode pi grok kimi cursor muse; do
    bin=$harness
    [ "$harness" != cursor ] || bin=cursor-agent
    if ! command -v "$bin" >/dev/null 2>&1; then
      note "$harness is not installed on this machine, so its attribution and banner behavior are unverified here"
      continue
    fi
    version=$(harness_version "$bin")
    provider=$(fm_quota_provider_for_harness "$harness")
    case "$harness" in
      claude|codex|grok|kimi|cursor)
        [ -n "$provider" ] ||
          fail "$harness ($version): a single-vendor harness no longer attributes to a provider"
        ;;
      *)
        [ -z "$provider" ] ||
          fail "$harness ($version): a multi-provider harness attributed to '$provider' from its name alone"
        ;;
    esac
    # Real rendered vendor text. Ordinary help and version output must never
    # read as a limit notice.
    text=$("$bin" --help 2>&1 </dev/null | head -200; printf '%s\n' "$version")
    if fm_quota_banner_matches "$text"; then
      fail "$harness ($version): ordinary vendor output matches the quota limit patterns, so healthy workers would be parked"
    fi
    CHECKED=$((CHECKED + 1))
    pass "$harness ($version): attribution is $([ -n "$provider" ] && printf '%s' "$provider" || printf 'deliberately unattributed'), and its ordinary output does not read as a limit notice"
  done
}

test_structural_signal_reachable
test_installed_harnesses

[ "$CHECKED" -gt 0 ] ||
  fail "nothing was checked: no supported harness and no quota-axi are installed, so this run proves nothing"
pass "quota refusal live guard: $CHECKED surfaces verified"
