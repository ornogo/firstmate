#!/usr/bin/env bash
# Fail-closed admission guard for the fleet: one writer, one lock, one flat-JSON
# ledger. This is a backstop against founder memory, not a concurrency kernel -
# no generations, revisions, or epochs. It performs no privileged operation and
# is a guard against founder error and launch races, not a security boundary.
#
# State is data/admission-ledger.json at the fleet root, outside any pooled
# worktree: a JSON object mapping an uppercase Linear issue key to
# {branch, worktree, reserved_at, status} with status in active|quarantined.
# Bootstrap provisions it as an empty object before spawning is possible; a
# missing ledger is never treated as empty, and a parseable-but-schema-invalid
# ledger is unusable rather than best-effort readable. Recovery from an unusable
# ledger is founder repair with the spawn path stopped, the old file copied
# aside first, the repair trial-logged, and occupancy reconstructed from live
# efforts before spawning resumes.
#
# Every operation takes an exclusive bounded-wait lock on the stable sibling
# admission-ledger.lock - never the ledger itself, whose inode is replaced by
# rename - and holds it across the whole read-validate-decide-write cycle, then
# writes a temp file and renames it over the ledger before releasing. That
# locked read-check-write is the linearization point, so two concurrent
# admissions cannot both observe the same free slot.
#
# The lock is a portable atomic mkdir, not flock(1): flock(1) does not ship on
# macOS, and bin/fm-supervise-daemon.sh already carries the same "no flock
# dependency" constraint for its single-instance lock. A held lock is never
# stolen - stealing would break the linearization the ledger depends on - so a
# lock-timeout refusal names the directory for founder repair instead.
#
# admit refuses on duplicate, cap, missing-key, binding-conflict,
# ledger-unusable, or lock-timeout, each with a distinct one-line message. A
# refusal, for any reason, creates no new ledger entry and mutates no existing
# entry. Ledger content is only ever passed to jq as data (--arg), never
# evaluated.
#
# Exit status: 0 success, 1 refusal or operational failure (the spawn does not
# proceed either way), 2 usage or argument error.
#
# Usage:
#   fm-admit.sh admit --branch <name> --worktree <path>
#   fm-admit.sh release <issue-key>
#   fm-admit.sh quarantine <issue-key>
#   fm-admit.sh resume <issue-key>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="$FM_HOME/data"
LEDGER="$DATA/admission-ledger.json"
LOCK="$DATA/admission-ledger.lock"

# Tracked in-script constants. The PoC cap is fixed at 1. A quarantined entry
# keeps counting against it, so a quarantine halts new admissions until the
# founder resolves it; that conservative posture is intentional.
ADMIT_CAP=1
LOCK_WAIT_SECS="${FM_ADMIT_LOCK_WAIT_SECS:-10}"

usage() {
  cat <<'EOF'
Usage:
  fm-admit.sh admit --branch <name> --worktree <path>
  fm-admit.sh release <issue-key>
  fm-admit.sh quarantine <issue-key>
  fm-admit.sh resume <issue-key>
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
abort() { printf 'error: %s\n' "$1" >&2; exit 1; }
refuse() { printf 'refused (%s): %s\n' "$1" "$2" >&2; exit 1; }

# --- lock -------------------------------------------------------------------
#
# The traps are armed before the acquire loop, not after it, so a signal
# arriving in the instant between mkdir returning and LOCK_HELD being set is the
# only unprotected window bash leaves. lock_release is a no-op until then.

LOCK_HELD=

lock_release() {
  [ -n "$LOCK_HELD" ] || return 0
  LOCK_HELD=
  rm -f "$LOCK/pid" 2>/dev/null || true
  rmdir "$LOCK" 2>/dev/null || true
}

trap 'lock_release' EXIT
trap 'lock_release; exit 130' INT
trap 'lock_release; exit 143' TERM

lock_acquire() {
  local deadline
  case "$LOCK_WAIT_SECS" in
    ''|*[!0-9]*) die "FM_ADMIT_LOCK_WAIT_SECS must be a non-negative integer, got: $LOCK_WAIT_SECS" ;;
  esac
  # mkdir fails with ENOENT, not EEXIST, when the ledger directory is missing,
  # and the loop below cannot tell the two apart: against an unprovisioned
  # FM_HOME it would spin out the whole wait and then blame a lock nobody holds.
  # Checking first turns that into an immediate, accurate refusal. This is not a
  # provisioning step - the ledger and its directory are bootstrap's to create,
  # and making one here would admit against a ledger the founder never installed.
  [ -d "$DATA" ] \
    || refuse ledger-unusable "the admission ledger directory $DATA does not exist; bootstrap provisions it along with the ledger (no directory, no lock, no read, no spawn)"
  deadline=$((SECONDS + LOCK_WAIT_SECS))
  while ! mkdir "$LOCK" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      refuse lock-timeout "the admission ledger lock $LOCK stayed held for ${LOCK_WAIT_SECS}s; no lock, no read, no spawn (a lock left behind by a dead process is founder repair: confirm no admission is running, then remove that directory)"
    fi
    sleep 0.1
  done
  LOCK_HELD=1
  printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || true
}

