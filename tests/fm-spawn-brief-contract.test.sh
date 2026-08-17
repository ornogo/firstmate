#!/usr/bin/env bash
# The worker-landed-lite delivery-contract refusal: bin/fm-spawn.sh will not
# launch a worker whose brief header does not carry the contract sentinel.
#
# Two layers, because they fail for different reasons and a test that only
# covered one would miss the other entirely:
#
#   1. The scan rule itself (fm_brief_header_carries_contract in
#      bin/fm-brief-contract-lib.sh). The rule is "read from line 1 to the first
#      task-body delimiter, exclusive, and require the sentinel as a whole line
#      in that region", and every interesting case is about the boundary rather
#      than about spawning. Driving those through a whole spawn would say
#      nothing extra while costing a process each.
#   2. The wiring in bin/fm-spawn.sh: that the refusal is reached at all, that it
#      is reached BEFORE the delivery-mode agreement check rather than after, and
#      that secondmate charters are excluded from it.
#
# The wiring cases assert on the absence of state/<id>.meta as well as on the
# refusal text, for the reason tests/fm-spawn-admit.test.sh gives: a guard that
# had drifted below the backend block would still print the same refusal while
# having already made a window.
#
# Ordering is asserted by construction rather than by reading the source. A
# brief that passes the sentinel check is fed to a spawn carrying a deliberate
# --mode disagreement, so the delivery-mismatch error is reachable only by
# getting past the sentinel guard; the mismatch text appearing is the proof that
# the guard passed. The same spawn shape is used for the refusal cases, so a
# guard that had moved below the mode check would print the mismatch text there
# and fail them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-brief-contract)
# Stock macOS sets TMPDIR with a trailing slash, so the fixture root arrives with
# a doubled separator; squeeze it out the way tests/fm-spawn-admit.test.sh does.
TMP_ROOT=$(printf '%s\n' "$TMP_ROOT" | tr -s '/')
export FM_BACKEND=tmux

# shellcheck source=bin/fm-brief-contract-lib.sh
. "$ROOT/bin/fm-brief-contract-lib.sh"

SENTINEL=$FM_DELIVERY_CONTRACT_SENTINEL
DELIM=$FM_BRIEF_TASK_BODY_DELIMITER
MODE_PREFIX=$FM_BRIEF_DELIVERY_MODE_PREFIX

# --- 1. the scan rule ------------------------------------------------------

# carries <name> <brief text> -> 0/1 from the scan rule, against a real file.
# The rule reads a path, so the fixtures are files rather than strings; writing
# them per case keeps each case's brief shape visible at its assertion.
carries() {
  local name=$1 text=$2 dir
  dir="$TMP_ROOT/scan/$name"
  mkdir -p "$dir"
  printf '%s' "$text" > "$dir/brief.md"
  fm_brief_header_carries_contract "$dir/brief.md"
}

test_template_header_satisfies_the_rule() {
  carries template "\
You are a crewmate.
$SENTINEL

$DELIM
Do the thing.
" || fail "the template header shape should satisfy the scan rule"
  pass "a header carrying the sentinel above the delimiter satisfies the rule"
}

# The whole point of bounding the region: a task body is issue-derived text that
# firstmate does not control, so a sentinel appearing in it means nothing about
# what the brief actually instructs.
test_sentinel_only_in_the_task_body_does_not_satisfy() {
  if carries body-only "\
You are a crewmate.

$DELIM
Do the thing. The contract line is $SENTINEL
"; then
    fail "a sentinel below the delimiter should not satisfy the rule"
  fi
  pass "a sentinel in the task body does not satisfy the rule"
}

# The same case stated the other way round, because this is the one an attacker
# or a careless paste actually produces: the header is bare, and the body
# carries the line. Neither half alone is a pass, and the body half must not
# rescue the header half.
test_task_body_sentinel_cannot_rescue_a_bare_header() {
  if carries no-rescue "\
You are a crewmate.
This header says nothing about delivery.

$DELIM
$SENTINEL
"; then
    fail "a body sentinel should not rescue a header that lacks one"
  fi
  pass "a sentinel alone on a body line cannot rescue a bare header"
}

