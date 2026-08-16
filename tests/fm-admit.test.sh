#!/usr/bin/env bash
# tests/fm-admit.test.sh - behavior tests for the fail-closed admission guard
# (bin/fm-admit.sh): the flat-JSON ledger, its six refusals, the release /
# quarantine / resume subcommands, and the locked read-check-write that makes a
# cap of 1 hold under concurrency. No backend, no tmux, no worktree pool - the
# guard only ever touches its own ledger and lock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADMIT="$ROOT/bin/fm-admit.sh"

# Each case gets its own FM_HOME so a ledger left behind by one case can never
# satisfy or break the next.
FM_HOME_ROOT=

new_home() {
  FM_HOME_ROOT=$(fm_test_tmproot fm-admit) || fail "cannot create a fixture root"
  mkdir -p "$FM_HOME_ROOT/data"
}

# seed_ledger <json>: write the ledger body bootstrap would have provisioned.
seed_ledger() {
  printf '%s\n' "$1" > "$FM_HOME_ROOT/data/admission-ledger.json"
}

ledger_path() { printf '%s\n' "$FM_HOME_ROOT/data/admission-ledger.json"; }
lock_path() { printf '%s\n' "$FM_HOME_ROOT/data/admission-ledger.lock"; }

# admit_run <args...>: run the guard against the current fixture home, capturing
# merged output in OUT and the exit status in RC.
OUT=
RC=0

admit_run() {
  set +e
  OUT=$(FM_HOME="$FM_HOME_ROOT" "$ADMIT" "$@" 2>&1)
  RC=$?
  set -e
}

# assert_ledger_unchanged <label>: the ledger body must be byte-identical to
# BEFORE, and no temp file may be left behind next to it.
BEFORE=

snapshot_ledger() { BEFORE=$(cat "$(ledger_path)" 2>/dev/null || printf '<absent>'); }

assert_ledger_unchanged() {
  local now
  now=$(cat "$(ledger_path)" 2>/dev/null || printf '<absent>')
  [ "$now" = "$BEFORE" ] || fail "$1: the ledger changed"$'\n'"--- before ---"$'\n'"$BEFORE"$'\n'"--- after ---"$'\n'"$now"
}

assert_no_temp_files() {
  local leftovers
  leftovers=$(find "$FM_HOME_ROOT/data" -name '.admission-ledger.*' 2>/dev/null)
  [ -z "$leftovers" ] || fail "$1: temp files left in the data directory"$'\n'"$leftovers"
}

assert_lock_released() {
  [ ! -e "$(lock_path)" ] || fail "$1: the lock directory was not released"
}

entry_field() { # <key> <field>
  jq -r --arg k "$1" --arg f "$2" '.[$k][$f]' "$(ledger_path)"
}

# --- usage and dispatch -----------------------------------------------------

new_home
seed_ledger '{}'
snapshot_ledger

admit_run
expect_code 2 "$RC" "no subcommand"
assert_contains "$OUT" "Usage:" "a bare invocation must print usage"

admit_run not-a-subcommand
expect_code 2 "$RC" "unknown subcommand"
assert_contains "$OUT" "unknown subcommand: not-a-subcommand" "unknown subcommand must name itself"

admit_run --help
expect_code 0 "$RC" "--help"
assert_contains "$OUT" "fm-admit.sh admit --branch <name> --worktree <path>" "--help must document admit"

admit_run admit --branch feat/orn-1-x
expect_code 2 "$RC" "admit without --worktree"
assert_contains "$OUT" "admit needs --worktree <path>" "a missing --worktree must say so"

admit_run admit --branch feat/orn-1-x --worktree
expect_code 2 "$RC" "--worktree with no value"
assert_contains "$OUT" "--worktree needs a value" "a valueless flag must say so"

admit_run admit --branch feat/orn-1-x --worktree relative/path
expect_code 2 "$RC" "relative worktree"
assert_contains "$OUT" "absolute --worktree path" "a relative worktree must be rejected"

