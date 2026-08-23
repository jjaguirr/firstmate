#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# There are three documented exceptions. The absorb classification
# (crew_absorb_class and its working/paused wrappers) is NOT a pure status-file
# read: it reuses bin/fm-crew-state.sh, which may make a bounded no-mistakes call,
# to decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal handling
# and first sighting of a stale hash, never on every wake, so the per-wake triage
# stays cheap. status_open_decisions_incremental (see "incremental (cursor-backed)
# open-decisions fold" below) also writes: it persists a per-status-file byte
# cursor and folded open-set as a side effect, so a per-drain fleet-wide scan
# stays bounded by new appends instead of re-reading each task's whole lifetime
# log every time. crew_worktree_written_since reads the task's meta file and walks
# a bounded slice of its worktree instead of a status file, so callers run it only
# at the moment they would otherwise escalate.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for lifecycle reconciliation and the
# "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# fm_run_timed, the shared hard bound the worktree write probe below puts around
# its one filesystem walk. bin/fm-timeout-lib.sh owns bounded execution for this
# repo, so nothing here re-derives the coreutils/BSD/perl selection. That library
# declares `set -u` for its own hygiene, which a sourced sibling must not impose on
# THIS library's consumers - several of them deliberately run without it - so the
# caller's setting is restored around the source.
case $- in *u*) _fm_classify_nounset=on ;; *) _fm_classify_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_CLASSIFY_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_classify_nounset" = on ] || set +u
unset _fm_classify_nounset

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a verified captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-captain-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line's leading verb is the verified captain-held transfer verb.
# The same pure verb read as status_is_paused, and the discriminator a supervisor
# needs once a declared wait has already been recognized: the two declarations get
# the same bounded cadence, but they block on DIFFERENT humans, so a recheck that
# names an external dependency for a hold points the captain away from the fact
# that they are the one who can clear it.
status_is_captain_held() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave a crew's endpoint idle, so both
# supervisors give them one cadence: the away-mode daemon defers the wedge and
# ages a pause marker instead, and the watcher applies its bounded pause cadence
# once pause_state_class has admitted the wait (fm-watch.sh owns which liveness
# evidence each kind of crew must supply for that).
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1
  status_is_paused "$line" || status_is_captain_held "$line"
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the durable status-fold contract that fixes this - a
# needs-decision/blocked line OPENS a keyed decision, and only an explicit
# resolution or a verified captain-held backlog transfer referencing that key
# CLOSES it. status_open_decisions_for_task is the corresponding current
# answerability verdict: it preserves that durable fold, then removes only the
# keys an active run-step has provably superseded, one key at a time (see
# _fm_open_decisions_reconcile_active_run). A pane read never closes a decision,
# and a later unrelated terminal line never clears an open captain decision on
# its own.
# Who WRITES the closing line is owned elsewhere: the answering firstmate closes
# at answer time through fm-send's --resolve-key (bin/fm-send.sh header), and a
# worker self-closes only a blocker that cleared without an answer (bin/fm-brief.sh
# rule 6), so closure never depends on a busy worker's discipline.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token names the decision. Its documented
# position sits between the verb and the colon, and a complete token at the
# head of the note is accepted as an EQUIVALENT position, because that
# misplaced-colon shape is common real worker output whose stated key must
# never silently collapse into the shared "default" bucket (issue #2109):
#   needs-decision [key=api-shape]: <summary>
#   needs-decision: [key=api-shape] <summary>
#   resolved       [key=api-shape]: <how it was decided>
# Both positions state the same key and yield the same note (a consumed
# note-head token is key metadata, stripped from the note); when both positions
# carry a token, the documented before-colon one wins and the note-head token
# stays note text. A token deeper inside the note is prose, never a stated key,
# so a summary merely MENTIONING "[key=x]" cannot open or close that decision.
# A line with no token in either position uses the key "default", preserving
# the historical one-open-decision-per-task behavior (a bare "resolved:" closes
# "default"). A stated key whose slug fails the charset below is rejected (the
# folds skip the line), never rewritten to "default".
# The parsers are pure reads of a single line. Status metadata may contain any
# number of "[name=value]" tags before the colon, in any order, so verb parsing
# ends at the first tag rather than special-casing "[key=...]".
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
# 0 when a complete "[key=...]" token sits in the documented position before
# the line's first colon (or anywhere on a line that has no colon at all).
_fm_key_before_colon() {  # <status-line>
  case "${1%%:*}" in
    *\[key=*\]*) return 0 ;;
    *) return 1 ;;
  esac
}
# Raw slug of a complete "[key=<slug>]" token at the head of the note (the
# first thing after the line's first colon, ignoring whitespace). Fails when
# the line has no colon or no complete token there; slug charset validity is
# the caller's check via _fm_decision_slug_ok, exactly as for the before-colon
# position.
_fm_key_at_note_head() {  # <status-line> -> raw slug
  local rest
  case "$1" in
    *:*) rest=${1#*:} ;;
    *) return 1 ;;
  esac
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in
    \[key=*\]*) rest=${rest#\[key=}; printf '%s' "${rest%%\]*}" ;;
    *) return 1 ;;
  esac
}
# 0 when a stated key slug is well-formed: nonempty, A-Za-z0-9._- only.
_fm_decision_slug_ok() {  # <slug>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  local n k
  case "$1" in
    *:*) n=${1#*:}; n=${n#"${n%%[![:space:]]*}"} ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  # A note-head token that states this line's key (no before-colon token, valid
  # slug) is key metadata, not note text: strip it so both stated-key positions
  # yield the same note.
  if ! _fm_key_before_colon "$1" && k=$(_fm_key_at_note_head "$1") \
    && _fm_decision_slug_ok "$k"; then
    n=${n#"[key=$k]"}
    n=${n#"${n%%[![:space:]]*}"}
  fi
  printf '%s' "$n"
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local k
  if _fm_key_before_colon "$1"; then
    k=${1%%:*}
    k=${k#*\[key=}
    k=${k%%\]*}
  else
    k=$(_fm_key_at_note_head "$1") || { printf 'default'; return 0; }
  fi
  _fm_decision_slug_ok "$k" || return 1
  printf '%s' "$k"
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold ONE status line into an existing "<key>\t<verb>\t<note>\n"-per-line open
# set, applying the same needs-decision/blocked-opens, resolved/captain-held-closes
# rule status_open_decisions documents above. Pure text transform, no file I/O.
# This is the ONE place the per-line open/resolved rule is written; both the
# whole-file fold (status_open_decisions) and the incremental cursor-backed fold
# (status_open_decisions_incremental) below call this instead of re-deriving the
# rule, so the two consumption strategies can never drift apart on semantics.
# Reserved decision-key namespaces, and the rule that makes them mean something.
#
# A key like `pending-reply-<id>` names a decision that one library raises and is
# the only thing that ever closes it. Every writer reaches this same stream: a
# local mate appends straight into it, and a remote mate's lines are mirrored
# into it verbatim. So without a rule here, any writer could claim a reserved
# key with an unrelated note, take the key over in this fold, and permanently
# block the owner's close - leaving a decision nothing will ever resolve - or
# clear the owner's decision with a bare resolution.
#
# The rule is deliberately generic, so this fold needs no knowledge of any
# particular owner: a reserved key may only be opened or closed by a line whose
# note speaks that namespace's own vocabulary, which its owner states by
# beginning the note with a `<namespace>...:` token. A line failing that is not a
# decision transition at all here and is folded as ordinary status. This is a
# consumer-side rule on purpose - it protects local and remote writers
# identically, and it can never fail a whole delta or wedge a stream the way a
# writer-side rejection would.
FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT='pending-reply-'

# 0 when <key> is not reserved, or is reserved and <note> speaks its vocabulary.
_fm_decision_key_transition_allowed() {  # <key> <note>
  local key=$1 note=$2 prefix
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        case "$note" in
          "$prefix"*:*) return 0 ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done
  return 0
}

_fm_decision_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb>
  local open=$1 line=$2 resolve=$3 held=$4 verb key note stripped
  stripped=${line//[[:space:]]/}
  [ -n "$stripped" ] || { printf '%s' "$open"; return 0; }
  verb=$(status_line_verb "$line")
  key=$(_fm_decision_key "$line") || { printf '%s' "$open"; return 0; }
  _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")" \
    || { printf '%s' "$open"; return 0; }
  case "$verb" in
    needs-decision|blocked)
      note=$(status_line_note "$line")
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
      ;;
    "$resolve"|"$held")
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      ;;
  esac
  printf '%s' "$open"
}

# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
# The scan_open_decisions wrapper below enumerates a whole directory rather than
# a single caller-chosen path, so a status file that is itself a symlink (e.g.
# escaping the state directory) is rejected outright with a plain [ -L ] check
# before any read - a cheap builtin, unlike fm_wake_latest_event's O_NOFOLLOW
# subprocess read, which exists for that function's much narrower payload-driven
# path resolution rather than this directory-local glob.
status_open_decisions() {  # <status-file>
  local f=$1 line resolve held open=''
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
  done < "$f"
  printf '%s' "$open"
}

# 0 when <key> has a record in a folded "<key>\t<verb>\t<note>" open set.
_fm_open_set_has() {  # <open-set> <key>
  case "$1" in
    "$2"$'\t'*|*$'\n'"$2"$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

# The verb stored for <key> in a folded open set (empty when it has no record).
_fm_open_set_verb() {  # <open-set> <key>
  local line
  while IFS= read -r line; do
    case "$line" in
      "$2"$'\t'*) line=${line#*$'\t'}; printf '%s' "${line%%$'\t'*}"; return 0 ;;
    esac
  done <<EOF
$1
EOF
  return 0
}

# The verb that last moved <key> in a status stream, which is what tells a
# consumer HOW the status side currently reads that key. Prints the opening verb
# (needs-decision or blocked) while the key is still open, the closing verb
# (resolved, or the captain-held durable-transfer verb) once it is closed, and
# nothing at all when no line in the stream ever stated a transition for it.
#
# The distinction between the two closing verbs is the whole point: a
# `captain-held` close is the VERIFIED handoff to a durable captain-held task
# (fm-captain-hold.sh complete writes it only after verifying that task), so the
# structured row staying open afterwards is correct. A `resolved` close claims
# the question is settled outright, so a structured row still open behind it is a
# contradiction between the two records - see fm-captain-hold.sh's `diverged`.
#
# Semantics are not re-derived here: every line goes through the same
# _fm_decision_fold_line rule the two folds use, and the reported verb is read
# off the transitions that rule produces. Only lines whose parsed key equals the
# requested one can move that key, so a caller-supplied key other than "default"
# lets the scan pre-filter the stream to lines carrying its token and stay cheap
# on a long log.
status_key_closing_verb() {  # <status-file> <key>
  local f=$1 want=$2 line resolve held open='' was verb='' stream
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  [ -n "$want" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  if [ "$want" = default ]; then
    stream=$(cat "$f") || return 0
  else
    stream=$(grep -F "[key=$want]" "$f") || stream=''
  fi
  [ -n "$stream" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    was=0
    _fm_open_set_has "$open" "$want" && was=1
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
    if [ "$was" = 1 ] && ! _fm_open_set_has "$open" "$want"; then
      verb=$(status_line_verb "$line")
    fi
  done <<EOF
$stream
EOF
  if _fm_open_set_has "$open" "$want"; then
    _fm_open_set_verb "$open" "$want"
    return 0
  fi
  printf '%s' "$verb"
}

# Status verbs that record the crew moving on with its work. In the lifecycle
# reconciliation below, one of these lines stating the SAME key as an open
# record, appended after it, is the durable per-key witness that the crew
# moved past that decision; the line itself closes nothing, a keyless or
# other-key progress line is never a witness for an untouched key, and the
# paused verb (a declared wait, not progress) is deliberately not one of them.
_fm_status_verb_is_progress() {  # <verb>
  case "$1" in
    working|done|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# The key a line explicitly states in either documented position, through the
# one key parser; fails for a keyless line, which _fm_decision_key would fold
# as "default" and which must never act as another record's witness.
_fm_decision_stated_key() {  # <status-line> -> key slug
  _fm_key_before_colon "$1" || _fm_key_at_note_head "$1" >/dev/null || return 1
  _fm_decision_key "$1"
}

# The durable fold re-run over the same bytes (optionally bounded by a captured
# end offset so a snapshot-bounded fold compares like with like) with one extra
# transition: a progress line stating a key drops that key's record. Every key
# open in the durable set but absent here was followed by its own progress
# line, which is the per-key evidence the active-run reconciliation needs.
# The drop honors the reserved-namespace rule exactly as every other
# transition does, so a reserved key is witnessed only by a line that speaks
# its owner's vocabulary.
# Fails (status 1, nothing printed) when the bytes cannot be re-read, so the
# caller can keep the durable set rather than reconcile against nothing.
# Fold ONE status line into a WITNESS set: the durable per-line rule
# (_fm_decision_fold_line, still the only decision parser) plus the single
# extra transition that a progress line stating a key drops that key. This is
# the ONE place that extra transition is written, so the whole-file witness
# fold below and the cursor-backed incremental fold further down cannot drift.
# Pure text transform, no file I/O.
_fm_decision_witness_fold_line() {  # <witness-set> <status-line> <resolve-verb> <held-verb>
  local witness=$1 line=$2 resolve=$3 held=$4 verb key
  verb=$(status_line_verb "$line")
  if _fm_status_verb_is_progress "$verb" && key=$(_fm_decision_stated_key "$line"); then
    if _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")"; then
      witness=$(_fm_decision_drop "$witness" "$key")
      [ -z "$witness" ] || witness="${witness}"$'\n'
    fi
    printf '%s' "$witness"
    return 0
  fi
  _fm_decision_fold_line "$witness" "$line" "$resolve" "$held"
}

_fm_open_decisions_with_keyed_progress() {  # <status-file> [<captured-end-offset>]
  local f=$1 captured_end=${2:-} line resolve held open='' size span
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$captured_end" in
    ''|*[!0-9]*) size=$(_fm_status_file_size "$f") || return 1 ;;
    *) size=$captured_end ;;
  esac
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  span=$(_fm_status_read_span "$f" 0 "$size" 2>/dev/null) || return 1
  # Same test-only observability seam the incremental fold records through, so
  # a boundedness assertion covers the whole picture: this whole-file witness
  # fold reads bytes 0..size, which is what the one-shot callers below already
  # pay for their durable fold, and a probe that could not see it would leave a
  # second unbounded read invisible.
  [ -n "${FM_OPEN_DECISIONS_READ_PROBE:-}" ] \
    && printf '%s\t%s\n' "$f" "$size" >> "$FM_OPEN_DECISIONS_READ_PROBE"
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(_fm_decision_witness_fold_line "$open" "$line" "$resolve" "$held")
  done <<EOF
$span
EOF
  printf '%s' "$open"
}

# fm-crew-state's current-state line for a task whose keyed decisions an active
# run could supersede, or nothing when no such run can exist. Only a local ship
# task can own an attributed no-mistakes run: fm-crew-state.sh skips run
# attribution for scouts and secondmates and answers a remote mate from its
# endpoint before its run-step path, so reading its meta the same way it does
# and skipping those tasks here avoids paying for the axi/pane/ssh reads on
# every drain for a task that can never produce a run-step verdict. An
# unreadable result is reported as nothing, which fails open to the durable set.
status_task_run_state() {  # <task-id> <status-file>
  local task=$1 meta="${2%.status}.meta" kind remote line=''
  if [ "$_FM_RUN_STATE_MEMO_ENABLED" = 1 ] && line=$(_fm_run_state_memo_get "$task"); then
    printf '%s' "$line"
    return 0
  fi
  [ "$_FM_RUN_STATE_MEMO_SEALED" = 0 ] || return 0
  line=''
  if [ -f "$meta" ] && [ -r "$meta" ]; then
    remote=$(grep '^remote_host=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
    if [ -z "$remote" ] && [ "${kind:-ship}" = ship ]; then
      line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || line=''
      line=${line%%$'\n'*}
    fi
  fi
  if [ "$_FM_RUN_STATE_MEMO_ENABLED" = 1 ]; then
    _FM_RUN_STATE_MEMO="${_FM_RUN_STATE_MEMO}${task}"$'\t'"${line}"$'\n'
  fi
  printf '%s' "$line"
}

# Per-process memo for status_task_run_state, off by default so an ordinary
# one-shot caller keeps reading live state. fm-crew-state.sh is NOT a pure read
# (it may make a bounded no-mistakes call, plus git and pane reads), so a
# surface that presents the whole fleet warms every verdict it can need through
# status_task_run_state_prefetch and then SEALS the memo. While sealed, a miss
# never execs the reader: it reports nothing, which fails open to the durable
# set, so "no crew-state exec happens under the presentation lock" is an
# invariant of the code rather than a property of the warming gate being
# perfect. The gate below folds the current durable set, so the only way to
# miss is a decision appended between the prefetch and the scan; that key stays
# PRESENTED for one drain (never hidden) and is warmed on the next.
# Records are "<task>\t<line>\n"; a task whose verdict is deliberately nothing
# (missing meta, scout, secondmate, remote mate, unreadable reader) memoizes an
# empty line so its gate is not re-walked either. Portable: no associative
# arrays, so this runs on bash 3.2 too.
_FM_RUN_STATE_MEMO=''
_FM_RUN_STATE_MEMO_ENABLED=0
_FM_RUN_STATE_MEMO_SEALED=0

_fm_run_state_memo_get() {  # <task-id> -> memoized line, status 1 when absent
  local task=$1 rest=$_FM_RUN_STATE_MEMO
  case "$rest" in
    "$task"$'\t'*) rest=${rest#"$task"$'\t'} ;;
    *$'\n'"$task"$'\t'*) rest=${rest#*$'\n'"$task"$'\t'} ;;
    *) return 1 ;;
  esac
  printf '%s' "${rest%%$'\n'*}"
}

# Turn the memo on, warm it for every task that currently holds an open keyed
# decision, and seal it, all BEFORE the caller takes its presentation lock.
# Only a task with a non-empty durable set can reach the active-run
# reconciliation, so the gate is that exact set, computed by the same
# cursor-backed fold the in-lock scan uses. This is the drain's ONLY fold of
# each task's new appends: it commits the cursor, so the scan behind the lock
# finds the cursor already at end of file and folds nothing a second time.
#
# The one exception is a home whose fleet presentation manifest does not exist
# yet. status_presentation_cursor_offset seeds the UNREAD surface from this
# same per-task cursor while that manifest is missing, so committing here would
# move an offset the unread section has not read yet and swallow a buried
# answer. Those drains fold in PEEK mode instead (no commit) and the in-lock
# scan folds and commits as before; the very first drain writes the manifest,
# and every drain after it takes the single-fold path.
status_task_run_state_prefetch() {  # <state>
  local state=$1 f task mode=peek
  _FM_RUN_STATE_MEMO=''
  _FM_RUN_STATE_MEMO_ENABLED=1
  _FM_RUN_STATE_MEMO_SEALED=0
  if [ -f "$state/.status-presentation-cursor" ] && [ ! -L "$state/.status-presentation-cursor" ]; then
    mode=''
  fi
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    status_open_decisions_incremental "$f" '' "$mode" >/dev/null || :
    [ -n "$FM_OPEN_DECISIONS_OPEN" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    status_task_run_state "$task" "$f" >/dev/null
  done
  _FM_RUN_STATE_MEMO_SEALED=1
  return 0
}

# Reconcile one durable open set with the task lifecycle, one key at a time,
# against an ALREADY COMPUTED witness set. A key is superseded only when BOTH
# hold: fm-crew-state proves this task is working on an active no-mistakes
# run-step, and the witness fold shows a later progress line stating that same
# key, so the record provably predates the crew moving past it. A key raised
# mid-run, or one followed only by keyless or other-key progress lines, is
# still in the witness set and stays open and answerable. Do not use a pane
# verdict here: rendered terminal activity can prove work is in progress for
# wake triage, but cannot close a captain decision. A missing, unreadable, or
# malformed current-state line fails open to the durable set. This is the ONE
# lifecycle rule every consumer shares; the two callers below differ only in
# how they obtained the witness set.
_fm_open_decisions_keep_witnessed() {  # <open-set> <witness-set> <current-state-line>
  local open=$1 witnessed=$2 current=$3 line
  [ -n "$open" ] || return 0
  case "$current" in
    'state: working · source: run-step'*) ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _fm_open_set_has "$witnessed" "${line%%$'\t'*}" || continue
    printf '%s\n' "$line"
  done <<EOF
$open
EOF
}

# Whole-file counterpart for the one-shot callers (fm-send, fm-afk-return, the
# fleet snapshot), which have already folded the whole log for their durable
# set and so pay the same order of cost for the witness fold. The per-drain
# path does NOT come through here: it carries its witness set in the same
# cursor as its durable set (status_open_decisions_incremental). A witness
# re-read failure is reported on stderr and fails open to the durable set,
# rather than letting an empty witness set drop every key.
_fm_open_decisions_reconcile_active_run() {  # <status-file> <open-set> <current-state-line>
  local f=$1 open=$2 current=$3 witnessed
  [ -n "$open" ] || return 0
  case "$current" in
    'state: working · source: run-step'*) ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  if ! witnessed=$(_fm_open_decisions_with_keyed_progress "$f"); then
    echo "warning: could not re-read $f to reconcile its open decisions with the active run; keeping every durable key open" >&2
    printf '%s' "$open"
    return 0
  fi
  _fm_open_decisions_keep_witnessed "$open" "$witnessed" "$current"
}

# The keys of a durable open set that the current answerability verdict has
# removed, in the same "<key>\t<verb>\t<note>" shape, so a consumer can name
# active-run supersession as the real reason a durably recorded key is not
# answerable instead of mislabeling it closed or mistyped.
status_open_decisions_superseded() {  # <durable-open-set> <current-open-set>
  local durable=$1 current=$2 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _fm_open_set_has "$current" "${line%%$'\t'*}" && continue
    printf '%s\n' "$line"
  done <<EOF
$durable
EOF
}

# Current answerability verdict for one task's keyed status decisions.
# The durable event fold above remains the source of every key and continues to
# drive the incremental cursor; _fm_open_decisions_reconcile_active_run is the
# one lifecycle rule both consumers share. A caller that already holds the
# task's current-state line (status_task_run_state) passes it as the third
# argument so the verdict and its explanation come from one read, and one that
# already folded the durable set passes it as the fourth so the log is not
# folded again.
status_open_decisions_for_task() {  # <task-id> <status-file> [<current-state-line>] [<durable-open-set>]
  local task=$1 f=$2 open current
  if [ $# -ge 4 ]; then open=$4; else open=$(status_open_decisions "$f"); fi
  [ -n "$open" ] || return 0
  if [ $# -ge 3 ]; then current=$3; else current=$(status_task_run_state "$task" "$f"); fi
  _fm_open_decisions_reconcile_active_run "$f" "$open" "$current"
}

# 0 when a COMPLETED single-owner task's keyed records are retired for the
# surfaces that ask "what is still pending", rather than "which key can still
# be answered". A scout or ship task delivers one deliverable - its report or
# its PR - so once it is done/failed its stale, never-keyed-resolved records
# surface as a report POINTER, not as a reopened pending decision. A secondmate
# is persistent and multiplexes many concerns onto one stream, so a terminal
# event on one concern must never retire another concern's key. This is the ONE
# statement of that rule: bin/fm-fleet-snapshot.sh reaches it through
# status_open_decisions_for_triage below with the crew's CURRENT state, and
# bin/fm-captain-hold.sh reaches it directly with the status log's LAST event
# verb, which is the only lifecycle signal that surface reads.
# Deliberately NOT part of the answerability verdict: fm-send's --resolve-key
# and the fleet-wide OPEN DECISIONS fold must keep a durably open key
# answerable after its task finishes, so only active-run supersession removes a
# key there.
status_open_decisions_retired_by_completion() {  # <kind> <state-or-verb>
  case "${1:-ship}" in secondmate) return 1 ;; esac
  case "$2" in
    done|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# Open-decision set for a fleet TRIAGE surface (bin/fm-fleet-snapshot.sh's
# hints.open_decisions), over the same durable fold and the same shared per-key
# reconciliation the answerability verdict uses. Callers pass the crew's
# already-read current-state line ("state: <s> · source: <src> · <detail>") so
# this makes no reader call of its own.
#
# Triage asks a DIFFERENT question from answerability - "is this crew still
# waiting on me right now", not "can this key still be answered" - so it does
# NOT share the per-key active-run reconciliation. It applies two wholesale
# rules of its own instead, and this is the one place they are stated:
#   - the completion rule above retires a finished single-owner task's records;
#     and
#   - a live ACTIVITY read (an authoritative run-step, or a busy pane) that is
#     neither parked nor blocked retires the whole non-secondmate set, so a crew
#     that resumed past a gate is not still triaged as parked.
# Between them those two rules already cover every state in which the
# answerability verdict would supersede anything (it fires only on
# `working · run-step`, which bin/fm-crew-state.sh emits for a ship task only,
# and the activity rule has retired that whole set first), so anything reaching
# the end of this function keeps its durable set verbatim.
# The activity rule is wholesale and pane-trusting where the answerability
# verdict is per-key and refuses pane evidence outright, so the two can still
# disagree for a busy-pane crew. That gap is deliberate and separately tested
# (a stale decision under a busy pane must not keep triage noisy); narrowing
# triage to the answerability verdict is a product decision, not a refactor.
status_open_decisions_for_triage() {  # <task-id> <status-file> <kind> <current-state-line>
  local f=$2 kind=$3 current=$4 open state source
  open=$(status_open_decisions "$f")
  [ -n "$open" ] || return 0
  state=${current#state: }
  state=${state%% *}
  source=none
  case "$current" in
    *'source: '*) source=${current#*source: }; source=${source%% *} ;;
  esac
  status_open_decisions_retired_by_completion "$kind" "$state" && return 0
  if [ "${kind:-ship}" != secondmate ] \
    && { [ "$source" = run-step ] || [ "$source" = pane ]; } \
    && [ "$state" != parked ] && [ "$state" != blocked ]; then
    return 0
  fi
  printf '%s' "$open"
}

# Fleet-wide wrapper around status_open_decisions: scans every task's status
# log under <state> and prefixes each still-open decision with its owning task
# id, so a per-wake or per-session surface can print the consolidated open set
# without re-walking the fold itself. A thin directory scan only - the fold
# above remains the ONE place the open/resolved semantics are decided. Prints
# one "<task>\t<key>\t<verb>\t<note>" line per open decision, in glob (task id)
# order; prints nothing when none are open.
scan_open_decisions() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions_for_task "$task" "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

# --- incremental (cursor-backed) open-decisions fold ------------------------
#
# status_open_decisions above re-reads and re-folds a status file's ENTIRE
# lifetime on every call, so its cost grows with total log size. A per-drain
# fleet-wide scan using that whole-file function would pay that cost for every
# task on every wake, which grows unbounded as tasks run longer and accumulate
# status history. status_open_decisions_incremental and scan_open_decisions_incremental
# below are the bounded-cost siblings used for that per-drain path: each call
# reads only the bytes appended to a status file since its own last call (a
# persisted per-file byte cursor) and folds just those new lines into a
# persisted running open-set, via the exact same _fm_decision_fold_line rule
# status_open_decisions uses - so the two strategies can never disagree on what
# is open. Cost is bounded by NEW appends since the last drain, not by the
# status file's total lifetime size.
#
# Correctness invariant (unchanged from the whole-file fold): an open decision
# is dropped ONLY by an explicit resolved/captain-held line for its exact key,
# never by cursor advancement, age, or being buried under later appends - the
# persisted open-set carries every still-open key forward across calls
# regardless of how much new unrelated log content has since been folded in.
#
# The cursor format is `version`, `offset`, `ident`, `witness=<line-count>`,
# that many witness-set lines, then the folded durable open set.
# The witness set is the same fold with one extra transition - a progress line
# stating a key drops that key - so the active-run lifecycle reconciliation is
# answered from carried state instead of a whole-log re-read on every drain.
# Both sets advance over the same bytes in one pass and are written together,
# so they can never disagree about how far they have consumed.
# FM_OPEN_DECISIONS_FOLD_VERSION must be bumped whenever
# _fm_decision_fold_line semantics change, so persisted state from an older
# interpretation is discarded and rebuilt from byte 0.
#
# Cursor invalidation is deliberately minimal, matching how status files are
# ACTUALLY used in this repo: every one is created once (`>`) and only ever
# appended to (`>>`) - never replaced, renamed, or rewritten in place. So the
# ways a cursor can go stale are a fold-version mismatch, a shrink (truncated),
# or the file at this path being a different file than before
# (replaced/rotated/recreated), which a changed device+inode makes an O(1) check
# via a single `stat` call - no content hashing, no re-reading the consumed
# prefix. Any signal falls back to a full re-fold of the whole current file from
# byte 0 - byte for byte what status_open_decisions itself would compute - and
# rewrites the cursor from that clean baseline. A same-inode, same-size,
# in-place byte edit is NOT detected; that is a deliberately accepted gap
# because no code path in this repo ever does that to a status file.
#
# The other real failure mode is OUR OWN read failing (a stat/wc/tail I/O
# error), not a malformed writer: every such read here is checked, and on
# failure this reports the already-trusted persisted set unchanged rather than
# risking a silent invalidation that would wipe it - never a bare "empty" as if
# nothing were open.
#
# Not a pure status-file read: this writes/rewrites the sibling cursor file as a
# side effect (state/.<task>.open-decisions-cursor), the library's second
# documented exception to the pure-read rule after crew_absorb_class. The write
# is atomic (temp file + rename), so a crash between calls leaves either the
# prior cursor or the new one, never a partial one. bin/fm-wake-drain.sh calls
# this only after releasing the wake-queue lock, so a hypothetical race between
# two overlapping drains can at worst redo a little folding work twice - never
# drop an open decision - because a losing writer's offset can only ever be
# equal to or behind an already-recorded byte position, and the next call
# re-derives from whatever offset actually landed on disk.
_fm_open_decisions_cursor_path() {  # <status-file>
  local f=$1 dir base
  dir=$(dirname "$f")
  base=$(basename "$f")
  printf '%s/.%s.open-decisions-cursor' "$dir" "${base%.status}"
}

FM_OPEN_DECISIONS_FOLD_VERSION=5

# Portable device:inode identity for the rotation/recreation check below.
_fm_open_decisions_file_ident() {  # <file> -> "dev:inode", empty on I/O failure
  local f=$1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null
  fi
}

_fm_status_file_size() {  # <status-file>
  local f=$1
  if [ -n "${FM_STATUS_SIZE_READER:-}" ]; then
    "$FM_STATUS_SIZE_READER" "$f"
    return
  fi
  LC_ALL=C wc -c < "$f" 2>/dev/null
}

_fm_status_read_span() {  # <status-file> <start-offset> <byte-length>
  local f=$1 start=$2 length=$3
  if [ -n "${FM_STATUS_SPAN_READER:-}" ]; then
    "$FM_STATUS_SPAN_READER" "$f" "$start" "$length"
    return
  fi
  perl -MFcntl=:DEFAULT -e '
    my ($path, $start, $length) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    sysseek($file, $start, 0) == $start or exit 1;
    while ($length > 0) {
      my $want = $length > 65536 ? 65536 : $length;
      my $read = sysread($file, my $chunk, $want);
      defined($read) && $read > 0 or exit 1;
      print $chunk or exit 1;
      $length -= $read;
    }
  ' "$f" "$start" "$length"
}

# Publish one incremental fold's two results. The durable open set is printed
# so every existing caller keeps working unchanged; both sets are also assigned
# to globals, because a caller that needs the witness set cannot read a second
# value out of a command substitution. Callers that want the witness set call
# the fold DIRECTLY (not inside `$(...)`) and then read these.
FM_OPEN_DECISIONS_OPEN=''
FM_OPEN_DECISIONS_WITNESSED=''
_fm_open_decisions_emit() {  # <open-set> <witness-set>
  FM_OPEN_DECISIONS_OPEN=$1
  FM_OPEN_DECISIONS_WITNESSED=$2
  printf '%s' "$1"
}

# A status log this fold can SEE but cannot READ. The cursor deliberately stays
# where it is - folding a partial read would be worse than folding nothing - so
# the appends behind the failure are not folded yet, and a decision opened in
# them is not yet known. Everything about that state must therefore
# over-report, never under-report: the witness set is published EQUAL to the
# durable set, so no key can be reported as run-superseded on evidence this
# call could not read, and the failure is announced on stderr rather than being
# indistinguishable from a quiet fleet. The nonzero return is part of the
# contract: a caller must not treat a frozen fold as a successful one.
FM_OPEN_DECISIONS_READ_FAILED=0
_fm_open_decisions_read_failed() {  # <status-file> <carried-open-set>
  FM_OPEN_DECISIONS_READ_FAILED=1
  echo "warning: could not read $1 to fold its open decisions; its cursor stays where it is and every durable key is kept open" >&2
  _fm_open_decisions_emit "$2" "$2"
  return 1
}

status_open_decisions_incremental() {  # <status-file> [<captured-end-offset>] [peek]
  local f=$1 captured_end=${2:-} mode=${3:-} cf offset ident open='' witness=''
  local trusted_open='' trusted_witness='' cursor_data rest header wcount i=0
  local version='' size actual_size cur_ident resolve held chunk_file chunk_size line cursor_dirty=0
  local target_cursor witness_count
  FM_OPEN_DECISIONS_OPEN=''
  FM_OPEN_DECISIONS_WITNESSED=''
  FM_OPEN_DECISIONS_READ_FAILED=0
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  cf=$(_fm_open_decisions_cursor_path "$f")
  offset=0
  ident=''
  if [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ]; then
    cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null) || cursor_data=''
  fi
  # Cursor body, in order: version, offset, ident, witness=<line-count>, that
  # many witness-set lines, then the durable open set. Both sets are folded
  # over the SAME bytes in one pass below and persisted together, so they can
  # never disagree about how far they have consumed. Any malformation drops
  # straight through to a full re-fold from byte 0.
  rest=${cursor_data:-}
  while [ -n "$rest" ]; do
    header=${rest%%$'\n'*}
    case "$header" in
      "version=$FM_OPEN_DECISIONS_FOLD_VERSION") ;;
      *) break ;;
    esac
    case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) break ;; esac
    header=${rest%%$'\n'*}
    case "$header" in offset=*) offset=${header#offset=} ;; *) offset=0; break ;; esac
    case "$offset" in ''|*[!0-9]*) offset=0; break ;; esac
    case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) offset=0; break ;; esac
    header=${rest%%$'\n'*}
    case "$header" in ident=*) ident=${header#ident=} ;; *) offset=0; break ;; esac
    [ -n "$ident" ] || { offset=0; break; }
    case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) offset=0; ident=''; break ;; esac
    header=${rest%%$'\n'*}
    case "$header" in witness=*) wcount=${header#witness=} ;; *) offset=0; ident=''; break ;; esac
    case "$wcount" in ''|*[!0-9]*) offset=0; ident=''; break ;; esac
    case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) rest='' ;; esac
    while [ "$i" -lt "$wcount" ]; do
      [ -n "$rest" ] || { offset=0; ident=''; witness=''; break 2; }
      witness="${witness}${rest%%$'\n'*}"$'\n'
      case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) rest='' ;; esac
      i=$((i + 1))
    done
    version=$FM_OPEN_DECISIONS_FOLD_VERSION
    open=$rest
    trusted_open=$open
    trusted_witness=$witness
    break
  done
  if [ -z "$version" ]; then
    offset=0
    ident=''
    open=''
    witness=''
  fi

  # A stat/size-read failure is a genuine I/O error, not "the file is empty" -
  # report the already-trusted persisted sets unchanged rather than risking a
  # silent invalidation that would wipe them.
  cur_ident=$(_fm_open_decisions_file_ident "$f") \
    || { _fm_open_decisions_emit "$trusted_open" "$trusted_witness"; return 0; }
  [ -n "$cur_ident" ] || { _fm_open_decisions_emit "$trusted_open" "$trusted_witness"; return 0; }
  actual_size=$(_fm_status_file_size "$f") \
    || { _fm_open_decisions_read_failed "$f" "$trusted_open"; return 1; }
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in
    ''|*[!0-9]*) _fm_open_decisions_read_failed "$f" "$trusted_open"; return 1 ;;
  esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in
      ''|*[!0-9]*) _fm_open_decisions_emit "$trusted_open" "$trusted_witness"; return 0 ;;
    esac
    [ "$captured_end" -le "$actual_size" ] \
      || { _fm_open_decisions_emit "$trusted_open" "$trusted_witness"; return 0; }
    size=$captured_end
  else
    size=$actual_size
  fi

  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$actual_size" ]; then
    offset=0
    open=''
    witness=''
    trusted_open=''
    trusted_witness=''
    cursor_dirty=1
  fi

  if [ "$offset" -lt "$size" ]; then
    chunk_file="$cf.read.$$"
    _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
      || { rm -f "$chunk_file"; _fm_open_decisions_read_failed "$f" "$trusted_open"; return 1; }
    chunk_size=$(LC_ALL=C wc -c < "$chunk_file" 2>/dev/null) \
      || { rm -f "$chunk_file"; _fm_open_decisions_read_failed "$f" "$trusted_open"; return 1; }
    chunk_size=${chunk_size//[[:space:]]/}
    case "$chunk_size" in
      ''|*[!0-9]*)
        rm -f "$chunk_file"; _fm_open_decisions_read_failed "$f" "$trusted_open"; return 1 ;;
    esac
    # Test-only observability seam (off by default, no production behavior
    # change): when set, records exactly how many bytes THIS call folded, so a
    # test can assert the incremental path stays bounded by new appends rather
    # than re-reading the whole file, without relying on timing or source text.
    # BOTH sets fold from this one read, so a bounded count here is a bounded
    # count for the lifecycle reconciliation too.
    [ -n "${FM_OPEN_DECISIONS_READ_PROBE:-}" ] \
      && printf '%s\t%s\n' "$f" "$chunk_size" >> "$FM_OPEN_DECISIONS_READ_PROBE"
    resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
    held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
    while IFS= read -r line || [ -n "$line" ]; do
      witness=$(_fm_decision_witness_fold_line "$witness" "$line" "$resolve" "$held")
      open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
    done < "$chunk_file"
    rm -f "$chunk_file"
    offset=$size
    cursor_dirty=1
  fi
  if [ "$cursor_dirty" -eq 1 ] && [ "$mode" != peek ]; then
    target_cursor="$cf.tmp.$$"
    if [ -n "$witness" ]; then
      case "$witness" in *$'\n') ;; *) witness="${witness}"$'\n' ;; esac
    fi
    witness_count=${witness//[!$'\n']/}
    witness_count=${#witness_count}
    {
      printf 'version=%s\n' "$FM_OPEN_DECISIONS_FOLD_VERSION"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      printf 'witness=%s\n' "$witness_count"
      if [ -n "$witness" ]; then printf '%s' "$witness"; fi
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$target_cursor" || return 1
    mv -f "$target_cursor" "$cf" || return 1
  fi
  _fm_open_decisions_emit "$open" "$witness"
}

# Incremental counterpart to status_open_decisions_for_task. One cursor-backed
# fold advances BOTH the durable set and its witness set over the same new
# bytes, and the shared per-key rule then reconciles them - so this path reads
# only what was appended since the last drain and never re-folds the whole log.
# The supersession itself is still not a durable event: the witness set records
# only that a same-key progress line was seen, so when the run parks the
# current-state gate stops firing and the durable decision surfaces again
# without any synthetic status event.
status_open_decisions_incremental_for_task() {  # <task-id> <status-file> [<captured-end-offset>]
  local task=$1 f=$2 captured_end=${3:-} open witnessed current
  if ! status_open_decisions_incremental "$f" "$captured_end" >/dev/null; then
    [ "$FM_OPEN_DECISIONS_READ_FAILED" = 1 ] || return 1
  fi
  open=$FM_OPEN_DECISIONS_OPEN
  witnessed=$FM_OPEN_DECISIONS_WITNESSED
  [ -n "$open" ] || return 0
  current=$(status_task_run_state "$task" "$f")
  _fm_open_decisions_keep_witnessed "$open" "$witnessed" "$current"
}

# Incremental sibling of scan_open_decisions: same fleet-wide directory walk and
# output shape ("<task>\t<key>\t<verb>\t<note>" per open decision), but folds
# each task's status log through status_open_decisions_incremental instead of
# the whole-file status_open_decisions, so a fleet-wide per-drain scan stays
# bounded by new appends rather than total lifetime log size across every task.
scan_open_decisions_incremental() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions_incremental_for_task "$task" "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

status_presentation_snapshot() {  # <state>
  local state=$1 f task size ident
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    size=$(_fm_status_file_size "$f") || return 1
    size=${size//[[:space:]]/}
    ident=$(_fm_open_decisions_file_ident "$f") || return 1
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$ident" ] || return 1
    printf '%s\t%s\t%s\n' "$task" "$size" "$ident" || return 1
  done
}

status_presentation_cursor_offset() {  # <status-file>
  local f=$1 state task manifest data row_task offset ident extra cur_ident size legacy
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
    data=$(LC_ALL=C command cat "$manifest" 2>/dev/null) || return 1
    offset=
    while IFS=$(printf '\t') read -r row_task ident legacy extra; do
      [ -n "$row_task" ] || continue
      [ -z "$extra" ] || return 1
      case "$legacy" in ''|*[!0-9]*) return 1 ;; esac
      [ -n "$ident" ] || return 1
      if [ "$row_task" = "$task" ]; then
        [ -z "$offset" ] || return 1
        offset=$legacy
        cur_ident=$ident
      fi
    done <<EOF
$data
EOF
    if [ -z "$offset" ]; then
      printf '0'
      return 0
    fi
    ident=$cur_ident
  else
    legacy=$(_fm_open_decisions_cursor_path "$f")
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
      status_open_decisions_cursor_offset "$f"
      return
    fi
    offset=0
    ident=$(_fm_open_decisions_file_ident "$f") || return 1
  fi
  cur_ident=$(_fm_open_decisions_file_ident "$f") || return 1
  size=$(_fm_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size:$offset" in *[!0-9:]*) return 1 ;; esac
  if [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then offset=0; fi
  printf '%s' "$offset"
}

status_retire_presentation_task() {  # <state> <task-id>
  local state=$1 task=$2 lock manifest tmp data row_task ident offset extra rc=0 found=0
  lock="$state/.status-presentation-lock"
  manifest="$state/.status-presentation-cursor"
  tmp="$manifest.tmp.$$"

  # A remote-home teardown can legitimately retire an endpoint ID that has no
  # status log in that home. Do not contend with that home's unrelated status
  # presenter in this no-op case. A concurrent presenter cannot add this task
  # without its status file, so a valid manifest with no matching row is a
  # durable proof that there is nothing to retire.
  if [ ! -e "$state/$task.status" ] && [ ! -L "$state/$task.status" ] \
    && [ ! -e "$state/.$task.open-decisions-cursor" ] \
    && [ ! -L "$state/.$task.open-decisions-cursor" ]; then
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
      return 0
    fi
    if [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] \
      && data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      while IFS=$(printf '\t') read -r row_task ident offset extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset" in ''|*[!0-9]*) rc=1; break ;; esac
        [ "$row_task" != "$task" ] || found=1
      done <<EOF
$data
EOF
      [ "$rc" -ne 0 ] || [ "$found" -ne 0 ] || return 0
      rc=0
    fi
  fi

  fm_lock_acquire_wait "$lock" || return 1
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    if [ ! -f "$manifest" ] || [ ! -r "$manifest" ] || [ -L "$manifest" ]; then
      rc=1
    elif ! data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      rc=1
    elif ! : > "$tmp"; then
      rc=1
    else
      while IFS=$(printf '\t') read -r row_task ident offset extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset" in ''|*[!0-9]*) rc=1; break ;; esac
        if [ "$row_task" != "$task" ]; then
          printf '%s\t%s\t%s\n' "$row_task" "$ident" "$offset" >> "$tmp" \
            || { rc=1; break; }
        fi
      done <<EOF
$data
EOF
      if [ "$rc" -eq 0 ]; then mv -f "$tmp" "$manifest" || rc=1; fi
      [ "$rc" -eq 0 ] || rm -f "$tmp"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$state/$task.status" "$state/.$task.open-decisions-cursor" || rc=1
  fi
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

status_acknowledge_presented_snapshot() {  # <state> <snapshot> [<fully-presented-task-ids>]
  local state=$1 snapshot=$2 fully_presented=${3:-} task endpoint ident f offset lines line safe
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    safe=false
    case "
$fully_presented
" in *$'\n'"$task"$'\n'*) safe=true ;; esac
    if [ "$safe" = false ]; then
      f="$state/$task.status"
      offset=$(status_presentation_cursor_offset "$f") || return 1
      lines=$(status_new_lines_since_cursor "$f" "$endpoint") || return 1
      # Once any informational line in this span is presented fleet-wide, the
      # contiguous cursor may advance through the captured endpoint. Routine
      # lines remain unacknowledged only while they are the sole unread content,
      # preserving delayed signal annotations without replaying a handled note
      # that happened to follow a routine line.
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *[![:space:]]*)
            if status_line_is_unread_surface "$line"; then safe=true; break; fi
            ;;
        esac
      done <<EOF
$lines
EOF
      if [ "$safe" = false ]; then endpoint=$offset; fi
    fi
    printf '%s\t%s\t%s\n' "$task" "$endpoint" "$ident" || return 1
  done <<EOF
$snapshot
EOF
}

status_commit_presentation_snapshot() {  # <state> <snapshot>
  local state=$1 snapshot=$2 task endpoint ident f cur_ident size tmp
  tmp="$state/.status-presentation-cursor.tmp.$$"
  : > "$tmp" || return 1
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    case "$endpoint" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ -n "$ident" ] || { rm -f "$tmp"; return 1; }
    f="$state/$task.status"
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || { rm -f "$tmp"; return 1; }
    cur_ident=$(_fm_open_decisions_file_ident "$f") || { rm -f "$tmp"; return 1; }
    size=$(_fm_status_file_size "$f") || { rm -f "$tmp"; return 1; }
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ "$cur_ident" = "$ident" ] && [ "$endpoint" -le "$size" ] \
      || { rm -f "$tmp"; return 1; }
    printf '%s\t%s\t%s\n' "$task" "$ident" "$endpoint" >> "$tmp" \
      || { rm -f "$tmp"; return 1; }
  done <<EOF
$snapshot
EOF
  mv -f "$tmp" "$state/.status-presentation-cursor" || { rm -f "$tmp"; return 1; }
}

scan_open_decisions_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f open line
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    open=$(status_open_decisions_incremental_for_task "$task" "$f" "$endpoint") || return 1
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done <<EOF
$snapshot
EOF
}

# --- unread status lines since the presentation cursor ----------------------
#
# The drain annotation historically printed only the newest status line, so a
# substantive `note:` answer immediately followed by a routine `note:` (or a
# pending-reply resolution buried under a later unrelated append) never reached
# the supervisor. Those verbs also never enter the OPEN DECISIONS fold, so they
# had no other surfacing path.
# These helpers are the ONE owner of "what is still unread since the last drain
# presentation": one fleet manifest records each status identity and last-
# presented byte offset, and one atomic replacement commits only the contiguous
# status spans that were successfully presented. A quiet fleet scan leaves
# routine working/done bytes unacknowledged so a subsequently published signal
# can still annotate them. A missing manifest row or changed file identity is
# offset 0 for the current file, while malformed or unreadable cursor state
# aborts presentation without advancing any offset. A trusted cursor at EOF
# prints nothing, so already-presented bytes are not replayed as new. Teardown
# retires a task's manifest row with its status file, so reusing a task ID starts
# the replacement log unread at byte 0. Informational `note:` lines and
# reserved-key pending-reply resolutions are the fleet-wide unread surface;
# they are not open decisions and are not persisted in the folded open-set.

# Read the legacy per-task open-decisions cursor used to seed the presentation
# offset before the fleet manifest exists. A fold-version mismatch, identity
# mismatch, or offset past the current size falls back to 0. Never writes unless
# a caller explicitly requests a migration snapshot.
status_open_decisions_cursor_offset() {  # <status-file>
  local f=$1 cf offset=0 ident='' version='' cursor_data first rest open=''
  local offset_line ident_line cur_ident size snapshot_witness witness_line witness_skip
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  cf=$(_fm_open_decisions_cursor_path "$f")
  if [ -e "$cf" ] || [ -L "$cf" ]; then
    [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ] || return 1
    if cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null); then
      first=${cursor_data%%$'\n'*}
      case "$first" in
        version=*)
          version=${first#version=}
          [ "$version" = "$FM_OPEN_DECISIONS_FOLD_VERSION" ] || version=''
          rest=${cursor_data#*$'\n'}
          offset_line=${rest%%$'\n'*}
          case "$offset_line" in
            offset=*) offset=${offset_line#offset=} ;;
            *) offset=0; version='' ;;
          esac
          case "$offset" in
            ''|*[!0-9]*) offset=0; version='' ;;
            *)
              case "$rest" in
                *$'\n'*)
                  rest=${rest#*$'\n'}
                  ident_line=${rest%%$'\n'*}
                  case "$ident_line" in
                    ident=*)
                      ident=${ident_line#ident=}
                      case "$rest" in *$'\n'*) open=${rest#*$'\n'} ;; esac
                      # A current-version cursor carries its witness set ahead
                      # of the durable set; this reader wants only the durable
                      # region, so skip the header and the lines it counts.
                      witness_line=${open%%$'\n'*}
                      case "$witness_line" in
                        witness=*)
                          witness_skip=${witness_line#witness=}
                          case "$witness_skip" in
                            ''|*[!0-9]*) offset=0; version='' ;;
                            *)
                              case "$open" in *$'\n'*) open=${open#*$'\n'} ;; *) open='' ;; esac
                              while [ "$witness_skip" -gt 0 ]; do
                                case "$open" in *$'\n'*) open=${open#*$'\n'} ;; *) open='' ;; esac
                                witness_skip=$((witness_skip - 1))
                              done
                              ;;
                          esac
                          ;;
                        *) offset=0; version='' ;;
                      esac
                      ;;
                    *) offset=0; version='' ;;
                  esac
                  ;;
                *) offset=0; version='' ;;
              esac
              ;;
          esac
          ;;
      esac
    else
      return 1
    fi
  fi
  cur_ident=$(_fm_open_decisions_file_ident "$f") || return 1
  [ -n "$cur_ident" ] || return 1
  size=$(_fm_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    offset=0
    open=''
  fi
  if [ -n "${FM_STATUS_CURSOR_SNAPSHOT_FILE:-}" ]; then
    # This legacy reader knows the durable set only, so the migrated cursor
    # records the witness set as EQUAL to it: nothing witnessed, therefore
    # nothing superseded, which is the fail-open direction. The next fold over
    # new bytes advances both sets normally from there.
    if [ -n "$open" ]; then
      case "$open" in *$'\n') ;; *) open="${open}"$'\n' ;; esac
    fi
    snapshot_witness=${open//[!$'\n']/}
    {
      printf 'version=%s\n' "$FM_OPEN_DECISIONS_FOLD_VERSION"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      printf 'witness=%s\n' "${#snapshot_witness}"
      if [ -n "$open" ]; then printf '%s%s' "$open" "$open"; fi
    } > "$FM_STATUS_CURSOR_SNAPSHOT_FILE" || return 1
  fi
  printf '%s' "$offset"
}

