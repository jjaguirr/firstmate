# shellcheck shell=bash
# fm-quota-lib.sh - the ONE owner of firstmate's provider-quota-refusal contract.
# Sourced, never executed. bin/fm-quota-watch.sh is its only production driver.
#
# The failure this exists for: a provider refuses a worker's turn because the
# account is out of quota. The harness renders a limit notice and ends the turn
# exactly the way a completed turn ends, so the pane goes idle with an empty
# composer while the agent process stays alive. Every supervision signal
# firstmate owns - the turn-end marker, the pane hash, the endpoint liveness
# read - is then byte-identical to a worker that finished and is waiting. The
# fleet parks, nothing escalates, and the wait outlives the quota window that
# caused it by however long it takes a human to notice.
#
# The contract this file states is: a quota refusal is a DECLARED EXTERNAL WAIT
# that carries its own reset time. It is recorded as a bounded wait rather than
# a wedge, so stale escalation does not fire against a wait that is known and
# expected to clear, and it retires on its own so the ordinary stale path takes
# the pane back if the wait was wrong or the resume did not restart progress.
#
# --- Evidence -------------------------------------------------------------
#
# Two signals answer "is this provider refusing right now", and they fail for
# different reasons, so neither is allowed to be the whole verdict on its own.
#
#   STRUCTURAL (fm_quota_probe). quota-axi's own effective-availability read for
#   the provider: `runway.status == exhausted_now` on the `all_models` scope.
#   This is machine-readable vendor accounting, not rendered text, so it carries
#   the verdict wherever it is available. Only the `all_models` scope is
#   consulted, because AGENTS.md's granularity rule is that provider-level or
#   all-model evidence applies to every model in the family while a named-model
#   window bounds only that model - and what is parked here is a worker, whose
#   provider is what got refused.
#
#   BANNER (fm_quota_banner_matches). The rendered limit notice. This is a
#   harness-dependent check in the sense firstmate-coding-guidelines defines, so
#   it obeys that rule rather than being trusted on its own: several independent
#   vendor phrasings are matched instead of one exact string, it is consulted
#   ONLY when the structural signal is genuinely unavailable (quota-axi missing,
#   below the floor, timed out, or unreadable - never merely when it disagrees),
#   it must be corroborated by two machine-verified facts the caller supplies
#   (the endpoint reads alive and the pane classifies exactly idle). A banner
#   match with no parsable reset time is bounded far shorter than a structural
#   wait and is never resumed automatically, because a resume time nobody can
#   read is a guess. A banner that DOES state its reset runs to that reset like
#   any other wait: on a home with no quota-axi the fallback is the only thing
#   that can recover the fleet, and a bound shorter than the stated reset would
#   retire the wait before the resume it exists to deliver - which is exactly the
#   reported incident, a notice at 06:05 stating a reset at 08:50.
#
#   The residual false positive this accepts is a worker whose own transcript
#   quotes a limit notice - an incident report, a test fixture, this very file.
#   While the structural read is unavailable such a pane can be recorded as
#   waiting, which suppresses its wedge reading until the stated reset, or for at
#   most FM_QUOTA_BANNER_WAIT_MAX_SECS when the notice states none, before the
#   wait expires and ordinary escalation resumes. That bounded cost is why the
#   fallback is allowed to exist: a wrong rendered-text verdict costs a delay
#   that ends on its own, while the cost of having no fallback is the original
#   failure returning in full on every home where quota-axi is missing.
#
# --- Provider attribution -------------------------------------------------
#
# The provider is established from the worker's recorded harness and model, and
# never from a name prefix. Two independent sources, in this order:
#
#   1. quota-axi's own model catalog (`quota-axi models --json`), a deterministic
#      provider/model join published by the same tool that reports the quota. A
#      recorded concrete model id present in that catalog names its provider
#      authoritatively.
#   2. FM_QUOTA_HARNESS_PROVIDERS below: the harnesses that authenticate to
#      exactly one vendor. opencode, pi, pi-signed, and muse are deliberately
#      absent - they are multi-provider surfaces, so their harness name is not
#      evidence of a provider, and a worker on one of them has no structural
#      verdict unless its recorded model resolved through the catalog.
#
# When both sources answer and DISAGREE, the provider is not established. A
# contradiction is missing evidence, never an excuse to pick one.
#
# An unestablished provider is disclosed uncertainty, not a failure: it means no
# structural verdict, so that worker falls to the corroborated-banner path and
# is never guessed onto some other account's quota window.
#
# --- Records --------------------------------------------------------------
#
# state/<id>.quota-wait   one line, atomically replaced:
#     v1 provider=<p> harness=<h> reset=<epoch|unknown> evidence=<structural|banner>
#        detected=<epoch> fp=<evidence-fingerprint> reset_src=<vendor|notice>
#   reset_src records where the RESET TIME came from, which is not the same
#   question as which signal carried the verdict: a structural verdict whose
#   limiting window named no resetsAt takes its clock from the rendered notice.
#   A record written before this field existed reads as vendor, which keeps an
#   in-flight wait on the deadline it was recorded with.
#   Present means "this worker is waiting out a provider refusal". Absent means
#   the ordinary supervision paths own the pane, with no exception of any kind.
#
# state/<id>.quota-spent   the evidence fingerprint of the last wait that ENDED
#   here, however it ended - resumed, refused, or expired. A wait is never
#   re-recorded from evidence that already produced one, which is what stops a
#   worker whose refusal cannot be cleared from oscillating forever between an
#   absorbed wait and an escalating pane. New evidence - a reset the vendor has
#   moved, a different rendered notice - has a different fingerprint and records
#   normally.
#
# state/<id>.quota-nudged  the reset epoch of the last resume actually delivered.
#   This is what makes "one nudge per reset" a property of the system rather
#   than of the caller's control flow: a resume is refused unless its reset
#   epoch is strictly newer than the recorded one, so no sequence of restarts,
#   re-detections, or crash recoveries can produce a second nudge for one window.
#
# Every reader treats a malformed or unreadable record as absent, which returns
# the pane to ordinary supervision rather than extending a wait nobody can read.

