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
#   4. Every reference to a destructive helper anywhere in tracked bin/ whose
#      name survives quote and backslash removal is in the reviewed allowlist
#      below. A new call site - which is what "a new automatic caller" looks
#      like in the diff - is not in the allowlist, so it fails. Rule 4 is the
#      general one; rules 1-3 pin the specific surfaces this fork had to remove.
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
# line too, and so does prose that merely reads like one. That cost is four
# lines today, and it is the right trade: a reviewer adding an entry has to say
# why the line cannot delete a branch, which is the question the check exists to
# force.
#
# Three of those four are the price of one deliberate widening. Rules 2 and 3
# used to scan from `git` up to the first `;`, `|` or `&`, to stop the match at
# what looked like the end of the git command. That exclusion was itself the
# grammar-modelling this header rejects, one level down: those characters are
# separators only when the shell reads them as such, and inside a quoted
# argument they are ordinary text. Measured against the excluding form,
# `git -C "/tmp/a;b" branch -D "$b"` passed rule 2 unreviewed, and
# `git -C "/tmp/a;b" reset --hard HEAD` passed rule 3. Both rules now scan the
# whole line, which cannot be wrong about where a command ends because it does
# not ask. The three extra entries are prose that names a branch after a `git`
# earlier on the line; each reason says which git command actually runs there.
#
# All three rules match through probe_filter, on the line with quote and
# backslash characters removed. Rules 2 and 3 gained that with rule 4: measured
# against the raw-line form, `git -C "$PROJ" "branch" -D "$b"`,
# `git -C "$PROJ" bra"nch" -D "$b"` and `"rm" -rf "$d"` all ran and all passed.
# One normalization for all three is the point - a hole found in any rule's
# reading of the shell is closed in every rule at once.
#
# Rule 4 matches a NAME rather than a verb, and that is its boundary. It reads
# the logical line with quote and backslash characters removed, so every way of
# writing the name that the shell resolves while parsing is caught, not just the
# contiguous one: `"$D/fm-""teardown.sh"`, `"$D/fm-tear"'down.sh'` and
# `$D/fm-tear\down.sh` all run the same helper and all match. Removing those
# characters can only join text that was already adjacent, so it adds hits and
# never drops one. Reaching the helper through a variable is caught as well,
# because the assignment names it: measured, `helper="$D/fm-teardown.sh"`
# followed by `"$helper" "$id" --force` fails rule 4 on the assignment.
#
# What rule 4 cannot see is a name the shell assembles at RUN time out of
# fragments that never appear together in the source - `"${p}teardown.sh"`, an
# array element built in a loop, an `eval` over a computed string. No scan of
# the text reaches those, and the answer is not to parse harder: the modelling
# that loses git's option grammar above loses shell expansion by a wider margin,
# and a scan that believes it resolves expansions fails open the first time it
# is wrong. Rule 4 is a guardrail against the call site somebody adds without
# thinking - which is what a new automatic caller has actually looked like in
# this fork - and not a sandbox against one written to evade it.
#
# Rules 2 and 3 share that boundary and do not escape it by matching a verb:
# `g=git; $g branch -D "$b"` spells neither `git branch` nor a removal verb the
# scan can see. What differs is the blast radius of the residue, not its
# existence. Any check made of text has this edge; the useful question is
# whether the ordinary spelling fails closed, and after these rules it does.
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

# Helpers whose whole job is destructive or irreversible. A reference to one is
# a call site until the allowlist says otherwise.
#
# Matched through probe_filter, so quote and backslash characters are gone
# before matching: measured against the contiguous-only form,
# `"$SCRIPT_DIR/fm-""teardown.sh" "$id" --force`,
# `"$SCRIPT_DIR/fm-tear"'down.sh' "$id" --force` and
# `$SCRIPT_DIR/fm-tear\down.sh "$id" --force` all reached fm-teardown.sh and all
# passed rule 4 unreviewed.
#
# The one two-word name matches its separator as `[[:space:]]+`, not a literal
# space: `fm-remote-secondmate-control.sh   retire` retires the remote half just
# as the single-spaced spelling does, and EXEC_LINES preserves internal
# whitespace, so a literal space here reads reindentation as a different command.
DESTRUCTIVE_RE='fm-teardown\.sh|fm-pr-merge\.sh|fm-merge-local\.sh|fm-remote-secondmate-control\.sh[[:space:]]+retire'

