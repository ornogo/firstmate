#!/usr/bin/env bash
# fm-destructive-automation-check.sh - pin that nothing automatic destroys work.
#
# Usage:
#   bin/fm-destructive-automation-check.sh
#   bin/fm-destructive-automation-check.sh --root <repo>
#
# This fork runs agent workers unattended, so a destructive lifecycle action
# reached by a watcher event, a PR-open hook, a worker exit, or a restart can
# delete a branch or a worktree that still holds the only copy of somebody's
# work. Upstream had exactly one such surface - fm-fleet-sync.sh's
# prune_gone_branches, which force-deleted every local branch whose remote
# counterpart was gone. "Gone" covers a PR closed WITHOUT merging, so a closed
# PR destroyed its unpushed commits. That function is removed here.
#
# Removing it is not enough on its own: nothing stopped it, or an equivalent,
# from coming back. This check turns that audit into a standing property, so a
# new automatic caller fails the suite instead of quietly shipping.
#
# Four rules, all fail-closed:
#
#   1. prune_gone_branches does not exist anywhere in the fork.
#   2. Local-branch deletion appears only in founder-run bin/fm-teardown.sh.
#   3. The startup sweep (bin/fm-fleet-sync.sh) deletes no branch, no worktree,
#      and no directory tree.
#   4. Every executable-position reference to a destructive helper anywhere in
#      tracked bin/ is in the reviewed allowlist below. A new call site - which
#      is what "a new automatic caller" looks like in the diff - is not in the
#      allowlist, so it fails. Rule 4 is the general one; rules 1-3 pin the
#      specific surfaces this fork had to remove.
#
# Prose is out of scope. Rules 2-4 read only executable lines: a whole-line
# comment, and the tail of a "code  # trailing comment" line, are stripped
# first, so documenting a destructive action never trips the check while
# invoking one does.
#
# Two files are the contract's own text rather than code it governs: this
# script, and tests/fm-destructive-automation.test.sh. Both have to name the
# banned function and the destructive helpers in order to ban them and to prove
# the ban works, so rule 1 skips both by path and rule 4 skips this script. The
# banned name therefore appears nowhere in this fork except in the check that
# bans it and the test that proves the ban. The exclusion is by exact path, not
# by wording: the same words in any other file still fail.
#
# What that costs, stated plainly: rule 4 does not audit this script's own call
# sites, so a change to either file is reviewed as a change to the rule, not as
# ordinary code. Rule 2 still covers this script, so branch deletion added here
# is still caught.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "fm-destructive-automation-check: --root needs a path" >&2; exit 2; }
      ROOT=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,6p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "fm-destructive-automation-check: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT" || { echo "fm-destructive-automation-check: cannot enter root $ROOT" >&2; exit 2; }

TAB=$(printf '\t')

# The teardown path a founder runs by hand. It is the ONLY sanctioned home for
# branch deletion, and nothing reaches it automatically.
TEARDOWN=bin/fm-teardown.sh

# The startup sweep bin/fm-bootstrap.sh backgrounds on every boot.
SWEEP=bin/fm-fleet-sync.sh

# This check and its test, which state the rules and so must name what the
# rules ban. See the header for what excluding them costs.
SELF=bin/fm-destructive-automation-check.sh
SELF_TEST=tests/fm-destructive-automation.test.sh

# Helpers whose whole job is destructive or irreversible. A reference to one in
# executable position is a call site until the allowlist says otherwise.
DESTRUCTIVE_RE='fm-teardown\.sh|fm-pr-merge\.sh|fm-merge-local\.sh|fm-remote-secondmate-control\.sh retire'

BRANCH_DELETE_RE='branch[[:space:]]+(-D|-d|--delete)([[:space:]]|$)'

# A provably-stale .git/packed-refs.lock is the sweep's one permitted removal:
# a single non-recursive rm -f of a lock file, which holds no work. Everything
# below would.
SWEEP_FORBIDDEN='branch[[:space:]]+(-D|-d|--delete)|worktree[[:space:]]+(remove|prune)|(^|[^[:alnum:]_-])rm[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*)([[:space:]]|$)'

# Reviewed call sites, as "<path><TAB><normalized line><TAB><reason>".
# Normalized means leading and trailing whitespace trimmed and internal runs
# collapsed to one space, so reindenting a reviewed line does not churn this
# list while changing what it does will. The reasons are load-bearing: each one
# has to say why no automatic path reaches that site.
ALLOWLIST=$(
  cat <<'ENTRIES'
bin/fm-teardown.sh	if out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh retire "$ID" --force < /dev/null 2>&1); then rc=0; else rc=$?; fi	founder-run teardown fanning out to retire the remote half of a remote secondmate
bin/fm-teardown.sh	if out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh retire "$ID" < /dev/null 2>&1); then rc=0; else rc=$?; fi	the same fan-out, non-forced form
bin/fm-teardown.sh	echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2	error-message text naming the manual recovery command, not an invocation
bin/fm-remote-secondmate-control.sh	"$SCRIPT_DIR/fm-teardown.sh" "$id" --force	reached only through this script's own retire verb, whose sole caller is the founder-run teardown allowlisted above
bin/fm-remote-secondmate-control.sh	"$SCRIPT_DIR/fm-teardown.sh" "$id"	the same retire verb, non-forced form
bin/fm-merge-local.sh	[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }	error-message text naming the right command for a PR task, not an invocation
bin/fm-test-run.sh	bin/fm-teardown.sh)	test-family classification case label, matching that path as data
bin/fm-test-run.sh	bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-review-diff.sh|\	test-family classification glob, matching those paths as data
ENTRIES
)

