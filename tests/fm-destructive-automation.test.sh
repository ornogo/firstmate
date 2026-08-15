#!/usr/bin/env bash
# Regression tests for bin/fm-destructive-automation-check.sh.
#
# The property under test is that no automatic path in this fork can delete
# somebody's work. The repository source tree IS that contract, so these tests
# run the real check over a faithful copy of tracked bin/ and then mutate one
# thing at a time. Each negative case is a reversible semantic mutation that
# reintroduces exactly one of the surfaces the fork removed, so a check that
# silently stopped enforcing a rule fails here instead of passing quietly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-destructive-automation-check.sh"

[ -x "$CHECK" ] || fail "bin/fm-destructive-automation-check.sh must exist and be executable"

# bin_fixture: a fresh git repo holding a copy of this repo's tracked bin/
# files. Copying rather than synthesizing keeps the real reviewed allowlist in
# play, so a mutation is measured against the same lines the check ships with.
# One fixture per mutation, and there are two dozen mutations, so the first
# call builds a template and the rest copy it wholesale. Re-running git init
# and a 140-file add per fixture dominated this test's runtime.
FIXTURE_TEMPLATE=""

bin_fixture() {
  local root repo f dir
  if [ -z "$FIXTURE_TEMPLATE" ]; then
    root=$(fm_test_tmproot fm-destructive-automation-template) || return 1
    repo="$root/repo"
    mkdir -p "$repo" || return 1
    git -C "$repo" init -q || return 1
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      dir=$(dirname "$f")
      mkdir -p "$repo/$dir" || return 1
      cp "$ROOT/$f" "$repo/$f" || return 1
    done < <(git -C "$ROOT" ls-files -- 'bin/*')
    git -C "$repo" add -A >/dev/null 2>&1 || return 1
    FIXTURE_TEMPLATE=$repo
  fi
  root=$(fm_test_tmproot fm-destructive-automation) || return 1
  cp -R "$FIXTURE_TEMPLATE" "$root/repo" || return 1
  printf '%s\n' "$root/repo"
}

# run_check <repo>: stdout+stderr of the check over <repo>, with its exit code
# appended as a final "rc=<n>" line so a test can assert on both.
run_check() {
  local out rc
  out=$("$CHECK" --root "$1" 2>&1)
  rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}

# --- the shipped tree passes ------------------------------------------------

out=$("$CHECK" 2>&1) || fail "the check must pass on this repository"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "fm-destructive-automation-check: ok scripts=" \
  "a passing run must report the number of scripts it scanned"
assert_contains "$out" "reviewed_call_sites=" \
  "a passing run must report how many destructive call sites are allowlisted"
# Rule 3's verb class is a list, so the number of sweep lines it licenses is the
# list's price. Pinning it means widening the class without reading the lines it
# newly catches fails here rather than passing quietly with a bigger allowlist.
assert_contains "$out" "reviewed_sweep_lines=10" \
  "the shipped sweep must license its ten reviewed lines, not silently more"$'\n'"--- output ---"$'\n'"$out"
pass "the shipped tree has no unreviewed destructive automation"

# --- the fixture is a faithful basis ----------------------------------------

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"

# The check is itself a tracked bin/ script, so it is inside its own scan basis.
# It was not while it was still untracked, and that gap is what let it report a
# clean run over a tree it would fail the moment it was committed. Assert the
# fixture holds it, so a future change that drops it from the basis fails here
# rather than restoring that false green.
[ -f "$FIXTURE/bin/fm-destructive-automation-check.sh" ] || \
  fail "the fixture must contain the check script itself; the check has to survive scanning its own source"

out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "an unmutated copy of tracked bin/ must pass, or every mutation below proves nothing"$'\n'"--- output ---"$'\n'"$out"
pass "an unmutated copy of tracked bin/, the check's own source included, passes the check"

# --- rule 1: prune_gone_branches cannot come back ---------------------------
#
# The surface this fork removed. Upstream deleted every local branch whose
# remote counterpart was gone, which includes a PR closed WITHOUT merging, so a
# closed PR destroyed its unpushed commits. The mutation reintroduces the name
# with a harmless body, which isolates rule 1 from rules 2 and 3.

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

prune_gone_branches() {
  echo "would prune"
}
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "reintroducing prune_gone_branches must fail the check"
assert_contains "$out" "prune_gone_branches must not exist in this fork" \
  "the failure must name prune_gone_branches"
pass "rule 1: reintroducing prune_gone_branches fails"

# Rule 1 reads prose as well as code, so the check that bans the name has to be
# allowed to write it - otherwise it fails on its own rule text. The exclusion
# is by exact path, and these two cases are what say so: the same words are
# legal in the check and illegal one file over.

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-destructive-automation-check.sh" <<'EOF'

# prune_gone_branches is the surface this rule exists to keep out.
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "the check that bans prune_gone_branches must be allowed to name it"$'\n'"--- output ---"$'\n'"$out"
pass "rule 1: the check may name the function it bans"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-teardown.sh" <<'EOF'

# prune_gone_branches would be handy here.
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "naming prune_gone_branches outside the check must still fail, even in a comment"
assert_contains "$out" "bin/fm-teardown.sh" "the failure must name the offending file"
pass "rule 1: the exclusion is by exact path, not by wording"

# --- rule 2: branch deletion stays inside founder-run teardown --------------

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

git -C "$PROJ" branch -D -- "$stale"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "deleting a branch outside teardown must fail the check"
assert_contains "$out" "runs git branch, which can delete one; only bin/fm-teardown.sh may" \
  "the failure must name the one sanctioned home for branch deletion"
assert_contains "$out" "bin/fm-bootstrap.sh:" "the failure must name the offending file"
pass "rule 2: deleting a local branch outside founder-run teardown fails"