# Print every non-blank status line whose bytes begin at or after the persisted
# presentation offset. Does not write the cursor. A missing manifest row or
# changed status identity reads the current file from offset 0; malformed or
# unreadable cursor state fails the scan. Symlinks and unreadable status files
# print nothing.
status_new_lines_since_cursor() {  # <status-file> [<captured-end-offset>]
  local f=$1 captured_end=${2:-} cf offset size actual_size chunk_file line rc=0
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  cf=$(_fm_open_decisions_cursor_path "$f")
  chunk_file="$cf.unread.$$"
  offset=$(status_presentation_cursor_offset "$f") || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  actual_size=$(_fm_status_file_size "$f") || return 1
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in ''|*[!0-9]*) return 1 ;; esac
    [ "$captured_end" -le "$actual_size" ] || return 1
    size=$captured_end
  else
    size=$actual_size
  fi
  [ "$offset" -lt "$size" ] || return 0
  _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
    || { rm -f "$chunk_file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *[![:space:]]*) printf '%s\n' "$line" || { rc=1; break; } ;;
    esac
  done < "$chunk_file"
  rm -f "$chunk_file"
  return "$rc"
}

# 0 when a status line is an informational `note:` or a reserved-key
# pending-reply resolution. Those lines never fold into OPEN DECISIONS, so the
# drain's unread-status surface is their only guaranteed presentation.
status_line_is_unread_surface() {  # <status-line>
  local line=$1 verb key note resolve held prefix
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = note ] && return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    "$resolve"|"$held") ;;
    *) return 1 ;;
  esac
  key=$(_fm_decision_key "$line") || return 1
  note=$(status_line_note "$line")
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        _fm_decision_key_transition_allowed "$key" "$note"
        return
        ;;
    esac
  done
  return 1
}

