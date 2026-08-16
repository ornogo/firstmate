#!/usr/bin/env bash
# The admission seam in bin/fm-spawn.sh: the argument contract that decides
# whether a spawn declares an effort at all, and the one audited call to
# bin/fm-admit.sh that sits between all of spawn's validation and the first
# spawn-side mutation.
#
# The property the seam exists for is "a refusal leaves no endpoint, no lease,
# and no branch", so the seam cases assert on what is NOT on disk (no window
# was created, no state/<id>.meta was written) rather than only on the refusal
# text. A seam that had drifted below the backend block would still print the
# same refusal while having already made a window.
#
# The refusal cases below all fail before the missing-brief check, which is
# itself reached before any tmux or treehouse side effect, so they create no
# windows or worktrees and need no fixture beyond a home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
ADMIT="$ROOT/bin/fm-admit.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-admit)
# Stock macOS sets TMPDIR with a trailing slash, so the fixture root arrives with
# a doubled separator. bin/fm-admit.sh refuses an empty path segment on purpose -
# a caller assembling paths that way should see it - but that refusal is aimed at
# the founder's typed --worktree, not at a fixture path, so the doubling is
# squeezed out here rather than asserted around.
TMP_ROOT=$(printf '%s\n' "$TMP_ROOT" | tr -s '/')
export FM_BACKEND=tmux

# make_admit_home <name> <mode> builds a bare home whose config/admission holds
# <mode>; an empty <mode> writes no file at all, which is the unguarded home
# every fixture and every home bootstrapped before the guard existed has.
make_admit_home() {
  local name=$1 mode=$2 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  [ -z "$mode" ] || printf '%s\n' "$mode" > "$home/config/admission"
  printf '%s\n' "$home"
}

# The overrides are cleared rather than unset so a stray value in the running
# shell cannot reach the spawn; FM_HOME alone then resolves config, data, state,
# and projects, which is also the only shape the guard's own $FM_HOME/data
# ledger resolution agrees with.
run_spawn() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  local home=$1
  shift
  run_spawn "$home" "$@" --mode no-mistakes --yolo off
}

# --- the argument contract -------------------------------------------------

# Accepting the pair on an unguarded home is the silent-failure shape the whole
# guard is meant to rule out: the founder types the effort they mean to reserve,
# the flags parse, and nothing is reserved.
test_pair_on_an_unguarded_home_is_refused() {
  local home out status
  home=$(make_admit_home pair-unguarded '')
  out=$(run_ship_spawn "$home" nope-admit-off-z1 --branch feat/orn-9001-x --worktree "$home")
  status=$?
  expect_code 1 "$status" "a pair on an unguarded home should be refused"
  assert_contains "$out" "admission guard is off" \
    "refusal did not name the unguarded home as the reason"
  pass "--branch/--worktree on a home whose guard is off is refused, not silently accepted"
}

# A ship spawn that could omit the pair on a guarded home would not be a guard.
test_guarded_ship_spawn_requires_the_pair() {
  local home out status
  home=$(make_admit_home pair-required on)
  out=$(run_ship_spawn "$home" nope-admit-nopair-z2)
  status=$?
  expect_code 1 "$status" "a guarded ship spawn with no pair should be refused"
  assert_contains "$out" "requires --branch <name> and --worktree <path>" \
    "refusal did not state the pair requirement"
  pass "a guarded home refuses a ship spawn that declares no effort"
}

# Both or neither. Each half is asserted separately because they kill different
# halves of the conjunction: dropping either one alone would leave a spawn that
# admits on a half-declared effort.
test_guarded_ship_spawn_refuses_branch_without_worktree() {
  local home out status
  home=$(make_admit_home pair-branch-only on)
  out=$(run_ship_spawn "$home" nope-admit-branchonly-z3 --branch feat/orn-9002-x)
  status=$?
  expect_code 1 "$status" "--branch without --worktree should be refused"
  assert_contains "$out" "requires --branch <name> and --worktree <path>" \
    "refusal did not state the pair requirement"
  pass "--branch alone is an incomplete effort declaration, not a partial admission"
}

test_guarded_ship_spawn_refuses_worktree_without_branch() {
  local home out status
  home=$(make_admit_home pair-worktree-only on)
  out=$(run_ship_spawn "$home" nope-admit-wtonly-z4 --worktree "$home")
  status=$?
  expect_code 1 "$status" "--worktree without --branch should be refused"
  assert_contains "$out" "requires --branch <name> and --worktree <path>" \
    "refusal did not state the pair requirement"
  pass "--worktree alone is an incomplete effort declaration, not a partial admission"
}

# A scout delivers a report and a secondmate runs in its own home; neither
# reserves a delivery branch, so a pair on either is a misunderstanding worth
# refusing rather than a flag to drop.
test_the_pair_is_refused_on_a_scout_and_a_secondmate() {
  local home out status kind
  home=$(make_admit_home pair-nonship on)
  for kind in --scout --secondmate; do
    out=$(run_spawn "$home" "nope-admit-nonship${kind}-z5" "$kind" --branch feat/orn-9003-x --worktree "$home")
    status=$?
    expect_code 1 "$status" "$kind with a pair should be refused"
    assert_contains "$out" "apply only to ship spawns" \
      "$kind refusal did not name the ship-only scope"
  done
  pass "--branch/--worktree are refused on scout and secondmate spawns"
}