# Bound on every quota-axi call. A quota read that cannot finish promptly is
# missing evidence, not a reason to hold the supervision loop.
FM_QUOTA_PROBE_TIMEOUT=${FM_QUOTA_PROBE_TIMEOUT:-20}
# How long a structural probe result is reused. Quota windows move in hours;
# re-reading per poll would spend a vendor call every 15 seconds for an answer
# that cannot have changed.
FM_QUOTA_PROBE_TTL=${FM_QUOTA_PROBE_TTL:-300}
# The provider/model catalog changes on vendor releases, not on usage.
FM_QUOTA_CATALOG_TTL=${FM_QUOTA_CATALOG_TTL:-3600}
# How long a wait carrying NO readable reset time may suppress ordinary stale
# escalation before it retires itself. Either signal can record one: a matched
# notice that states no clock, and a structural verdict whose limiting window
# carried no resetsAt. Deliberately short either way, because a wait with
# nothing to wait for must cost a bounded delay rather than an open-ended
# silence. A wait that DOES carry a reset runs to that reset instead, because
# retiring it earlier would drop the resume it was recorded for.
FM_QUOTA_BANNER_WAIT_MAX_SECS_DEFAULT=1800
FM_QUOTA_BANNER_WAIT_MAX_SECS=${FM_QUOTA_BANNER_WAIT_MAX_SECS:-$FM_QUOTA_BANNER_WAIT_MAX_SECS_DEFAULT}
# Ceiling on a wait whose reset time was read from RENDERED TEXT rather than
# from the vendor's own accounting, measured from detection.
# A stated reset governs below the ceiling and is truncated to it above.
# Six hours is chosen to clear the founding incident comfortably rather than
# tightly: that notice appeared at 06:05 and stated an 08:50 reset, 2h45m, so a
# real vendor window of that shape is honored untouched with room to spare.
# What the ceiling refuses is the outlier - a transcript that quotes someone
# else's notice, or a notice stating a window most of a day out - which would
# otherwise hold one pane out of ordinary escalation for that whole time on a
# home where no structural read is available to contradict it.
# A wait suppresses only an idle pane and never a stopped worker or a reported
# blocker, but a day of silence is still a guard made quieter without making the
# condition rarer, which this contract does not accept.
# A reset the VENDOR itself stated is not capped here: that evidence is the
# account rather than rendered text, and truncating it would drop the resume the
# wait exists to deliver.
FM_QUOTA_NOTICE_RESET_MAX_SECS_DEFAULT=21600
FM_QUOTA_NOTICE_RESET_MAX_SECS=${FM_QUOTA_NOTICE_RESET_MAX_SECS:-$FM_QUOTA_NOTICE_RESET_MAX_SECS_DEFAULT}
# Grace added after a reset time before a resume is attempted, so a nudge does
# not land in the same second the window turns over.
FM_QUOTA_RESET_GRACE_SECS=${FM_QUOTA_RESET_GRACE_SECS:-60}
# How often the whole scan is evaluated. Kept here rather than in the scan
# script because the watcher poll asks whether a scan is DUE before paying to
# start one: the supervision loop runs every few seconds and a quota answer
# cannot change that fast, so a per-poll process launch would be pure cost.
FM_QUOTA_SCAN_INTERVAL=${FM_QUOTA_SCAN_INTERVAL:-300}

fm_quota_scan_marker() {  # <state-dir>
  printf '%s/.quota-scan' "$1"
}