admit_run admit --branch feat/orn-1-x --worktree /pool/../etc
expect_code 2 "$RC" "traversal in worktree"
assert_contains "$OUT" "no '..' segment" "a '..' segment must be rejected rather than resolved"

admit_run release
expect_code 2 "$RC" "release with no key"
admit_run release ORN-1 ORN-2
expect_code 2 "$RC" "release with two keys"
admit_run release not-a-key
expect_code 2 "$RC" "release with a non-key"
assert_contains "$OUT" "not a Linear issue key: not-a-key" "a malformed key must be named"

assert_ledger_unchanged "argument errors"
pass "argument and usage errors exit 2, name the problem, and never touch the ledger"

# --- ledger-unusable: every unusable shape refuses, none is treated as empty --

new_home
BEFORE='<absent>'
admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1
expect_code 1 "$RC" "missing ledger"
assert_contains "$OUT" "refused (ledger-unusable)" "a missing ledger must refuse"
assert_contains "$OUT" "a missing ledger is never treated as empty" "the refusal must say a missing ledger is not an empty one"
assert_absent "$(ledger_path)" "a refusal must not create the ledger it could not read"
assert_lock_released "missing ledger"
pass "a missing ledger refuses as unusable and is never treated as empty"

# An FM_HOME bootstrap has never provisioned has no data directory at all, and
# that is not lock contention. It has to be said that way too: mkdir fails
# ENOENT on the missing parent, which an acquire loop cannot tell from a lock
# someone else holds, so an unguarded loop spends the whole wait bound and then
# blames a lock nobody is holding. The bound here is deliberately non-zero -
# refusing before the loop is the only way to answer this fast.
FM_HOME_ROOT=$(fm_test_tmproot fm-admit) || fail "cannot create a fixture root"
set +e
OUT=$(FM_HOME="$FM_HOME_ROOT" FM_ADMIT_LOCK_WAIT_SECS=3 "$ADMIT" \
  admit --branch feat/orn-1-x --worktree /pool/wt-1 2>&1)
RC=$?
set -e
expect_code 1 "$RC" "unprovisioned data directory"
assert_contains "$OUT" "refused (ledger-unusable)" "an unprovisioned data directory must refuse as unusable"
assert_contains "$OUT" "$FM_HOME_ROOT/data does not exist" "the refusal must name the directory that is missing"
assert_not_contains "$OUT" "lock-timeout" "a missing directory must never be reported as lock contention"
assert_absent "$(lock_path)" "a refusal must not create the lock directory it could not take"
assert_absent "$(ledger_path)" "a refusal must not provision the ledger bootstrap owns"
pass "an unprovisioned data directory refuses immediately instead of spinning out the lock wait"

new_home
seed_ledger '{}'
mv "$(ledger_path)" "$FM_HOME_ROOT/data/real.json"
ln -s "$FM_HOME_ROOT/data/real.json" "$(ledger_path)"
snapshot_ledger
admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1
expect_code 1 "$RC" "symlinked ledger"
assert_contains "$OUT" "it is a symlink" "a symlinked ledger must refuse as a symlink"
assert_ledger_unchanged "symlinked ledger"

new_home
mkdir -p "$(ledger_path)"
admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1
expect_code 1 "$RC" "directory ledger"
assert_contains "$OUT" "it is not a regular file" "a directory in the ledger's place must refuse"

new_home
seed_ledger '{ this is not json'
snapshot_ledger
admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1
expect_code 1 "$RC" "unparseable ledger"
assert_contains "$OUT" "refused (ledger-unusable)" "an unparseable ledger must refuse"
assert_ledger_unchanged "unparseable ledger"

new_home
seed_ledger '[]'
admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1
expect_code 1 "$RC" "array ledger"
assert_contains "$OUT" "refused (ledger-unusable)" "a JSON array is not a ledger object"

new_home
seed_ledger '{"ORN-1": {"branch": "feat/orn-1-x", "worktree": "/pool/wt-1"}}'
admit_run admit --branch feat/orn-2-y --worktree /pool/wt-2
expect_code 1 "$RC" "entry missing fields"
assert_contains "$OUT" "refused (ledger-unusable)" "an entry missing reserved_at/status must refuse"

