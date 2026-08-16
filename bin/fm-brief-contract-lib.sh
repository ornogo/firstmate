#!/usr/bin/env bash
# Shared ownership of the two machine-read strings in the worker-landed-lite
# delivery contract.
#
# ONE owner for the two strings a brief emitter writes and a brief checker
# reads:
#   1. FM_DELIVERY_CONTRACT_SENTINEL - the literal line a template-generated
#      crewmate brief carries in its header region;
#   2. FM_BRIEF_TASK_BODY_DELIMITER - the fixed line that ends that header
#      region and opens the issue-derived task body.
#
# bin/fm-brief.sh emits both, and fm_brief_header_carries_contract below reads
# them: it scans a brief from its first line up to the first occurrence of the
# delimiter (exclusive) and reports whether that region carries the sentinel as
# an exact whole-line match. bin/fm-spawn.sh refuses to launch a worker whose
# brief fails that check.
#
# The strings and the scan rule live together because emitter and checker have
# to agree on both byte for byte: two spellings of the sentinel produce a guard
# that always refuses, and two spellings of the delimiter silently move the
# boundary between the checked header and the unchecked task body. A caller that
# re-implemented the scan beside its own copy of the strings would reintroduce
# exactly that drift, which is why the boundary rule is not left at the call
# site.
#
# Neither string is a version knob to bump casually. The sentinel names the
# contract revision a brief was generated under, so changing it invalidates
# every brief already on disk; the delimiter is load-bearing for the header
# boundary, so changing it moves what a checker can see.
#
# No side effects on source. set -u / set -e safe.

# shellcheck disable=SC2034 # Read by sourcing callers (bin/fm-brief.sh).
FM_DELIVERY_CONTRACT_SENTINEL='DELIVERY-CONTRACT: worker-landed-lite v1'
# shellcheck disable=SC2034 # Read by sourcing callers (bin/fm-brief.sh).
FM_BRIEF_TASK_BODY_DELIMITER='# Task'

fm_brief_header_carries_contract() {  # <brief path> -> 0 when the header region carries the sentinel
  local brief=$1 line saw_delimiter=0 saw_sentinel=0
  # Reading stops at the FIRST delimiter line, which is what makes the whole
  # rule one rule rather than several: nothing below that line is ever read, so
  # a sentinel in the task body cannot rescue a header that lacks one, and a
  # delimiter-lookalike further down cannot extend the region being vouched for.
  # There is deliberately no whole-file fallback - a brief carrying no delimiter
  # at all bounds no header region, so there is nothing to vouch for and it is
  # refused exactly like a missing sentinel.
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$FM_BRIEF_TASK_BODY_DELIMITER" ]; then
      saw_delimiter=1
      break
    fi
    if [ "$line" = "$FM_DELIVERY_CONTRACT_SENTINEL" ]; then
      saw_sentinel=1
    fi
  done < "$brief"
  [ "$saw_delimiter" = 1 ] && [ "$saw_sentinel" = 1 ]
}
