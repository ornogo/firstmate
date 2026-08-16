#!/usr/bin/env bash
# Shared ownership of the admission ledger's location, its lock, and the
# read-and-validate step that every ledger operation begins with.
#
# ONE owner for three things two scripts must agree on exactly:
#   1. where the ledger and its lock live under a given FM_HOME;
#   2. the bounded-wait exclusive lock protecting them;
#   3. what a usable ledger is - the schema check that decides whether the file
#      may be believed at all.
#
# bin/fm-admit.sh is the ledger's only writer and was the only caller until
# fm-spawn.sh's resume mode arrived. Resume mode is a reader, but not a bare
# one: it must hold the same lock from its binding check through worker
# creation, so that concurrent resumes of one effort serialize and every one
# after the first sees the window the first created. A child process cannot hold
# a lock on its parent's behalf - bin/fm-admit.sh releases on exit, by
# construction - so the lock has to be acquirable in the caller's own shell.
# Duplicating it there instead would put two spellings of one mutex, and two
# spellings of "is this ledger usable?", in the tree.
#
# The lock is a portable atomic mkdir, not flock(1): flock(1) does not ship on
# macOS, and bin/fm-supervise-daemon.sh already carries the same "no flock
# dependency" constraint for its single-instance lock. A held lock is never
# stolen - stealing would break the linearization the ledger depends on - so a
# lock-timeout is reported for founder repair instead.
#
# Two rules keep this usable from inside a larger script:
#
#   - It installs no traps. bin/fm-spawn.sh already owns a single EXIT trap
#     (spawn_abort_cleanup); a trap installed here would silently replace it and
#     turn a lock helper into a cleanup regression. Each caller wires
#     fm_admit_lock_release into the cleanup it already has.
#   - It never exits. Every failure returns non-zero with FM_ADMIT_ERR_CLASS and
#     FM_ADMIT_ERR set, so each caller reports in its own vocabulary - the
#     guard's "refused (<class>): <message>", spawn's "error: <message>" - and
#     an exit from inside a sourced function cannot cut a caller's cleanup short.

# Set by every failing function, read by the caller that reports it. The class
# is the guard's refusal vocabulary (ledger-unusable, lock-timeout) or `usage`
# for a caller-side argument error.
FM_ADMIT_ERR_CLASS=
FM_ADMIT_ERR=

# A setter, deliberately returning 0: under `set -e` a bare non-zero statement
# inside an `if` body or a `case` branch exits the shell, and a library that
# promises never to exit cannot report a failure through its own return status.
# Every failure path here calls this and then returns 1 itself.
fm_admit_set_err() {  # <class> <message>
  # shellcheck disable=SC2034 # Read by sourcing callers when a function returns non-zero.
  FM_ADMIT_ERR_CLASS=$1
  # shellcheck disable=SC2034 # Read by sourcing callers when a function returns non-zero.
  FM_ADMIT_ERR=$2
}

# --- paths ------------------------------------------------------------------

# Sets FM_ADMIT_DATA_DIR, FM_ADMIT_LEDGER, and FM_ADMIT_LOCK_DIR for an FM_HOME.
# Single owner on purpose: the guard resolves its ledger from $FM_HOME/data
# unconditionally, and a caller that derived the path its own way could take one
# lock while reading another home's ledger.
FM_ADMIT_DATA_DIR=
FM_ADMIT_LEDGER=
FM_ADMIT_LOCK_DIR=

fm_admit_resolve_paths() {  # <fm-home>
  FM_ADMIT_DATA_DIR="$1/data"
  FM_ADMIT_LEDGER="$FM_ADMIT_DATA_DIR/admission-ledger.json"
  # The lock is the stable sibling, never the ledger itself, whose inode is
  # replaced by the publishing rename.
  FM_ADMIT_LOCK_DIR="$FM_ADMIT_DATA_DIR/admission-ledger.lock"
}

# --- lock -------------------------------------------------------------------

# Non-empty exactly while this shell holds the lock. fm_admit_lock_release is a
# no-op until fm_admit_lock_acquire sets it, so a caller may wire the release
# into its cleanup before it ever acquires - which is what lets the cleanup be
# armed ahead of the acquire loop rather than after it.
FM_ADMIT_LOCK_HELD=

fm_admit_lock_release() {
  [ -n "$FM_ADMIT_LOCK_HELD" ] || return 0
  FM_ADMIT_LOCK_HELD=
  rm -f "$FM_ADMIT_LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$FM_ADMIT_LOCK_DIR" 2>/dev/null || true
}