new_home
seed_ledger '{"ORN-1": {"branch": "feat/orn-1-x", "worktree": "/pool/wt-1", "reserved_at": "2026-08-16T00:00:00Z", "status": "retired"}}'
admit_run admit --branch feat/orn-2-y --worktree /pool/wt-2
expect_code 1 "$RC" "unknown status"
assert_contains "$OUT" "refused (ledger-unusable)" "a status outside active|quarantined must refuse"

new_home
seed_ledger '{"not-a-key": {"branch": "feat/orn-1-x", "worktree": "/pool/wt-1", "reserved_at": "2026-08-16T00:00:00Z", "status": "active"}}'
admit_run admit --branch feat/orn-2-y --worktree /pool/wt-2
expect_code 1 "$RC" "non-ORN ledger key"
assert_contains "$OUT" "refused (ledger-unusable)" "a key outside the ORN-<n> shape must refuse"
pass "a parseable-but-schema-invalid ledger is unusable, not best-effort readable"

# --- admit: the happy path --------------------------------------------------

new_home
seed_ledger '{}'
admit_run admit --branch feat/orn-2529-admission-guard --worktree /pool/wt-1
expect_code 0 "$RC" "first admit"
assert_contains "$OUT" "admitted ORN-2529" "a successful admit must name the uppercased key"
[ "$(entry_field ORN-2529 branch)" = "feat/orn-2529-admission-guard" ] || fail "branch was not recorded verbatim"
[ "$(entry_field ORN-2529 worktree)" = "/pool/wt-1" ] || fail "worktree was not recorded"
[ "$(entry_field ORN-2529 status)" = "active" ] || fail "a new reservation must be active"
case "$(entry_field ORN-2529 reserved_at)" in
  ????-??-??T??:??:??Z) : ;;
  *) fail "reserved_at is not a UTC ISO-8601 stamp: $(entry_field ORN-2529 reserved_at)" ;;
esac
[ "$(jq 'length' "$(ledger_path)")" = 1 ] || fail "the ledger must hold exactly one entry"
[ -f "$(ledger_path)" ] && [ ! -L "$(ledger_path)" ] || fail "the ledger must still be a regular file after the rename"
assert_no_temp_files "first admit"
assert_lock_released "first admit"
pass "admit records {branch, worktree, reserved_at, status=active} under the uppercased key"

# A trailing slash is not a distinct binding.
new_home
seed_ledger '{}'
admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1/
expect_code 0 "$RC" "trailing-slash worktree"
[ "$(entry_field ORN-1 worktree)" = "/pool/wt-1" ] || fail "a trailing slash must be normalized away"
pass "a trailing slash is stripped so /pool/wt and /pool/wt/ cannot both be admitted"

# --- missing-key ------------------------------------------------------------

new_home
seed_ledger '{}'
snapshot_ledger

for BAD in \
  feat/no-key-at-all \
  orn-1-no-type-prefix \
  feat/prefix-orn-1 \
  feat/orn-1-x-orn-2-y \
  feat/orn-1/nested \
  feat/ORN-1-uppercase; do
  admit_run admit --branch "$BAD" --worktree /pool/wt-1
  expect_code 1 "$RC" "missing-key for '$BAD'"
  assert_contains "$OUT" "refused (missing-key)" "'$BAD' must be refused as missing-key"
done
assert_ledger_unchanged "missing-key refusals"
assert_lock_released "missing-key refusals"
pass "a branch must position exactly one lowercase key right after the type prefix, or it is refused"

# The lock is never taken for a malformed branch: the refusal lands even while
# another holder owns the lock, so a bad argument cannot wait out the bounded
# lock and cannot be misreported as a lock timeout.
mkdir "$(lock_path)"
admit_run admit --branch feat/no-key-at-all --worktree /pool/wt-1
expect_code 1 "$RC" "missing-key under a held lock"
assert_contains "$OUT" "refused (missing-key)" "a malformed branch must refuse before the lock is contended"
assert_not_contains "$OUT" "lock-timeout" "a malformed branch must not be reported as a lock timeout"
rmdir "$(lock_path)"
pass "branch shape is checked before the lock, so a bad argument never waits on a live admission"