# 0 when a scan is due. A missing or unreadable marker reads as due, so a fresh
# home evaluates once immediately rather than waiting out a first interval.
fm_quota_scan_due() {  # <state-dir>
  case "$FM_QUOTA_SCAN_INTERVAL" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(fm_path_age "$(fm_quota_scan_marker "$1")")" -ge "$FM_QUOTA_SCAN_INTERVAL" ]
}

# Advance the cadence without having evaluated anything. The one caller is a
# supervision loop whose scan could not run at all: without this it would retry
# the failed launch on every poll, turning one broken install into a spawn loop
# underneath the fleet.
fm_quota_scan_defer() {  # <state-dir>
  : > "$(fm_quota_scan_marker "$1")" 2>/dev/null || true
}

# Harnesses that authenticate to exactly one vendor, as a provider token
# quota-axi accepts. Multi-provider harnesses are absent on purpose; see the
# provider-attribution note above.
FM_QUOTA_HARNESS_PROVIDERS="claude:claude codex:codex grok:grok kimi:kimi cursor:cursor"

fm_quota_bin() {
  printf '%s' "${FM_QUOTA_AXI_BIN:-quota-axi}"
}

# Run one bounded, non-interactive quota-axi read. stdin is closed so no vendor
# prompt can block the supervision loop, and the keychain prompt is never opted
# into here.
fm_quota_axi_read() {  # <args...>
  local bin
  bin=$(fm_quota_bin)
  command -v "$bin" >/dev/null 2>&1 || return 1
  case "$FM_QUOTA_PROBE_TIMEOUT" in ''|*[!0-9]*|0) return 1 ;; esac
  fm_run_timed "$FM_QUOTA_PROBE_TIMEOUT" "$bin" "$@" 2>/dev/null </dev/null
}

# --- provider attribution ---------------------------------------------------
#
# The recorded meta is read through bin/fm-backend.sh's fm_meta_get, which every
# driver of this file already sources. There is deliberately no second reader
# here: a private copy would resolve a repeated key differently from the rest of
# the fleet and quietly attribute a worker to another vendor's account.

# Provider for one harness token through the single-vendor table, or empty.
fm_quota_provider_for_harness() {  # <harness>
  local harness=$1 entry
  [ -n "$harness" ] || return 0
  for entry in $FM_QUOTA_HARNESS_PROVIDERS; do
    [ "${entry%%:*}" = "$harness" ] || continue
    printf '%s' "${entry#*:}"
    return 0
  done
  return 0
}

fm_quota_catalog_path() {  # <state-dir>
  printf '%s/.quota-catalog.json' "$1"
}

# Refresh and print quota-axi's provider/model catalog, reusing a cached copy
# within FM_QUOTA_CATALOG_TTL. A failed refresh keeps serving the cached copy:
# a stale join is still authoritative about which vendor publishes a model id,
# and losing it would silently downgrade attribution to the harness table alone.
fm_quota_catalog() {  # <state-dir>
  local state=$1 cache tmp
  cache=$(fm_quota_catalog_path "$state")
  if [ -s "$cache" ] && [ "$(fm_path_age "$cache")" -lt "$FM_QUOTA_CATALOG_TTL" ]; then
    cat "$cache"
    return 0
  fi
  tmp="$cache.tmp.$$"
  if fm_quota_axi_read models --json > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  [ -s "$cache" ] || return 1
  cat "$cache"
}

# Provider for one concrete model id through that catalog, or empty. A model id
# published by more than one provider resolves to nothing rather than to the
# first match.
fm_quota_provider_for_model() {  # <state-dir> <model>
  local state=$1 model=$2 providers
  case "$model" in ''|default|-|unknown) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  providers=$(fm_quota_catalog "$state" 2>/dev/null |
    jq -r --arg id "$model" '[.models[]? | select(.id == $id) | .provider] | unique | .[]' 2>/dev/null) || return 0
  [ -n "$providers" ] || return 0
  [ "$(printf '%s\n' "$providers" | wc -l | tr -d ' ')" = 1 ] || return 0
  # The provider token becomes part of a quota-axi argument and of a marker
  # filename, so only a plain token is accepted from catalog data.
  case "$providers" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  printf '%s' "$providers"
}

# The established provider for a task's recorded meta, or empty when it is not
# established. Empty is a real answer here: no structural verdict is available
# for that worker, and nothing downstream may substitute a guess.
fm_quota_provider_for_meta() {  # <state-dir> <meta>
  local state=$1 meta=$2 harness model from_harness from_model
  harness=$(fm_meta_get "$meta" harness) || harness=
  model=$(fm_meta_get "$meta" model) || model=
  from_harness=$(fm_quota_provider_for_harness "$harness")
  from_model=$(fm_quota_provider_for_model "$state" "$model")
  if [ -n "$from_model" ] && [ -n "$from_harness" ]; then
    # Two sources that contradict each other are two sources that cannot be
    # trusted. Refuse rather than rank them.
    [ "$from_model" = "$from_harness" ] || return 0
    printf '%s' "$from_model"
    return 0
  fi
  printf '%s' "${from_model:-$from_harness}"
}