# Acquires the exclusive ledger lock, waiting up to FM_ADMIT_LOCK_WAIT_SECS.
# Requires fm_admit_resolve_paths first.
fm_admit_lock_acquire() {
  local wait_secs deadline
  wait_secs="${FM_ADMIT_LOCK_WAIT_SECS:-10}"
  case "$wait_secs" in
    ''|*[!0-9]*)
      fm_admit_set_err usage "FM_ADMIT_LOCK_WAIT_SECS must be a non-negative integer, got: $wait_secs"
      return 1
      ;;
  esac
  # mkdir fails with ENOENT, not EEXIST, when the ledger directory is missing,
  # and the loop below cannot tell the two apart: against an unprovisioned
  # FM_HOME it would spin out the whole wait and then blame a lock nobody holds.
  # Checking first turns that into an immediate, accurate refusal. This is not a
  # provisioning step - the ledger and its directory are bootstrap's to create,
  # and making one here would admit against a ledger the founder never installed.
  if [ ! -d "$FM_ADMIT_DATA_DIR" ]; then
    fm_admit_set_err ledger-unusable "the admission ledger directory $FM_ADMIT_DATA_DIR does not exist; bootstrap provisions it along with the ledger (no directory, no lock, no read, no spawn)"
    return 1
  fi
  deadline=$((SECONDS + wait_secs))
  while ! mkdir "$FM_ADMIT_LOCK_DIR" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      fm_admit_set_err lock-timeout "the admission ledger lock $FM_ADMIT_LOCK_DIR stayed held for ${wait_secs}s; no lock, no read, no spawn (a lock left behind by a dead process is founder repair: confirm no admission is running, then remove that directory)"
      return 1
    fi
    sleep 0.1
  done
  FM_ADMIT_LOCK_HELD=1
  printf '%s\n' "$$" > "$FM_ADMIT_LOCK_DIR/pid" 2>/dev/null || true
}

# --- ledger -----------------------------------------------------------------

# Sets FM_ADMIT_LEDGER_JSON to the validated ledger body. Requires
# fm_admit_resolve_paths, and is only meaningful while the lock is held.
FM_ADMIT_LEDGER_JSON=

fm_admit_ledger_read() {
  local reason=
  if [ -L "$FM_ADMIT_LEDGER" ]; then
    reason="it is a symlink"
  elif [ ! -e "$FM_ADMIT_LEDGER" ]; then
    reason="it does not exist (a missing ledger is never treated as empty; bootstrap provisions it as {})"
  elif [ ! -f "$FM_ADMIT_LEDGER" ]; then
    reason="it is not a regular file"
  elif [ ! -r "$FM_ADMIT_LEDGER" ]; then
    reason="it is not readable"
  fi
  if [ -n "$reason" ]; then
    fm_admit_set_err ledger-unusable "the admission ledger $FM_ADMIT_LEDGER cannot be used: $reason"
    return 1
  fi

  if ! FM_ADMIT_LEDGER_JSON=$(cat "$FM_ADMIT_LEDGER"); then
    fm_admit_set_err ledger-unusable "the admission ledger $FM_ADMIT_LEDGER cannot be used: it could not be read"
    return 1
  fi

  if ! printf '%s' "$FM_ADMIT_LEDGER_JSON" | jq -e '
    type == "object"
    and (keys_unsorted | all(test("^ORN-[0-9]+$")))
    and (to_entries | all(.value
      | type == "object"
      and (.branch | type == "string" and length > 0)
      and (.worktree | type == "string" and length > 0)
      and (.reserved_at | type == "string" and length > 0)
      and (.status == "active" or .status == "quarantined")))
  ' >/dev/null 2>&1; then
    fm_admit_set_err ledger-unusable "the admission ledger $FM_ADMIT_LEDGER cannot be used: it is not a JSON object mapping ORN keys to {branch, worktree, reserved_at, status in active|quarantined}"
    return 1
  fi
}

# Runs a jq filter over the body fm_admit_ledger_read validated. Ledger content
# reaches jq only through --arg bindings the caller supplies, never spliced into
# a filter, so nothing in the ledger is ever evaluated.
fm_admit_ledger_query() { printf '%s' "$FM_ADMIT_LEDGER_JSON" | jq "$@"; }

# --- key normalization ------------------------------------------------------

fm_admit_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Sets FM_ADMIT_ISSUE_KEY to the uppercase ledger key. Not a command
# substitution helper: `f "$(g)"` discards g's exit status, so a caller writing
# `use "$(fm_admit_require_issue_key "$1")"` would run on with an empty key
# instead of stopping.
FM_ADMIT_ISSUE_KEY=

fm_admit_require_issue_key() {  # <argument>
  FM_ADMIT_ISSUE_KEY=$(fm_admit_upper "$1")
  if [[ ! $FM_ADMIT_ISSUE_KEY =~ ^ORN-[0-9]+$ ]]; then
    FM_ADMIT_ISSUE_KEY=
    fm_admit_set_err usage "not a Linear issue key: $1"
    return 1
  fi
}