# A relaunch replaces the agent inside an effort that is already admitted, so a
# pair on one either re-admits (refused as a duplicate) or contradicts the entry
# that exists. Both halves are refused at the argument layer instead.
test_relaunch_refuses_a_redeclared_effort() {
  local home out status
  home=$(make_admit_home relaunch on)
  out=$(run_spawn "$home" nope-admit-relaunch-z6 --relaunch --branch feat/orn-9004-x)
  status=$?
  expect_code 1 "$status" "--relaunch with --branch should be refused"
  assert_contains "$out" "--relaunch reuses the effort" \
    "refusal did not name the already-admitted effort"

  out=$(run_spawn "$home" nope-admit-relaunch-z7 --relaunch --worktree "$home")
  status=$?
  expect_code 1 "$status" "--relaunch with --worktree should be refused"
  assert_contains "$out" "--relaunch reuses the effort" \
    "refusal did not name the already-admitted effort"
  pass "--relaunch refuses a re-declared --branch or --worktree"
}

# The pair names ONE effort, so a batch has no coherent value for it. Refusing
# beats dropping it: a founder who typed the pair would otherwise believe the
# batch was admitted under it.
test_the_pair_is_refused_in_a_batch() {
  local home out status
  home=$(make_admit_home batch on)
  out=$(run_ship_spawn "$home" nope-admit-batch-a-z8=projects/none-a \
    nope-admit-batch-b-z9=projects/none-b --branch feat/orn-9005-x --worktree "$home")
  status=$?
  expect_code 1 "$status" "a pair in a batch should be refused"
  assert_contains "$out" "refused in a batch" \
    "refusal did not name the batch as the reason"
  pass "--branch/--worktree are refused in a batch rather than silently dropped"
}

# A typo in the file that decides whether the guard runs must never resolve to
# "do not guard", which is what any fallback-to-off would do.
test_unreadable_admission_mode_is_refused_rather_than_treated_as_off() {
  local home out status
  home=$(make_admit_home garbage-mode ON)
  out=$(run_ship_spawn "$home" nope-admit-garbage-z10)
  status=$?
  expect_code 1 "$status" "an unrecognized config/admission value should be refused"
  assert_contains "$out" "must say 'on' or 'off'" \
    "refusal did not name the two accepted values"
  pass "an unrecognized config/admission value is refused, never treated as off"
}

# Absent means off; existing-but-blank does not. A file the founder created and
# left empty - or filled with only whitespace - is a half-written config, and
# resolving it to off would silently spawn unguarded on a home someone was in
# the middle of arming.
test_a_blank_admission_file_is_refused_rather_than_treated_as_off() {
  local case_name home out status
  for case_name in empty whitespace; do
    home=$(make_admit_home "blank-mode-$case_name" '')
    if [ "$case_name" = empty ]; then
      : > "$home/config/admission"
    else
      printf '\n   \n\t\n' > "$home/config/admission"
    fi
    out=$(run_ship_spawn "$home" "nope-admit-blank-$case_name-z11")
    status=$?
    expect_code 1 "$status" \
      "the $case_name config/admission should be refused, not treated as off; got: $out"
    assert_contains "$out" "must say 'on' or 'off'" \
      "the $case_name config/admission was not refused as an unreadable value"
  done
  pass "a blank config/admission is refused rather than treated as off"
}

# A -f test alone cannot tell "nobody armed this home" from "the thing that says
# whether this home is armed is broken", and the second must not spawn.
test_a_non_regular_admission_entry_is_refused_rather_than_treated_as_off() {
  local case_name home out status
  for case_name in directory dangling-symlink; do
    home=$(make_admit_home "broken-mode-$case_name" '')
    if [ "$case_name" = directory ]; then
      mkdir -p "$home/config/admission"
    else
      ln -s "$home/config/no-such-admission-target" "$home/config/admission"
    fi
    out=$(run_ship_spawn "$home" "nope-admit-broken-$case_name-z12")
    status=$?
    expect_code 1 "$status" \
      "a $case_name at config/admission should be refused, not treated as off; got: $out"
    assert_contains "$out" "not a readable regular file" \
      "a $case_name at config/admission was not named as a broken config"
  done
  pass "a non-regular config/admission entry is refused rather than treated as off"
}

# Stripping whitespace everywhere rather than at the ends turns a typo into a
# valid value, and the valid value it lands on is the one that disarms the guard.
test_internal_whitespace_does_not_normalize_a_typo_into_off() {
  local home out status
  home=$(make_admit_home split-token 'o ff')
  out=$(run_ship_spawn "$home" nope-admit-split-z13)
  status=$?
  expect_code 1 "$status" \
    "'o ff' should be refused rather than normalized to 'off'; got: $out"
  assert_contains "$out" "must say 'on' or 'off'" \
    "'o ff' was not refused as an unrecognized value"

  # The other half of the same change: trimming the ends is still supported, so
  # a padded value reads as the word it surrounds rather than joining the typos.
  home=$(make_admit_home padded-token '   on   ')
  out=$(run_ship_spawn "$home" nope-admit-padded-z14)
  status=$?
  expect_code 1 "$status" "a padded 'on' should still arm the guard; got: $out"
  assert_contains "$out" "requires --branch <name> and --worktree <path>" \
    "a padded 'on' did not read as an armed guard"
  pass "internal whitespace does not normalize a typo into 'off'"
}