# --- structural probe -------------------------------------------------------

fm_quota_probe_path() {  # <state-dir>
  printf '%s/.quota-probe.json' "$1"
}

# Refresh quota-axi's provider report for <providers> (a comma list), reusing a
# cached copy within FM_QUOTA_PROBE_TTL. The cache is keyed to the provider set
# it was fetched for, so a fleet that gains a worker on a new provider re-reads
# immediately instead of serving that provider "unknown" until the TTL lapses.
#
# Unlike the catalog, a failed refresh does NOT fall back to a cached copy: an
# old headroom reading is not evidence about right now, and treating it as such
# is how a resumed worker would be parked again on a window that already reset.
fm_quota_probe_refresh() {  # <state-dir> <providers>
  local state=$1 providers=$2 cache key tmp
  cache=$(fm_quota_probe_path "$state")
  key="$cache.providers"
  if [ -s "$cache" ] && [ "$(fm_path_age "$cache")" -lt "$FM_QUOTA_PROBE_TTL" ] &&
    [ "$(head -1 "$key" 2>/dev/null || true)" = "$providers" ]; then
    return 0
  fi
  tmp="$cache.tmp.$$"
  if fm_quota_axi_read --provider "$providers" --json > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if mv -f "$tmp" "$cache" 2>/dev/null; then
      printf '%s\n' "$providers" > "$key" 2>/dev/null || true
      return 0
    fi
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp" "$cache" "$key"
  return 1
}