# A body heading that looks like the delimiter sits below the real first one, so
# first-occurrence bounding already ignores it. Asserted because a future
# last-occurrence or any-occurrence reading would silently widen the region to
# include attacker-controlled text.
test_a_delimiter_lookalike_in_the_body_cannot_extend_the_region() {
  if carries lookalike "\
You are a crewmate.
This header says nothing about delivery.

$DELIM
Do the thing.

$DELIM
$SENTINEL
"; then
    fail "a second delimiter should not extend the scanned region"
  fi
  pass "a delimiter-looking line in the body cannot extend the scanned region"
}

# No delimiter bounds no header region, so there is nothing the rule can vouch
# for. Refusing is the fail-closed reading; the fail-open one is to give up on
# bounding and scan the whole file, which is what the next case rules out.
test_a_brief_with_no_delimiter_is_refused() {
  if carries no-delimiter "\
You are a crewmate.
$SENTINEL
Do the thing.
"; then
    fail "a brief with no delimiter should be refused even though the sentinel is present"
  fi
  pass "a brief carrying no delimiter at all is refused like a missing sentinel"
}

# The specific fallback that must not exist. This brief would pass a whole-file
# scan twice over - the sentinel is present, and present below a delimiter - so
# a rule that ever falls back to scanning the file accepts it.
test_the_rule_never_falls_back_to_scanning_the_whole_file() {
  if carries no-fallback "\
You are a crewmate.
This header says nothing about delivery.

$DELIM
$SENTINEL
$SENTINEL
"; then
    fail "the rule fell back to scanning the whole file"
  fi
  pass "the rule never falls back to a whole-file scan"
}

# Whole-line, not substring: a line that merely mentions the sentinel is prose,
# not a declaration, and prose is exactly what a task body is full of.
test_the_sentinel_must_be_a_whole_line() {
  if carries substring "\
You are a crewmate.
Note: this brief predates $SENTINEL and does not follow it.

$DELIM
Do the thing.
"; then
    fail "a sentinel embedded in a longer line should not satisfy the rule"
  fi
  pass "the sentinel must be an exact whole line, not a substring"
}

# header_mode <name> <brief text> -> prints the mode the rule reads, empty when
# it reads none. Same file-backed shape as carries() above, for the same reason.
header_mode() {
  local name=$1 text=$2 dir
  dir="$TMP_ROOT/scan/$name"
  mkdir -p "$dir"
  printf '%s' "$text" > "$dir/brief.md"
  fm_brief_header_delivery_mode "$dir/brief.md" || true
}