FAILURES=0

fail() {
  printf 'fm-destructive-automation-check: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

# Every tracked bin/ script as "<path><TAB><lineno><TAB><code>", one executable
# line each. Whole-line comments (the shebang among them) are dropped and
# " # trailing comment" tails are cut, in one pass so the scan stays cheap.
EXEC_LINES=$(
  # shellcheck disable=SC2016 # awk owns every $ expression in this literal program.
  git ls-files -z -- 'bin/*' \
    | xargs -0 awk '
        {
          probe = $0
          sub(/^[ \t]+/, "", probe)
          if (probe ~ /^#/ || probe == "") next
          code = $0
          sub(/[ \t]#[ \t].*$/, "", code)
          sub(/[ \t]#$/, "", code)
          gsub(/\t/, " ", code)
          print FILENAME "\t" FNR "\t" code
        }
      '
)

SCANNED=$(git ls-files -- 'bin/*' | wc -l | tr -d ' ')
[ "$SCANNED" -gt 0 ] || fail "no tracked bin/ scripts were found under $ROOT"

# --- rule 1: prune_gone_branches is gone -----------------------------------

PRUNE_HITS=$(git grep -n -e 'prune_gone_branches' -- ":!$SELF" ":!$SELF_TEST" || true)
if [ -n "$PRUNE_HITS" ]; then
  fail "prune_gone_branches must not exist in this fork; it force-deleted local branches on any closed PR:"
  printf '%s\n' "$PRUNE_HITS" | sed 's/^/  /' >&2
fi

# --- rule 2: branch deletion lives only in founder-run teardown -------------

while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file=${hit%%"$TAB"*}
  [ "$file" != "$TEARDOWN" ] || continue
  rest=${hit#*"$TAB"}
  fail "${file}:${rest%%"$TAB"*} deletes a local branch; only $TEARDOWN may:"
  printf '  %s\n' "${rest#*"$TAB"}" >&2
done <<EOF
$(printf '%s\n' "$EXEC_LINES" | grep -E -- "$BRANCH_DELETE_RE" || true)
EOF

# --- rule 3: the startup sweep never deletes --------------------------------

if [ ! -f "$SWEEP" ]; then
  fail "$SWEEP is missing; the startup-sweep rule cannot be checked"
else
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rest=${hit#*"$TAB"}
    fail "${SWEEP}:${rest%%"$TAB"*} deletes a branch, a worktree, or a directory tree; the startup sweep must not:"
    printf '  %s\n' "${rest#*"$TAB"}" >&2
  done <<EOF
$(printf '%s\n' "$EXEC_LINES" | grep -E -- "^${SWEEP}${TAB}" | grep -E -- "$SWEEP_FORBIDDEN" || true)
EOF
fi

# --- rule 4: every destructive call site is reviewed ------------------------

while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file=${hit%%"$TAB"*}
  # This script names every destructive helper in DESTRUCTIVE_RE and in the
  # allowlist below, so auditing itself would flag its own rule text.
  [ "$file" != "$SELF" ] || continue
  rest=${hit#*"$TAB"}
  lineno=${rest%%"$TAB"*}
  code=${rest#*"$TAB"}

  # A script naming only itself - usage text, a self-exec - calls nothing.
  self=${file##*/}
  others=${code//"$self"/}
  printf '%s\n' "$others" | grep -Eq -- "$DESTRUCTIVE_RE" || continue

  norm=$(printf '%s\n' "$code" | awk '{ $1 = $1; print }')
  if ! printf '%s\n' "$ALLOWLIST" | grep -Fq -- "${file}${TAB}${norm}${TAB}"; then
    fail "${file}:${lineno} reaches a destructive helper and is not in the reviewed allowlist:"
    printf '  %s\n' "$norm" >&2
    printf '  Add it to ALLOWLIST in bin/fm-destructive-automation-check.sh with a reason that says why no automatic path reaches it.\n' >&2
  fi
done <<EOF
$(printf '%s\n' "$EXEC_LINES" | grep -E -- "$DESTRUCTIVE_RE" || true)
EOF

# --- verdict ----------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'fm-destructive-automation-check: FAILED (%d finding(s))\n' "$FAILURES" >&2
  exit 1
fi

REVIEWED=$(printf '%s\n' "$ALLOWLIST" | grep -c . || true)
printf 'fm-destructive-automation-check: ok scripts=%s reviewed_call_sites=%s\n' "$SCANNED" "$REVIEWED"
