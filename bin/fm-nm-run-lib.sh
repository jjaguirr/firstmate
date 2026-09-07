#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Does run head $2 match worktree $1's code identity? Four outcomes, because
# each names a different fact and collapsing any two of them is what let a live
# run be misread as a dead one (see the incident notes in bin/fm-crew-state.sh's
# header). "Provably not ours" and "we cannot tell whose run this is" were the
# first pair to be separated; "the branch was rewritten" and "the crew committed
# past the run" are the second, because a rewritten head is exactly what a
# pipeline rebase leaves on the branch a crew owns, while a run head the crew
# has since committed past is a run that crew genuinely moved on from:
#
#   $FM_NM_HEAD_MATCH (0)      attributable to this worktree
#     - equal commits (short or full SHA), or
#     - worktree HEAD is an ancestor of the run head, i.e. pipeline fix commits
#       on the same history advanced the run tip past local HEAD
#   $FM_NM_HEAD_MISMATCH (1)   provably NOT this worktree's code
#     - run head is a strict ancestor of worktree HEAD: local work advanced
#       outside the run, so the crew is past it
#     - no head recorded at all, so there is nothing to bind
#   $FM_NM_HEAD_DIVERGED (3)   provably not this worktree's code EITHER, but by
#                              a rewrite rather than by the crew moving on
#     - both heads resolve and neither is an ancestor of the other, so the
#       branch's history was rewritten. Routinely that rewrite is the pipeline
#       rebasing the branch this crew owns, after which no run row can match the
#       local head again, so a caller reporting state may weigh branch identity
#       here - see bin/fm-crew-state.sh's run-selection rules.
#   $FM_NM_HEAD_UNRESOLVED (2) undecidable, NOT a refutation
#     - the run head is not an object this worktree has, so neither the equality
#       nor the ancestry test can run. The routine cause is benign and expected:
#       the pipeline keeps its own copy of the branch, so between its first
#       pushed commit and the crew's next sync the run tip simply is not here
#       yet. A rewritten foreign branch looks identical from here, so this is
#       never evidence either way.
#     - the worktree's own HEAD cannot be read
#
# Callers that only ever attribute on proof can keep testing the exit status as
# a boolean: every non-match outcome is non-zero, so `... || return 1` still
# refuses on all three. bin/fm-teardown.sh depends on exactly that, and aborting
# a run is destructive, so a diverged head must keep refusing there too. A
# caller that reports state must branch on 2 and 3 explicitly rather than
# reading either as a plain mismatch.
FM_NM_HEAD_MATCH=0
FM_NM_HEAD_MISMATCH=1
FM_NM_HEAD_UNRESOLVED=2
FM_NM_HEAD_DIVERGED=3
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return "$FM_NM_HEAD_MISMATCH"
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return "$FM_NM_HEAD_UNRESOLVED"
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) \
    || return "$FM_NM_HEAD_UNRESOLVED"
  [ "$run_full" = "$local_full" ] && return "$FM_NM_HEAD_MATCH"
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null \
    && return "$FM_NM_HEAD_MATCH"
  git -C "$wt" merge-base --is-ancestor "$run_full" "$local_full" 2>/dev/null \
    && return "$FM_NM_HEAD_MISMATCH"
  return "$FM_NM_HEAD_DIVERGED"
}
