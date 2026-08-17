#!/usr/bin/env bash
# tests/brief-fixture-lib.sh - the one writer of contract-valid brief fixtures.
#
# bin/fm-spawn.sh refuses to launch a ship or scout worker whose brief header
# region does not carry the worker-landed-lite delivery contract, and a ship
# spawn additionally requires the delivery-mode line there.
# bin/fm-brief-contract-lib.sh owns those strings and the region rule. Any test
# that runs a real spawn therefore needs a brief shaped like a generated one; a
# one-line placeholder is refused before the test reaches what it came to prove.
#
# This is a file of its own rather than a helper inside tests/lib.sh because the
# backend and end-to-end suites deliberately do not source that library - it
# bundles temp-root, fakebin, and cleanup machinery whose assumptions those
# suites replace - yet they drive the same real fm-spawn.sh and need the same
# fixture. A second copy of the writer would drift from the emitter the first
# time the contract changed, and the suites holding that copy are exactly the
# ones that self-skip when their harness is not installed, so the drift would
# surface as a silent skip rather than a failed assertion.
#
# Source it after ROOT is set (the firstmate repo root):
#   # shellcheck source=tests/brief-fixture-lib.sh
#   . "$ROOT/tests/brief-fixture-lib.sh"
#
# No side effects on source. set -u / set -e safe.

# fm_test_write_brief <path> [mode]: write the smallest brief bin/fm-spawn.sh
# will launch - the delivery-contract sentinel in the header region, a task-body
# delimiter to bound that region, and, for a ship spawn, the recorded mode.
#
# For fixtures whose subject is something other than the brief. A suite that is
# actually about brief content should generate one with bin/fm-brief.sh instead,
# so it pins the real emitter rather than this stand-in.
#
# The two strings come from the contract library rather than being spelled here,
# because a fixture carrying its own copy of the sentinel keeps passing after the
# real one changes, which turns every suite using it into a false green.
#
# The mode default is ${2-...} rather than ${2:-...} so that an explicit empty
# argument means "omit the mode line" instead of collapsing back to the default.
# A scout brief is exactly that shape - sentinel, no mode - so the distinction is
# a real fixture case, not a hypothetical one.
#
# A secondmate charter needs neither line and is not written by this helper:
# charters carry no task body, therefore no delimiter, and fm-spawn.sh excludes
# them from both checks.
fm_test_write_brief() {
  local path=$1 mode=${2-no-mistakes} dir label
  # shellcheck source=bin/fm-brief-contract-lib.sh
  . "$ROOT/bin/fm-brief-contract-lib.sh"
  dir=$(dirname "$path")
  label=$(basename "$dir")
  mkdir -p "$dir"
  {
    printf '%s\n' 'You are a crewmate.'
    printf '%s\n' "$FM_DELIVERY_CONTRACT_SENTINEL"
    # Both contract facts go in the header region, above the delimiter, because
    # that is the only region fm-spawn.sh reads them from.
    [ -z "$mode" ] || printf '%s%s\n' "$FM_BRIEF_DELIVERY_MODE_PREFIX" "$mode"
    printf '\n%s\n' "$FM_BRIEF_TASK_BODY_DELIMITER"
    printf 'Fixture brief for %s.\n' "$label"
  } > "$path"
}
