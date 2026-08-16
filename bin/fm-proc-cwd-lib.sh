#!/usr/bin/env bash
# Shared ownership of one question: which processes are still working inside
# this directory?
#
# A process is attributed to a task by its CURRENT WORKING DIRECTORY being at
# or under a root that belongs to that task - its worktree, its task tmpdir.
# bin/fm-teardown.sh asks in order to reap what a closed backend pane left
# behind. bin/fm-spawn.sh's resume mode asks for the opposite reason: not "what
# should I kill?" but "can I positively confirm nothing survives before I create
# a worker?" - and that second caller is why this is a library. Two spellings of
# "is anything still running in this worktree?" could disagree, and the one that
# disagrees in the fail-open direction starts a second worker inside a worktree
# a live one is still mutating.
#
# Both functions fail CLOSED: a non-zero return means the scan could not
# establish a safe result, never that nothing was found. That distinction is the
# whole point. An empty result and an unavailable scan are indistinguishable to
# a caller that collapses them, and only one of the two is proof of absence.
#
# This library installs no traps and never exits, so it is safe to source into a
# larger script that owns its own cleanup. Callers report in their own
# vocabulary; nothing here writes to stderr.
#
# Process IDENTITY is deliberately not here: bin/fm-wake-lib.sh already owns
# fm_pid_identity, which pins a pid to its start time so a recycled pid cannot
# impersonate the original.

# Pids of every process whose CURRENT WORKING DIRECTORY is exactly $1 or under
# it, from one bounded system-wide `lsof -a -d cwd` scan (never the recursive
# +D file-tree walk, which lsof itself documents as slow). Never $$ (the pid of
# the shell that sourced this library). Empty output when nothing matches;
# a non-zero return means the scan could not establish a safe result.
fm_proc_pids_with_cwd_under() {  # <dir>
  local dir=$1 out pid path line
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(cd "$dir" && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ -n "$pid" ] && [ "$pid" != "$$" ] && printf '%s\n' "$pid"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

# Sets FM_PROC_PIDS to the sorted union of the pids working under every root
# given. On failure, returns non-zero with FM_PROC_FAILED_DIR naming the root
# whose scan failed; the caller must read that as "cannot confirm", never "none".
FM_PROC_PIDS=
FM_PROC_FAILED_DIR=

fm_proc_pids_under_roots() {  # <dir>...
  FM_PROC_PIDS=
  FM_PROC_FAILED_DIR=
  local dir dir_pids pids=""
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! dir_pids=$(fm_proc_pids_with_cwd_under "$dir"); then
      # shellcheck disable=SC2034 # Read by sourcing callers when this returns non-zero.
      FM_PROC_FAILED_DIR=$dir
      return 1
    fi
    pids="$pids
$dir_pids"
  done
  # shellcheck disable=SC2034 # Read by sourcing callers after this returns.
  FM_PROC_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
}
