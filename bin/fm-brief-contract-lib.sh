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
# bin/fm-brief.sh emits both. The spawn-time hard refusal that reads them - it
# scans a brief from its first line up to the first occurrence of the delimiter
# (exclusive) and refuses unless that region carries the sentinel as an exact
# whole-line match - is the following increment, and lands in bin/fm-spawn.sh.
# The strings live here from the start because emitter and checker have to agree
# on both byte for byte: two spellings of the sentinel produce a guard that
# always refuses, and two spellings of the delimiter silently move the boundary
# between the checked header and the unchecked task body.
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
