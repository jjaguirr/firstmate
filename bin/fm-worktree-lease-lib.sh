#!/usr/bin/env bash
# fm-worktree-lease-lib.sh - durable Treehouse worktree ownership for ordinary
# Firstmate tasks.
#
# A ship or scout worktree is acquired with `treehouse get --lease`, then its
# immutable lease id, holder, and owning firstmate home are published with the
# task metadata.  Recovery verifies all three against Treehouse's live status
# inventory before it is allowed to reuse a worktree after its endpoint is
# gone.  A path, a branch, or a task label alone never establishes ownership.
#
# This library only owns the Treehouse lease proof and acquisition mechanics.
# bin/fm-spawn.sh owns endpoint creation and metadata publication,
# bin/fm-control.sh owns the recovery transaction, and bin/fm-teardown.sh owns
# the matched return.

fm_worktree_lease_canonical_dir() {  # <directory>
  local dir=${1:-}
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P
}

fm_worktree_lease_holder() {  # <canonical-home> <task-id>
  local home=${1:-} id=${2:-} digest
  [ -n "$home" ] && [ -n "$id" ] || return 1
  digest=$(printf '%s' "$home" | cksum 2>/dev/null | awk '{print $1}') || return 1
  case "$digest" in ''|*[!0-9]*) return 1 ;; esac
  printf 'firstmate-%s-%s' "$digest" "$id"
}

fm_worktree_lease_status_exact() {  # <project> <worktree> <lease-id> <holder>
  local project=${1:-} worktree=${2:-} lease_id=${3:-} holder=${4:-}
  local project_real worktree_real status matches
  project_real=$(fm_worktree_lease_canonical_dir "$project") || return 1
  worktree_real=$(fm_worktree_lease_canonical_dir "$worktree") || return 1
  [ -n "$lease_id" ] && [ -n "$holder" ] || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  status=$(cd "$project_real" && treehouse status --json 2>/dev/null) || return 1
  matches=$(printf '%s' "$status" | jq -r --arg path "$worktree_real" \
    '[.[]? | select(.path == $path)] | length' 2>/dev/null) || return 1
  [ "$matches" = 1 ] || return 1
  printf '%s' "$status" | jq -e --arg path "$worktree_real" \
    --arg lease_id "$lease_id" --arg holder "$holder" '
      [.[]? | select(.path == $path)]
      | length == 1
        and .[0].status == "leased"
        and .[0].lease_id == $lease_id
        and .[0].lease_holder == $holder
    ' >/dev/null 2>&1
}

# fm_worktree_lease_pool_entry_unheld: true (0) only when Treehouse's live
# status inventory parses and positively shows <worktree> is not held: either
# no entry lists that path, or exactly one entry lists it with a status that
# is a non-empty string other than "leased". An unreadable or unparseable
# inventory, a missing tool, duplicate entries, or a missing status field
# returns 1, so "free" is never inferred from a failed read.
fm_worktree_lease_pool_entry_unheld() {  # <project> <worktree>
  local project=${1:-} worktree=${2:-} project_real worktree_real status verdict
  project_real=$(fm_worktree_lease_canonical_dir "$project") || return 1
  worktree_real=$(fm_worktree_lease_canonical_dir "$worktree") || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  status=$(cd "$project_real" && treehouse status --json 2>/dev/null) || return 1
  verdict=$(printf '%s' "$status" | jq -r --arg path "$worktree_real" '
    if type != "array" then error("not an array") else
      [.[] | select(.path == $path)]
      | if length == 0 then "absent"
        elif length == 1
          and ((.[0].status | type) == "string")
          and ((.[0].status | length) > 0)
          and (.[0].status != "leased") then "unleased"
        else "held" end
    end' 2>/dev/null) || return 1
  case "$verdict" in
    absent|unleased) return 0 ;;
    *) return 1 ;;
  esac
}

fm_worktree_lease_read_meta() {  # <meta> <home> <task-id>
  local meta=${1:-} home=${2:-} id=${3:-} home_real count
  FM_WORKTREE_LEASE_ID=
  FM_WORKTREE_LEASE_HOLDER=
  FM_WORKTREE_LEASE_HOME=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  home_real=$(fm_worktree_lease_canonical_dir "$home") || return 1
  for key in worktree_lease_id worktree_lease_holder worktree_lease_home; do
    count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
    [ "$count" = 1 ] || return 1
  done
  FM_WORKTREE_LEASE_ID=$(grep '^worktree_lease_id=' "$meta" | cut -d= -f2-)
  FM_WORKTREE_LEASE_HOLDER=$(grep '^worktree_lease_holder=' "$meta" | cut -d= -f2-)
  FM_WORKTREE_LEASE_HOME=$(grep '^worktree_lease_home=' "$meta" | cut -d= -f2-)
  [ -n "$FM_WORKTREE_LEASE_ID" ] && [ -n "$FM_WORKTREE_LEASE_HOLDER" ] \
    && [ -n "$FM_WORKTREE_LEASE_HOME" ] || return 1
  [ "$FM_WORKTREE_LEASE_HOME" = "$home_real" ] || return 1
  [ "$FM_WORKTREE_LEASE_HOLDER" = "$(fm_worktree_lease_holder "$home_real" "$id")" ] || return 1
}