# Rule 2 inverted: every `git branch` invocation, whatever its options. Matching
# the verb rather than a delete option is what makes an unanticipated spelling
# fail closed - see the header on why reading the option run cannot be made
# correct.
#
# `git.*`, not `git[^;|&]*`. Stopping the scan at the first `;`, `|` or `&` was
# an attempt to end the match at the end of the git command, and it was the
# header's own failure mode: it modelled a subset of the shell's grammar and fell
# open at the boundary of the subset, because those characters are separators
# only when the shell reads them as such. Measured against the excluding form,
# `git -C "/tmp/a;b" branch -D "$b"` and its `|` and `&` variants all passed rule
# 2 unreviewed - a quoted path is an argument, not a boundary. Widening costs the
# three prose lines reviewed below, and buys a rule that does not need to know
# where a command ends.
BRANCH_RE='git.*[[:space:]]branch([[:space:]]|$)'

# Lines outside teardown that read as a `git branch` invocation and have been
# read and found not to delete anything, as "<path><TAB><normalized line><TAB>
# <reason>", normalized the same way as ALLOWLIST below. Tracked bin/ has
# exactly two real `git branch` invocations and both are the sanctioned
# deletions in bin/fm-teardown.sh, so every entry here is prose: the word
# "branch" reached by BRANCH_RE's `.*` from a `git` earlier on the same line,
# inside an echo or after the `||` of a rev-parse. That is the price of not
# guessing where a command ends, and each reason below says which git command
# actually runs on the line and why it cannot delete a ref.
BRANCH_ALLOWLIST=$(
  cat <<'ENTRIES'
bin/fm-bootstrap.sh	echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"	one echo whose text happens to put the word "branch" after a `git checkout` suggestion; it runs no git command
bin/fm-merge-local.sh	git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }	the only git command on the line is rev-parse --verify --quiet, a read that resolves a ref name; the word "branch" is in the echo of its failure path, which exits
bin/fm-promote.sh	echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"	one echo printing the next command for the founder to run; the git verbs and "create branch" are prose inside its quoted instruction text, and nothing on the line executes
bin/fm-review-diff.sh	git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }	the same read-then-exit shape as fm-merge-local.sh above, against the worktree rather than the project
ENTRIES
)

