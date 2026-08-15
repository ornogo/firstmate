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
#   2. `git branch` runs only in founder-run bin/fm-teardown.sh, or on a
#      reviewed line.
#   3. The startup sweep (bin/fm-fleet-sync.sh) runs nothing removal-capable
#      except its two reviewed lines.
#   4. Every executable-position reference to a destructive helper anywhere in
#      tracked bin/ is in the reviewed allowlist below. A new call site - which
#      is what "a new automatic caller" looks like in the diff - is not in the
#      allowlist, so it fails. Rule 4 is the general one; rules 1-3 pin the
#      specific surfaces this fork had to remove.
#
# Rules 2 and 3 match the ACTION, not one spelling of it, and both are inverted
# for the same reason. A check that listed spellings would pass on
# `rm --recursive`, `git branch -df`, `git branch --force --delete`, and
# `git worktree --force remove` - the same deletions written the other legal
# way - which is a fail-open hole in a check whose whole premise is fail-closed.
#
# Recognizing more spellings does not fix that, because the thing being modelled
# is git's option grammar, and it loses: `git branch --sort committerdate -D b`
# deletes the branch and exits 0, but any pattern that walks an option run
# stops at `committerdate`, which does not begin with a hyphen. Rules 2 and 3
# therefore flag the VERB - every `git branch` invocation, every removal-capable
# command in the startup sweep - and require each one to be a reviewed line in
# an allowlist. A spelling nobody anticipated fails by default instead of
# passing, and no git grammar has to be modelled to keep that true.
#
# The cost is that a read-only `git branch` outside teardown needs a reviewed
# line too, and so does prose that merely reads like one. That cost is one line
# today, and it is the right trade: a reviewer adding an entry has to say why
# the line cannot delete a branch, which is the question the check exists to
# force.
#
# Every allowlist below licenses exactly one occurrence. An entry does not say
# "this text is approved", it says "this occurrence is approved": a second copy
# of an approved line is a second call site nobody read, sitting in whatever
# control flow the copy landed in, which is exactly the new automatic caller
# these rules exist to catch. Zero occurrences fails too, because a stale entry
# is the same hole on a delay - it sits there licensing a line that is gone,
# ready to approve it silently the day it comes back. Neither count is a
# judgement call, so both fail, with the count in the message.
#
# Prose is out of scope. Rules 2-4 read only executable lines: a whole-line
# comment is dropped, and the tail of a "code  # trailing comment" line is cut,
# so documenting a destructive action never trips the check while invoking one
# does.
#
# A naive cut is quote-blind, and a quote-blind cut fails open:
# `printf '%s' ' # '; "$SCRIPT_DIR/fm-teardown.sh" "$id" --force` is a harmless
# command followed by a real teardown, and cutting at the first ` # ` deletes
# the teardown before any rule sees it. Nothing here parses shell to tell a
# quoted `#` from a comment, because that is the same losing game as modelling
# git's option grammar and it loses the same way.
#
# So the cut is taken only where it is sound without a parser. On a line with no
# quote character on it, no `#` can be inside a string. That leaves exactly one
# construct where a whitespace-preceded `#` is still not a comment: a parameter
# expansion whose pattern contains one, as in `cmd=${cmd%%  #*}` - which is a
# real line in `bin/fm-bootstrap.sh`, not a hypothetical, and verified against
# bash to strip a suffix rather than start a comment. Writing one needs `${`, so
# a line carrying neither a quote nor `${` cannot hold a non-comment `#`, and on
# such a line everything from the first whitespace-preceded `#` is comment. Note
# that this is `#` with no whitespace required after it: `echo boot #note` is a
# comment to bash, so it must be one here too, or the check invents findings in
# prose. Any line with a quote or a `${` on it is kept whole and read as code.
#
# The cost is that a trailing comment on a line that also carries a quoted
# string or a parameter expansion is read as code, so prose there naming a
# destructive helper needs a reviewed entry. A whole-line comment is never
# ambiguous and is always dropped, so the fix is to put the sentence on its own
# line, which costs nothing.
#
# Two files are the contract's own text rather than code it governs: this
# script, and tests/fm-destructive-automation.test.sh. Both have to name the
# banned function and the destructive helpers in order to ban them and to prove
# the ban works, so rule 1 skips both by path, and rules 2 and 4 skip this
# script. The banned name therefore appears nowhere in this fork except in the
# check that bans it and the test that proves the ban. The exclusion is by exact
# path, not by wording: the same words in any other file still fail.
#
# Rules 2 and 4 skip this script for a sharper reason than "it names what it
# bans": an allowlist cannot license a line in the file that stores the licence.
# The entry has to quote the line it exempts, so the record is itself a hit, and
# adding an entry for that record does not help - the new entry is one too.
# There is no fixed point. Rule 3 escapes it only because it is scoped to the
# sweep file, so this script's copies of the sweep's reviewed lines are never
# scanned.
#
# What that costs, stated plainly: no rule audits this script's own call sites,
# so a change to either file is reviewed as a change to the rule, not as
# ordinary code. That is the compensating control, and it is the reason the
# reasons in every allowlist below are load-bearing prose rather than a token.
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
NL='
'

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