# --- duplicate, binding-conflict, cap ---------------------------------------

new_home
seed_ledger '{}'
admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1
expect_code 0 "$RC" "seed admit"
snapshot_ledger

admit_run admit --branch feat/orn-1-different-slug --worktree /pool/wt-2
expect_code 1 "$RC" "duplicate key"
assert_contains "$OUT" "refused (duplicate)" "an already-held key must refuse as duplicate"
assert_contains "$OUT" "ORN-1 (active)" "the duplicate refusal must name the key and its status"

admit_run admit --branch feat/orn-2-y --worktree /pool/wt-1
expect_code 1 "$RC" "worktree already bound"
assert_contains "$OUT" "refused (binding-conflict)" "a reused worktree must refuse as binding-conflict"

admit_run admit --branch feat/orn-1-x --worktree /pool/wt-2
expect_code 1 "$RC" "branch already bound"
assert_contains "$OUT" "refused (duplicate)" "a reused branch carrying the held key is a duplicate first"

admit_run admit --branch feat/orn-2-y --worktree /pool/wt-2
expect_code 1 "$RC" "cap reached"
assert_contains "$OUT" "refused (cap)" "an unrelated second effort must refuse at the cap"
assert_contains "$OUT" "1 of 1" "the cap refusal must report the occupancy it enforced"

assert_ledger_unchanged "refusals at cap"
assert_no_temp_files "refusals at cap"
assert_lock_released "refusals at cap"
pass "duplicate, binding-conflict, and cap each refuse distinctly and none mutates the ledger"

# --- release ----------------------------------------------------------------

admit_run release orn-1
expect_code 0 "$RC" "release lowercase key"
assert_contains "$OUT" "released ORN-1" "release must uppercase its argument"
[ "$(jq 'length' "$(ledger_path)")" = 0 ] || fail "release must remove the entry"

snapshot_ledger
admit_run release ORN-1
expect_code 1 "$RC" "release absent key"
assert_contains "$OUT" "no entry for ORN-1" "releasing an absent key must say so"
assert_ledger_unchanged "release of an absent key"

admit_run admit --branch feat/orn-2-y --worktree /pool/wt-2
expect_code 0 "$RC" "admit after release"
pass "release frees the slot, is case-insensitive, and exits non-zero on an absent key"

# --- quarantine and resume --------------------------------------------------

new_home
seed_ledger '{}'
admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1
expect_code 0 "$RC" "seed admit for quarantine"

admit_run quarantine orn-1
expect_code 0 "$RC" "quarantine"
assert_contains "$OUT" "ORN-1 quarantined" "quarantine must confirm the new status"
[ "$(entry_field ORN-1 status)" = "quarantined" ] || fail "quarantine must flip the status"

snapshot_ledger
admit_run quarantine ORN-1
expect_code 0 "$RC" "quarantine is idempotent"
assert_contains "$OUT" "already quarantined" "a repeated quarantine must confirm rather than alarm"
assert_ledger_unchanged "repeated quarantine"

# A quarantined entry keeps counting against the cap.
admit_run admit --branch feat/orn-2-y --worktree /pool/wt-2
expect_code 1 "$RC" "cap with a quarantined entry"
assert_contains "$OUT" "refused (cap)" "a quarantined entry must still occupy the cap"

admit_run admit --branch feat/orn-1-x --worktree /pool/wt-1
expect_code 1 "$RC" "duplicate against a quarantined entry"
assert_contains "$OUT" "ORN-1 (quarantined)" "the duplicate refusal must report the quarantined status"

admit_run resume orn-1
expect_code 0 "$RC" "resume"
assert_contains "$OUT" "ORN-1 active" "resume must confirm the restored status"
[ "$(entry_field ORN-1 status)" = "active" ] || fail "resume must flip the status back"
[ "$(jq 'length' "$(ledger_path)")" = 1 ] || fail "resume must not change occupancy"