# Print "<provider>\t<exhausted|available|unknown>\t<reset-epoch|unknown>" for
# every provider in the current probe snapshot.
#
# exhausted requires the all_models scope to report runway.status exhausted_now.
# The reset epoch is the LATEST reset among that scope's limiting windows,
# because headroom returns only once every window that is currently limiting has
# turned over; taking the earliest would resume a worker into a refusal.
# available and unknown are kept distinct so a caller can tell "the vendor says
# there is headroom" from "nothing could be read", and only the second one
# admits the banner fallback.
fm_quota_probe_report() {  # <state-dir>
  local state=$1 cache
  cache=$(fm_quota_probe_path "$state")
  [ -s "$cache" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r '
    .providers[]? as $p
    | ($p.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")) as $scope
    | ($scope.runway.status // "unknown") as $runway
    | ([$p.windows[]? | select(.id as $id | ($scope.limitingWindowIds // []) | index($id)) | .resetsAt]
        | map(select(. != null)) | sort | last) as $reset
    | [ $p.provider,
        (if $runway == "exhausted_now" then "exhausted"
         elif $scope.status == "known" then "available"
         else "unknown" end),
        ($reset // "unknown") ]
    | @tsv
  ' "$cache" 2>/dev/null
}

# Convert one ISO-8601 instant to epoch seconds, or print nothing.
fm_quota_iso_to_epoch() {  # <iso>
  local iso=$1 epoch
  case "$iso" in ''|unknown) return 0 ;; esac
  epoch=$(date -u -d "$iso" +%s 2>/dev/null) ||
    epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${iso%%.*}" +%s 2>/dev/null) || return 0
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$epoch"
}

# Print "<exhausted|available|unknown>\t<reset-epoch|unknown>" for one provider
# from the current snapshot. An absent provider row is unknown, never available.
fm_quota_provider_status() {  # <state-dir> <provider>
  local state=$1 provider=$2 line status reset epoch
  line=$(fm_quota_probe_report "$state" 2>/dev/null | awk -F'\t' -v p="$provider" '$1 == p {print; exit}') || line=
  if [ -z "$line" ]; then
    printf 'unknown\tunknown'
    return 0
  fi
  status=$(printf '%s' "$line" | cut -f2)
  reset=$(printf '%s' "$line" | cut -f3)
  epoch=$(fm_quota_iso_to_epoch "$reset")
  printf '%s\t%s' "$status" "${epoch:-unknown}"
}

# --- banner corroboration ---------------------------------------------------
#
# Independent vendor phrasings, matched case-insensitively. These are separate
# alternatives rather than one canonical string precisely so that a single
# vendor wording change cannot silently disable the check: any one of them
# carries the match, and the live guard in the live-harness-optin family is what
# proves the set still describes the installed harnesses.
FM_QUOTA_BANNER_PATTERNS='hit your (session|usage|weekly|5-hour) limit
usage limit reached
you.?ve reached your [a-z0-9 -]*limit
rate limit exceeded
quota exceeded
limit reached[.,]? *(resets|try again|upgrade)'

# 0 when <text> carries a provider refusal notice.
fm_quota_banner_matches() {  # <text>
  local text=$1 pattern
  [ -n "$text" ] || return 1
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    printf '%s' "$text" | grep -qiE "$pattern" && return 0
  done <<EOF
$FM_QUOTA_BANNER_PATTERNS
EOF
  return 1
}

# Print only the lines of <text> that carry a refusal notice, which is what the
# banner fingerprint is taken over.
fm_quota_banner_signature() {  # <text>
  local text=$1 pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    printf '%s' "$text" | grep -iE "$pattern" || true
  done <<EOF
$FM_QUOTA_BANNER_PATTERNS
EOF
}

# Print the epoch a banner's own reset hint names, or nothing when the notice
# carries none this parser can read without guessing. One shape is accepted: the
# bare wall-clock time of day docs/verification/quota-refusal.md records a vendor
# actually rendering, resolved to its NEXT occurrence in local time - the only
# reading of "resets 8:50am" that cannot land in the past. A second spelling no
# harness is observed to produce would widen the weakest signal in this file for
# no evidence, so there is deliberately none.
fm_quota_banner_reset_epoch() {  # <text>
  local text=$1 clock hour minute meridiem today epoch now
  clock=$(printf '%s' "$text" |
    grep -oiE 'reset[s]?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)' | head -1) || clock=
  [ -n "$clock" ] || return 0
  hour=$(printf '%s' "$clock" | grep -oE '[0-9]{1,2}(:[0-9]{2})?' | head -1)
  minute=${hour#*:}
  [ "$minute" != "$hour" ] || minute=00
  hour=${hour%%:*}
  meridiem=$(printf '%s' "$clock" | grep -oiE '(am|pm)$' | tr 'APM' 'apm')
  case "$hour" in ''|*[!0-9]*) return 0 ;; esac
  case "$minute" in ''|*[!0-9]*) return 0 ;; esac
  [ "$hour" -le 12 ] && [ "$minute" -le 59 ] || return 0
  [ "$meridiem" != pm ] || [ "$hour" -eq 12 ] || hour=$((hour + 12))
  [ "$meridiem" != am ] || [ "$hour" -ne 12 ] || hour=0
  today=$(date +%Y-%m-%d)
  epoch=$(date -d "$today $(printf '%02d:%02d:00' "$hour" "$minute")" +%s 2>/dev/null) ||
    epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$today $(printf '%02d:%02d:00' "$hour" "$minute")" +%s 2>/dev/null) || return 0
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ "$epoch" -gt "$now" ] || epoch=$((epoch + 86400))
  printf '%s' "$epoch"
}

# --- wait records -----------------------------------------------------------

fm_quota_wait_path() {  # <state-dir> <id>
  printf '%s/%s.quota-wait' "$1" "$2"
}

fm_quota_nudged_path() {  # <state-dir> <id>
  printf '%s/%s.quota-nudged' "$1" "$2"
}

# Atomically write one wait record. <fingerprint> identifies the EVIDENCE this
# wait rests on, so the same evidence cannot produce a second wait once this one
# has ended; an empty fingerprint records a wait that is never suppressed later,
# which is the safe direction.
fm_quota_wait_write() {  # <state-dir> <id> <provider> <harness> <reset-epoch|unknown> <evidence> [fingerprint] [reset-source]
  local state=$1 id=$2 provider=$3 harness=$4 reset=$5 evidence=$6 fp=${7:-} src=${8:-vendor} path tmp
  case "$src" in notice) ;; *) src=vendor ;; esac
  path=$(fm_quota_wait_path "$state" "$id")
  tmp="$path.tmp.$$"
  printf 'v1 provider=%s harness=%s reset=%s evidence=%s detected=%s fp=%s reset_src=%s\n' \
    "$provider" "${harness:-unknown}" "$reset" "$evidence" "$(date +%s)" "$fp" "$src" > "$tmp" || return 1
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# The fingerprint of one piece of refusal evidence. Structural evidence is named
# by the account and the reset it stated; banner evidence by the matched notice
# lines alone, never the whole capture, so a ticking clock or a repainting footer
# is not mistaken for a new refusal.
fm_quota_fingerprint() {  # <evidence> <provider> <reset-or-matched-text>
  local evidence=$1 provider=$2 detail=$3
  case "$evidence" in
    structural) printf 'structural:%s:%s' "$provider" "$detail" ;;
    *) printf 'banner:%s' "$(printf '%s' "$detail" | cksum | tr -d ' \n')" ;;
  esac
}

fm_quota_spent_path() {  # <state-dir> <id>
  printf '%s/%s.quota-spent' "$1" "$2"
}

# 0 when <fingerprint> has NOT already produced a wait that ended. An empty
# fingerprint is never spent, so evidence this code cannot fingerprint keeps its
# ordinary behavior instead of being silently suppressed.
fm_quota_fingerprint_unspent() {  # <state-dir> <id> <fingerprint>
  local state=$1 id=$2 fp=$3
  [ -n "$fp" ] || return 0
  [ "$(head -1 "$(fm_quota_spent_path "$state" "$id")" 2>/dev/null || true)" != "$fp" ]
}

# A reset epoch as a readable instant, for the supervision reasons a human
# eventually reads. Lives here rather than in one caller because both the scan
# and the watcher's stale recheck report the same wait.
fm_quota_format_reset() {  # <epoch|unknown>
  case "$1" in
    ''|unknown|*[!0-9]*) printf 'at an unknown time' ;;
    *) date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
       date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
       printf 'at an unknown time' ;;
  esac
}