# Rule 2 inverted: every `git branch` invocation, whatever its options. Matching
# the verb rather than a delete option is what makes an unanticipated spelling
# fail closed - see the header on why reading the option run cannot be made
# correct.
BRANCH_RE='git[^;|&]*[[:space:]]branch([[:space:]]|$)'

# Lines outside teardown that read as a `git branch` invocation and have been
# read and found not to delete anything, as "<path><TAB><normalized line><TAB>
# <reason>", normalized the same way as ALLOWLIST below. Tracked bin/ has
# exactly two real `git branch` invocations and both are the sanctioned
# deletions in bin/fm-teardown.sh, so the one entry here is prose.
BRANCH_ALLOWLIST=$(
  cat <<'ENTRIES'
bin/fm-bootstrap.sh	echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"	one echo whose text happens to put the word "branch" after a `git checkout` suggestion; it runs no git command
ENTRIES
)

# Rule 3 inverted: every verb reaching the sweep that can destroy work, whatever
# its options, so the reviewed lines below are the only ones that may run.
# Matching the verb rather than the invocation is what makes an unanticipated
# spelling fail closed.
#
# "Destroy work" is wider than "delete". Discarding an uncommitted edit loses it
# as completely as removing the file does, so the git verbs cover both the ref
# and path removals (branch, worktree, clean, gc, prune, reflog, update-ref) and
# the ones that overwrite or move the working tree (reset, checkout, restore,
# switch, stash), plus push, which deletes a remote branch by `--delete` or by a
# colon refspec that names no local side. Each is flagged on the verb alone; a
# reviewed line says why that occurrence cannot lose anything.
#
# "--prune" on git fetch is deliberately not matched: it drops remote-tracking
# refs, which hold no work. It is spelled with a hyphen before the verb, and the
# git alternatives all require whitespace there, so `git prune` is caught and
# `git fetch --prune` is not.
#
# The leading boundary excludes the characters that make a longer word - so
# `confirm ` and `fm-rm ` are not removals - but deliberately allows `/`, so a
# path-qualified `/bin/rm -rf` is caught. Excluding `/` was a hole: naming the
# absolute path is an ordinary way to invoke a command, and the sweep is exactly
# where an unattended one would sit. The cost is that a line ending a path in
# `/rm` is flagged too, which is the fail-closed direction and costs nothing in
# the shipped sweep.
SWEEP_FORBIDDEN='(^|[^[:alnum:]_.-])(rm|rmdir|unlink|shred)([[:space:]]|$)|git[^;|&]*[[:space:]](branch|worktree|clean|gc|prune|reflog|update-ref|reset|checkout|restore|switch|stash|push)([[:space:]]|$)|-delete([[:space:]]|$)|-exec[[:space:]]+[^[:space:]]*rm'