snapshot_ledger
admit_run resume ORN-1
expect_code 0 "$RC" "resume is idempotent"
assert_contains "$OUT" "already active" "a repeated resume must confirm rather than alarm"
assert_ledger_unchanged "repeated resume"

admit_run quarantine ORN-404
expect_code 1 "$RC" "quarantine absent key"
assert_contains "$OUT" "no entry for ORN-404" "quarantining an absent key must say so"
admit_run resume ORN-404
expect_code 1 "$RC" "resume absent key"
assert_contains "$OUT" "no entry for ORN-404" "resuming an absent key must say so"
[ "$(jq 'has("ORN-404")' "$(ledger_path)")" = false ] || fail "resume must never create an entry"
assert_lock_released "quarantine and resume"
pass "quarantine and resume flip one status, are idempotent, hold occupancy, and never create an entry"

# --- lock-timeout -----------------------------------------------------------

new_home
seed_ledger '{}'
mkdir "$(lock_path)"
printf '999999\n' > "$(lock_path)/pid"
snapshot_ledger

set +e
OUT=$(FM_HOME="$FM_HOME_ROOT" FM_ADMIT_LOCK_WAIT_SECS=0 "$ADMIT" \
  admit --branch feat/orn-1-x --worktree /pool/wt-1 2>&1)
RC=$?
set -e
expect_code 1 "$RC" "lock timeout"
assert_contains "$OUT" "refused (lock-timeout)" "a held lock must refuse as lock-timeout"
assert_contains "$OUT" "no lock, no read, no spawn" "the refusal must state the fail-closed rule"
assert_present "$(lock_path)" "a held lock must never be stolen"
assert_grep 999999 "$(lock_path)/pid" "the incumbent holder's lock contents must be left intact"
assert_ledger_unchanged "lock timeout"
rmdir_out=$(rm -rf "$(lock_path)" 2>&1) || fail "cannot clear the fixture lock: $rmdir_out"

# The bound is validated, not silently coerced.
set +e
OUT=$(FM_HOME="$FM_HOME_ROOT" FM_ADMIT_LOCK_WAIT_SECS=soon "$ADMIT" \
  admit --branch feat/orn-1-x --worktree /pool/wt-1 2>&1)
RC=$?
set -e
expect_code 2 "$RC" "non-numeric lock wait"
assert_contains "$OUT" "must be a non-negative integer" "a non-numeric bound must be rejected"
pass "a held lock refuses without stealing it, and the wait bound is validated rather than coerced"

# --- the locked read-check-write is the linearization point ------------------
#
# The failure this proves is the one the lock exists for: two admissions reading
# the same free slot and both writing. Two things have to be arranged before a
# shell test can actually observe it.
#
# The racers have to genuinely overlap. Spawning them in a loop does not manage
# that: starting one shell costs more than a whole admission takes, so racer 1
# is finished before racer 3 exists. So the test holds the lock itself, waits
# until every racer is spinning in the guard's bounded-wait acquire loop, and
# only then releases it.
#
# And the critical section has to be wider than the 0.1s the acquire loop sleeps
# between attempts, or a second racer cannot get inside it even when the guard
# leaves it open. A jq shim first on the racers' PATH buys that: it is the one
# command the section is built out of, the guard shells out to it, and slowing
# it stretches the window without putting a delay hook in the guard for tests to
# reach. The lock's correctness does not depend on how fast the section runs, so
# stretching it changes only what this test can see. Concretely, it stretches
# the span between the read and the write to roughly four shim delays, which a
# racer polling every 0.1s lands inside - so a lock released anywhere before the
# write shows up here as more than one reservation.

new_home
seed_ledger '{}'
CONCURRENT=8
STATUS_DIR="$FM_HOME_ROOT/status"
STARTED_DIR="$FM_HOME_ROOT/started"
SLOW_BIN="$FM_HOME_ROOT/slowbin"
mkdir -p "$STATUS_DIR" "$STARTED_DIR" "$SLOW_BIN"