# Fleet-wide unread informational lines: one "<task>\t<status-line>" row per
# still-unread `note:` or pending-reply resolution, in glob (task id) order.
# Prints nothing when none are unread. Directory scan rejects status symlinks
# the same way scan_open_decisions does.
scan_unread_surface_lines() {  # <state>
  local state=$1 f task lines line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    lines=$(status_new_lines_since_cursor "$f") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done
  return 0
}

scan_unread_surface_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f lines line
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    lines=$(status_new_lines_since_cursor "$f" "$endpoint") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done <<EOF
$snapshot
EOF
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# Directories excluded from the worktree write probe below, and the depth it walks.
# The excluded set is everything a supervisor read or a package manager can write
# without the crew doing any work - .git first, so firstmate's own read-only git
# commands against the worktree can never make the probe self-fulfilling - plus the
# large generated trees that would make the walk expensive. Both are overridable so
# a home with an unusual layout can widen or narrow the probe. The list is a skip
# list, so clearing it skips nothing and widens the walk to the whole depth-bounded
# tree; it never disables the probe, which would quietly cost the wedge detector a
# liveness input on a home that meant to widen it. Defaulted with the plain form so
# an explicitly empty value stays empty: clearing the knob in the environment is the
# documented way to ask for that wider walk, and treating empty as unset would hand
# the default skip list back to exactly the home that asked for more coverage.
FM_WORKTREE_WRITE_PRUNE=${FM_WORKTREE_WRITE_PRUNE-'.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'}
FM_WORKTREE_WRITE_MAXDEPTH=${FM_WORKTREE_WRITE_MAXDEPTH:-6}