# --- ledger -----------------------------------------------------------------

# Sets LEDGER_JSON to the validated ledger body. Never called through command
# substitution, so a refusal exits the real shell and runs the real EXIT trap.
LEDGER_JSON=

ledger_read() {
  local reason=
  if [ -L "$LEDGER" ]; then
    reason="it is a symlink"
  elif [ ! -e "$LEDGER" ]; then
    reason="it does not exist (a missing ledger is never treated as empty; bootstrap provisions it as {})"
  elif [ ! -f "$LEDGER" ]; then
    reason="it is not a regular file"
  elif [ ! -r "$LEDGER" ]; then
    reason="it is not readable"
  fi
  [ -z "$reason" ] || refuse ledger-unusable "the admission ledger $LEDGER cannot be used: $reason"

  LEDGER_JSON=$(cat "$LEDGER") \
    || refuse ledger-unusable "the admission ledger $LEDGER cannot be used: it could not be read"

  printf '%s' "$LEDGER_JSON" | jq -e '
    type == "object"
    and (keys_unsorted | all(test("^ORN-[0-9]+$")))
    and (to_entries | all(.value
      | type == "object"
      and (.branch | type == "string" and length > 0)
      and (.worktree | type == "string" and length > 0)
      and (.reserved_at | type == "string" and length > 0)
      and (.status == "active" or .status == "quarantined")))
  ' >/dev/null 2>&1 \
    || refuse ledger-unusable "the admission ledger $LEDGER cannot be used: it is not a JSON object mapping ORN keys to {branch, worktree, reserved_at, status in active|quarantined}"
}

# ledger_write <json>: temp file in the ledger's own directory, then an atomic
# rename over the ledger while the lock is still held.
ledger_write() {
  local tmp
  tmp=$(mktemp "$DATA/.admission-ledger.XXXXXX") \
    || abort "cannot create a ledger temp file in $DATA"
  chmod 600 "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$1" > "$tmp"; then
    rm -f "$tmp"
    abort "cannot write the ledger temp file $tmp"
  fi
  if ! mv -f "$tmp" "$LEDGER"; then
    rm -f "$tmp"
    abort "cannot replace the ledger $LEDGER"
  fi
}

ledger_query() { printf '%s' "$LEDGER_JSON" | jq "$@"; }

# Every jq filter this script runs, in one place. jq owns each `$` here: they
# name --arg bindings and must reach jq unexpanded, which is also the property
# that keeps ledger content data - it arrives through --arg and is never spliced
# into a filter, so nothing in the ledger is ever evaluated.
# shellcheck disable=SC2016
{
  JQ_HAS_KEY='has($k)'
  JQ_KEY_STATUS='.[$k].status'
  JQ_BINDING_TAKEN='to_entries | any(.value.branch == $b or .value.worktree == $w)'
  JQ_RESERVE='.[$k] = {branch: $b, worktree: $w, reserved_at: $t, status: "active"}'
  JQ_DELETE_KEY='del(.[$k])'
  JQ_SET_STATUS='.[$k].status = $s'
}