# `git branch -D` is one spelling of branch deletion, not the definition of it.
# A rule that recognized only the spellings the fork happens to use today would
# pass on the identical deletion written the other legal way, which is a
# fail-open hole in a fail-closed check. Each of these is a real git invocation
# that deletes a local branch, and each must fail on its own.
#
# The last two are why rule 2 flags the verb instead of reading the option run.
# `--sort` and `--format` take a space-separated argument, so the option run is
# `--sort committerdate -D`, and any pattern that walks it stops at
# `committerdate`, which does not begin with a hyphen. Both were verified
# against real git (2.50.1): each prints "Deleted branch" and exits 0.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
BRANCH_SPELLINGS=(
  'git -C "$PROJ" branch -df "$stale"'
  'git -C "$PROJ" branch --force --delete "$stale"'
  'git -C "$PROJ" branch --force -D "$stale"'
  'git -C "$PROJ" branch -d --force "$stale"'
  'git -C "$PROJ" branch --delete "$stale"'
  'git -C "$PROJ" branch --sort committerdate -D "$stale"'
  'git -C "$PROJ" branch --format "%(refname)" -D "$stale"'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-bootstrap.sh"
printf '%s\n' "${BRANCH_SPELLINGS[@]}" >> "$FIXTURE/bin/fm-bootstrap.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "branch deletion in any option form must fail"$'\n'"--- output ---"$'\n'"$out"
# The check reports every finding, so one run says which spellings it caught -
# and, by omission, which one it would have let through.
for spelling in "${BRANCH_SPELLINGS[@]}"; do
  assert_contains "$out" "$spelling" \
    "branch deletion written as \`$spelling\` must be caught like any other spelling"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 2: every option form that deletes a branch fails, not just -D"

# The stated cost of flagging the verb: a read-only `git branch` outside
# teardown needs a reviewed line too. That is the trade, so it has to be the
# tested behaviour rather than an aspiration - a check that quietly let
# read-only forms through would be reading the option run again, with the hole
# that comes with it. The failure has to say what to do about it, because a
# reviewer meeting this for the first time is the whole audience for the rule.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

git -C "$PROJ" branch --show-current
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an unreviewed git branch invocation must fail even when it only reads"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "add it to BRANCH_ALLOWLIST" \
  "the failure must tell the reviewer how to license a line that cannot delete"
pass "rule 2: a read-only git branch still needs a reviewed line"

# And the allowlist has to actually license one, or the rule is unusable and the
# next reviewer weakens it instead. The shipped tree carries exactly one entry -
# an fm-bootstrap.sh echo whose text puts "branch" after a `git checkout`
# suggestion - so a clean fixture passing is that entry doing its job. Keyed per
# line, not per file: a real deletion added to the same file still fails.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
out=$(run_check "$FIXTURE")
assert_contains "$out" "reviewed_branch_lines=4" \
  "the shipped tree must license its four reviewed branch lines, not zero"$'\n'"--- output ---"$'\n'"$out"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

git -C "$PROJ" branch -D -- "$stale"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "the branch allowlist must license a line, not the file holding it"$'\n'"--- output ---"$'\n'"$out"
pass "rule 2: the branch allowlist licenses a line, not a whole file"

# The same deletion inside teardown is the sanctioned path and must stay legal,
# or rule 2 would just be banning branch deletion outright.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-teardown.sh" <<'EOF'

git -C "$WT" branch -D "$another"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "founder-run teardown must still be allowed to delete a branch"$'\n'"--- output ---"$'\n'"$out"
pass "rule 2: founder-run teardown may still delete a branch"

# Rule 2 skips the check's own source, and the reason is structural rather than
# a convenience: BRANCH_ALLOWLIST stores each exemption by quoting the line it
# exempts, so every entry is itself a `git branch` line in this file, and an
# entry licensing that entry would be one too. There is no fixed point, so the
# file holding the licences cannot be audited by the rule they license.
#
# That exemption has to stay narrow, which is what this case pins: it is by
# exact path, not by wording. The identical line in any other bin/ script still
# fails, so "skip the file that stores the allowlist" cannot widen into "skip
# anything that looks like the check".
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-destructive-automation-check.sh" <<'EOF'

git -C "$PROJ" branch -D -- "$stale"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "rule 2 must skip the file that stores its own allowlist"$'\n'"--- output ---"$'\n'"$out"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cp "$FIXTURE/bin/fm-destructive-automation-check.sh" "$FIXTURE/bin/fm-copy-of-the-check.sh"
cat >> "$FIXTURE/bin/fm-copy-of-the-check.sh" <<'EOF'

git -C "$PROJ" branch -D -- "$stale"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "the exemption must be the path, not the file's contents"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "bin/fm-copy-of-the-check.sh:" \
  "the failure must name the copy, which is not the exempt path"
pass "rule 2: the exclusion is by exact path, not by wording"

# --- rule 3: the startup sweep deletes nothing ------------------------------
#
# bin/fm-bootstrap.sh backgrounds this sweep on every boot, so anything it can
# delete, it deletes unattended and with no founder present.

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" worktree remove "$wt"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "removing a worktree from the startup sweep must fail the check"
assert_contains "$out" "The startup sweep runs unattended on every boot" \
  "the failure must say why the startup sweep is held to this rule"
pass "rule 3: removing a worktree from the startup sweep fails"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

rm -rf "$PROJ/.git/rebase-merge"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "a recursive removal in the startup sweep must fail the check"
# shellcheck disable=SC2016 # The expected text is the fixture's source line, not an expansion.
assert_contains "$out" 'rm -rf "$PROJ/.git/rebase-merge"' \
  "the failure must quote the offending line"
pass "rule 3: a recursive removal in the startup sweep fails"

# Rule 3 is inverted, so it must catch removals nobody thought to enumerate.
# Each of these is the same deletion as a case above, written the other legal
# way; a rule that listed spellings would pass every one of them.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_SPELLINGS=(
  'rm --recursive --force "$PROJ/.git/rebase-merge"'
  'git -C "$PROJ" worktree --force remove "$wt"'
  'git -C "$PROJ" worktree prune'
  'git -C "$PROJ" clean -xfd'
  'find "$PROJ/.git" -name "*.lock" -delete'
  'find "$PROJ" -type d -exec rm -rf {} +'
  'rmdir "$PROJ/.git/worktrees/$wt"'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_SPELLINGS[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "removals in the startup sweep must fail"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "not one of the startup sweep's reviewed lines" \
  "the failure must say the line is unreviewed"
for spelling in "${SWEEP_SPELLINGS[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: every removal-capable spelling in the startup sweep fails"

# Destroying work is wider than deleting it. Each of these overwrites or moves
# the working tree, or drops a ref, without naming a removal verb, so a rule
# that only watched for deletions would let an unattended boot discard whatever
# was uncommitted in the clone.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_OVERWRITES=(
  'git -C "$PROJ" reset --hard "$BASE"'
  'git -C "$PROJ" checkout -f "$DEFAULT"'
  'git -C "$PROJ" restore --staged --worktree .'
  'git -C "$PROJ" switch --discard-changes "$DEFAULT"'
  'git -C "$PROJ" stash clear'
  'git -C "$PROJ" update-ref -d "refs/heads/$b"'
  'git -C "$PROJ" push origin :"refs/heads/$b"'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_OVERWRITES[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "working-tree-overwriting git verbs in the startup sweep must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_OVERWRITES[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: a git verb that overwrites the working tree or drops a ref fails"

# Naming a command by absolute path is an ordinary way to invoke it, and the
# unattended sweep is exactly where one would sit. The boundary before the
# removal verbs must therefore admit the `/`, or every one of these is a hole.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_QUALIFIED=(
  '/bin/rm -rf "$PROJ/.git/rebase-merge"'
  '/usr/bin/rmdir "$PROJ/.git/worktrees/$wt"'
  'find "$PROJ" -type d -exec /bin/rm -rf {} +'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_QUALIFIED[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a path-qualified removal in the startup sweep must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_QUALIFIED[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: a removal named by absolute path in the startup sweep fails"

# Nothing about an unattended sweep makes `truncate -s 0` safer than
# `git checkout -f`. These replace a named file's contents without naming a
# removal verb and without going through git at all, so a rule that watched only
# git and only deletions left the ordinary way to destroy a file wide open.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_PLAIN_OVERWRITES=(
  'truncate -s 0 "$PROJ/notes.md"'
  'dd if=/dev/zero of="$PROJ/notes.md"'
  'tee "$PROJ/notes.md" < /dev/null'
  'install /dev/null "$PROJ/notes.md"'
  'cp -f /dev/null "$PROJ/notes.md"'
  'mv /tmp/staged "$PROJ/notes.md"'
  'ln -sf /tmp/staged "$PROJ/notes.md"'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_PLAIN_OVERWRITES[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "plain-shell overwrites in the startup sweep must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_PLAIN_OVERWRITES[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: a plain-shell overwrite in the startup sweep fails"

# The redirect is the one destructive form with no verb to match, so it gets its
# own test rather than an entry in the verb list. The dangerous spelling is the
# bare one and the safe spellings are the enumerable ones, so the test strips the
# appends, the descriptor duplications and the writes to /dev/null, and treats
# whatever `>` is left as a truncation. `&>` is the case worth stating: it is not
# an append despite the doubled character, and it truncates both streams into the
# file it names.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_TRUNCATING_REDIRECTS=(
  'printf %s "" > "$PROJ/notes.md"'
  ': > "$PROJ/notes.md"'
  'cat /tmp/staged &> "$PROJ/notes.md"'
  'printf %s x >| "$PROJ/notes.md"'
  'git -C "$PROJ" log --oneline 2> "$PROJ/notes.md"'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_TRUNCATING_REDIRECTS[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a truncating redirect in the startup sweep must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_TRUNCATING_REDIRECTS[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: a truncating redirect in the startup sweep fails"

# The paired legal case. A redirect that appends, names a descriptor rather than
# a file, or writes to /dev/null destroys nothing, and a redirect test that could
# not tell those from a truncation would either fail the shipped tree or be
# switched off. Two of the three are already pinned by the shipped-tree assertion
# above, because the sweep is full of `>&2` and `>/dev/null` - drop either of
# those from the test and the shipped tree fails before this fixture is reached.
# The append is not: the sweep contains no `>>` at all, so this is the only thing
# standing between an append and a false finding. It is mutation-proved on
# exactly that mutant - deleting the append strip leaves the shipped tree green
# and turns this case rc=1. `&>>` is the reason to spell the pair out: `&>` is a
# truncation despite the ampersand, and doubling the `>` does make this one an
# append.
#
# `>&10` is a fourth that nothing upstream pins. The strip has to read the whole
# digit run, because stopping after one digit leaves the `0` standing and turns a
# descriptor duplication into a finding. It is mutation-proved on exactly that
# single-digit mutant, which leaves the shipped tree green because the sweep
# duplicates only single-digit descriptors.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_SAFE_REDIRECTS=(
  'printf %s x >> "$PROJ/fleet-sync.log"'
  'printf %s x &>> "$PROJ/fleet-sync.log"'
  'git -C "$PROJ" status --porcelain >/dev/null 2>&1'
  'echo "sync complete" >&2'
  'git -C "$PROJ" rev-parse HEAD 2>&-'
  'git -C "$PROJ" log --oneline >&10'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_SAFE_REDIRECTS[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "appends, descriptor redirects and /dev/null writes must stay legal in the startup sweep"$'\n'"--- output ---"$'\n'"$out"
pass "rule 3: a redirect that destroys nothing stays legal in the startup sweep"

# The other side of a subtractive test: an exemption that matches a *prefix* of
# the target deletes the `>` that a longer name still truncates. Both exemptions
# had that shape and both were reachable. `>&2foo` is not a descriptor
# duplication - bash duplicates only when the word is all digits or `-`, and
# otherwise sends both streams to the file named by the word, so `echo hi >&2foo`
# truncates ./2foo - and `/dev/null.backup` is an ordinary file that happens to
# start with the null device's name. `/dev/nullify` is the same hole without the
# separator, so the boundary cannot simply be punctuation. All three are rc=0 on
# the check extracted from `e6e7122` and rc=1 now, which is this fixture's
# receipt; no mutant is needed, because the shipped check is the mutant.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_PREFIX_BYPASSES=(
  'printf %s x >/dev/null.backup'
  'printf %s x > /dev/nullify'
  'echo hi >&2foo'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_PREFIX_BYPASSES[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a redirect target that merely starts with an exempt name must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_PREFIX_BYPASSES[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: a target that merely starts with an exempt name still fails"

# A verb list only covers the verbs somebody thought of, and the first list
# thought only of removals. Every spelling here rewrites a file that is already
# there without deleting anything and without a truncating `>`, so all eight were
# rc=0 on the check extracted from `1e16206`; they are rc=1 now, which is this
# fixture's receipt, and no mutant is needed because the shipped check is the
# mutant. The last one is the class that no widening of the other three reaches:
# `python3 -c` carries no destructive verb at all, so the interpreter name is the
# only static handle there is. `rsync --delete` is deliberately absent - it was
# already caught at `1e16206`, but by the `-delete` alternative meant for
# `find`, so putting it here would make the baseline rc=1 and prove nothing.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_INPLACE_MUTATORS=(
  'sed -i "" "s/x/y/" "$PROJ/notes.md"'
  'perl -pi -e "s/x/y/" "$PROJ/notes.md"'
  'awk -i inplace "{print}" "$PROJ/notes.md"'
  'ed -s "$PROJ/notes.md" < "$PROJ/cmds"'
  'patch -p1 -d "$PROJ" < "$PROJ/p.diff"'
  'sort -o "$PROJ/notes.md" "$PROJ/notes.md"'
  'gzip -f "$PROJ/notes.md"'
  'python3 -c "import pathlib; pathlib.Path(p).write_text(s)"'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_INPLACE_MUTATORS[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an in-place rewrite in the startup sweep must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_INPLACE_MUTATORS[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: overwriting a file in place is as destructive as removing it"

# The interpreter class is matched on the executable's name, and an executable's
# name ordinarily carries a version. Every spelling here was rc=0 on the check
# extracted from `b4aea22` - the trailing boundary wanted whitespace and got the
# `.` of `python3.12` or the `5` of `perl5.36` - and all four are rc=1 now, which
# is this fixture's receipt. Two of them, `python3.12` and `python2`, are the
# reported spelling's family; the other two are there because the hole was never
# python's, it belonged to every name in the group.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_VERSIONED_INTERPRETERS=(
  'python3.12 -c "import pathlib; pathlib.Path(p).unlink()"'
  'perl5.36 -pi -e "s/x/y/" "$PROJ/notes.md"'
  'ruby3.1 -i -e "gsub(/x/,0)" "$PROJ/notes.md"'
  'python2 -c "open(p,0).write(0)"'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_VERSIONED_INTERPRETERS[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a version-suffixed interpreter in the startup sweep must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_VERSIONED_INTERPRETERS[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: an interpreter keeps its name when it carries a version"

# The other side of that tolerance, and the reason it is spelled `[0-9]+(...)`
# rather than the shorter `[-.0-9]*`: a version has to start with a digit, or the
# rule stops reading English as English. `dd` and `cp` are both in the removal
# class, and a message that ends on one ends on a full stop - which the looser
# spelling eats, leaving the space behind it to satisfy the boundary. These are
# message lines rather than comments because rule 3 does not read comments, so a
# commented version of this case would pass either way and prove nothing; both
# were checked rc=1 under `[-.0-9]*` before being written down here.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
{
  printf '\n'
  # shellcheck disable=SC2016 # A source line written into a fixture, not a command this test runs.
  printf '%s\n' 'echo "$label: skipping, this project has no dd." >&2'
  # shellcheck disable=SC2016 # Likewise.
  printf '%s\n' 'echo "$label: nothing was copied by cp." >&2'
} >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "a sentence ending on a verb and a full stop is not a versioned executable"$'\n'"--- output ---"$'\n'"$out"
pass "rule 3: a version suffix must start with a digit, so prose stays prose"

# The fourth round in a row to find the verb list short, and the one that stops
# it being answered with more verbs. Each of these names its output in an option
# rather than in a destructive verb or a `>`, and five of the six went unreported
# by the check extracted from `45f4f3e`. The sixth, `dd if=/dev/zero of=`, is the
# control: the `dd` verb catches it on both checks, so the receipt here is the
# five named spellings and not the exit code, which was already 1 either way.
# The last three matter most: `ffmpeg`,
# `openssl` and `somevendortool` are in no list in this file and never will be,
# so they are the receipt that the alternative matching them reads a convention
# rather than a namespace. Delete that alternative and those three go quiet
# while the first two still fail, which is the failure this case exists to
# distinguish.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_OUTPUT_OPTION_WRITERS=(
  'curl -o "$PROJ/notes.md" "$url"'
  'wget -O "$PROJ/notes.md" "$url"'
  'ffmpeg -y -i a.mp4 -o "$PROJ/out.mp4"'
  'openssl enc --out "$PROJ/notes.md"'
  'somevendortool --output-file "$PROJ/notes.md"'
  'dd if=/dev/zero of="$PROJ/notes.md"'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_OUTPUT_OPTION_WRITERS[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a command that names its output in an option must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_OUTPUT_OPTION_WRITERS[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: an output option is caught whatever command carries it"

# The residue of reading a convention instead of a parse, pinned so it stays
# stated rather than discovered. `-o` is not always an output: the two spellings
# here are a shell option and a ps format, and neither names a file. Both are
# caught anyway, and the rule says so in its header - in the sweep they would
# each need a reviewed entry explaining that they write nothing. That is
# fail-closed and deliberate, so quieting them later has to break this case
# first. Both lines were rc=0 on the check extracted from `45f4f3e`.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
{
  printf '\n'
  printf '%s\n' 'set -o pipefail'
  # shellcheck disable=SC2016 # A source line written into a fixture, not a command this test runs.
  printf '%s\n' 'ps -p "$pid" -o command='
} >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an -o that names no file is still caught, and the header says why"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "set -o pipefail" \
  "the shell-option spelling must be the one reported"$'\n'"--- output ---"$'\n'"$out"
pass "rule 3: the output-option handle over-reads in the fail-closed direction"

# The attached form of the same option, which is how a single-letter option
# ordinarily takes its argument. All three went unreported by the check
# extracted from `8311115`, where the alternative wanted whitespace or `=` after
# the `-o` and the character after it is a quote or a `$`. `gcc` carries the
# case: it is in no verb list here and never will be, so requiring a separator
# handed the escape straight back to the commands the option handle exists to
# reach. The third line is the widened over-read, caught for the reason the
# header gives - a single-dash option that merely starts with `o` names no file
# and would need a reviewed entry saying so.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_ATTACHED_OUTPUT_OPTIONS=(
  'gcc input.c -o"$PROJ/tool"'
  'gcc input.c -o$PROJ/tool2'
  'ssh -oBatchMode=yes host true'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_ATTACHED_OUTPUT_OPTIONS[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an output option with its argument attached must fail"$'\n'"--- output ---"$'\n'"$out"
for spelling in "${SWEEP_ATTACHED_OUTPUT_OPTIONS[@]}"; do
  assert_contains "$out" "$spelling" \
    "\`$spelling\` in the startup sweep must be caught"$'\n'"--- output ---"$'\n'"$out"
done
pass "rule 3: a single-letter output option may carry its argument attached"

# The other side of that widening: a long option cannot take an attached
# argument, so the long forms keep the separator the short ones dropped, and
# `--outdated` is not `--out`. This is the only case standing between the long
# forms and the same treatment, so dropping their separator has to break it.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
{
  printf '\n'
  printf '%s\n' 'somevendortool --outdated --check >/dev/null'
} >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "a long option that merely starts with --out names no output file"$'\n'"--- output ---"$'\n'"$out"
pass "rule 3: the long output options keep the separator the short ones drop"

# The verb list holds `prune` and `push`, so the two forms the sweep is meant to
# keep have to be pinned from the other side: `--prune` on git fetch drops
# remote-tracking refs, which hold no work, and a read is a read. Both are
# spelled with no whitespace-preceded destructive verb, which is what keeps them
# out - so a future widening that reaches them breaks this case first.
# shellcheck disable=SC2016 # These are source lines written into a fixture, not commands this test runs.
SWEEP_LEGAL=(
  'git -C "$PROJ" fetch --prune origin'
  'git -C "$PROJ" status --porcelain'
  'git -C "$PROJ" rev-parse --verify --quiet HEAD'
)
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
printf '\n' >> "$FIXTURE/bin/fm-fleet-sync.sh"
printf '%s\n' "${SWEEP_LEGAL[@]}" >> "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "git fetch --prune and read-only git must stay legal in the startup sweep"$'\n'"--- output ---"$'\n'"$out"
pass "rule 3: git fetch --prune and read-only git stay legal in the startup sweep"

# The sweep's one permitted removal is a provably-stale packed-refs lock: a
# single non-recursive rm -f of a lock file, holding no work. It is permitted as
# that exact reviewed line, not as a class - "any rm -f is fine here" is how the
# next unattended deletion arrives wearing a safe-looking flag.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

rm -f "$another_lock"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a new unreviewed rm in the startup sweep must fail even in a non-recursive form"$'\n'"--- output ---"$'\n'"$out"
pass "rule 3: the reviewed removal is a line, not a licence for the verb"

# A second copy of the reviewed lock removal is a second removal, and the copy
# is somewhere nobody read: the reason on that entry is that THAT lock is
# provably stale, which says nothing about a lock somewhere else in the sweep.
# The reviewed line staying legal is proved by the unmutated fixture above,
# which contains it and passes; this case proves the approval does not travel
# with the text.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

reap_any_lock() {
  lock=$1
  if ! rm -f "$lock"; then
    echo "could not clear the lock" >&2
  fi
}
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a second copy of the reviewed lock removal must fail"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "SWEEP_ALLOWLIST has an entry that rule 3 matched 2 times" \
  "the failure must say the entry matched more than once"$'\n'"--- output ---"$'\n'"$out"
pass "rule 3: an entry licenses one occurrence, not every copy of its text"

# --- rule 4: every destructive call site is reviewed ------------------------

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

"$SCRIPT_DIR/fm-teardown.sh" "$id" --force
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "a new automatic caller of teardown must fail the check"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must say the call site is unreviewed"
assert_contains "$out" "bin/fm-bootstrap.sh:" "the failure must name the offending file"
pass "rule 4: a new automatic caller of a destructive helper fails"

# The allowlist is keyed by line, not by file. Without that, one reviewed entry
# would license every future call site in the same script - which is exactly
# how an automatic caller would slip into an already-allowlisted dispatcher.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-remote-secondmate-control.sh" <<'EOF'

"$SCRIPT_DIR/fm-teardown.sh" "$id" --now
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a new call site in an already-allowlisted file must still fail"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "bin/fm-remote-secondmate-control.sh:" \
  "the failure must name the already-allowlisted file"
pass "rule 4: the allowlist licenses a line, not a whole file"

# A merge helper reached automatically is the same class of loss as a branch
# delete: it rewrites the default branch with nobody watching.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-watch.sh" <<'EOF'

"$SCRIPT_DIR/fm-merge-local.sh" "$id"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "a watcher reaching a merge helper must fail the check"
assert_contains "$out" "bin/fm-watch.sh:" "the failure must name the watcher"
pass "rule 4: a watcher reaching a merge helper fails"

# A script re-invoking its own destructive verb is a real call site and must be
# caught like any other. This is a regression fixture: rule 4 used to strip a
# script's own name from the line before matching, on the theory that a file
# naming itself was usage text. That rewrote
# `fm-remote-secondmate-control.sh retire "$id"` inside its own file into
# ` retire "$id"`, which matches no destructive helper - so the one script whose
# retire verb tears down a remote secondmate was the one script allowed to call
# it unreviewed. The self-strip is gone; a file naming itself in usage text is
# the rarer case and belongs in the allowlist, where it is read once.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-remote-secondmate-control.sh" <<'EOF'

fm-remote-secondmate-control.sh retire "$id"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a script re-invoking its own destructive verb must not be exempt"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "bin/fm-remote-secondmate-control.sh:" \
  "the failure must name the self-invoking script"
pass "rule 4: a script re-invoking its own destructive verb fails"

# --- a helper name split by the shell's own punctuation ---------------------
#
# Regression fixtures for a fail-open rule 4 had while it matched the raw line:
# the helper's name had to appear contiguously, so any of the shell's ordinary
# ways of writing the same path hid the call site. All three payloads below run
# fm-teardown.sh and all three passed the check unreviewed. Rule 4 now matches
# the line with quote and backslash characters removed, which is exactly the
# punctuation the shell resolves while parsing.
#
# The removal cannot cost a hit: no helper name contains a quote or a backslash,
# so a contiguous name is untouched by it.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

"$SCRIPT_DIR/fm-""teardown.sh" "$id" --force
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a name split across two double-quoted strings must still be a call site"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must be rule 4's, not an unrelated one"
pass "rule 4: adjacent double-quoted strings do not hide a helper name"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

"$SCRIPT_DIR/fm-tear"'down.sh' "$id" --force
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a name split across a double- and a single-quoted string must still be a call site"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must be rule 4's, not an unrelated one"
pass "rule 4: mixing quote styles does not hide a helper name"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

$SCRIPT_DIR/fm-tear\down.sh "$id" --force
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an escaped character inside a name must still be a call site"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must be rule 4's, not an unrelated one"
pass "rule 4: a backslash inside a helper name does not hide it"

# Reaching the helper through a variable is caught on the assignment, because
# the assignment is where the name is written. This pins that: the obvious way
# to quiet rule 4's false positives is to skip lines that assign rather than
# invoke, and doing so reopens the whole indirect class - measured, a rule 4
# that skips assignment lines passes this payload.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

helper="$SCRIPT_DIR/fm-teardown.sh"
"$helper" "$id" --force
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a helper reached through a variable must be caught where the name is written"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must be rule 4's, not an unrelated one"
pass "rule 4: an assignment naming a helper is a reviewable call site"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

"$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh   retire "$ID"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "extra spacing before the retire verb must not hide the call site"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must be rule 4's, not an unrelated one"
pass "rule 4: whitespace between a helper and its verb is not part of the name"

# --- a quoted metacharacter is an argument, not a command boundary -----------
#
# Regression fixtures for a fail-open rules 2 and 3 shared while they scanned
# from `git` only as far as the first `;`, `|` or `&`. That exclusion was meant
# to end the match where the git command ends, but those characters are
# separators only when the shell reads them as such: inside a quoted argument
# they are ordinary text, and the scan stopped anyway. Every payload below runs
# the destructive git command it names, and every one passed unreviewed. Both
# rules now scan the whole line, which cannot be wrong about where a command
# ends because it does not ask.
#
# Rule 2's payloads go in bin/fm-bootstrap.sh, which is not the startup sweep,
# so only rule 2 can catch them and the assertion is unambiguous about which
# rule closed the hole.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

git -C "/tmp/a;b" branch -D "$b"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a semicolon inside a quoted path must not end the scan of a git command"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "runs git branch, which can delete one" \
  "the failure must be rule 2's, not an unrelated one"
pass "rule 2: a quoted semicolon does not hide a branch deletion"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

git -C "/tmp/a|b" branch -D "$b"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a pipe inside a quoted path must not end the scan of a git command"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "runs git branch, which can delete one" \
  "the failure must be rule 2's, not an unrelated one"
pass "rule 2: a quoted pipe does not hide a branch deletion"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

git -C "/tmp/a&b" branch -D "$b"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an ampersand inside a quoted path must not end the scan of a git command"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "runs git branch, which can delete one" \
  "the failure must be rule 2's, not an unrelated one"
pass "rule 2: a quoted ampersand does not hide a branch deletion"

# The same normalization rule 4 uses reaches rules 2 and 3 too, so quoting the
# verb no longer hides it either. `git "branch" -D` runs git's branch verb.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

git -C "$PROJ" bra"nch" -D "$b"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a quote splitting the branch verb must not hide the invocation"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "runs git branch, which can delete one" \
  "the failure must be rule 2's, not an unrelated one"
pass "rule 2: a quote inside the git verb does not hide a branch deletion"

# A rule reads the code, not the path it came from. Records are
# "<path><TAB><lineno><TAB><code>", so matching the whole record let BRANCH_RE
# take its `git` from the file name and its ` branch ` from the line, and rules 2
# and 3 have no second test to catch that - the check reported a line as running
# `git branch` when it ran no git at all. Fail-closed, but the remedy a
# maintainer reaches for is an allowlist entry licensing that line forever under
# a reason that was never true.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat > "$FIXTURE/bin/git-notes-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' " branch "
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "a git-named file must not lend its name to a rule matching the line"$'\n'"--- output ---"$'\n'"$out"
pass "rule 2: the file name is not part of the line the rule reads"

# The other direction of the same cut, because it is the one that can fail open:
# trimming by whitespace instead of by TAB would eat the code's first word and
# turn this into ` branch -D "$1"`, which BRANCH_RE no longer matches. That
# mutant is already killed upstream of here - an over-cut also strips the first
# word of the four lines the shipped BRANCH_ALLOWLIST licenses, so the stale-entry
# counter fires on the unmutated tree - and this case is the paired legal/illegal
# companion above, pinning that a git-named file gets no dispensation either way.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat > "$FIXTURE/bin/git-notes-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git branch -D "$1"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "dropping the path prefix must not drop the line's own first word"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "runs git branch, which can delete one" \
  "the failure must be rule 2's, not an unrelated one"
pass "rule 2: a real deletion in a git-named file still fails"

# Rule 3's payloads go in the startup sweep itself, which is where the rule
# looks.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "/tmp/a;b" reset --hard HEAD
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a semicolon inside a quoted path must not hide a sweep reset"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: a quoted semicolon does not hide a working-tree overwrite"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "/tmp/a|b" worktree remove wt
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a pipe inside a quoted path must not hide a sweep worktree removal"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: a quoted pipe does not hide a worktree removal"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

"rm" -rf "$d"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "quoting the command name must not hide a sweep removal"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: a quoted command name does not hide a removal"


# --- rule 3 flags the whole work-destroying verb class ------------------------
#
# Six of these were named by a reviewer that read the old list as incomplete;
# the seventh and eighth are verbs the same class implies but nobody named, and
# they are here so the fix reads as the class it claims rather than as the six
# spellings that were pointed at. Each payload is an ordinary git command that
# would run unattended on every boot.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" merge "$BASE"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a merge overwrites the working tree from another ref"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: an unattended git merge is a reviewable line"
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" rebase "$BASE"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a rebase rewrites the branch and can drop commits"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: an unattended git rebase is a reviewable line"
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" cherry-pick "$sha"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a cherry-pick writes the working tree and can conflict"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: an unattended git cherry-pick is a reviewable line"
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" revert --no-edit "$sha"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a revert commits over existing work"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: an unattended git revert is a reviewable line"
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" am "$patch"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "am applies a patch series to the working tree"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: an unattended git am is a reviewable line"
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" apply "$patch"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "apply writes the patch into the working tree"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: an unattended git apply is a reviewable line"
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" read-tree --reset -u HEAD
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "read-tree --reset -u overwrites the index and the working tree"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: an unattended git read-tree is a reviewable line"
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" sparse-checkout set lib
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "sparse-checkout removes paths from the working tree"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "can destroy work" \
  "the failure must be rule 3's, not an unrelated one"
pass "rule 3: an unattended git sparse-checkout is a reviewable line"

# --- prose stays out of scope -----------------------------------------------
#
# Every rule but the first reads executable lines only. Documenting a
# destructive action is how this codebase explains itself; a check that flagged
# prose would be silenced within a week.

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

# Never do this here: "$SCRIPT_DIR/fm-teardown.sh" "$id", or git branch -D "$b".
echo boot   # bin/fm-merge-local.sh and git branch -D belong to the founder
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "comments naming destructive actions must not trip the check"$'\n'"--- output ---"$'\n'"$out"
pass "prose: whole-line and trailing comments naming destructive actions are ignored"

# Regression fixture for a false positive the cut had while it required
# whitespace after the `#`: bash starts a comment at `#` alone, so `echo boot
# #note` is a comment to bash and had to be one here too. It was not, so a
# sentence written without the courtesy space was read as code, and prose naming
# a helper failed a check that claims to ignore prose. The cut now takes
# everything from the first whitespace-preceded `#`, matching bash.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

echo boot   #bin/fm-teardown.sh is the founder toolkit
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "a trailing comment with no space after the hash is still a comment"$'\n'"--- output ---"$'\n'"$out"
pass "prose: a trailing comment with no space after the hash is ignored, as bash reads it"

# The stated cost of reading a trailing comment only on an unambiguous line: on
# a line carrying a quote, the tail is kept and read as code, so prose there
# that names a destructive helper fails. This is the trade, pinned so it is a
# decision rather than a surprise - and the escape hatch is free, because the
# whole-line comment in the case above is dropped whatever it quotes.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

echo "boot"   # bin/fm-teardown.sh is the founder's, not ours
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a trailing comment on a quoted line is read as code, by design"$'\n'"--- output ---"$'\n'"$out"
pass "prose: a trailing comment on a quoted line is read as code, and that cost is pinned"

# --- the comment cut cannot be used to hide code ----------------------------
#
# Regression fixtures for a fail-open the cut had while it was quote-blind: a
# quoted `#` earlier on the line made everything after it look like a comment,
# so a real command written after one was deleted before any rule saw it. One
# fixture per rule, because the cut feeds all three.

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

printf '%s' ' # ' ; "$SCRIPT_DIR/fm-teardown.sh" "$id" --force
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a quoted hash must not hide a teardown call from rule 4"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must be rule 4's, not an unrelated one"
pass "comment cut: a quoted hash cannot hide a destructive call site from rule 4"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

printf '%s' ' # ' ; git branch -D "$stale"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a quoted hash must not hide a branch deletion from rule 2"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "runs git branch, which can delete one" \
  "the failure must be rule 2's, not an unrelated one"
pass "comment cut: a quoted hash cannot hide a branch deletion from rule 2"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

printf '%s' ' # ' ; rm -rf "$wt"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a quoted hash must not hide a removal from rule 3"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "not one of the startup sweep's reviewed lines" \
  "the failure must be rule 3's, not an unrelated one"
pass "comment cut: a quoted hash cannot hide a removal from rule 3"

# The other way a whitespace-preceded `#` is not a comment, and the reason the
# cut is withheld from a line carrying `${` as well as one carrying a quote: a
# parameter expansion whose pattern contains one. `cmd=${cmd%%  #*}` is a real
# line in bin/fm-bootstrap.sh, so this is a construct the fork writes, not a
# hypothetical - and it carries no quote, so a cut guarded on quotes alone would
# take it, keep `cmd=${cmd%%`, and delete whatever was written after it.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

cmd=${cmd%% #*}; $SCRIPT_DIR/fm-teardown.sh $id --force
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a hash inside a parameter expansion must not hide a teardown call"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must be rule 4's, not an unrelated one"
pass "comment cut: a hash inside a parameter expansion cannot hide a destructive call site"

# --- a continuation cannot be used to split a command -----------------------
#
# Regression fixtures for a fail-open every action rule had while the scan read
# physical source lines. Bash joins a line ending in a backslash to the next, so
# one destructive command can be written as two lines that each look harmless,
# and rules 2, 3 and 4 all passed the split forms below. The split is not exotic:
# 93 of the fork's 140 tracked bin/ scripts already continue a line this way, so
# a deletion written in the house style was the one the check could not see.

# shellcheck disable=SC2016 # these are fixture payloads; the $ names must reach the fixture unexpanded.
SPLIT_COMMANDS=(
  'git -C "$PROJ" \
  branch -D "$stale"'
  'git -C "$PROJ" \
  worktree remove --force "$wt"'
  'git \
  -C "$PROJ" \
  reset --hard "$BASE"'
)
for split in "${SPLIT_COMMANDS[@]}"; do
  FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
  printf '\n%s\n' "$split" >> "$FIXTURE/bin/fm-fleet-sync.sh"
  git -C "$FIXTURE" add -A >/dev/null 2>&1
  out=$(run_check "$FIXTURE")
  assert_contains "$out" "rc=1" \
    "a command split across lines must be read as one command:"$'\n'"$split"$'\n'"--- output ---"$'\n'"$out"
done
pass "continuation: splitting a destructive command across lines still fails"

# The same hole one level down: the continuation can fall inside the helper's
# own name, and inside a double-quoted string, where bash removes it just the
# same.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-spawn.sh" <<'EOF'

"$SCRIPT_DIR/fm-\
teardown.sh" "$id" --force
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a helper name split by a continuation must not hide the call site"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "reaches a destructive helper and is not in the reviewed allowlist" \
  "the failure must be rule 4's, not an unrelated one"
pass "continuation: splitting a destructive helper's own name still fails"

# The join's own fail-open, pinned from the other side. A backslash inside a
# comment is inert to bash, so the command below runs; joining it into the
# comment instead would delete it before any rule looked. This passes on both
# sides of the fix and is not a regression fixture for it - it exists so the
# flush cannot be dropped later as a redundant branch.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

# about to delete the stale branch \
git branch -D "$stale"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a comment ending in a backslash must not swallow the next command"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "runs git branch, which can delete one" \
  "the failure must be rule 2's, not an unrelated one"
pass "continuation: a comment ending in a backslash does not swallow the next command"

# --- approval is keyed on the whole line, not a suffix of one ---------------
#
# Regression fixtures for a fail-open the allowlist tests had while membership
# was an unanchored `grep -F` over whole entries. A hit that is merely a *suffix*
# of a reviewed line inherited that line's approval, and suffix is the dangerous
# direction: a reviewed line is usually longer than the bare destructive command
# it wraps, because what makes it safe is the guard wrapped around it. Rule 3's
# reviewed sweep checkout is safe precisely because of the `if !` its reason
# cites, and rule 3's reviewed `rm -f` because of the same - so dropping the
# guard leaves a suffix, and the approval written for the guarded form carried
# over to the unguarded one. The occurrence counter did not catch it either: the
# reviewed line is still there, still matched exactly once.
#
# Both payloads below passed the check unreviewed. Rules 2 and 4 key on
# `<path><TAB><line>` and were not exploitable this way today, but only because
# no tracked bin/ path is a suffix of another - a property of the tree, not of
# the test - so they are anchored by the same helper without a fixture that can
# reach them from this fork's own file list.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

git -C "$PROJ" checkout --quiet "$DEFAULT" 2>/dev/null; then
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an unguarded checkout must not inherit the guarded one's approval"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "not one of the startup sweep's reviewed lines" \
  "the failure must be rule 3's, not an unrelated one"
pass "anchoring: dropping a reviewed line's guard drops its approval with it"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

rm -f "$lock"; then
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an unguarded removal must not inherit the guarded one's approval"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "not one of the startup sweep's reviewed lines" \
  "the failure must be rule 3's, not an unrelated one"
pass "anchoring: a reviewed removal's suffix is not itself reviewed"

# --- an entry licenses one occurrence ---------------------------------------
#
# Regression fixtures for a fail-open every allowlist had while approval was
# keyed on text alone: a reviewed line copied into new control flow inherited
# the original's approval, which is exactly what a new automatic caller looks
# like. Rule 3's copy case is above, next to its own rule.

# The copy is written on one line while the original is continued across four.
# They are the same command, so they normalize to the same reviewed line and the
# count catches the copy: approval attaches to the invocation, not to the layout
# someone happened to give it.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-remote-secondmate-control.sh" <<'EOF'

auto_reaper() {
  FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 "$SCRIPT_DIR/fm-teardown.sh" "$id" --force
}
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a copy of a reviewed call site in unreviewed control flow must fail"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "ALLOWLIST has an entry that rule 4 matched 2 times" \
  "the failure must say the entry matched more than once"$'\n'"--- output ---"$'\n'"$out"
pass "occurrence: a copy of a reviewed call site is an unreviewed call site"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "a copy of the reviewed branch line must fail"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "BRANCH_ALLOWLIST has an entry that rule 2 matched 2 times" \
  "the failure must say the entry matched more than once"$'\n'"--- output ---"$'\n'"$out"
pass "occurrence: a copy of the reviewed branch line is an unreviewed line"

# Zero occurrences fails for the same reason one-per-entry does. A stale entry
# is not a tidiness problem: it sits there licensing a line that no longer
# exists, so the day that line comes back - restored by a revert, a merge, or a
# copy from history - it is approved without anybody reading it.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
grep -v '^    bin/fm-teardown\.sh)$' "$FIXTURE/bin/fm-test-run.sh" > "$FIXTURE/trimmed" \
  || fail "could not trim the allowlisted line out of the fixture"
mv "$FIXTURE/trimmed" "$FIXTURE/bin/fm-test-run.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" \
  "an entry whose line is gone must fail"$'\n'"--- output ---"$'\n'"$out"
assert_contains "$out" "matched no call site for" \
  "the failure must say the entry matched nothing"$'\n'"--- output ---"$'\n'"$out"
pass "occurrence: a stale entry fails rather than waiting to re-license its line"

# --- fail-closed on a basis it cannot read ----------------------------------

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
rm -f "$FIXTURE/bin/fm-fleet-sync.sh"
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "a missing startup sweep must fail rather than silently pass"
assert_contains "$out" "the startup-sweep rule cannot be checked" \
  "the failure must say which rule lost its basis"
pass "fail-closed: a missing startup sweep fails instead of vacuously passing"

EMPTY_ROOT=$(fm_test_tmproot fm-destructive-automation-empty) || fail "could not build the empty fixture"
git -C "$EMPTY_ROOT" init -q || fail "could not init the empty fixture"
out=$(run_check "$EMPTY_ROOT")
assert_contains "$out" "rc=1" "a repository with no tracked bin/ scripts must fail, not pass"
assert_contains "$out" "no tracked bin/ scripts were found" \
  "the failure must say the scan found nothing to scan"
pass "fail-closed: an empty scan basis fails instead of reporting ok"