# An empty value would otherwise reach the guard as an empty branch or worktree.
test_the_pair_requires_non_empty_values() {
  local home out status
  home=$(make_admit_home empty-values on)
  out=$(run_ship_spawn "$home" nope-admit-emptybranch-z11 --branch '' --worktree "$home")
  status=$?
  expect_code 1 "$status" "an empty --branch should be refused"
  assert_contains "$out" "--branch requires a non-empty value" \
    "refusal did not name the empty --branch"

  out=$(run_ship_spawn "$home" nope-admit-emptywt-z12 --branch feat/orn-9006-x --worktree '')
  status=$?
  expect_code 1 "$status" "an empty --worktree should be refused"
  assert_contains "$out" "--worktree requires a non-empty value" \
    "refusal did not name the empty --worktree"
  pass "--branch and --worktree each require a non-empty value"
}

# orca owns both the worktree and the terminal and creates the worktree itself,
# so an admitted --worktree could never be the one the task ends up in and the
# post-lease binding check would have nothing true to compare against.
test_an_orca_ship_spawn_cannot_be_admitted() {
  local home out status
  home=$(make_admit_home orca on)
  out=$(run_ship_spawn "$home" nope-admit-orca-z13 --backend orca \
    --branch feat/orn-9007-x --worktree "$home")
  status=$?
  expect_code 1 "$status" "an admitted orca ship spawn should be refused"
  assert_contains "$out" "creates its own worktree" \
    "refusal did not name orca's self-owned worktree as the reason"
  pass "backend=orca is refused on a guarded home rather than admitted against a worktree it will not use"
}

# bin/fm-admit.sh has no FM_DATA_OVERRIDE and always resolves $FM_HOME/data, so
# a spawn whose own data directory was pointed elsewhere would guard a different
# ledger than the one its home actually uses.
test_a_diverged_data_directory_is_refused() {
  local home out status
  home=$(make_admit_home diverged-data on)
  mkdir -p "$home/elsewhere"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/elsewhere" \
    FM_STATE_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" nope-admit-diverged-z14 --mode no-mistakes --yolo off \
    --branch feat/orn-9008-x --worktree "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a guarded spawn with a diverged data directory should be refused"
  assert_contains "$out" "reads its ledger from" \
    "refusal did not name the ledger the guard would have read"
  pass "a guarded spawn whose data directory diverges from \$FM_HOME/data is refused"
}

# --- the seam itself -------------------------------------------------------