fm_worktree_lease_verify_meta() {  # <meta> <project> <worktree> <home> <task-id>
  local meta=${1:-} project=${2:-} worktree=${3:-} home=${4:-} id=${5:-}
  fm_worktree_lease_read_meta "$meta" "$home" "$id" || return 1
  fm_worktree_lease_status_exact "$project" "$worktree" \
    "$FM_WORKTREE_LEASE_ID" "$FM_WORKTREE_LEASE_HOLDER"
}

# fm_worktree_lease_no_process_cwd: prove no process remains rooted in a
# worktree before a missing endpoint may receive a replacement. A missing pane
# is not enough on its own: a detached agent could still be running from that
# copy. The conservative result treats any process under the worktree as a
# conflict, not merely a process whose name looks like a known harness.
#
# Returns 0 when no process is found, 1 when one or more are found, and 2 when
# the host cannot be scanned safely. FM_WORKTREE_LEASE_LIVE_PIDS contains the
# matching process ids on a 1 result. lsof is the portable primary probe; the
# Linux /proc fallback keeps hermetic Linux tests and lean hosts fail-closed.
fm_worktree_lease_no_process_cwd() {  # <worktree>
  local worktree=${1:-} real out line pid path proc cwd
  FM_WORKTREE_LEASE_LIVE_PIDS=
  real=$(fm_worktree_lease_canonical_dir "$worktree") || return 2
  if command -v lsof >/dev/null 2>&1; then
    out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 2
    pid=
    while IFS= read -r line; do
      case "$line" in
        p*)
          pid=${line#p}
          case "$pid" in ''|*[!0-9]*) return 2 ;; esac
          ;;
        fcwd) [ -n "$pid" ] || return 2 ;;
        n*)
          [ -n "$pid" ] || return 2
          path=${line#n}
          case "$path" in
            "$real"|"$real"/*)
              [ "$pid" = "$$" ] || FM_WORKTREE_LEASE_LIVE_PIDS="${FM_WORKTREE_LEASE_LIVE_PIDS}${FM_WORKTREE_LEASE_LIVE_PIDS:+ }$pid"
              ;;
          esac
          ;;
        '') ;;
        *) return 2 ;;
      esac
    done <<EOF
$out
EOF
  elif [ -d /proc ]; then
    for proc in /proc/[0-9]*; do
      [ -d "$proc" ] || continue
      pid=${proc##*/}
      [ "$pid" = "$$" ] && continue
      cwd=$(readlink -f "$proc/cwd" 2>/dev/null || true)
      case "$cwd" in
        "$real"|"$real"/*)
          FM_WORKTREE_LEASE_LIVE_PIDS="${FM_WORKTREE_LEASE_LIVE_PIDS}${FM_WORKTREE_LEASE_LIVE_PIDS:+ }$pid"
          ;;
      esac
    done
  else
    return 2
  fi
  [ -z "$FM_WORKTREE_LEASE_LIVE_PIDS" ]
}

fm_worktree_lease_acquire() {  # <project> <home> <task-id>
  local project=${1:-} home=${2:-} id=${3:-} project_real home_real holder record
  FM_WORKTREE_LEASE_WORKTREE=
  FM_WORKTREE_LEASE_ID=
  FM_WORKTREE_LEASE_HOLDER=
  FM_WORKTREE_LEASE_HOME=
  project_real=$(fm_worktree_lease_canonical_dir "$project") || return 1
  home_real=$(fm_worktree_lease_canonical_dir "$home") || return 1
  holder=$(fm_worktree_lease_holder "$home_real" "$id") || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  record=$(cd "$project_real" && treehouse get --lease --lease-holder "$holder" --json 2>/dev/null) || return 1
  FM_WORKTREE_LEASE_WORKTREE=$(printf '%s' "$record" | jq -r '.path // empty' 2>/dev/null)
  FM_WORKTREE_LEASE_ID=$(printf '%s' "$record" | jq -r '.lease_id // empty' 2>/dev/null)
  FM_WORKTREE_LEASE_HOLDER=$(printf '%s' "$record" | jq -r '.lease_holder // empty' 2>/dev/null)
  FM_WORKTREE_LEASE_HOME=$home_real
  [ -n "$FM_WORKTREE_LEASE_WORKTREE" ] && [ -n "$FM_WORKTREE_LEASE_ID" ] \
    && [ "$FM_WORKTREE_LEASE_HOLDER" = "$holder" ] || return 1
  FM_WORKTREE_LEASE_WORKTREE=$(fm_worktree_lease_canonical_dir "$FM_WORKTREE_LEASE_WORKTREE") || return 1
  fm_worktree_lease_status_exact "$project_real" "$FM_WORKTREE_LEASE_WORKTREE" \
    "$FM_WORKTREE_LEASE_ID" "$FM_WORKTREE_LEASE_HOLDER"
}

fm_worktree_lease_return_exact() {  # <project> <worktree> <lease-id> <holder>
  local project=${1:-} worktree=${2:-} lease_id=${3:-} holder=${4:-} project_real
  project_real=$(fm_worktree_lease_canonical_dir "$project") || return 1
  [ -n "$worktree" ] && [ -n "$lease_id" ] && [ -n "$holder" ] || return 1
  cd "$project_real" && treehouse return --force "$worktree" \
    --if-lease-id "$lease_id" --if-lease-holder "$holder"
}