fm_quota_spend_fingerprint() {  # <state-dir> <id> <fingerprint>
  local path tmp
  [ -n "$3" ] || return 0
  path=$(fm_quota_spent_path "$1" "$2")
  tmp="$path.tmp.$$"
  printf '%s\n' "$3" > "$tmp" || return 1
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Print one field of a wait record, or nothing. A record that is not the known
# schema prints nothing for every field, which every caller reads as absent.
fm_quota_wait_field() {  # <state-dir> <id> <field>
  local state=$1 id=$2 field=$3 path line value
  path=$(fm_quota_wait_path "$state" "$id")
  [ -s "$path" ] || return 0
  line=$(head -1 "$path" 2>/dev/null) || return 0
  case "$line" in 'v1 '*) ;; *) return 0 ;; esac
  value=$(printf '%s' "$line" | tr ' ' '\n' | sed -n "s/^$field=//p" | head -1)
  printf '%s' "$value"
}

# The throttle marker for the bounded re-surface bin/fm-watch.sh gives an
# absorbed quota wait. It is keyed to the TASK rather than to a window marker so
# that retiring the wait retires its cadence in the same operation: a later,
# separate wait then measures its re-surface from its own start instead of
# inheriting a spent one.
fm_quota_resurfaced_path() {  # <state-dir> <id>
  printf '%s/%s.quota-resurfaced' "$1" "$2"
}

fm_quota_wait_clear() {  # <state-dir> <id>
  rm -f "$(fm_quota_wait_path "$1" "$2")" "$(fm_quota_resurfaced_path "$1" "$2")"
}

# The reset-less bound, as a number. A knob this code cannot read as a number
# falls back to the documented default rather than aborting the watcher poll
# loop on an arithmetic error under `set -u`.
fm_quota_banner_bound() {
  case "$FM_QUOTA_BANNER_WAIT_MAX_SECS" in
    ''|*[!0-9]*) printf '%s' "$FM_QUOTA_BANNER_WAIT_MAX_SECS_DEFAULT" ;;
    *) printf '%s' "$FM_QUOTA_BANNER_WAIT_MAX_SECS" ;;
  esac
}

# The rendered-text reset ceiling, as a number. A knob this code cannot read as
# a number falls back to the documented default rather than aborting the
# watcher poll loop on an arithmetic error under `set -u`.
fm_quota_notice_bound() {
  case "$FM_QUOTA_NOTICE_RESET_MAX_SECS" in
    ''|*[!0-9]*) printf '%s' "$FM_QUOTA_NOTICE_RESET_MAX_SECS_DEFAULT" ;;
    *) printf '%s' "$FM_QUOTA_NOTICE_RESET_MAX_SECS" ;;
  esac
}

# The grace added after a reset time, as a number. A knob this code cannot read
# as a number is no grace at all rather than an arithmetic error under `set -u`.
fm_quota_reset_grace() {
  case "$FM_QUOTA_RESET_GRACE_SECS" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$FM_QUOTA_RESET_GRACE_SECS" ;;
  esac
}

# The moment a wait stops being a wait even if nothing else happens, so no
# recorded wait can outlive its own evidence. A wait carrying a readable reset
# expires when the resume it is owed becomes due, never before it: a deadline
# earlier than that would retire the record inside the grace window and drop the
# one resume the wait exists to deliver. A reset-less wait has no such moment to
# reach, so it expires on fm_quota_banner_bound measured from detection -
# whichever signal recorded it, the notice path or a structural verdict whose
# limiting window carried no resetsAt.
#
# That a wait STATING its reset runs to that reset, with the reset-less bound
# applying only to one stating none, is deliberate: the founding incident is a
# notice at 06:05 naming an 08:50 reset, so a short blanket cap would retire the
# wait before the resume it exists to deliver. A long wait cannot hide a broken
# worker either way - it always retires at its own deadline and can never
# re-extend, and fm_quota_wait_suppresses stands in front of neither a terminal
# status nor a non-alive reading.
#
# A reset read from RENDERED TEXT is additionally truncated to
# fm_quota_notice_bound measured from detection, because that evidence is a
# vendor string rather than the account: it is honored where a real window would
# fall and refused where it would buy most of a day of silence. A reset the
# vendor itself stated is never truncated.
fm_quota_wait_deadline() {  # <state-dir> <id>
  local state=$1 id=$2 reset detected grace bound src deadline ceiling
  reset=$(fm_quota_wait_field "$state" "$id" reset)
  detected=$(fm_quota_wait_field "$state" "$id" detected)
  case "$detected" in ''|*[!0-9]*) return 1 ;; esac
  case "$reset" in
    ''|*[!0-9]*) bound=$(fm_quota_banner_bound); printf '%s' $((detected + bound)); return ;;
  esac
  grace=$(fm_quota_reset_grace)
  deadline=$((reset + grace))
  src=$(fm_quota_wait_field "$state" "$id" reset_src)
  if [ "$src" = notice ]; then
    ceiling=$((detected + $(fm_quota_notice_bound)))
    [ "$reset" -le "$ceiling" ] || deadline=$ceiling
  fi
  printf '%s' "$deadline"
}