# A fake tmux that logs every invocation, so a case can assert no window was
# created rather than only that a refusal was printed.
make_seam_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  # The window-presence question --resume asks, answerable three ways: a listing
  # that names the window, a listing that does not, and a tmux that cannot say.
  # Defaulted so a case that sets none of them gets "the session is there and it
  # holds no windows", which is what every pre-resume case already assumed.
  has-session) exit "${FM_FAKE_TMUX_HAS_SESSION:-0}" ;;
  list-windows)
    [ -z "${FM_FAKE_TMUX_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
    exit "${FM_FAKE_TMUX_LIST_RC:-0}"
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# A home a real ship spawn can complete in: a guarded config, a real project
# with a real pooled worktree, a second real checkout standing in for a worktree
# the pool could hand out instead, and a brief for the task.
make_seam_case() {
  local name=$1 id=$2
  SEAM_HOME="$TMP_ROOT/$name/home"
  SEAM_PROJ="$TMP_ROOT/$name/project"
  SEAM_WT="$TMP_ROOT/$name/wt"
  SEAM_OTHER="$TMP_ROOT/$name/other-checkout"
  SEAM_LOG="$TMP_ROOT/$name/tmux-log"
  SEAM_FAKEBIN=$(make_seam_fakebin "$TMP_ROOT/$name/fake")
  mkdir -p "$SEAM_HOME/data/$id" "$SEAM_HOME/projects" "$SEAM_HOME/state" "$SEAM_HOME/config"
  printf 'on\n' > "$SEAM_HOME/config/admission"
  printf 'codex\n' > "$SEAM_HOME/config/crew-harness"
  printf '{}\n' > "$SEAM_HOME/data/admission-ledger.json"
  fm_git_worktree "$SEAM_PROJ" "$SEAM_WT" "wt-$name"
  fm_git_init_commit "$SEAM_OTHER"
  printf 'brief for %s\n' "$id" > "$SEAM_HOME/data/$id/brief.md"
  touch "$SEAM_HOME/state/.last-watcher-beat"
}

# <id> <branch> <worktree> [pane-path]; the pane settles into <worktree> unless a
# different pane path is given.
run_seam_spawn() {
  local id=$1 branch=$2 worktree=$3 pane=${4:-$3}
  FM_ROOT_OVERRIDE='' FM_HOME="$SEAM_HOME" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_TMUX_LOG="$SEAM_LOG" \
    PATH="$SEAM_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$SEAM_PROJ" --mode no-mistakes --yolo off \
    --branch "$branch" --worktree "$worktree" 2>&1
}

assert_no_window_created() {
  local id=$1 what=$2
  if [ -f "$SEAM_LOG" ] && grep -q 'new-window' "$SEAM_LOG"; then
    fail "$what created a tmux window; the seam must refuse before the first spawn-side mutation"
  fi
  assert_absent "$SEAM_HOME/state/$id.meta" \
    "$what published a task record; the seam must refuse before the first spawn-side mutation"
}

# The admitted path end to end: the effort reaches the ledger, and it reaches it
# recorded against the branch and worktree that were declared.
test_an_admitted_ship_spawn_records_the_effort() {
  local id out status
  id=admit-seam-ok-z20
  make_seam_case seam-ok "$id"
  out=$(run_seam_spawn "$id" feat/orn-9101-seam "$SEAM_WT")
  status=$?
  expect_code 0 "$status" "an admitted ship spawn should succeed, got: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  jq -e --arg wt "$SEAM_WT" \
    '.["ORN-9101"].branch == "feat/orn-9101-seam" and .["ORN-9101"].worktree == $wt' \
    "$SEAM_HOME/data/admission-ledger.json" >/dev/null \
    || fail "the ledger did not record the admitted effort: $(cat "$SEAM_HOME/data/admission-ledger.json")"
  pass "an admitted ship spawn reaches the ledger bound to the declared branch and worktree"
}

# The load-bearing seam case. A spawn refused at the cap must leave nothing
# behind, which is only true while the seam sits above the backend block.
test_a_spawn_refused_at_the_cap_creates_nothing() {
  local id out status before
  id=admit-seam-cap-z21
  make_seam_case seam-cap "$id"
  FM_HOME="$SEAM_HOME" "$ADMIT" admit --branch feat/orn-9102-held --worktree "$SEAM_OTHER" >/dev/null \
    || fail "could not seed the ledger to its cap"
  before=$(cat "$SEAM_HOME/data/admission-ledger.json")

  out=$(run_seam_spawn "$id" feat/orn-9103-blocked "$SEAM_WT")
  status=$?
  expect_code 1 "$status" "a spawn at the cap should be refused"
  assert_contains "$out" "release one before admitting another" \
    "refusal did not come from the cap"
  assert_no_window_created "$id" "a spawn refused at the cap"
  [ "$(cat "$SEAM_HOME/data/admission-ledger.json")" = "$before" ] \
    || fail "a refused spawn mutated the ledger"
  pass "a spawn refused at the cap creates no window, publishes no task record, and leaves the ledger alone"
}

# A missing ledger is the state bootstrap's provisioning exists to prevent, and
# it must refuse rather than read as "nothing is admitted yet" - which would make
# deleting the file the way to bypass the cap.
test_a_missing_ledger_refuses_the_spawn() {
  local id out status
  id=admit-seam-noledger-z22
  make_seam_case seam-noledger "$id"
  rm -f "$SEAM_HOME/data/admission-ledger.json"

  out=$(run_seam_spawn "$id" feat/orn-9104-noledger "$SEAM_WT")
  status=$?
  expect_code 1 "$status" "a spawn against a missing ledger should be refused"
  assert_no_window_created "$id" "a spawn refused for a missing ledger"
  assert_absent "$SEAM_HOME/data/admission-ledger.json" \
    "the spawn created the ledger it was supposed to refuse over"
  pass "a missing ledger refuses the spawn instead of reading as an empty one"
}

# A pooled worktree exists before it is leased, so a --worktree that is not there
# is a typo rather than a race, and is worth catching before the reservation.
test_a_worktree_that_does_not_exist_is_refused_before_admission() {
  local id out status
  id=admit-seam-nowt-z23
  make_seam_case seam-nowt "$id"

  out=$(run_seam_spawn "$id" feat/orn-9105-nowt "$TMP_ROOT/seam-nowt/not-there")
  status=$?
  expect_code 1 "$status" "a nonexistent --worktree should be refused"
  assert_contains "$out" "is not an existing directory" \
    "refusal did not name the missing directory"
  assert_no_window_created "$id" "a spawn refused for a missing worktree"
  [ "$(cat "$SEAM_HOME/data/admission-ledger.json")" = '{}' ] \
    || fail "a spawn refused for a missing worktree still reserved the effort"
  pass "a --worktree that does not exist is refused before anything is reserved"
}

# The pool answers only after the window exists, so the binding check runs after
# the mutation it guards. Its job is to catch a spawn that landed somewhere other
# than the effort it was admitted for - and to leave the reservation held, since
# dropping it on a spawn that already took a lease is the fail-open direction.
test_a_lease_that_misses_the_admitted_worktree_is_refused_and_stays_held() {
  local id out status
  id=admit-seam-binding-z24
  make_seam_case seam-binding "$id"

  out=$(run_seam_spawn "$id" feat/orn-9106-binding "$SEAM_WT" "$SEAM_OTHER")
  status=$?
  expect_code 1 "$status" "a lease outside the admitted worktree should be refused"
  assert_contains "$out" "was admitted for worktree" \
    "refusal did not name the admitted worktree"
  jq -e '.["ORN-9106"].branch == "feat/orn-9106-binding"' \
    "$SEAM_HOME/data/admission-ledger.json" >/dev/null \
    || fail "the reservation was unwound on a spawn that had already taken a lease"
  pass "a lease outside the admitted worktree is refused with the reservation still held"
}

# --- --resume --------------------------------------------------------------
#
# --resume restarts an effort the guard already admitted and quarantine then
# stopped. It makes no admission decision, so the cases below are about the two
# things it does instead: BINDING (the entry must exist, be active, and match
# the preserved effort exactly, or refuse) and the CRITICAL SECTION (inside the
# ledger lock, an existing window or an unconfirmed prior worker refuses, so two
# concurrent resumes of one effort yield exactly one worker).
#
# Every refusal is asserted against disk as well as text, for the same reason
# the seam cases are: a refusal that had already made a window or edited the
# ledger would print exactly the same line.

# fakebin/lsof for the resume cases. The confirmed-dead scan is the one answer a
# resume test must not take from the host's real process table: "nothing is
# running under this worktree" would be true there by accident rather than by
# assertion, and the case that needs a survivor could not be built at all.
# FM_FAKE_LSOF_CWD holds one "<pid> <path>" pair per line, rendered in the -Fpn
# shape the scan parses; FM_FAKE_LSOF_RC makes the scan itself fail.
add_resume_lsof() {
  local fakebin=$1
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_LSOF_RC:-0}" != 0 ]; then
  echo "lsof: simulated failure" >&2
  exit "$FM_FAKE_LSOF_RC"
fi
[ -n "${FM_FAKE_LSOF_CWD:-}" ] || exit 0
while read -r pid path; do
  [ -n "$pid" ] || continue
  printf 'p%s\nfcwd\nn%s\n' "$pid" "$path"
done <<EOF
$FM_FAKE_LSOF_CWD
EOF
SH
  chmod +x "$fakebin/lsof"
}

