#!/usr/bin/env bash
# Behavior tests for /stow's inspect-then-update memory contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_stow_skill_task_note_contract() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep 'tasks-axi show <id> --full' "$stow" "stow skill does not require inspecting task notes first"
  assert_grep 'tasks-axi update <id> --body-file <path>' "$stow" "stow skill does not require task body replacement"
  assert_grep '--archive-body' "$stow" "stow skill does not document recoverable task body archival"
  assert_grep 'Never append.' "$stow" "stow skill does not forbid append-first task notes"
  assert_no_grep 'carry that context into the replacement body' "$stow" "stow skill still preserves archive-only context in the replacement body"
  pass "stow skill task-note contract includes recoverable body archival"
}

test_agents_backlog_task_note_contract() {
  local agents="$ROOT/AGENTS.md"

  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'current `tasks-axi --help` own the backlog schema' "$agents" \
    "AGENTS.md does not point exact task-note mechanics to the command owner"
  assert_grep 'Inspect the current task note before replacing its considered body' "$agents" \
    "AGENTS.md does not require inspecting task notes before replacement"
  assert_grep 'archive the superseded body when recoverability matters rather than appending by default' "$agents" \
    "AGENTS.md lost recoverable replacement and no-append semantics"
  assert_no_grep 'tasks-axi show <id> --full' "$agents" \
    "AGENTS.md duplicates exact task-note read syntax from its conditional owner"
  assert_no_grep 'tasks-axi update <id> --body-file <path>' "$agents" \
    "AGENTS.md duplicates exact task-note update syntax from its conditional owner"
  pass "AGENTS.md keeps task-note hygiene inline and points exact mechanics to their owner"
}

test_stow_and_agents_route_to_memory_map_topic_files() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md" agents="$ROOT/AGENTS.md" doc="$ROOT/docs/memory-maps.md"

  assert_grep 'data/learnings/MAP.md' "$stow" "stow skill does not route learnings through the map"
  assert_grep 'bin/fm-memory-map.sh validate' "$stow" "stow skill does not keep the map valid when adding a topic"
  assert_grep 'docs/memory-maps.md' "$stow" "stow skill does not point at the map format owner"
  assert_grep 'docs/memory-maps.md' "$agents" "AGENTS.md does not point at the map format owner"
  assert_grep 'Rules that always apply' "$doc" "the map doc lost the always-loaded rules section"
  assert_grep 'Inspect-then-update applies per topic file' "$doc" "the map doc lost the per-topic-file curation rule"
  assert_no_grep 'read when: <trigger>' "$agents" "AGENTS.md restates the map line format owned by docs/memory-maps.md"
  pass "stow, handoff, and AGENTS.md route memory writes to map topic files and point at the doc owner"
}

run_case test_stow_skill_task_note_contract
run_case test_agents_backlog_task_note_contract
run_case test_stow_and_agents_route_to_memory_map_topic_files
fm_case_summary "fm-stow-contract"