# Rule 3 inverted: every verb reaching the sweep that can destroy work, whatever
# its options, so the reviewed lines below are the only ones that may run.
# Matching the verb rather than the invocation is what makes an unanticipated
# spelling fail closed.
#
# "Destroy work" is wider than "delete", and wider than "git". Nothing about an
# unattended sweep makes `truncate -s 0 "$PROJ/notes.md"` safer than
# `git -C "$PROJ" checkout -f`, so the plain-shell overwrites are here too:
# truncate, dd, tee, install, cp, mv and ln all replace a named file's contents,
# and the redirect that does the same thing is handled by probe_filter's
# truncating-redirect test rather than by a verb, since it has no verb of its
# own. Adding those seven cost zero reviewed entries - the sweep writes no files
# outside git - so there was no tradeoff to weigh, only an omission to close.
#
# Discarding an uncommitted edit loses it
# as completely as removing the file does, so the git verbs cover the ref and
# path removals (branch, worktree, clean, gc, prune, reflog, update-ref, repack,
# tag, replace, notes), the ones that overwrite or move the working tree or the
# index (reset, checkout, restore, switch, stash, merge, rebase, cherry-pick,
# revert, am, apply, read-tree, sparse-checkout, submodule, update-index, mv,
# bisect), the ones that rewrite history or where a ref points (filter-branch,
# symbolic-ref, remote), and push, which deletes a remote branch by `--delete`
# or by a colon refspec that names no local side. Each is flagged on the verb
# alone; a reviewed line says why that occurrence cannot lose anything.
#
# The list is the enforceable form of the rule, and it is a list, so state the
# residue plainly rather than implying it away: a git verb outside it is not
# reviewed. The alternative was measured rather than argued. Flagging every
# `git` in the sweep needs no list and cannot be incomplete, and it costs 20
# reviewed entries on today's sweep, all but one of them plain reads
# (`rev-parse`, `show-ref`, `merge-base`, `rev-list`, `fetch --prune`) plus one
# false hit on an `echo`. Twenty entries of reads is not a stricter gate; it is
# the same gate with the reviewed set diluted until nobody reads it, and it
# re-reviews on every read somebody adds. So the verbs are enumerated, the class
# is stated above so a reader can judge what is missing rather than guess, and
# adding one is a one-line change with a measured cost - this round added
# fourteen verbs for four entries.
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
#
# The git alternative reads `git.*` for the reason given on BRANCH_RE: the same
# separator exclusion stood here, and `git -C "/tmp/a;b" reset --hard HEAD`,
# `git -C "/tmp/a|b" worktree remove wt` and `git -C "/tmp/a&b" checkout -f HEAD`
# all passed rule 3 unreviewed. That widening cost the sweep nothing, since it
# has no prose naming a git verb; the four entries below beyond the original
# three are the cost of the verb class, not of `git.*`.
SWEEP_FORBIDDEN='(^|[^[:alnum:]_.-])(rm|rmdir|unlink|shred|truncate|dd|tee|install|cp|mv|ln)([[:space:]]|$)|git.*[[:space:]](branch|worktree|clean|gc|prune|reflog|update-ref|reset|checkout|restore|switch|stash|push|merge|rebase|cherry-pick|revert|am|apply|read-tree|sparse-checkout|submodule|filter-branch|replace|notes|tag|update-index|repack|symbolic-ref|remote|bisect|mv)([[:space:]]|$)|-delete([[:space:]]|$)|-exec[[:space:]]+[^[:space:]]*rm'

# The sweep's reviewed lines, as "<normalized line><TAB><reason>", normalized
# the same way as ALLOWLIST below. Every reason has to hold for the sweep's
# unattended context: nothing here may destroy work.
SWEEP_ALLOWLIST=$(
  cat <<'ENTRIES'
if ! rm -f "$lock"; then	a single non-recursive rm -f of a provably-stale .git/packed-refs.lock, which holds no work
git -C "$PROJ" worktree list --porcelain 2>/dev/null | sed -n 's#^branch refs/heads/##p' | grep -Fxq -- "$DEFAULT"	a read: the whole pipeline lists worktrees and asks whether one holds the default branch, removing none
if ! git -C "$PROJ" checkout --quiet "$DEFAULT" 2>/dev/null; then	re-attaches a detached HEAD the branch above has already proven clean, free of unique commits, and an ancestor of the base; --quiet is not --force, so git aborts rather than overwrite, and every other drift is reported and left untouched
ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)	a read: symbolic-ref with no ref-and-value pair and no --delete resolves origin/HEAD and prints it; the || true swallows the failure when it is unset
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")	the same read against HEAD, asking which branch is checked out before deciding anything; it writes nothing and its failure path yields the empty string
if ! git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then	a read: the get-url subcommand prints a remote URL, and the failure branch reports "no origin remote" and returns; remote is flagged for its remove, prune and set-url subcommands, which this line does not use
if ! merge_output=$(git -C "$PROJ" merge --ff-only "$BASE" 2>&1); then	the only line in the sweep that writes the working tree: --ff-only refuses to merge and exits non-zero unless the local ref is already an ancestor of the base, so it can only advance a branch that has no commits of its own, and the lines above have already proven the tree clean, the branch an ancestor, and the base a real commit; the failure path reports and returns without a second attempt
echo "usage: fm-fleet-sync.sh [<project-dir-or-name>]" >&2	the > is prose inside the usage text, in the placeholder <project-dir-or-name>; the line's only real redirect is >&2, a descriptor duplication that names no file
echo "$label: removed provably-stale packed-refs lock $lock (age >= ${FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS}s, no live holder) and retrying fetch" >&2	the > is prose inside the message text, in the comparison >=; the line's only real redirect is >&2, which names no file
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