# A resumable effort, in the state quarantine leaves behind: the seam fixture's
# guarded home and real pooled worktree, checked out on the branch the entry
# names (a preserved effort is on its own branch), an active ledger entry
# written by bin/fm-admit.sh itself rather than hand-rolled JSON, and the task
# record whose worktree= is what maps the entry back to a task.
#
# The fake answers are reset here rather than per case, so a case that sets none
# of them gets "no window, nothing running" - the state a resume is supposed to
# proceed from - instead of inheriting the previous case's.
make_resume_case() {  # <name> <id> <issue-number>
  local name=$1 id=$2 num=$3
  make_seam_case "$name" "$id"
  add_resume_lsof "$SEAM_FAKEBIN"
  RESUME_ID=$id
  RESUME_KEY="ORN-$num"
  RESUME_BRANCH="feat/orn-$num-resume"
  RESUME_TARGET="firstmate:fm-$id"
  RESUME_META="$SEAM_HOME/state/$id.meta"
  RESUME_PANE_PATH=$SEAM_WT
  FM_FAKE_TMUX_WINDOWS=
  FM_FAKE_TMUX_HAS_SESSION=0
  FM_FAKE_TMUX_LIST_RC=0
  FM_FAKE_LSOF_CWD=
  FM_FAKE_LSOF_RC=0
  git -C "$SEAM_WT" checkout -q -b "$RESUME_BRANCH"
  FM_HOME="$SEAM_HOME" "$ADMIT" admit --branch "$RESUME_BRANCH" --worktree "$SEAM_WT" >/dev/null \
    || fail "could not seed the resumable admission entry for $RESUME_KEY"
  fm_write_meta "$RESUME_META" \
    "window=$RESUME_TARGET" \
    "endpoint_task_id=$id" \
    "worktree=$SEAM_WT" \
    "project=$SEAM_PROJ" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  RESUME_LEDGER_BEFORE=$(cat "$SEAM_HOME/data/admission-ledger.json")
  RESUME_META_BEFORE=$(cat "$RESUME_META")
}

run_resume_spawn() {  # <issue-key> [extra spawn args...]
  local key=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$SEAM_HOME" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$RESUME_PANE_PATH" FM_FAKE_TMUX_LOG="$SEAM_LOG" \
    FM_FAKE_TMUX_WINDOWS="$FM_FAKE_TMUX_WINDOWS" \
    FM_FAKE_TMUX_HAS_SESSION="$FM_FAKE_TMUX_HAS_SESSION" \
    FM_FAKE_TMUX_LIST_RC="$FM_FAKE_TMUX_LIST_RC" \
    FM_FAKE_LSOF_CWD="$FM_FAKE_LSOF_CWD" \
    FM_FAKE_LSOF_RC="$FM_FAKE_LSOF_RC" \
    PATH="$SEAM_FAKEBIN:$PATH" \
    "$SPAWN" --resume "$key" "$@" 2>&1
}

# "A refusal creates no new ledger entry, mutates no existing entry, and leaves
# no spawn-side artifacts", asserted as three separate things because they fail
# separately: the window is the artifact, and the entry and the task record are
# each mutable by a different half of the mode.
assert_resume_created_nothing() {  # <what>
  local what=$1
  if [ -f "$SEAM_LOG" ] && grep -q 'new-window' "$SEAM_LOG"; then
    fail "$what created a tmux window; a refused resume must leave no endpoint behind"
  fi
  [ "$(cat "$SEAM_HOME/data/admission-ledger.json")" = "$RESUME_LEDGER_BEFORE" ] \
    || fail "$what changed the admission ledger; a refused resume must leave it exactly as it found it"
  [ ! -f "$RESUME_META" ] || [ "$(cat "$RESUME_META")" = "$RESUME_META_BEFORE" ] \
    || fail "$what rewrote the task record it refused to resume"
}