# The sweep's reviewed lines, as "<normalized line><TAB><reason>", normalized
# the same way as ALLOWLIST below. Every reason has to hold for the sweep's
# unattended context: nothing here may destroy work.
SWEEP_ALLOWLIST=$(
  cat <<'ENTRIES'
if ! rm -f "$lock"; then	a single non-recursive rm -f of a provably-stale .git/packed-refs.lock, which holds no work
git -C "$PROJ" worktree list --porcelain 2>/dev/null | sed -n 's#^branch refs/heads/##p' | grep -Fxq -- "$DEFAULT"	a read: the whole pipeline lists worktrees and asks whether one holds the default branch, removing none
if ! git -C "$PROJ" checkout --quiet "$DEFAULT" 2>/dev/null; then	re-attaches a detached HEAD the branch above has already proven clean, free of unique commits, and an ancestor of the base; --quiet is not --force, so git aborts rather than overwrite, and every other drift is reported and left untouched
ENTRIES
)

# Reviewed call sites, as "<path><TAB><normalized line><TAB><reason>".
# Normalized means leading and trailing whitespace trimmed and internal runs
# collapsed to one space, so reindenting a reviewed line does not churn this
# list while changing what it does will. The line is the whole logical command,
# joined across any backslash continuations, so an entry quotes the invocation a
# reviewer has to judge rather than whichever fragment fell on one source line.
# The reasons are load-bearing: each one has to say why no automatic path
# reaches that site.
ALLOWLIST=$(
  cat <<'ENTRIES'
bin/fm-teardown.sh	if out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh retire "$ID" --force < /dev/null 2>&1); then rc=0; else rc=$?; fi	founder-run teardown fanning out to retire the remote half of a remote secondmate
bin/fm-teardown.sh	if out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh retire "$ID" < /dev/null 2>&1); then rc=0; else rc=$?; fi	the same fan-out, non-forced form
bin/fm-teardown.sh	echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2	error-message text naming the manual recovery command, not an invocation
bin/fm-remote-secondmate-control.sh	FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 "$SCRIPT_DIR/fm-teardown.sh" "$id" --force	reached only through this script's own retire verb, whose sole caller is the founder-run teardown allowlisted above
bin/fm-remote-secondmate-control.sh	FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 "$SCRIPT_DIR/fm-teardown.sh" "$id"	the same retire verb, non-forced form
bin/fm-merge-local.sh	[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }	error-message text naming the right command for a PR task, not an invocation
bin/fm-test-run.sh	bin/fm-teardown.sh)	test-family classification case label, matching that path as data
bin/fm-test-run.sh	bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-review-diff.sh| bin/fm-x-*|bin/fm-check*)	test-family classification glob, matching those paths as data
bin/fm-merge-local.sh	ID=${1:?usage: fm-merge-local.sh <task-id>}	the script's own name inside its usage string, not an invocation
ENTRIES
)

FAILURES=0

