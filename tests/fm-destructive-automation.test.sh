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
bin_fixture() {
  local root repo f dir
  root=$(fm_test_tmproot fm-destructive-automation) || return 1
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
  printf '%s\n' "$repo"
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
pass "the shipped tree has no unreviewed destructive automation"

# --- the fixture is a faithful basis ----------------------------------------

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "an unmutated copy of tracked bin/ must pass, or every mutation below proves nothing"$'\n'"--- output ---"$'\n'"$out"
pass "an unmutated copy of tracked bin/ passes the check"

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

# --- rule 2: branch deletion stays inside founder-run teardown --------------

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

git -C "$PROJ" branch -D -- "$stale"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "deleting a branch outside teardown must fail the check"
assert_contains "$out" "deletes a local branch; only bin/fm-teardown.sh may" \
  "the failure must name the one sanctioned home for branch deletion"
assert_contains "$out" "bin/fm-bootstrap.sh:" "the failure must name the offending file"
pass "rule 2: deleting a local branch outside founder-run teardown fails"

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
assert_contains "$out" "the startup sweep must not" \
  "the failure must say the startup sweep may not delete"
pass "rule 3: removing a worktree from the startup sweep fails"

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

rm -rf "$PROJ/.git/rebase-merge"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=1" "a recursive removal in the startup sweep must fail the check"
assert_contains "$out" "directory tree" "the failure must name the tree removal"
pass "rule 3: a recursive removal in the startup sweep fails"

# The sweep's one permitted removal is a provably-stale packed-refs lock: a
# single non-recursive rm -f of a lock file, holding no work. Rule 3 has to
# leave it alone or the sweep could not recover from an orphaned lock at all.
FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-fleet-sync.sh" <<'EOF'

rm -f "$another_lock"
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "a non-recursive lock-file removal must stay legal in the startup sweep"$'\n'"--- output ---"$'\n'"$out"
pass "rule 3: a non-recursive lock-file removal stays legal"

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

# --- prose stays out of scope -----------------------------------------------
#
# Every rule but the first reads executable lines only. Documenting a
# destructive action is how this codebase explains itself; a check that flagged
# prose would be silenced within a week.

FIXTURE=$(bin_fixture) || fail "could not build the bin/ fixture"
cat >> "$FIXTURE/bin/fm-bootstrap.sh" <<'EOF'

# Never do this here: "$SCRIPT_DIR/fm-teardown.sh" "$id", or git branch -D "$b".
echo "boot"   # bin/fm-merge-local.sh and git branch -D are the founder's, not ours
EOF
git -C "$FIXTURE" add -A >/dev/null 2>&1
out=$(run_check "$FIXTURE")
assert_contains "$out" "rc=0" \
  "comments naming destructive actions must not trip the check"$'\n'"--- output ---"$'\n'"$out"
pass "prose: whole-line and trailing comments naming destructive actions are ignored"

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