# Wall-clock seconds the probe's single walk may take. The walk runs synchronously
# inside the caller's poll loop at the exact moment an escalation would otherwise
# fire, and -xdev keeps it out of a nested mount but cannot help when the worktree
# root ITSELF sits on a hung network or container mount; unbounded, such a walk
# would wedge the very supervisor that exists to notice a wedge, stalling its
# heartbeat instead of escalating. Hitting the bound is a negative outcome like
# every other: it reads as no evidence, so the caller's escalation schedule is
# untouched and a stall that writes nothing still escalates on the existing
# schedule. A value that is not a positive integer is not a bound at all (`timeout
# 0` and the perl fallback's `alarm 0` both disable the deadline), so the default
# applies instead; the check lives at the point of use so an in-process override
# gets it too.
FM_WORKTREE_WRITE_TIMEOUT=${FM_WORKTREE_WRITE_TIMEOUT:-10}

# 0 when some regular file under <id>'s recorded worktree is newer than
# <anchor-file>: positive evidence the crew is still producing work even though its
# rendered pane has gone quiet. This is the third liveness input the wedge detector
# has, after pane quietness and the run step, and it exists because neither of
# those can see a crew that is writing source, then tests, then documentation
# behind a static pane - the 2026-08-14 case of eight consecutive possible-wedge
# escalations against a crew that was demonstrably working the whole time.
#
# 1 for every other outcome, including an id with no recorded worktree, a worktree
# that is gone, a missing anchor, and a walk that fails or finds nothing. Absence of
# evidence therefore always leaves the caller's existing escalation schedule
# untouched, so a crew that writes nothing still escalates exactly as before.
#
# A kind=secondmate task records a provisioned firstmate home, not a code tree, and
# such a home runs its OWN supervision inside it: its state/ directory churns a
# watcher beacon, pane hashes, and heartbeats whether or not the mate is producing
# anything, so a walk there would report liveness for a mate that has done nothing.
# Those homes are excluded outright rather than by pruning "state", which would also
# hide a legitimate source directory of that name in an ordinary worktree. The
# exclusion is a negative outcome like any other, so an unproductive mate keeps
# escalating on the caller's unchanged schedule.
#
# The anchor is the caller's own idle-window timer file, whose mtime already marks
# when the quiet window opened, so `-newer` needs no clock arithmetic, no temp
# file, and no portable mtime-setting. Not a pure status-file read (see the header):
# one pruned, depth-bounded, wall-clock-bounded walk per call, which callers must
# reach only when they are otherwise about to escalate, never on every poll. A walk
# that outlives FM_WORKTREE_WRITE_TIMEOUT is killed and reported as no evidence, so
# a hung mount costs the escalation nothing but the bound. -xdev holds that walk to the
# worktree's own filesystem rather than descending into a nested network or container
# mount, so a write that lands only under such a mount is one more negative outcome.
crew_worktree_written_since() {  # <id> <state> <anchor-file>
  local id=$1 state=$2 anchor=$3 wt kind name hit bound
  local -a names=() prune=()
  [ -n "$id" ] || return 1
  [ -f "$anchor" ] || return 1
  wt=$(grep '^worktree=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  kind=$(grep '^kind=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$kind" != secondmate ] || return 1
  if [ -e "$wt/.fm-secondmate-home" ] || [ -L "$wt/.fm-secondmate-home" ]; then
    return 1
  fi
  read -r -a names <<< "$FM_WORKTREE_WRITE_PRUNE"
  for name in ${names[@]+"${names[@]}"}; do
    [ "${#prune[@]}" -eq 0 ] || prune+=( -o )
    prune+=( -name "$name" )
  done
  bound=$FM_WORKTREE_WRITE_TIMEOUT
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  if [ "${#prune[@]}" -gt 0 ]; then
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      \( "${prune[@]}" \) -prune -o -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  else
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  fi
  [ -n "$hit" ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
# A kind=secondmate task's .status signal is never absorbable here regardless of
# busy evidence: that stream is the mate's routed-reply channel, so every append
# is parent-directed content the supervisor must read (a routed reply, a newly
# raised decision, a mirrored remote line), and a busy mate agent makes its note
# more current, not less deliverable. Scoped to .status files - a mate's bare
# turn-ended ping still uses the ordinary provably-working absorb.
signal_crew_provably_working() {  # <file> ...
  local f base dir task seen=""
  for f in "$@"; do
    base=${f##*/}
    dir=${f%/*}
    [ "$dir" != "$f" ] || dir=.
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case "$base" in
      *.status)
        if [ "$(grep '^kind=' "$dir/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2-)" = secondmate ]; then
          return 1
        fi
        ;;
    esac
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