test_the_header_mode_is_read_from_the_header() {
  local got
  got=$(header_mode mode-header "\
You are a crewmate.
$SENTINEL
${MODE_PREFIX}no-mistakes

$DELIM
Do the thing.
")
  [ "$got" = no-mistakes ] || fail "the header's mode should be read, got '$got'"
  pass "the delivery mode is read from the header region"
}

# The bug this pins: the mode used to be parsed from the whole file, so the
# task body - which is issue-derived text firstmate does not control - could
# supply the very value it was going to be checked against. A brief recording
# no mode in its header records no mode, whatever its task text says.
test_a_body_supplied_mode_is_not_read() {
  local got
  got=$(header_mode mode-body "\
You are a crewmate.
$SENTINEL

$DELIM
${MODE_PREFIX}no-mistakes
Do the thing.
")
  [ -z "$got" ] || fail "a task-body mode line was read as the brief's mode: '$got'"
  pass "a mode line in the task body is not read as the brief's mode"
}

# Reading the LAST match instead of the first is the natural cheap fix, and it
# does not work: a scout brief carries no mode line of its own, so the forged
# one is the only match either way. Pinned so the cheap fix is not reintroduced.
test_a_body_mode_cannot_win_by_being_the_only_match() {
  local got
  got=$(header_mode mode-body-only "\
You are a crewmate.
$SENTINEL

$DELIM
${MODE_PREFIX}direct-PR
")
  [ -z "$got" ] || fail "a sole body mode line was read as the brief's mode: '$got'"
  pass "a body mode line is ignored even when it is the only one in the file"
}

# The header's own line wins over a body line placed above it in the file, so
# the rule is a region rule and not a first-or-last-match rule.
test_the_header_mode_wins_over_a_body_line() {
  local got
  got=$(header_mode mode-both "\
You are a crewmate.
$SENTINEL
${MODE_PREFIX}no-mistakes

$DELIM
${MODE_PREFIX}local-only
Do the thing.
")
  [ "$got" = no-mistakes ] || fail "the body line overrode the header's mode: '$got'"
  pass "the header's mode wins over a task-body mode line"
}

# --- 2. the wiring in fm-spawn.sh ------------------------------------------

# make_home <name> builds a bare unguarded home. Unguarded (no config/admission)
# is what lets these spawns run without --branch/--worktree, which
# tests/fm-spawn-admit.test.sh pins as the legacy shape; this suite is about the
# brief, so it stays on the shape that reaches the brief checks with the fewest
# other requirements.
#
# The harness is pinned because an unpinned one is resolved by detecting the
# harness firstmate is itself running under, which makes the suite read a
# property of the host rather than of the brief. A host with no harness around
# it resolves "unknown", and fm-spawn.sh refuses an unknown harness ABOVE the
# brief checks, so every case below would fail for a reason it is not testing.
# The backend is pinned for the same reason. Any verified adapter serves, and
# the one case that reaches a backend reaches a fake tmux placed on PATH.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$home"
}

# make_project <name> builds the git checkout a ship spawn resolves as its
# project.
make_project() {
  local name=$1 proj
  proj="$TMP_ROOT/$name/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  printf 'x\n' > "$proj/f"
  git -C "$proj" add -A
  git -C "$proj" -c user.email=fixture@example.invalid -c user.name=fixture commit -qm init
  printf '%s\n' "$proj"
}

run_spawn() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND=tmux \
    "$SPAWN" "$@" 2>&1
}

# The refusal has to happen before anything exists to clean up, so every wiring
# case checks the same thing: no recorded task.
assert_no_task_recorded() {
  local home=$1 id=$2 context=$3
  assert_absent "$home/state/$id.meta" "$context: a refused spawn recorded a task"
}

test_a_ship_brief_without_the_sentinel_is_refused() {
  local home proj out status id=contract-missing-z1
  home=$(make_home missing)
  proj=$(make_project missing)
  mkdir -p "$home/data/$id"
  printf 'You are a crewmate.\n\n%s\nDo the thing.\n' "$DELIM" > "$home/data/$id/brief.md"
  out=$(run_spawn "$home" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a ship brief with no delivery contract should be refused"
  assert_contains "$out" "carries no worker-landed-lite delivery contract" \
    "refusal did not name the missing delivery contract"
  assert_no_task_recorded "$home" "$id" "missing sentinel"
  pass "a ship spawn whose brief header lacks the sentinel is refused"
}

# Upstream warned here and launched anyway. That is the fail-open this replaces,
# so the case asserts the exit code as much as the text: a warning that still
# launched would print something similar and return 0.
test_the_refusal_is_a_hard_stop_not_a_warning() {
  local home proj out status id=contract-hardstop-z2
  home=$(make_home hardstop)
  proj=$(make_project hardstop)
  mkdir -p "$home/data/$id"
  printf 'You are a crewmate.\n\n%s\nDo the thing.\n' "$DELIM" > "$home/data/$id/brief.md"
  out=$(run_spawn "$home" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "the missing-contract refusal must exit nonzero, not warn and continue"
  assert_not_contains "$out" "warning:" \
    "the refusal still emitted a warning, which is the fail-open shape it replaces"
  assert_no_task_recorded "$home" "$id" "hard stop"
  pass "a missing delivery contract is a hard refusal, not a warning that launches anyway"
}

# A brief whose header is bare but whose body carries the line, run end to end.
# The scan rule already covers the boundary; this covers that fm-spawn.sh calls
# the bounded rule and not some looser check of its own.
test_a_ship_spawn_is_refused_when_only_the_body_carries_the_sentinel() {
  local home proj out status id=contract-bodyonly-z3
  home=$(make_home bodyonly)
  proj=$(make_project bodyonly)
  mkdir -p "$home/data/$id"
  printf 'You are a crewmate.\n\n%s\n%s\n' "$DELIM" "$SENTINEL" > "$home/data/$id/brief.md"
  out=$(run_spawn "$home" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a spawn whose brief carries the sentinel only in the body should be refused"
  assert_contains "$out" "carries no worker-landed-lite delivery contract" \
    "refusal did not name the missing delivery contract"
  assert_no_task_recorded "$home" "$id" "body-only sentinel"
  pass "fm-spawn.sh applies the bounded rule, not a whole-file search"
}

# The positive case, and the ordering case, in one. A real generated brief is
# used rather than a hand-written fixture so the emitter and the checker are
# pinned to each other instead of both to this file's idea of the format. The
# spawn then carries a --mode the brief disagrees with, so reaching the
# delivery-mismatch error proves the sentinel guard passed and sits above it.
test_a_generated_brief_passes_the_guard_and_reaches_the_mode_check() {
  local home proj out status id=contract-generated-z4
  home=$(make_home generated)
  proj=$(make_project generated)
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE='' \
    "$BRIEF" "$id" "$(basename "$proj")" --mode no-mistakes > /dev/null
  out=$(run_spawn "$home" "$id" "$proj" --mode direct-PR --yolo off)
  status=$?
  expect_code 1 "$status" "the mismatched --mode should still be refused"
  assert_not_contains "$out" "carries no worker-landed-lite delivery contract" \
    "a template-generated brief was refused for lacking the delivery contract"
  assert_contains "$out" "delivery mismatch for $id" \
    "the spawn did not reach the delivery-mode check, so the guard's position is unproven"
  pass "a template-generated brief passes the guard, which sits above the delivery-mode check"
}

# The other half of the fail-open removal. A brief can carry the sentinel and
# still record no mode - the sentinel is a literal line, and a scout-shaped
# brief carries it without one - so this stayed a separate check rather than
# being folded into the sentinel guard, and it stopped warning too.
test_a_ship_brief_with_no_mode_line_is_refused() {
  local home proj out status id=contract-nomode-z5
  home=$(make_home nomode)
  proj=$(make_project nomode)
  mkdir -p "$home/data/$id"
  printf 'You are a crewmate.\n%s\n\n%s\nDo the thing.\n' "$SENTINEL" "$DELIM" \
    > "$home/data/$id/brief.md"
  out=$(run_spawn "$home" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a ship brief recording no delivery mode should be refused"
  assert_contains "$out" "records no delivery contract line" \
    "refusal did not name the missing mode line"
  assert_not_contains "$out" "warning:" \
    "the missing mode line still warned instead of refusing"
  assert_no_task_recorded "$home" "$id" "no mode line"
  pass "a ship brief carrying the sentinel but no mode line is refused, not warned about"
}

# A secondmate charter carries no sentinel and no task body, therefore no
# delimiter, so the rule that refuses an unbounded brief would refuse every
# charter if the kind gate were not there.
#
# Proving the exclusion needs the spawn to get PAST the guard, which means
# reaching the backend. A fake tmux that refuses gives that a deterministic
# landing point on any host: the marker can only be printed from below the
# guard. Asserting only the absence of the refusal would pass vacuously if the
# spawn had died above the guard for an unrelated reason.
test_a_secondmate_charter_is_excluded_from_the_guard() {
  local home sub out fakebin id=contract-secondmate-z6
  home=$(make_home secondmate)
  sub="$TMP_ROOT/secondmate/sub"
  # A secondmate home is a firstmate home, so it needs the markers fm-spawn.sh
  # checks for one (AGENTS.md and bin/) before it will launch into it.
  mkdir -p "$sub/data" "$sub/state" "$sub/config" "$sub/projects" "$sub/bin"
  printf '%s\n' "$id" > "$sub/.fm-secondmate-home"
  printf '# home\n' > "$sub/AGENTS.md"
  printf 'You are a second mate.\nScope: fixture.\n' > "$sub/data/charter.md"

  fakebin=$(fm_fakebin "$TMP_ROOT/secondmate")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
echo "fake tmux reached: the spawn got past the brief checks" >&2
exit 1
SH
  chmod +x "$fakebin/tmux"

  out=$(PATH="$fakebin:$PATH" FM_SKIP_SECONDMATE_INHERIT=1 \
    run_spawn "$home" "$id" "$sub" --secondmate)
  assert_not_contains "$out" "carries no worker-landed-lite delivery contract" \
    "a secondmate charter was refused for lacking the delivery contract"
  assert_contains "$out" "fake tmux reached" \
    "the secondmate spawn never reached the backend, so the exclusion is unproven"
  pass "a secondmate charter is excluded from the delivery-contract guard"
}

# inject_task_body_line <brief> <line> puts a line into the issue-derived task
# body, immediately below the delimiter - exactly where a task description
# lands. Done against a real generated brief so the case tracks the template.
inject_task_body_line() {
  local brief=$1 line=$2 tmp
  tmp="$brief.injected"
  awk -v want="$DELIM" -v add="$line" '
    { print }
    !done_it && $0 == want { print add; done_it = 1 }
  ' "$brief" > "$tmp"
  mv "$tmp" "$brief"
}

# The reviewer-reported attack, end to end against real generated briefs: a
# SCOUT brief - whose deliverable is a report and never a PR - accepted as a
# ship task purely because its task text contains a mode line. Before the mode
# was read from the header region, this spawn launched a worker holding scout
# instructions while the task record said ship, and nothing downstream could
# notice the disagreement.
test_a_body_mode_cannot_make_a_scout_brief_pass_a_ship_spawn() {
  local home proj out status id=contract-scoutbody-z7
  home=$(make_home scoutbody)
  proj=$(make_project scoutbody)
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE='' \
    "$BRIEF" "$id" "$(basename "$proj")" --scout > /dev/null
  inject_task_body_line "$home/data/$id/brief.md" "${MODE_PREFIX}no-mistakes"

  out=$(run_spawn "$home" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a scout brief must not pass a ship spawn on a body-supplied mode"
  assert_contains "$out" "records no delivery contract line" \
    "the body-supplied mode satisfied the ship spawn"
  assert_no_task_recorded "$home" "$id" "body-supplied mode"
  pass "a task-body mode line cannot make a scout brief pass a ship spawn"
}

# The same hole in its quieter form: the task text silently choosing the rigor
# its own task is validated under. The brief is generated no-mistakes and its
# body asks for direct-PR; the header's mode must be what the spawn checks, so
# the downgrade surfaces as a mismatch instead of being granted.
test_a_body_mode_cannot_downgrade_the_recorded_rigor() {
  local home proj out status id=contract-downgrade-z8
  home=$(make_home downgrade)
  proj=$(make_project downgrade)
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE='' \
    "$BRIEF" "$id" "$(basename "$proj")" --mode no-mistakes > /dev/null
  inject_task_body_line "$home/data/$id/brief.md" "${MODE_PREFIX}direct-PR"

  out=$(run_spawn "$home" "$id" "$proj" --mode direct-PR --yolo off)
  status=$?
  expect_code 1 "$status" "a body-supplied mode must not authorize a rigor downgrade"
  assert_contains "$out" "the brief says mode=no-mistakes" \
    "the spawn read the task body's mode instead of the header's"
  assert_no_task_recorded "$home" "$id" "body-supplied downgrade"
  pass "a task-body mode line cannot downgrade the rigor a ship task is validated under"
}

test_template_header_satisfies_the_rule
test_sentinel_only_in_the_task_body_does_not_satisfy
test_task_body_sentinel_cannot_rescue_a_bare_header
test_a_delimiter_lookalike_in_the_body_cannot_extend_the_region
test_a_brief_with_no_delimiter_is_refused
test_the_rule_never_falls_back_to_scanning_the_whole_file
test_the_sentinel_must_be_a_whole_line
test_a_ship_brief_without_the_sentinel_is_refused
test_the_refusal_is_a_hard_stop_not_a_warning
test_a_ship_spawn_is_refused_when_only_the_body_carries_the_sentinel
test_a_generated_brief_passes_the_guard_and_reaches_the_mode_check
test_a_ship_brief_with_no_mode_line_is_refused
test_a_secondmate_charter_is_excluded_from_the_guard
test_the_header_mode_is_read_from_the_header
test_a_body_supplied_mode_is_not_read
test_a_body_mode_cannot_win_by_being_the_only_match
test_the_header_mode_wins_over_a_body_line
test_a_body_mode_cannot_make_a_scout_brief_pass_a_ship_spawn
test_a_body_mode_cannot_downgrade_the_recorded_rigor