# Reads "<path><TAB><lineno><TAB><line>" records on stdin and prints the ones
# whose *probe* matches $1, where the probe is the line with quote and backslash
# characters removed. Every rule matches through here, so all three share one
# answer to "what does the shell read this line as".
#
# Removal, not blanking: the shell deletes those characters while parsing, so
# `git "branch" -D` runs git's branch verb and `fm-tear\down.sh` runs
# fm-teardown.sh. Blanking would keep the two halves apart and miss both. The
# removal only ever adds hits - deleting characters can only bring text together,
# never separate it - so no rule loses a match it had before, and the shipped
# tree gains none. See the header for the residue removal does not reach.
#
# One awk pass rather than grep, because the match is on the probe while the
# printed record is the original line: an allowlist entry has to quote the source
# a reviewer reads, not a stripped rewrite of it.
#
# The probe is the third field alone. A record is "<path><TAB><lineno><TAB><code>",
# and matching the whole record lets one rule read half its pattern out of the
# path: `bin/git-notes.sh` carrying `printf '%s\n' " branch "` satisfies
# BRANCH_RE's `git` from the path and its ` branch ` from the code, and rules 2
# and 3 have no second test - unlike rule 4, which re-checks $code in the loop -
# so the check reports a line as running `git branch` when it runs no git at all.
# The direction is fail-closed, but the remedy a maintainer reaches for is an
# allowlist entry, and that entry then permanently licenses a line under a reason
# that was never true. Fields, not characters: cutting on whitespace would eat
# the code's first word and turn `git branch -D "$b"` into ` branch -D "$b"`,
# which BRANCH_RE no longer matches - a miss, which is the direction this check
# does not get to have.
#
# A non-empty $2 adds the truncating-redirect test, and only rule 3 passes it: a
# redirect destroys the file it names, so it belongs to the sweep's question and
# not to "does this line delete a branch" or "does it invoke a teardown helper".
# It is subtractive rather than a pattern, because the dangerous form is the bare
# one and it is the safe spellings that are enumerable: strip the appends
# (">>", "&>>", which add and cannot truncate), the descriptor duplications
# (">&2", "2>&1", ">&-", which name no file), and the writes to /dev/null, and
# any ">" still standing truncates something. "&>" is deliberately not stripped
# with the appends - it redirects both streams and truncates while doing it - and
# ">|" needs no case of its own, since overriding noclobber leaves its ">" behind.
probe_filter() {
  # shellcheck disable=SC2016 # awk owns every $ expression in this literal program.
  FM_PROBE_RE=$1 FM_PROBE_REDIR=${2-} awk '
    BEGIN {
      SQ = sprintf("%c", 39)
      re = ENVIRON["FM_PROBE_RE"]
      redir = ENVIRON["FM_PROBE_REDIR"]
    }
    {
      probe = $0
      sub(/^[^\t]*\t[^\t]*\t/, "", probe)
      gsub(/"/, "", probe)
      gsub(SQ, "", probe)
      gsub(/\\/, "", probe)
      if (probe ~ re) { print; next }
      if (redir != "") {
        rd = probe
        gsub(/&?>>/, "", rd)
        gsub(/>&[0-9-]/, "", rd)
        gsub(/&?[0-9]?>[[:space:]]*\/dev\/null/, "", rd)
        if (rd ~ />/) { print }
      }
    }
  ' || true
}

# Exact-key membership in a "<key><TAB>...<TAB><reason>" allowlist. The key is
# "<path><TAB><normalized line>" for rules 2 and 4 and the normalized line alone
# for rule 3.
#
# The match is anchored at both ends: `case` matches an entry from its first
# character, and the trailing TAB ends the key field. A substring test - which
# is what `grep -F` gives - is anchored at neither, so a hit that is merely a
# *suffix* of a reviewed line inherits that line's approval. Suffix is the
# dangerous direction, because a reviewed line is usually longer than the bare
# destructive command it wraps: rule 3's reviewed sweep checkout is safe
# precisely because of the `if !` guard its reason cites, and dropping that
# guard leaves a suffix of the reviewed line. Measured against the unanchored
# form, both `git -C "$PROJ" checkout --quiet "$DEFAULT" 2>/dev/null; then` and
# `rm -f "$lock"; then` passed rule 3 unreviewed.
#
# Rules 2 and 4 were not exploitable that way today, but only because their key
# starts with a path and no tracked bin/ path is a suffix of another - a
# property of the tree, not a guarantee of the test. They are anchored here too.
allow_has() {
  allow_list=$1
  allow_key=$2
  while IFS= read -r allow_entry; do
    case $allow_entry in
      "$allow_key$TAB"*) return 0 ;;
    esac
  done <<<"$allow_list"
  return 1
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
  if allow_has "$BRANCH_ALLOWLIST" "${file}${TAB}${norm}"; then
    continue
  fi
  fail "${file}:${lineno} runs git branch, which can delete one; only $TEARDOWN may, and this is not a reviewed line:"
  printf '  %s\n' "$norm" >&2
  printf '  If it cannot delete a branch, add it to BRANCH_ALLOWLIST in bin/fm-destructive-automation-check.sh with a reason that says why.\n' >&2
done <<EOF
$(printf '%s\n' "$EXEC_LINES" | probe_filter "$BRANCH_RE")
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
    if allow_has "$SWEEP_ALLOWLIST" "$norm"; then
      continue
    fi
    fail "${SWEEP}:${lineno} can destroy work - remove a branch, a worktree, or a path, or overwrite the working tree - and is not one of the startup sweep's reviewed lines:"
    printf '  %s\n' "$norm" >&2
    printf '  The startup sweep runs unattended on every boot. Remove it, or add it to SWEEP_ALLOWLIST in bin/fm-destructive-automation-check.sh with a reason that says why it cannot destroy work.\n' >&2
  done <<EOF
$(printf '%s\n' "$EXEC_LINES" | grep -E -- "^${SWEEP}${TAB}" | probe_filter "$SWEEP_FORBIDDEN" redirect)
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
  #
  # Matched on the probe, not the line, the same way probe_filter matches: quote
  # and backslash characters are the shell's, removed before matching so a name
  # split across them still reads as one. The allowlist key below stays the
  # untouched line, so an entry quotes the source a reviewer has to judge.
  probe=${code//\"/}
  probe=${probe//\'/}
  probe=${probe//\\/}
  [[ $probe =~ $DESTRUCTIVE_RE ]] || continue

  norm=$(printf '%s\n' "$code" | awk '{ $1 = $1; print }')
  CALL_SEEN="${CALL_SEEN}${file}${TAB}${norm}${NL}"
  if ! allow_has "$ALLOWLIST" "${file}${TAB}${norm}"; then
    fail "${file}:${lineno} reaches a destructive helper and is not in the reviewed allowlist:"
    printf '  %s\n' "$norm" >&2
    printf '  Add it to ALLOWLIST in bin/fm-destructive-automation-check.sh with a reason that says why no automatic path reaches it.\n' >&2
  fi
done <<EOF
$(
  # The pre-filter matches the same probe the loop re-derives, so a name split
  # across quotes reaches the loop with its source intact.
  printf '%s\n' "$EXEC_LINES" | probe_filter "$DESTRUCTIVE_RE"
)
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