# --- argument shapes --------------------------------------------------------

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Sets BRANCH_KEY to the uppercase ledger key, or returns non-zero when the
# branch name does not carry exactly one positioned Linear issue key.
BRANCH_KEY=

branch_key() {
  local branch=$1 count
  BRANCH_KEY=
  # Exactly one embedded key in the whole name (ORN-180), counted
  # case-insensitively so a second key mentioned anywhere in the slug is caught.
  count=$(printf '%s\n' "$branch" | grep -o -i -E 'orn-[0-9]+' | wc -l | tr -d '[:space:]')
  [ "$count" = 1 ] || return 1
  # The key starts right after the Conventional-Commit type's '/' and is bounded
  # by a '-' or the end of the name, so a key buried mid-slug is not positioned.
  [[ $branch =~ ^[a-z]+/(orn-[0-9]+)(-[^/]*)?$ ]] || return 1
  BRANCH_KEY=$(upper "${BASH_REMATCH[1]}")
}

# Sets WORKTREE_PATH, for the same reason require_issue_key does. Strips
# trailing slashes so /pool/wt and /pool/wt/ cannot both be admitted as distinct
# bindings. A '..' segment is rejected outright rather than resolved, because an
# unresolved traversal makes the binding comparison unreliable and resolving one
# would require the path to already exist.
WORKTREE_PATH=

normalize_worktree() {
  local path=$1
  case "$path" in
    /*) ;;
    *) die "admit needs an absolute --worktree path, got: $path" ;;
  esac
  # A binding conflict is decided by string equality, so every alternate
  # spelling of one path has to be ruled out before it reaches the ledger: two
  # admissions spelling the same worktree differently would each read the
  # other's binding as some other worktree's and both be let through. Trailing
  # slashes are stripped, since that spelling is unambiguous and callers produce
  # it routinely. The rest are refused rather than rewritten - a caller emitting
  # an empty or dot segment is assembling paths in a way the founder should see,
  # and quietly repairing it here would hide that from them.
  case "$path" in
    *//*) die "admit needs a --worktree path with no empty segment, got: $path" ;;
    */../*|*/..) die "admit needs a --worktree path with no '..' segment, got: $path" ;;
    */./*|*/.) die "admit needs a --worktree path with no '.' segment, got: $path" ;;
  esac
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
  WORKTREE_PATH=$path
}

# Sets ISSUE_KEY. Not a command substitution helper: `f "$(g)"` discards g's
# exit status, so a die() inside a substituted argument would leave the caller
# running with an empty key instead of aborting.
ISSUE_KEY=

require_issue_key() {
  ISSUE_KEY=$(upper "$1")
  [[ $ISSUE_KEY =~ ^ORN-[0-9]+$ ]] || die "not a Linear issue key: $1"
}

# --- subcommands ------------------------------------------------------------

