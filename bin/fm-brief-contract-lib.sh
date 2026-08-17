#!/usr/bin/env bash
# Shared ownership of the three machine-read strings in the worker-landed-lite
# delivery contract, and of the one region rule that makes them trustworthy.
#
# ONE owner for the three strings a brief emitter writes and a brief checker
# reads:
#   1. FM_DELIVERY_CONTRACT_SENTINEL - the literal line a template-generated
#      crewmate brief carries in its header region;
#   2. FM_BRIEF_TASK_BODY_DELIMITER - the fixed line that ends that header
#      region and opens the issue-derived task body;
#   3. FM_BRIEF_DELIVERY_MODE_PREFIX - the prefix of the line a ship brief
#      carries in that same header region to record its delivery mode.
#
# bin/fm-brief.sh emits all three, and everything below works through one
# definition of the header region - everything from a brief's first line up to
# the first occurrence of the delimiter (exclusive), computed by
# fm_brief_header_region. Two readers consume it, and bin/fm-spawn.sh refuses to
# launch a worker whose brief fails either. One writer amends it, for the single
# case where a brief's delivery mode is decided after it was generated:
# bin/fm-promote.sh turning a scout into a ship task.
#
# WHY BOTH FACTS ARE READ FROM THE SAME BOUNDED REGION, AND ONLY FROM IT.
# A generated brief has exactly one attacker-or-issue-controlled span: the task
# body substituted in below the delimiter. The header region is the only part a
# checker can trust, and it is trustworthy for one structural reason - the scan
# stops at the FIRST delimiter, so body content, which is always below that
# line, can never move the boundary or reach inside it. Reading a contract fact
# from anywhere else means reading it from text the task description can forge.
# That is not hypothetical: a whole-file scan for the mode line lets a scout
# brief, whose deliverable is a report and never a PR, satisfy a ship spawn just
# by containing a mode line in its task text, and lets a task description
# silently downgrade the delivery rigor its own task is validated under. Neither
# is detectable afterwards, because the recorded task and the worker's
# instructions disagree from the first instant.
#
# Reading the last match rather than the first does not fix that, which is worth
# stating so it is not re-proposed: a scout brief carries no mode line at all, so
# the only match in it is the forged one either way.
#
# The strings and the region rule live together because emitter and checker have
# to agree on all of them byte for byte: two spellings of the sentinel produce a
# guard that always refuses, and two spellings of the delimiter silently move the
# boundary between the checked header and the unchecked task body. A caller that
# re-implemented the scan beside its own copy of the strings would reintroduce
# exactly that drift, which is why the boundary rule is not left at the call
# site.
#
# None of the three is a version knob to bump casually. The sentinel names the
# contract revision a brief was generated under, so changing it invalidates
# every brief already on disk; the delimiter is load-bearing for the header
# boundary, so changing it moves what a checker can see; the mode prefix is the
# spawn-time handshake, so changing it makes every ship brief unlaunchable.
#
# No side effects on source. set -u / set -e safe.

# shellcheck disable=SC2034 # Read by sourcing callers (bin/fm-brief.sh).
FM_DELIVERY_CONTRACT_SENTINEL='DELIVERY-CONTRACT: worker-landed-lite v1'
# shellcheck disable=SC2034 # Read by sourcing callers (bin/fm-brief.sh).
FM_BRIEF_TASK_BODY_DELIMITER='# Task'
# shellcheck disable=SC2034 # Read by sourcing callers (bin/fm-brief.sh).
FM_BRIEF_DELIVERY_MODE_PREFIX='Delivery contract: mode='

fm_brief_header_region() {  # <brief path> -> prints the header region; non-zero when no delimiter bounds one
  local brief=$1 line saw_delimiter=0
  # Stopping at the FIRST delimiter is what makes this one rule rather than
  # several: nothing below that line is ever read, so neither a sentinel nor a
  # mode line in the task body can vouch for a header that lacks one, and a
  # delimiter-lookalike further down cannot extend the region being vouched for.
  # There is deliberately no whole-file fallback - a brief carrying no delimiter
  # at all bounds no header region, so there is nothing to read and every reader
  # below refuses it.
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$FM_BRIEF_TASK_BODY_DELIMITER" ]; then
      saw_delimiter=1
      break
    fi
    printf '%s\n' "$line"
  done < "$brief"
  [ "$saw_delimiter" = 1 ]
}