# 0 while a recorded wait is still current: the record parses and its deadline
# has not passed. This is the ONE predicate supervision asks before treating an
# idle pane as a declared wait rather than a possible wedge, so everything it
# cannot read positively answers "no" and returns the pane to ordinary handling.
fm_quota_wait_active() {  # <state-dir> <id>
  local deadline
  deadline=$(fm_quota_wait_deadline "$1" "$2") || return 1
  [ -n "$deadline" ] || return 1
  [ "$(date +%s)" -lt "$deadline" ]
}

# 0 when a status line is one the captain is still owed: a terminal verb, or a
# captain-relevant line that is not an ordinary progress verb. A quota refusal
# explains an idle PANE, never a reading a worker already declared, so nothing
# on this path may stand in front of one or nudge a worker holding one. The
# status predicates come from bin/fm-classify-lib.sh, which every driver of this
# file already sources.
fm_quota_status_owed_to_captain() {  # <status-line>
  local last=$1
  [ -n "$last" ] || return 1
  status_is_terminal_verb "$last" && return 0
  status_is_captain_relevant "$last"
}

# THE one owner of the question "may this recorded wait stand in front of a
# supervision reading". Every suppression site asks this and composes no
# preconditions of its own, so a later caller cannot take the record's benefit
# while quietly dropping one of its guards. fm_quota_wait_active stays the
# deadline predicate underneath it, for this owner and for the non-suppression
# readers - the scan and the resume path - that only ask whether a record is
# still current.
#
# <admission> is the caller's own liveness evidence, in bin/fm-watch.sh's
# vocabulary, and is explicit precisely because the daemon has none where the
# watcher does:
#   admit-alive   the idle-stale path, which reads the endpoint and admits an
#                 alive reading as new evidence.
#   refuse-alive  the busy-turn-bound path. A pane past that bound renders a
#                 harness busy footer, so a hung foreground call there looks
#                 exactly like a worker still being served, and absorbing it is
#                 how a long hang hides. Never suppressed.
#   unknown       the away-mode daemon, which takes no liveness reading at all.
#                 It is not the busy-hang path either, so the record and the
#                 status line carry the decision alone.
#
# A status line the captain is still owed is never suppressed at any site: a
# worker that reported blocked: or done: still owes that reading, and a wait
# that swallowed it would be exactly the quieter alarm without a rarer condition
# this contract forbids.
fm_quota_wait_suppresses() {  # <state-dir> <id> <last-status-line> <admission>
  local state=$1 id=$2 last=$3 admission=$4
  [ -n "$id" ] || return 1
  case "$admission" in
    admit-alive|unknown) ;;
    *) return 1 ;;
  esac
  ! fm_quota_status_owed_to_captain "$last" || return 1
  fm_quota_wait_active "$state" "$id"
}

# The provider a recorded wait names, as a human reads it. `unattributed` is an
# internal token for a worker whose provider could not be established, never a
# vendor name, so no surface may print it as one. Lives here rather than in one
# caller for the same reason fm_quota_format_reset does: the watcher's stale
# recheck and the away-mode daemon report the same record.
fm_quota_wait_provider_name() {  # <state-dir> <id>
  local provider
  provider=$(fm_quota_wait_field "$1" "$2" provider)
  case "$provider" in
    ''|unattributed) printf 'provider' ;;
    *) printf '%s' "$provider" ;;
  esac
}

# 0 when the resume a recorded wait is owed can actually be REACHED: its reset
# parses, and its own deadline does not retire the record before that resume
# comes due. The presence of a reset is not that question and may never be used
# as a proxy for it, because the rendered-text ceiling produces waits whose reset
# is perfectly readable and whose resume can still never fire - the record is
# gone at the cap, hours before the notice's stated reset arrives. This is the
# one owner of the promise, so the reporting surfaces and the resume path cannot
# disagree about which waits self-resume.
fm_quota_wait_resume_reachable() {  # <state-dir> <id>
  local state=$1 id=$2 reset deadline grace
  reset=$(fm_quota_wait_field "$state" "$id" reset)
  case "$reset" in ''|*[!0-9]*) return 1 ;; esac
  deadline=$(fm_quota_wait_deadline "$state" "$id") || return 1
  case "$deadline" in ''|*[!0-9]*) return 1 ;; esac
  grace=$(fm_quota_reset_grace)
  [ "$deadline" -ge $((reset + grace)) ]
}