cmd_admit() {
  local branch='' worktree='' count status now updated
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch) [ "$#" -ge 2 ] || die "--branch needs a value"; branch=$2; shift 2 ;;
      --branch=*) branch=${1#--branch=}; shift ;;
      --worktree) [ "$#" -ge 2 ] || die "--worktree needs a value"; worktree=$2; shift 2 ;;
      --worktree=*) worktree=${1#--worktree=}; shift ;;
      *) die "unknown admit argument: $1" ;;
    esac
  done
  [ -n "$branch" ] || die "admit needs --branch <name>"
  [ -n "$worktree" ] || die "admit needs --worktree <path>"
  normalize_worktree "$worktree"
  worktree=$WORKTREE_PATH

  # Checked before the lock: it reads no ledger state, so a malformed branch
  # fails fast without making a concurrent admission wait out the bounded lock.
  branch_key "$branch" \
    || refuse missing-key "branch '$branch' does not position exactly one lowercase Linear issue key immediately after its Conventional-Commit type prefix (expected <type>/orn-<number>[-<slug>])"

  lock_acquire
  ledger_read

  if ledger_query -e --arg k "$BRANCH_KEY" "$JQ_HAS_KEY" >/dev/null; then
    status=$(ledger_query -r --arg k "$BRANCH_KEY" "$JQ_KEY_STATUS")
    refuse duplicate "the ledger already holds $BRANCH_KEY ($status); release it, or resolve the quarantine, before admitting it again"
  fi

  # Binding conflict is checked before the cap deliberately. Both are true when a
  # full ledger already holds the requested branch or worktree, and the specific
  # collision is the more useful thing to say; checking the cap first would also
  # make this refusal unreachable at ADMIT_CAP=1, where any conflicting entry is
  # already the one filling the cap.
  if ledger_query -e --arg b "$branch" --arg w "$worktree" "$JQ_BINDING_TAKEN" >/dev/null; then
    refuse binding-conflict "branch '$branch' or worktree '$worktree' is already bound to an existing ledger entry"
  fi

  count=$(ledger_query 'length')
  if [ "$count" -ge "$ADMIT_CAP" ]; then
    refuse cap "the ledger holds $count of $ADMIT_CAP admitted efforts; release one before admitting another (a quarantined entry still counts, so resolve any quarantine first)"
  fi

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  updated=$(ledger_query --arg k "$BRANCH_KEY" --arg b "$branch" --arg w "$worktree" --arg t "$now" \
    "$JQ_RESERVE")
  ledger_write "$updated"
  printf 'admitted %s (branch %s, worktree %s)\n' "$BRANCH_KEY" "$branch" "$worktree"
}

cmd_release() {
  local key updated
  [ "$#" -eq 1 ] || die "release needs exactly one <issue-key>"
  require_issue_key "$1"
  key=$ISSUE_KEY
  lock_acquire
  ledger_read
  ledger_query -e --arg k "$key" "$JQ_HAS_KEY" >/dev/null \
    || abort "the ledger has no entry for $key; nothing was released"
  updated=$(ledger_query --arg k "$key" "$JQ_DELETE_KEY")
  ledger_write "$updated"
  printf 'released %s\n' "$key"
}

# Shared by quarantine and resume: both flip exactly one status, both exit
# non-zero when the key is absent, and both are idempotent on a key already in
# the target status - exiting zero, leaving the ledger unchanged, and saying so,
# so a founder re-running a checklist step mid-incident gets confirmation rather
# than a false alarm. Neither creates an entry, and neither changes occupancy:
# the entry keeps counting against the cap throughout.
#
# There is no "wrong source status" branch because there is no third status to
# be in: ledger_read has already refused anything outside active|quarantined, so
# an entry that is not already in the target status is in the only other one.
flip_status() {
  local verb=$1 to=$2 key=$3 updated
  lock_acquire
  ledger_read
  ledger_query -e --arg k "$key" "$JQ_HAS_KEY" >/dev/null \
    || abort "the ledger has no entry for $key; nothing was ${verb}d"
  if [ "$(ledger_query -r --arg k "$key" "$JQ_KEY_STATUS")" = "$to" ]; then
    printf '%s is already %s; the ledger is unchanged\n' "$key" "$to"
    return 0
  fi
  updated=$(ledger_query --arg k "$key" --arg s "$to" "$JQ_SET_STATUS")
  ledger_write "$updated"
  printf '%s %s\n' "$key" "$to"
}

cmd_quarantine() {
  [ "$#" -eq 1 ] || die "quarantine needs exactly one <issue-key>"
  require_issue_key "$1"
  flip_status quarantine quarantined "$ISSUE_KEY"
}

cmd_resume() {
  [ "$#" -eq 1 ] || die "resume needs exactly one <issue-key>"
  require_issue_key "$1"
  flip_status resume active "$ISSUE_KEY"
}

# --- dispatch ---------------------------------------------------------------

command -v jq >/dev/null 2>&1 || die "fm-admit.sh needs jq on PATH"

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUBCOMMAND=$1
shift
case "$SUBCOMMAND" in
  admit) cmd_admit "$@" ;;
  release) cmd_release "$@" ;;
  quarantine) cmd_quarantine "$@" ;;
  resume) cmd_resume "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $SUBCOMMAND" ;;
esac