# Each flag names something the ledger entry or the task's own record already
# fixes, so accepting one would either restate it or contradict it. They are
# asserted one at a time because each is a separate conjunct: dropping any one
# leaves a resume that silently honours a contradicting flag.
test_resume_refuses_every_contradicting_flag() {
  local home out status
  home=$(make_admit_home resume-args on)
  set -- \
    "--relaunch|different verbs" \
    "--scout|recorded kind" \
    "--secondmate|recorded kind" \
    "--backend tmux|recorded backend" \
    "--mode no-mistakes|recorded delivery mode" \
    "--yolo off|recorded yolo posture" \
    "--branch feat/orn-9200-x|branch already admitted" \
    "--worktree $home|worktree already admitted"
  local pair flag needle
  for pair in "$@"; do
    flag=${pair%%|*}
    needle=${pair#*|}
    # shellcheck disable=SC2086 # each fixture flag is a deliberate 1-2 word argv.
    out=$(run_spawn "$home" --resume ORN-9200 $flag)
    status=$?
    expect_code 1 "$status" "--resume with $flag should be refused, got: $out"
    assert_contains "$out" "$needle" "--resume $flag was not refused for the reason it contradicts"
  done

  out=$(run_spawn "$home" --resume ORN-9200 some-task-id)
  status=$?
  expect_code 1 "$status" "--resume with a positional should be refused"
  assert_contains "$out" "resolves the task from the admission ledger" \
    "a positional beside --resume was not refused as a second, contradictory task"
  pass "--resume refuses every flag that would re-declare what the ledger entry or task record already fixes"
}

test_resume_requires_a_non_empty_key() {
  local home out status
  home=$(make_admit_home resume-emptykey on)
  out=$(run_spawn "$home" --resume '')
  status=$?
  expect_code 1 "$status" "an empty --resume value should be refused"
  assert_contains "$out" "--resume requires a non-empty value" \
    "refusal did not name the empty key"
  pass "--resume requires a non-empty issue key"
}

# With the guard off there is no ledger, so there is nothing to bind against -
# and no quarantine could have produced a resumable effort in the first place.
# Reading the absent ledger as "no entry" would be the same fail-open mistake as
# reading a missing ledger file as an empty one.
test_resume_is_refused_on_an_unguarded_home() {
  local home out status
  home=$(make_admit_home resume-unguarded '')
  out=$(run_spawn "$home" --resume ORN-9201)
  status=$?
  expect_code 1 "$status" "--resume on an unguarded home should be refused"
  assert_contains "$out" "admission guard is off for this home" \
    "refusal did not name the unguarded home as the reason"
  pass "--resume on a home whose guard is off is refused, not treated as an empty ledger"
}

# Never admitted and admitted-but-not-cleared are different mistakes with
# different fixes, so they get different messages rather than one "cannot
# resume". The quarantined half is also the one that must not silently proceed:
# an entry is still held throughout a quarantine, so a resume that ignored the
# status would restart an effort the founder deliberately stopped.
test_resume_refuses_an_absent_or_quarantined_entry() {
  local out status
  make_resume_case resume-absent resume-absent-z30 9210
  out=$(run_resume_spawn ORN-9299)
  status=$?
  expect_code 1 "$status" "--resume on a key with no entry should be refused"
  assert_contains "$out" "its status is 'absent'" \
    "refusal did not distinguish a key that was never admitted"
  assert_resume_created_nothing "a resume of an unadmitted key"

  make_resume_case resume-quarantined resume-quarantined-z31 9211
  FM_HOME="$SEAM_HOME" "$ADMIT" quarantine ORN-9211 >/dev/null \
    || fail "could not quarantine the seeded entry"
  RESUME_LEDGER_BEFORE=$(cat "$SEAM_HOME/data/admission-ledger.json")
  out=$(run_resume_spawn ORN-9211)
  status=$?
  expect_code 1 "$status" "--resume on a quarantined entry should be refused"
  assert_contains "$out" "its status is 'quarantined'" \
    "refusal did not distinguish an entry that is held but not cleared"
  assert_contains "$out" "bin/fm-admit.sh resume ORN-9211" \
    "refusal did not name the founder step that clears a quarantine"
  assert_resume_created_nothing "a resume of a quarantined entry"
  pass "--resume refuses an absent entry and a quarantined one, each as its own mistake"
}

# The entry names the worktree the lease is still held on. If it is not there,
# the effort it was admitted for is not there either, and the answer is to
# release the entry rather than to resume into a path that no longer exists.
test_resume_refuses_a_ledger_worktree_that_is_gone() {
  local out status
  make_resume_case resume-nowt resume-nowt-z32 9212
  rm -rf "$SEAM_WT"
  out=$(run_resume_spawn ORN-9212)
  status=$?
  expect_code 1 "$status" "--resume against a missing admitted worktree should be refused"
  assert_contains "$out" "which is not an existing directory" \
    "refusal did not name the missing worktree"
  assert_contains "$out" "the lease is still held" \
    "refusal did not say the entry is still holding a lease"
  assert_resume_created_nothing "a resume against a missing worktree"
  pass "--resume refuses an entry whose admitted worktree is gone rather than resuming into it"
}

# The branch half of "the entry's recorded branch and worktree match the
# preserved effort". Both arms matter: a worktree moved onto other work and a
# worktree left on a detached HEAD are both "not the effort that was admitted",
# and a check that only compared non-empty strings would pass the second.
test_resume_refuses_a_worktree_that_is_not_on_the_admitted_branch() {
  local out status
  make_resume_case resume-branch resume-branch-z33 9213
  git -C "$SEAM_WT" checkout -q -b feat/orn-9299-elsewhere
  out=$(run_resume_spawn ORN-9213)
  status=$?
  expect_code 1 "$status" "--resume onto a different branch should be refused"
  assert_contains "$out" "is on 'feat/orn-9299-elsewhere'" \
    "refusal did not name the branch the worktree is actually on"
  assert_resume_created_nothing "a resume onto a different branch"

  make_resume_case resume-detached resume-detached-z34 9214
  git -C "$SEAM_WT" checkout -q --detach
  out=$(run_resume_spawn ORN-9214)
  status=$?
  expect_code 1 "$status" "--resume onto a detached HEAD should be refused"
  assert_contains "$out" "is on 'a detached HEAD'" \
    "a detached HEAD was not named as the reason"
  assert_resume_created_nothing "a resume onto a detached HEAD"
  pass "--resume refuses a worktree that is not on the branch its entry was admitted for"
}

# A worktree is leased to exactly one task, so the admitted worktree maps back to
# exactly one task record. Zero and several are both refusals: guessing would
# resume the wrong task's brief, kind, and delivery contract, and there is no
# tie-break that is better than saying so.
test_resume_refuses_zero_or_several_tasks_for_the_admitted_worktree() {
  local out status
  make_resume_case resume-notask resume-notask-z35 9215
  rm -f "$RESUME_META"
  RESUME_META_BEFORE=
  out=$(run_resume_spawn ORN-9215)
  status=$?
  expect_code 1 "$status" "--resume with no task recording the worktree should be refused"
  assert_contains "$out" "there is nothing to resume" \
    "refusal did not say there was no task to resume"
  assert_resume_created_nothing "a resume with no matching task record"

  make_resume_case resume-twotasks resume-twotasks-z36 9216
  fm_write_meta "$SEAM_HOME/state/resume-twotasks-rival-z37.meta" \
    "window=firstmate:fm-resume-twotasks-rival-z37" \
    "worktree=$SEAM_WT" \
    "project=$SEAM_PROJ" \
    "harness=codex" \
    "kind=ship"
  out=$(run_resume_spawn ORN-9216)
  status=$?
  expect_code 1 "$status" "--resume with two tasks on the worktree should be refused"
  assert_contains "$out" "refusing rather than guessing which one" \
    "refusal did not say it declined to guess"
  assert_resume_created_nothing "a resume with two matching task records"
  pass "--resume refuses when zero or several tasks record the admitted worktree"
}

# The first half of the critical section, and the one that makes two concurrent
# resumes yield one worker: the second serializes on the ledger lock, and by the
# time it runs the first has already created the window it now finds.
test_resume_refuses_while_the_recorded_window_still_exists() {
  local out status
  make_resume_case resume-livewindow resume-livewindow-z38 9217
  FM_FAKE_TMUX_WINDOWS="fm-$RESUME_ID"
  out=$(run_resume_spawn ORN-9217)
  status=$?
  expect_code 1 "$status" "--resume with the recorded window still present should be refused"
  assert_contains "$out" "still exists" "refusal did not name the surviving window"
  assert_contains "$out" "--relaunch" \
    "refusal did not point at the verb that does adopt a live window"
  assert_resume_created_nothing "a resume blocked by a live window"
  pass "--resume refuses while the effort's window still exists rather than running a second worker beside it"
}

# "Window presence is grounds for refusal, never proof of absence" has a third
# case the other two hide: tmux answering neither way. Collapsing that into
# absent is the fail-open direction, and it is exactly what a tmux that is
# wedged, unreachable, or too old to list windows would produce.
test_resume_refuses_when_the_window_probe_cannot_answer() {
  local out status
  make_resume_case resume-blindprobe resume-blindprobe-z39 9218
  FM_FAKE_TMUX_LIST_RC=2
  out=$(run_resume_spawn ORN-9218)
  status=$?
  expect_code 1 "$status" "--resume should refuse when tmux cannot answer the window question"
  assert_contains "$out" "could not establish whether" \
    "refusal did not name the unanswered question"
  assert_resume_created_nothing "a resume whose window probe could not answer"
  pass "--resume refuses an unanswerable window probe rather than reading it as an absent window"
}

# A worker can outlive the window it was started in, so an absent window only
# earns the right to ask the harder question. Note the session is missing here
# too: that is a genuine absence (there is no window anywhere to find), so the
# case gets past the window check and fails on the process scan - which is also
# what pins a missing session as absent rather than as unanswerable.
test_resume_refuses_when_a_prior_worker_survives_the_window() {
  local out status wt_real
  make_resume_case resume-livepid resume-livepid-z40 9219
  FM_FAKE_TMUX_HAS_SESSION=1
  # The scan compares against the root it resolved with `pwd -P`, and the test
  # tmproot lives under a symlinked /var on macOS, so the stubbed cwd has to be
  # spelled the same way or the survivor lands outside the worktree it is in.
  wt_real=$(cd "$SEAM_WT" && pwd -P)
  FM_FAKE_LSOF_CWD="424242 $wt_real/src"
  out=$(run_resume_spawn ORN-9219)
  status=$?
  expect_code 1 "$status" "--resume with a surviving worker should be refused"
  assert_contains "$out" "still working under" "refusal did not name the surviving work"
  assert_contains "$out" "424242" "refusal did not name the pid that is still running"
  assert_resume_created_nothing "a resume blocked by a surviving worker"
  pass "--resume refuses a worker that outlived its window rather than starting a second one on the same worktree"
}

# The fail-closed half of the confirmed-dead check. An empty result and an
# unavailable scan are indistinguishable to a caller that collapses them, and
# only one of the two is proof of absence.
test_resume_refuses_when_the_confirmed_dead_scan_cannot_answer() {
  local out status
  make_resume_case resume-blindscan resume-blindscan-z41 9220
  FM_FAKE_LSOF_RC=2
  out=$(run_resume_spawn ORN-9220)
  status=$?
  expect_code 1 "$status" "--resume should refuse when the process scan fails"
  assert_contains "$out" "refusing rather than starting a second worker" \
    "refusal did not name the unanswered question"
  assert_contains "$out" "$SEAM_WT" "refusal did not name the root whose scan failed"
  assert_resume_created_nothing "a resume whose process scan could not answer"
  pass "--resume refuses a scan that cannot answer rather than reading it as nothing surviving"
}

# Resume creates a FRESH window, which starts in the project like any spawn, so
# the pane is walked into the preserved worktree explicitly. A pane that never
# gets there is an agent about to run outside the copy holding the effort's work.
test_resume_refuses_a_pane_that_never_reaches_the_admitted_worktree() {
  local out status
  make_resume_case resume-strandedpane resume-strandedpane-z42 9221
  RESUME_PANE_PATH=$SEAM_OTHER
  out=$(run_resume_spawn ORN-9221)
  status=$?
  expect_code 1 "$status" "a pane outside the admitted worktree should be refused"
  assert_contains "$out" "not the admitted worktree" \
    "refusal did not name the worktree the resume was for"
  pass "--resume refuses to start an agent in a pane that never reached the admitted worktree"
}

# The admitted path. What makes it a resume rather than a spawn is entirely in
# what does NOT change: no new entry, no second reservation, no new lease. The
# ledger is compared byte for byte before and after for exactly that reason.
test_resume_restarts_the_effort_without_touching_the_ledger() {
  local out status
  make_resume_case resume-ok resume-ok-z43 9222
  out=$(run_resume_spawn ORN-9222)
  status=$?
  expect_code 0 "$status" "a bound resume should succeed, got: $out"
  grep -q 'new-window' "$SEAM_LOG" \
    || fail "a successful resume created no replacement window"
  [ "$(cat "$SEAM_HOME/data/admission-ledger.json")" = "$RESUME_LEDGER_BEFORE" ] \
    || fail "a resume changed the ledger: $(cat "$SEAM_HOME/data/admission-ledger.json")"
  # The pane is walked into the preserved worktree by cd rather than by
  # `treehouse get`, because taking no new lease is half of what resume means.
  grep -q "cd .*$SEAM_WT" "$SEAM_LOG" \
    || fail "a resume did not walk its new pane into the preserved worktree"
  pass "a bound resume restarts the effort in a new window without writing to the ledger"
}

test_pair_on_an_unguarded_home_is_refused
test_guarded_ship_spawn_requires_the_pair
test_guarded_ship_spawn_refuses_branch_without_worktree
test_guarded_ship_spawn_refuses_worktree_without_branch
test_the_pair_is_refused_on_a_scout_and_a_secondmate
test_relaunch_refuses_a_redeclared_effort
test_the_pair_is_refused_in_a_batch
test_unreadable_admission_mode_is_refused_rather_than_treated_as_off
test_a_blank_admission_file_is_refused_rather_than_treated_as_off
test_a_non_regular_admission_entry_is_refused_rather_than_treated_as_off
test_internal_whitespace_does_not_normalize_a_typo_into_off
test_the_pair_requires_non_empty_values
test_an_orca_ship_spawn_cannot_be_admitted
test_a_diverged_data_directory_is_refused
test_an_admitted_ship_spawn_records_the_effort
test_a_spawn_refused_at_the_cap_creates_nothing
test_a_missing_ledger_refuses_the_spawn
test_a_worktree_that_does_not_exist_is_refused_before_admission
test_a_lease_that_misses_the_admitted_worktree_is_refused_and_stays_held
test_resume_refuses_every_contradicting_flag
test_resume_requires_a_non_empty_key
test_resume_is_refused_on_an_unguarded_home
test_resume_refuses_an_absent_or_quarantined_entry
test_resume_refuses_a_ledger_worktree_that_is_gone
test_resume_refuses_a_worktree_that_is_not_on_the_admitted_branch
test_resume_refuses_zero_or_several_tasks_for_the_admitted_worktree
test_resume_refuses_while_the_recorded_window_still_exists
test_resume_refuses_when_the_window_probe_cannot_answer
test_resume_refuses_when_a_prior_worker_survives_the_window
test_resume_refuses_when_the_confirmed_dead_scan_cannot_answer
test_resume_refuses_a_pane_that_never_reaches_the_admitted_worktree
test_resume_restarts_the_effort_without_touching_the_ledger

echo "# all fm-spawn-admit tests passed"