# The reset a recorded wait carries, as a clause a sentence about that wait can
# take, and NOTHING at all when no reset could be read. A wait with no reset has
# no time to state, so no surface may render one: the resume outcome below is
# where that case is spoken, once. Lives here beside the other renderers so both
# detection lines ask the same owner rather than each deciding locally.
fm_quota_wait_reset_phrase() {  # <state-dir> <id>
  local reset
  reset=$(fm_quota_wait_field "$1" "$2" reset)
  case "$reset" in ''|*[!0-9]*) return 0 ;; esac
  printf ', resets %s' "$(fm_quota_format_reset "$reset")"
}

# What a reader must expect of a recorded wait. Only a resume this record can
# reach is promised: a wait whose reset nobody could read is never resumed, and
# neither is one the ceiling caps short of the reset its notice states, so no
# surface may report either as self-resuming.
fm_quota_wait_resume_outcome() {  # <state-dir> <id>
  if fm_quota_wait_resume_reachable "$1" "$2"; then
    printf 'this worker is resumed automatically when that limit resets'
    return
  fi
  case "$(fm_quota_wait_field "$1" "$2" reset)" in
    ''|*[!0-9]*) printf 'no reset time could be read, so this worker is NOT resumed automatically' ;;
    *) printf 'that reset was read from a rendered notice and is capped, so this wait retires first and the worker is NOT resumed automatically; ordinary escalation takes this pane back at the cap, and an account still refused records a fresh wait on fresh evidence' ;;
  esac
}

# 0 when a recorded wait's reset time has arrived and a resume is therefore due.
# A wait whose resume is not reachable is never due: one with no readable reset
# expires instead, because a resume time nobody could read is a guess and
# guessing is how a nudge lands in a worker that is actually mid-task; and one
# the ceiling caps has already spent the deadline it was recorded with, so
# delivering at its stated reset would honour a bound the record no longer has.
fm_quota_wait_resume_due() {  # <state-dir> <id>
  local reset grace
  fm_quota_wait_resume_reachable "$1" "$2" || return 1
  reset=$(fm_quota_wait_field "$1" "$2" reset)
  grace=$(fm_quota_reset_grace)
  [ "$(date +%s)" -ge $((reset + grace)) ]
}

# 0 when a resume for <reset-epoch> has NOT been delivered before. This is what
# makes one-nudge-per-reset a property of the durable record rather than of any
# caller's control flow: a repeated, restarted, or recovered scan reads the same
# refusal here.
fm_quota_nudge_unspent() {  # <state-dir> <id> <reset-epoch>
  local state=$1 id=$2 reset=$3 last
  case "$reset" in ''|*[!0-9]*) return 1 ;; esac
  last=$(head -1 "$(fm_quota_nudged_path "$state" "$id")" 2>/dev/null) || last=
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  [ "$reset" -gt "$last" ]
}

fm_quota_nudge_record() {  # <state-dir> <id> <reset-epoch>
  local path tmp
  path=$(fm_quota_nudged_path "$1" "$2")
  tmp="$path.tmp.$$"
  printf '%s\n' "$3" > "$tmp" || return 1
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Claim <reset-epoch>'s one resume, atomically against any other scan. Reading
# the durable record and writing it are one step here because they are two steps
# everywhere else: a watcher displaced by the stale-lock steal can still overlap
# the one that replaced it, both would sit in the same forced re-probe for
# seconds, and both would otherwise read the same reset as unspent and deliver
# into the same live pane. The claim is made BEFORE
# delivery, so a crash between the two costs one missed resume that the ordinary
# stale path escalates, never a second nudge.
#
# Returns 0 when this caller owns the resume, 1 when the reset was already spent,
# and 2 when the claim could not be made at all - another scan holds it, or the
# record could not be written - which delivers nothing and leaves the wait for a
# later scan. The lock is bin/fm-wake-lib.sh's, so a scan killed mid-claim leaves
# a dead-pid hold that the next attempt reclaims rather than a permanent block.
fm_quota_nudge_claim() {  # <state-dir> <id> <reset-epoch>
  local state=$1 id=$2 reset=$3 lock rc
  lock="$(fm_quota_nudged_path "$state" "$id").lock"
  fm_lock_try_acquire "$lock" || return 2
  if fm_quota_nudge_unspent "$state" "$id" "$reset"; then
    if fm_quota_nudge_record "$state" "$id" "$reset"; then
      rc=0
    else
      rc=2
    fi
  else
    rc=1
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}