fm_brief_header_carries_contract() {  # <brief path> -> 0 when the header region carries the sentinel
  local brief=$1 header line
  header=$(fm_brief_header_region "$brief") || return 1
  while IFS= read -r line; do
    if [ "$line" = "$FM_DELIVERY_CONTRACT_SENTINEL" ]; then
      return 0
    fi
  done <<< "$header"
  return 1
}

fm_brief_header_delivery_mode() {  # <brief path> -> prints the mode recorded in the header region; non-zero when absent
  local brief=$1 header line rest
  header=$(fm_brief_header_region "$brief") || return 1
  while IFS= read -r line; do
    case $line in
      "$FM_BRIEF_DELIVERY_MODE_PREFIX"*)
        rest=${line#"$FM_BRIEF_DELIVERY_MODE_PREFIX"}
        printf '%s\n' "${rest%% *}"
        return 0
        ;;
    esac
  done <<< "$header"
  return 1
}

# fm_brief_header_set_delivery_mode <brief path> <mode>: record <mode> as the
# brief's header delivery mode, in place, so fm_brief_header_delivery_mode reads
# it back. Non-zero, having changed nothing, when the brief has no header region
# to write into.
#
# The one caller is bin/fm-promote.sh. A scout brief carries the sentinel but no
# mode line, because a scout has no delivery posture to record; promotion is
# where that posture is first decided, so it is also where the brief has to start
# carrying it. Leaving the brief alone and flipping only the task record is what
# strands a promoted scout: its record says ship while its brief still says
# nothing, and every later spawn of it - a relaunch after its agent died, with
# the worktree still holding unlanded work - is refused by the ship mode check.
#
# This is a writer in the reader's file because it obeys the same region rule,
# and the rule is what makes it safe: the new line goes immediately after the
# sentinel, so it lands where a generated ship brief carries it and inside the
# only span a checker trusts. A caller writing the line itself would need its own
# copy of the boundary scan and of all three strings, which is the drift this
# file exists to prevent - and getting it wrong would append the mode below the
# delimiter, where the task description could have supplied it.
#
# Refusing a brief whose header carries no sentinel is deliberate, and it is not
# a case to "fix" by writing one: the sentinel asserts that the brief states the
# four worker-landed-lite rules, so stamping it onto a brief that does not state
# them forges the contract instead of recording a mode. Such a brief needs
# re-scaffolding, which is the caller's warning to give.
#
# An existing header mode line is replaced rather than joined, so promoting is
# idempotent and can never leave two lines for the reader to choose between. Any
# mode line below the delimiter is left exactly as it is: that text belongs to
# the task body, this function does not read contract facts from it, and quietly
# editing a worker's task description is not this function's business.
fm_brief_header_set_delivery_mode() {  # <brief path> <mode> -> 0 when the header now records <mode>
  local brief=$1 mode=$2 tmp line in_header=1 placed=0
  fm_brief_header_carries_contract "$brief" || return 1
  tmp="$brief.setmode.${BASHPID:-$$}"
  if ! while IFS= read -r line || [ -n "$line" ]; do
         if [ "$in_header" = 1 ]; then
           if [ "$line" = "$FM_BRIEF_TASK_BODY_DELIMITER" ]; then
             in_header=0
           else
             case $line in
               "$FM_BRIEF_DELIVERY_MODE_PREFIX"*) continue ;;
             esac
           fi
         fi
         printf '%s\n' "$line"
         if [ "$placed" = 0 ] && [ "$line" = "$FM_DELIVERY_CONTRACT_SENTINEL" ]; then
           printf '%s%s\n' "$FM_BRIEF_DELIVERY_MODE_PREFIX" "$mode"
           placed=1
         fi
       done < "$brief" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv "$tmp" "$brief"
}