REAL_JQ=$(command -v jq) || fail "jq is required to widen the critical section"
cat > "$SLOW_BIN/jq" <<EOF
#!/usr/bin/env bash
sleep 0.12
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$SLOW_BIN/jq"

mkdir "$(lock_path)"

for i in $(seq 1 "$CONCURRENT"); do
  (
    # Disarm the library's cleanup traps: a backgrounded subshell inherits them,
    # and letting one fire would delete this fixture root out from under the
    # siblings still racing for the slot.
    trap - EXIT INT TERM
    # A refusal is the expected outcome for all but one racer, and errexit is
    # live in the parent: without this the losers die on the refusal and never
    # record the status this case counts.
    set +e
    : > "$STARTED_DIR/$i"
    PATH="$SLOW_BIN:$PATH" FM_HOME="$FM_HOME_ROOT" FM_ADMIT_LOCK_WAIT_SECS=60 "$ADMIT" admit \
      --branch "feat/orn-$i-effort" --worktree "/pool/wt-$i" >/dev/null 2>&1
    printf '%s\n' "$?" > "$STATUS_DIR/$i"
  ) &
done

BARRIER_DEADLINE=$((SECONDS + 60))
while [ "$(find "$STARTED_DIR" -type f | wc -l | tr -d '[:space:]')" -lt "$CONCURRENT" ]; do
  [ "$SECONDS" -lt "$BARRIER_DEADLINE" ] || fail "only $(find "$STARTED_DIR" -type f | wc -l) of $CONCURRENT racers started"
  sleep 0.1
done
# Every racer has been handed to exec; settle long enough that each has reached
# the guard's acquire loop before the lock it is waiting on disappears.
sleep 1
rmdir "$(lock_path)"
wait

ADMITTED=0
for i in $(seq 1 "$CONCURRENT"); do
  [ -f "$STATUS_DIR/$i" ] || fail "concurrent admission $i never reported a status"
  [ "$(cat "$STATUS_DIR/$i")" = 0 ] && ADMITTED=$((ADMITTED + 1))
done
[ "$ADMITTED" = 1 ] || fail "exactly one of $CONCURRENT concurrent admissions must succeed, got $ADMITTED"
[ "$(jq 'length' "$(ledger_path)")" = 1 ] || fail "the ledger must hold exactly one entry after $CONCURRENT concurrent admissions"
jq -e 'to_entries | all(.value.status == "active")' "$(ledger_path)" >/dev/null \
  || fail "the surviving entry must be a well-formed active reservation"
assert_no_temp_files "concurrent admissions"
assert_lock_released "concurrent admissions"
pass "$CONCURRENT concurrent admissions against a cap of 1 yield exactly one reservation and one intact ledger"

# --- ledger content is data, never evaluated --------------------------------

new_home
mkdir -p "$FM_HOME_ROOT/canary"
# The unexpanded $(...) and `...` are the payload: this test asserts the guard
# never lets them reach a shell, so they must survive into the ledger literally.
# shellcheck disable=SC2016
INJECTED='feat/orn-1-$(touch '"$FM_HOME_ROOT"'/canary/pwned)`touch '"$FM_HOME_ROOT"'/canary/pwned2`'
seed_ledger "$(jq -n --arg b "$INJECTED" \
  '{"ORN-1": {branch: $b, worktree: "/pool/wt-1", reserved_at: "2026-08-16T00:00:00Z", status: "active"}}')"

admit_run quarantine ORN-1
expect_code 0 "$RC" "quarantine with a hostile branch value"
admit_run admit --branch feat/orn-2-y --worktree /pool/wt-2
expect_code 1 "$RC" "admit against a hostile ledger value"
assert_absent "$FM_HOME_ROOT/canary/pwned" "a ledger value must never reach a shell"
assert_absent "$FM_HOME_ROOT/canary/pwned2" "a ledger value must never reach a shell"
[ "$(entry_field ORN-1 branch)" = "$INJECTED" ] || fail "the hostile value must round-trip through the rewrite verbatim"
pass "ledger content reaches jq only as --arg data and is never evaluated, even across a rewrite"

echo "# fm-admit.test.sh: all assertions passed"