fail() {
  printf 'fm-destructive-automation-check: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

# One entry, one occurrence - see the header for why both a duplicate and a
# stale entry are the same fail-open hole. Takes the list, the lines that
# actually reached that list's allowlist test, and the list's name. Each rule
# builds its seen-list inside its own loop, after its own exclusions, so the two
# sides are compared over identical input.
check_entry_counts() {
  entries=$1
  seen=$2
  list_name=$3
  rule=$4
  noun=$5
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    key=${entry%"$TAB"*}
    count=$(printf '%s' "$seen" | grep -Fxc -- "$key" || true)
    if [ "$count" -eq 1 ]; then
      continue
    fi
    if [ "$count" -eq 0 ]; then
      fail "$list_name has an entry that $rule matched no $noun for; a stale entry re-licenses the line the day it comes back, so delete it:"
    else
      fail "$list_name has an entry that $rule matched $count times; each entry licenses one $noun, and a copy of a reviewed line is a line nobody read:"
    fi
    printf '  %s\n' "$(printf '%s' "$key" | tr "$TAB" ' ')" >&2
  done <<EOF
$entries
EOF
}

# Every tracked bin/ script as "<path><TAB><lineno><TAB><code>", one executable
# command each. Whole-line comments (the shebang among them) are dropped,
# trailing-comment tails are cut, and backslash continuations are joined, in one
# pass so the scan stays cheap. The reported line number is the first physical
# line of a joined run, which is where a reader would go looking.
#
# The tail is cut only on a line carrying neither a quote nor `${`: on such a
# line a whitespace-preceded `#` can be neither inside a string nor inside a
# parameter expansion's pattern, which are the only two ways it is not a
# comment, so the cut is sound with no shell parsing. Any other line is read
# whole. See the header for why the conservative read is the only safe one here.
#
# Joining is what makes the rules read commands instead of source lines. Without
# it the scan is blind to `git -C "$PROJ" \` followed by `branch -D "$b"`, which
# is one command to bash and two lines to grep; the same split hides a sweep
# removal, and `fm-\` + `teardown.sh` hides a helper invocation. The join is
# deliberately cruder than bash: every line ending in a backslash is joined to
# the next with the backslash dropped and the next line's leading whitespace
# kept, which is exactly how bash removes a `\<newline>`. Bash declines to join
# in two cases this does not model - an escaped `\\` ending a line, and a
# backslash inside a single-quoted string - and in both the crude rule joins
# where bash would not. That direction is safe: over-joining only makes a
# logical line longer, so it can raise a finding a human then reads, while
# under-joining is the failure that hides a deletion and cannot happen here.
#
# A whole-line comment or a blank line flushes rather than continues. A
# backslash inside a comment is inert to bash as well, and on the joined form
# the `#` would start a comment that swallows the rest anyway, so flushing
# agrees with bash and keeps the following line reported at its own number.
EXEC_LINES=$(
  # shellcheck disable=SC2016 # awk owns every $ expression in this literal program.
  git ls-files -z -- 'bin/*' \
    | xargs -0 awk '
        function flush() {
          if (held_line > 0) { print held_file "\t" held_line "\t" held }
          held = ""; held_line = 0
        }
        BEGIN { SQ = sprintf("%c", 39); held = ""; held_line = 0 }
        FNR == 1 { flush() }
        {
          probe = $0
          sub(/^[ \t]+/, "", probe)
          if (probe ~ /^#/ || probe == "") { flush(); next }
          code = $0
          if (index(code, SQ) == 0 && index(code, "\"") == 0 && index(code, "${") == 0) {
            sub(/[ \t]#.*$/, "", code)
          }
          gsub(/\t/, " ", code)
          if (held_line > 0) {
            held = held code
          } else {
            held_file = FILENAME; held_line = FNR; held = code
          }
          if (held ~ /\\$/) { sub(/\\$/, "", held); next }
          flush()
        }
        END { flush() }
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

BRANCH_SEEN=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file=${hit%%"$TAB"*}
  [ "$file" != "$TEARDOWN" ] || continue
  # An allowlist cannot license a line in the file that stores the licence: the
  # entry quotes the line it exempts, so the record is itself a hit, and adding
  # an entry for that record does not help because the new entry is one too.
  # Rule 4 skips this script for the same reason. See the header.
  [ "$file" != "$SELF" ] || continue
  rest=${hit#*"$TAB"}
  lineno=${rest%%"$TAB"*}
  norm=$(printf '%s\n' "${rest#*"$TAB"}" | awk '{ $1 = $1; print }')
  BRANCH_SEEN="${BRANCH_SEEN}${file}${TAB}${norm}${NL}"
  if printf '%s\n' "$BRANCH_ALLOWLIST" | grep -Fq -- "${file}${TAB}${norm}${TAB}"; then
    continue
  fi
  fail "${file}:${lineno} runs git branch, which can delete one; only $TEARDOWN may, and this is not a reviewed line:"
  printf '  %s\n' "$norm" >&2
  printf '  If it cannot delete a branch, add it to BRANCH_ALLOWLIST in bin/fm-destructive-automation-check.sh with a reason that says why.\n' >&2
done <<EOF
$(printf '%s\n' "$EXEC_LINES" | grep -E -- "$BRANCH_RE" || true)
EOF

check_entry_counts "$BRANCH_ALLOWLIST" "$BRANCH_SEEN" BRANCH_ALLOWLIST "rule 2" line

# --- rule 3: the startup sweep never deletes --------------------------------

if [ ! -f "$SWEEP" ]; then
  fail "$SWEEP is missing; the startup-sweep rule cannot be checked"
else
  SWEEP_SEEN=""
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rest=${hit#*"$TAB"}
    lineno=${rest%%"$TAB"*}
    norm=$(printf '%s\n' "${rest#*"$TAB"}" | awk '{ $1 = $1; print }')
    SWEEP_SEEN="${SWEEP_SEEN}${norm}${NL}"
    if printf '%s\n' "$SWEEP_ALLOWLIST" | grep -Fq -- "${norm}${TAB}"; then
      continue
    fi
    fail "${SWEEP}:${lineno} can destroy work - remove a branch, a worktree, or a path, or overwrite the working tree - and is not one of the startup sweep's reviewed lines:"
    printf '  %s\n' "$norm" >&2
    printf '  The startup sweep runs unattended on every boot. Remove it, or add it to SWEEP_ALLOWLIST in bin/fm-destructive-automation-check.sh with a reason that says why it cannot destroy work.\n' >&2
  done <<EOF
$(printf '%s\n' "$EXEC_LINES" | grep -E -- "^${SWEEP}${TAB}" | grep -E -- "$SWEEP_FORBIDDEN" || true)
EOF

  check_entry_counts "$SWEEP_ALLOWLIST" "$SWEEP_SEEN" SWEEP_ALLOWLIST "rule 3" line
fi

# --- rule 4: every destructive call site is reviewed ------------------------

CALL_SEEN=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file=${hit%%"$TAB"*}
  # This script names every destructive helper in DESTRUCTIVE_RE and in the
  # allowlist below, so auditing itself would flag its own rule text.
  [ "$file" != "$SELF" ] || continue
  rest=${hit#*"$TAB"}
  lineno=${rest%%"$TAB"*}
  code=${rest#*"$TAB"}

  # Deliberately matched against the whole line, including a script's own name.
  # Stripping the self-name first would have been a hole: it rewrites
  # `fm-remote-secondmate-control.sh retire "$id"` into ` retire "$id"`, which
  # DESTRUCTIVE_RE no longer matches, so that script re-invoking its own retire
  # verb passed unreviewed. A script naming itself in usage text is the rarer
  # case and belongs in ALLOWLIST, where it is read once and recorded.
  #
  # Matched in-shell rather than through grep: the pre-filter passes every line
  # that names a destructive helper at all, which is ~2250 lines of the fork's
  # own usage and error text, and one subshell each was this check's entire
  # runtime.
  [[ $code =~ $DESTRUCTIVE_RE ]] || continue

  norm=$(printf '%s\n' "$code" | awk '{ $1 = $1; print }')
  CALL_SEEN="${CALL_SEEN}${file}${TAB}${norm}${NL}"
  if ! printf '%s\n' "$ALLOWLIST" | grep -Fq -- "${file}${TAB}${norm}${TAB}"; then
    fail "${file}:${lineno} reaches a destructive helper and is not in the reviewed allowlist:"
    printf '  %s\n' "$norm" >&2
    printf '  Add it to ALLOWLIST in bin/fm-destructive-automation-check.sh with a reason that says why no automatic path reaches it.\n' >&2
  fi
done <<EOF
$(printf '%s\n' "$EXEC_LINES" | grep -E -- "$DESTRUCTIVE_RE" || true)
EOF

check_entry_counts "$ALLOWLIST" "$CALL_SEEN" ALLOWLIST "rule 4" "call site"

# --- verdict ----------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'fm-destructive-automation-check: FAILED (%d finding(s))\n' "$FAILURES" >&2
  exit 1
fi

REVIEWED=$(printf '%s\n' "$ALLOWLIST" | grep -c . || true)
SWEEP_REVIEWED=$(printf '%s\n' "$SWEEP_ALLOWLIST" | grep -c . || true)
BRANCH_REVIEWED=$(printf '%s\n' "$BRANCH_ALLOWLIST" | grep -c . || true)
printf 'fm-destructive-automation-check: ok scripts=%s reviewed_call_sites=%s reviewed_branch_lines=%s reviewed_sweep_lines=%s\n' \
  "$SCANNED" "$REVIEWED" "$BRANCH_REVIEWED" "$SWEEP_REVIEWED"
