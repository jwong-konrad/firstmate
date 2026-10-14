#!/usr/bin/env bash
# Behavior tests for the cold archive (docs/archive.md): bin/fm-archive.sh (staging,
# manifests, card mirror, free-space floor), bin/fm-transcript-archive-hook.sh (offset
# logic, silence, locking), bin/fm-archive-install.sh (LaunchAgent rendering), and
# bin/fm-ledger.sh (ledger contents). Hermetic: temp dirs, fake mount/diskutil/launchctl,
# no real card, no real ~/.claude, no real launchd.
#
# Matrix:
#   archiver: stages transcripts, file-history, reports, handoffs, screenshots, ledgers;
#     card absent -> "card absent, staging only", exit 0, nothing created under the mount root;
#     internal free-space floor -> exit 3, nothing written; idempotent second run; growth appends
#     only the new bytes; a shrunken source never overwrites; versioned files keep a .bak;
#     database-dump-style files are never staged; card mirror with matching UUID; wrong UUID, read-only,
#     nearly full, and a write failure mid-mirror all leave staging intact and exit 0;
#     manifests verify and flag corruption; the secret scan reports names and counts only.
#   hook: creates, appends, never duplicates, agrees with the archiver offset, prints nothing,
#     always exits 0, skips behind a live lock and steals a dead one, survives parallel runs.
#   installer: rendered plist is valid and escaped, install/uninstall drive launchctl, a linked
#     worktree is refused.
#   ledger: tokens counted once per message id, window filter, scratch caps, rerun keeps the first.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

ARCHIVE="$ROOT/bin/fm-archive.sh"
HOOK="$ROOT/bin/fm-transcript-archive-hook.sh"
INSTALL="$ROOT/bin/fm-archive-install.sh"
LEDGER="$ROOT/bin/fm-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-archive-tests)
REAL_CP=$(command -v cp)
VAULT_UUID=FAKE0000-0000-4000-8000-0000000000AA

# make_env <name> [mounted]: a sandbox with a fake ~/.claude, a fake firstmate home, a fake
# /Volumes, and mount/diskutil stubs. Prints the sandbox dir. When "mounted" is given the
# ARCHVOL volume appears mounted with the pinned UUID.
make_env() {
  local name=$1 mounted=${2:-} e fb
  e="$TMP_ROOT/$name"
  fb="$e/fakebin"
  mkdir -p "$e/claude/projects/-proj/sess/subagents" "$e/claude/file-history/s1" \
    "$e/home/data/t1/shots" "$e/home/data/handoffs/h1" "$e/home/state" "$e/volroot" "$fb"
  printf '%s\n' '{"line":1}' > "$e/claude/projects/-proj/sess.jsonl"
  printf '%s\n' '{"agent":1}' > "$e/claude/projects/-proj/sess/subagents/agent-1.jsonl"
  printf '%s\n' 'before' > "$e/claude/file-history/s1/x@v1"
  printf '%s\n' 'report one' > "$e/home/data/t1/report.md"
  printf '%s\n' 'png-bytes' > "$e/home/data/t1/shots/a.png"
  printf '%s\n' 'handoff one' > "$e/home/data/handoffs/h1/h.md"
  printf '%s\n' "ARCHVOL $VAULT_UUID" > "$e/card-volumes"
  if [ -n "$mounted" ]; then
    mkdir -p "$e/volroot/ARCHVOL"
    printf '#!/bin/sh\necho "/dev/fake1 on /System/Volumes/Data (apfs, local)"\necho "/dev/fake2 on %s/ARCHVOL (apfs, local)"\n' "$e/volroot" > "$fb/mount"
  else
    printf '#!/bin/sh\necho "/dev/fake1 on /System/Volumes/Data (apfs, local)"\n' > "$fb/mount"
  fi
  printf '#!/bin/sh\necho "   Volume UUID:              %s"\n' "${DISKUTIL_UUID:-$VAULT_UUID}" > "$fb/diskutil"
  chmod +x "$fb/mount" "$fb/diskutil"
  printf '%s\n' "$e"
}

# run_archive <env-dir> [args...]: run the archiver against the sandbox.
run_archive() {
  local e=$1
  shift
  env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" FM_HOME="$e/home" \
    FM_CARD_MOUNT_ROOT="$e/volroot" FM_CARD_VOLUMES_FILE="$e/card-volumes" FM_ARCHIVE_VAULT_VOLUME=ARCHVOL \
    FM_ARCHIVE_MIN_FREE_GIB=0 FM_ARCHIVE_CARD_MIN_FREE_GIB=0 \
    PATH="$e/fakebin:$PATH" "$ARCHIVE" "$@"
}

# tree_sum <dir>: stable checksum listing of regular files, ignoring the run log and last-run record.
tree_sum() {
  (cd "$1" && find . -type f ! -name archive.log ! -name last-run ! -path './.locks/*' -print | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)
}

test_archive_stages_every_source() {
  local e out
  e=$(make_env stage-all)
  printf '%s\n' '{"ledger":1}' > "$e/home/data/t1/ledger.json"
  printf '%s\n' 'tail' > "$e/home/data/t1/scrollback.txt"
  mkdir -p "$e/home/data/t1/scratch"
  printf '%s\n' 'M file' > "$e/home/data/t1/scratch/status.txt"
  out=$(run_archive "$e" --no-mirror) || fail "stage-all: archiver failed: $out"
  cmp -s "$e/claude/projects/-proj/sess.jsonl" "$e/arch/transcripts/-proj/sess.jsonl" || fail "stage-all: transcript not staged"
  cmp -s "$e/claude/projects/-proj/sess/subagents/agent-1.jsonl" "$e/arch/transcripts/-proj/sess/subagents/agent-1.jsonl" || fail "stage-all: subagent transcript not staged"
  assert_present "$e/arch/file-history/s1/x@v1" "stage-all: file-history not staged"
  assert_present "$e/arch/tasks/t1/report.md" "stage-all: report not staged"
  assert_present "$e/arch/tasks/t1/ledger.json" "stage-all: ledger not staged"
  assert_present "$e/arch/tasks/t1/scrollback.txt" "stage-all: scrollback not staged"
  assert_present "$e/arch/tasks/t1/scratch/status.txt" "stage-all: scratch snapshot not staged"
  assert_present "$e/arch/handoffs/h1/h.md" "stage-all: handoff not staged"
  assert_present "$e/arch/evidence/t1/shots/a.png" "stage-all: screenshot not staged"
  ls "$e/arch"/MANIFEST-*.sha256 >/dev/null 2>&1 || fail "stage-all: no monthly manifest written"
  pass "archiver stages transcripts, subagents, file-history, reports, ledgers, handoffs, and screenshots"
}

test_archive_card_absent_stages_and_exits_zero() {
  local e out rc
  e=$(make_env card-absent)
  set +e
  out=$(run_archive "$e" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "card-absent: must exit 0"
  assert_contains "$out" "card absent, staging only" "card-absent: missing the staging-only notice"
  assert_present "$e/arch/transcripts/-proj/sess.jsonl" "card-absent: staging must still be written"
  assert_absent "$e/volroot/ARCHVOL" "card-absent: must never create the volume path"
  [ -z "$(ls -A "$e/volroot")" ] || fail "card-absent: something was written under the mount root"
  pass "card absent: stages, says staging only, exits 0, writes nothing under the mount root"
}

test_archive_floor_refuses_and_writes_nothing() {
  local e out rc
  e=$(make_env floor)
  set +e
  out=$(env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" FM_HOME="$e/home" \
    FM_ARCHIVE_MIN_FREE_GIB=99999999 PATH="$e/fakebin:$PATH" "$ARCHIVE" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "floor: must refuse with exit 3"
  assert_contains "$out" "refused" "floor: missing the refusal message"
  assert_absent "$e/arch" "floor: nothing may be written below the floor"
  pass "internal free-space floor refuses with exit 3 and writes nothing"
}

test_archive_is_idempotent() {
  local e before after out
  e=$(make_env idem)
  run_archive "$e" >/dev/null 2>&1 || fail "idem: first run failed"
  before=$(tree_sum "$e/arch")
  out=$(run_archive "$e" 2>&1) || fail "idem: second run failed"
  after=$(tree_sum "$e/arch")
  [ "$before" = "$after" ] || fail "idem: a second run changed the archive"$'\n'"$before"$'\n---\n'"$after"
  assert_contains "$out" "transcripts new=0 grown=0" "idem: second run should copy nothing"
  assert_contains "$out" "manifest +0" "idem: second run should add no manifest entries"
  pass "a second archive run changes nothing"
}

test_archive_growth_appends_only_new_bytes() {
  local e out
  e=$(make_env growth)
  run_archive "$e" >/dev/null 2>&1 || fail "growth: first run failed"
  printf '%s\n' '{"line":2}' >> "$e/claude/projects/-proj/sess.jsonl"
  out=$(run_archive "$e" 2>&1) || fail "growth: second run failed"
  assert_contains "$out" "grown=1" "growth: a grown session was not appended"
  cmp -s "$e/claude/projects/-proj/sess.jsonl" "$e/arch/transcripts/-proj/sess.jsonl" || fail "growth: staged copy differs from the source"
  [ "$(grep -c . "$e/arch/transcripts/-proj/sess.jsonl")" = 2 ] || fail "growth: new bytes were not appended exactly once"
  out=$(run_archive "$e" --verify) || fail "growth: manifests do not verify: $out"
  assert_contains "$out" "problems=0" "growth: verify reported problems"
  pass "a still-open session is captured by appending only what grew"
}

test_archive_shrunken_source_never_overwrites() {
  local e out
  e=$(make_env shrink)
  printf '%s\n' '{"line":2}' >> "$e/claude/projects/-proj/sess.jsonl"
  run_archive "$e" >/dev/null 2>&1 || fail "shrink: first run failed"
  printf '%s\n' 'x' > "$e/claude/projects/-proj/sess.jsonl"
  out=$(run_archive "$e" 2>&1) || fail "shrink: second run failed"
  assert_contains "$out" "shrank=1" "shrink: shrunken source not reported"
  [ "$(grep -c . "$e/arch/transcripts/-proj/sess.jsonl")" = 2 ] || fail "shrink: archived content was lost"
  pass "a shrunken source never overwrites archived transcript content"
}

test_archive_changed_report_keeps_previous_version() {
  local e
  e=$(make_env versioned)
  run_archive "$e" >/dev/null 2>&1 || fail "versioned: first run failed"
  printf '%s\n' 'report two' > "$e/home/data/t1/report.md"
  run_archive "$e" >/dev/null 2>&1 || fail "versioned: second run failed"
  assert_grep "report two" "$e/arch/tasks/t1/report.md" "versioned: report not refreshed"
  grep -l "report one" "$e/arch/tasks/t1/"report.md.*.bak >/dev/null 2>&1 || fail "versioned: previous version not kept as .bak"
  pass "a changed report is refreshed and the previous version is kept"
}

test_archive_never_stages_database_dumps() {
  local e
  e=$(make_env no-dumps)
  mkdir -p "$e/home/data/db-checkpoints/c1" "$e/home/data/t1/db"
  printf '%s\n' 'dump' > "$e/home/data/db-checkpoints/c1/dump.sql.gz"
  printf '%s\n' 'dump' > "$e/home/data/t1/dump.sql.gz"
  printf '%s\n' 'dump' > "$e/home/data/t1/db/app.sql"
  run_archive "$e" >/dev/null 2>&1 || fail "no-dumps: run failed"
  [ -z "$(find "$e/arch" \( -name '*.sql*' -o -path '*db-checkpoints*' \) -print)" ] || fail "no-dumps: a database dump was staged"
  pass "database dumps are never staged"
}

test_archive_imports_a_raw_clone() {
  local e
  e=$(make_env import)
  mkdir -p "$e/raw/projects/-old" "$e/raw/file-history/s9"
  printf '%s\n' '{"old":1}' > "$e/raw/projects/-old/old.jsonl"
  printf '%s\n' 'old-edit' > "$e/raw/file-history/s9/y@v1"
  run_archive "$e" --no-mirror --import "$e/raw" >/dev/null 2>&1 || fail "import: run failed"
  assert_present "$e/arch/transcripts/-old/old.jsonl" "import: raw clone transcript not staged"
  assert_present "$e/arch/file-history/s9/y@v1" "import: raw clone file-history not staged"
  pass "--import stages a raw clone of ~/.claude"
}

test_archive_mirrors_to_a_verified_card() {
  local e out
  e=$(make_env mirror mounted)
  printf '%s\n' '{"line":2}' >> "$e/claude/projects/-proj/sess.jsonl"
  out=$(run_archive "$e" 2>&1) || fail "mirror: run failed: $out"
  assert_contains "$out" "mirror ok" "mirror: no success line"
  cmp -s "$e/claude/projects/-proj/sess.jsonl" "$e/volroot/ARCHVOL/secure/archive/transcripts/-proj/sess.jsonl" || fail "mirror: transcript differs on the card"
  assert_present "$e/volroot/ARCHVOL/secure/archive/evidence/t1/shots/a.png" "mirror: screenshot not mirrored"
  assert_present "$e/volroot/ARCHVOL/secure/archive/tasks/t1/report.md" "mirror: report not mirrored"
  ls "$e/volroot/ARCHVOL/secure/archive"/MANIFEST-*.sha256 >/dev/null 2>&1 || fail "mirror: manifest not mirrored"
  printf '%s\n' '{"line":3}' >> "$e/claude/projects/-proj/sess.jsonl"
  run_archive "$e" >/dev/null 2>&1 || fail "mirror: second run failed"
  cmp -s "$e/claude/projects/-proj/sess.jsonl" "$e/volroot/ARCHVOL/secure/archive/transcripts/-proj/sess.jsonl" || fail "mirror: growth not carried to the card"
  out=$(run_archive "$e" 2>&1)
  assert_contains "$out" "mirror ok (0 files copied" "mirror: an unchanged archive should copy nothing"
  pass "a pinned, unlocked, writable card receives an exact mirror, and growth follows"
}

test_archive_wrong_volume_is_treated_as_absent() {
  local e out rc
  e=$(DISKUTIL_UUID=00000000-0000-0000-0000-000000000000 make_env wrong-uuid mounted)
  set +e
  out=$(run_archive "$e" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "wrong-uuid: must exit 0"
  assert_contains "$out" "card absent, staging only" "wrong-uuid: should stage only"
  assert_contains "$out" "wrong volume" "wrong-uuid: should say the volume is wrong"
  assert_absent "$e/volroot/ARCHVOL/secure" "wrong-uuid: nothing may be written to the wrong volume"
  pass "a volume with the wrong UUID is never written to"
}

test_archive_read_only_card_stays_in_staging() {
  local e out rc
  [ "$(id -u)" != 0 ] || { pass "skip: read-only card test needs a non-root user"; return 0; }
  e=$(make_env readonly mounted)
  chmod 555 "$e/volroot/ARCHVOL"
  set +e
  out=$(run_archive "$e" 2>&1)
  rc=$?
  set -e
  chmod 755 "$e/volroot/ARCHVOL"
  expect_code 0 "$rc" "readonly: must exit 0"
  assert_contains "$out" "card absent, staging only" "readonly: should stage only"
  assert_contains "$out" "not writable" "readonly: should say the card is not writable"
  assert_present "$e/arch/transcripts/-proj/sess.jsonl" "readonly: staging must still be written"
  pass "a read-only card stays in staging and says why"
}

test_archive_nearly_full_card_is_not_written() {
  local e out rc
  e=$(make_env card-full mounted)
  set +e
  out=$(env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" FM_HOME="$e/home" \
    FM_CARD_MOUNT_ROOT="$e/volroot" FM_CARD_VOLUMES_FILE="$e/card-volumes" FM_ARCHIVE_VAULT_VOLUME=ARCHVOL \
    FM_ARCHIVE_MIN_FREE_GIB=0 FM_ARCHIVE_CARD_MIN_FREE_GIB=99999999 \
    PATH="$e/fakebin:$PATH" "$ARCHIVE" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "card-full: must exit 0"
  assert_contains "$out" "staging only" "card-full: should stage only"
  assert_absent "$e/volroot/ARCHVOL/secure/archive/transcripts" "card-full: nothing may be mirrored below the card floor"
  pass "a nearly full card is left alone"
}

test_archive_card_write_failure_keeps_staging_intact() {
  local e out rc
  e=$(make_env card-fails mounted)
  # A cp that fails for anything destined under the fake card, as a full or yanked card would.
  cat > "$e/fakebin/cp" <<SH
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    $e/volroot/*) echo "cp: No space left on device" >&2; exit 1 ;;
  esac
done
exec "$REAL_CP" "\$@"
SH
  chmod +x "$e/fakebin/cp"
  set +e
  out=$(run_archive "$e" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "card-fails: must exit 0"
  assert_contains "$out" "card write failed" "card-fails: failure not reported"
  cmp -s "$e/claude/projects/-proj/sess.jsonl" "$e/arch/transcripts/-proj/sess.jsonl" || fail "card-fails: staging was disturbed"
  [ -z "$(find "$e/volroot/ARCHVOL" -name '*.tmp.*' -print)" ] || fail "card-fails: temp files left on the card"
  pass "a card that fails mid-mirror stops the mirror, reports it, and leaves staging intact"
}

test_archive_manifest_detects_corruption() {
  local e out rc
  e=$(make_env corrupt)
  run_archive "$e" --no-mirror >/dev/null 2>&1 || fail "corrupt: first run failed"
  printf '%s' '{"line":9}' | dd of="$e/arch/transcripts/-proj/sess.jsonl" bs=1 conv=notrunc 2>/dev/null
  set +e
  out=$(run_archive "$e" --verify)
  rc=$?
  set -e
  expect_code 1 "$rc" "corrupt: verify must fail"
  assert_contains "$out" "CORRUPT transcripts/-proj/sess.jsonl" "corrupt: the damaged file was not named"
  pass "manifest verification names a corrupted file"
}

test_archive_secret_scan_reports_names_not_values() {
  local e secret report
  e=$(make_env scan)
  secret=AKIAABCDEFGHIJKLMNOP
  printf '%s\n' "{\"out\":\"key $secret here\"}" >> "$e/claude/projects/-proj/sess.jsonl"
  run_archive "$e" --no-mirror >/dev/null 2>&1 || fail "scan: run failed"
  report=$(ls "$e/arch/reports"/secret-scan-*.txt)
  assert_grep "aws-access-key" "$report" "scan: pattern name missing from the report"
  assert_grep "transcripts/-proj/sess.jsonl" "$report" "scan: file missing from the report"
  assert_no_grep "$secret" "$report" "scan: the matched secret leaked into the report"
  assert_no_grep "$secret" "$e/arch/archive.log" "scan: the matched secret leaked into the log"
  pass "the secret scan reports pattern names and counts, never the match"
}

# ------------------------------------------------------------------------- hook

run_hook() {  # <env-dir> <json>
  local e=$1 json=$2
  printf '%s' "$json" | env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" \
    FM_ARCHIVE_MIN_FREE_GIB=0 PATH="$e/fakebin:$PATH" "$HOOK"
}

test_hook_creates_appends_and_stays_silent() {
  local e src out rc
  e=$(make_env hook-basic)
  src="$e/claude/projects/-proj/sess.jsonl"
  set +e
  out=$(run_hook "$e" "{\"session_id\":\"sess\",\"transcript_path\":\"$src\",\"hook_event_name\":\"Stop\"}" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "hook-basic: must exit 0"
  [ -z "$out" ] || fail "hook-basic: the hook printed output: $out"
  cmp -s "$src" "$e/arch/transcripts/-proj/sess.jsonl" || fail "hook-basic: transcript not archived"
  printf '%s\n' '{"line":2}' >> "$src"
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  cmp -s "$src" "$e/arch/transcripts/-proj/sess.jsonl" || fail "hook-basic: growth not appended exactly once"
  pass "the hook archives, appends only new lines, and prints nothing"
}

test_hook_archives_subagent_transcript() {
  local e src sub
  e=$(make_env hook-sub)
  src="$e/claude/projects/-proj/sess.jsonl"
  sub="$e/claude/projects/-proj/sess/subagents/agent-1.jsonl"
  run_hook "$e" "{\"session_id\":\"sess\",\"agent_id\":\"agent-1\",\"transcript_path\":\"$src\",\"agent_transcript_path\":\"$sub\",\"hook_event_name\":\"SubagentStop\"}" >/dev/null 2>&1
  cmp -s "$sub" "$e/arch/transcripts/-proj/sess/subagents/agent-1.jsonl" || fail "hook-sub: subagent transcript not archived"
  cmp -s "$src" "$e/arch/transcripts/-proj/sess.jsonl" || fail "hook-sub: session transcript not archived"
  pass "the hook archives both the session and the subagent transcript"
}

test_hook_and_archiver_share_one_offset() {
  local e src out
  e=$(make_env hook-offset)
  src="$e/claude/projects/-proj/sess.jsonl"
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  printf '%s\n' '{"line":2}' >> "$src"
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  out=$(run_archive "$e" --no-mirror 2>&1)
  assert_contains "$out" "transcripts new=1 grown=0" "hook-offset: the archiver should find only the unseen subagent file"
  cmp -s "$src" "$e/arch/transcripts/-proj/sess.jsonl" || fail "hook-offset: content differs after hook plus archiver"
  out=$(run_archive "$e" --verify) || fail "hook-offset: manifest does not verify: $out"
  pass "the hook and the nightly archiver agree on the offset and never copy a byte twice"
}

test_hook_exits_zero_on_bad_input() {
  local e rc out
  e=$(make_env hook-bad)
  for input in '' 'not json' '{"transcript_path":"/nonexistent/x.jsonl"}' '{}'; do
    set +e
    out=$(run_hook "$e" "$input" 2>&1)
    rc=$?
    set -e
    expect_code 0 "$rc" "hook-bad: must exit 0 for input '$input'"
    [ -z "$out" ] || fail "hook-bad: output for input '$input': $out"
  done
  pass "the hook exits 0 and prints nothing on bad input"
}

test_hook_refuses_untrusted_paths() {
  local e p reason n=0
  e=$(make_env hook-refuse)
  mkdir -p "$e/outsidedir" "$e/claude/projects/-proj"
  printf '%s\n' 'TOPSECRETCONTENT' > "$e/elsewhere.jsonl"
  printf '%s\n' 'TOPSECRETCONTENT' > "$e/outside.jsonl"
  printf '%s\n' 'TOPSECRETCONTENT' > "$e/outsidedir/x.jsonl"
  printf '%s\n' 'TOPSECRETCONTENT' > "$e/claude/projects/-proj/key.pem"
  ln -s "$e/elsewhere.jsonl" "$e/claude/projects/-proj/link.jsonl"
  ln -s "$e/outsidedir" "$e/claude/projects/-linked"
  for p in \
    "$e/elsewhere.jsonl" \
    "$e/claude/projects/-proj/../../../outside.jsonl" \
    "$e/claude/projects/-proj/./sess.jsonl" \
    "$e/claude/projects/-proj/key.pem" \
    "$e/claude/projects/-proj/link.jsonl" \
    "$e/claude/projects/-linked/x.jsonl" \
    "claude/projects/-proj/sess.jsonl" \
    "$e/claude/projects"; do
    run_hook "$e" "{\"transcript_path\":\"$p\",\"agent_transcript_path\":\"$p\"}" >/dev/null 2>&1
    n=$((n + 1))
  done
  [ -z "$(find "$e/arch/transcripts" -type f 2>/dev/null)" ] || fail "hook-refuse: a refused path was archived: $(find "$e/arch/transcripts" -type f)"
  assert_absent "$e/arch/transcripts/_other" "hook-refuse: nothing may be filed outside the projects tree"
  [ -z "$(find "$e/arch" -name '*outside*' -o -name '*elsewhere*' 2>/dev/null)" ] || fail "hook-refuse: a path escaped the transcripts directory"
  [ "$(grep -c 'hook refused a transcript path' "$e/arch/archive.log")" -ge "$n" ] || fail "hook-refuse: refusals were not all logged"
  for reason in "not absolute" "dot component" "not a .jsonl file" "path is a symlink" "outside the projects directory"; do
    assert_grep "$reason" "$e/arch/archive.log" "hook-refuse: the log should name the reason '$reason'"
  done
  assert_no_grep "TOPSECRETCONTENT" "$e/arch/archive.log" "hook-refuse: file content reached the log"
  assert_no_grep "$e" "$e/arch/archive.log" "hook-refuse: a path reached the log"
  pass "the hook refuses relative, dotted, non-jsonl, symlinked, and out-of-tree paths and logs only the reason"
}

test_hook_never_overwrites_with_a_shorter_source() {
  local e src
  e=$(make_env hook-shrink)
  src="$e/claude/projects/-proj/sess.jsonl"
  printf '%s\n' '{"line":2}' >> "$src"
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  printf '%s\n' 'x' > "$src"
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  [ "$(grep -c . "$e/arch/transcripts/-proj/sess.jsonl")" = 2 ] || fail "hook-shrink: archived content was lost"
  pass "the hook never replaces archived content with a shorter source"
}

test_hook_skips_behind_a_live_lock_and_steals_a_dead_one() {
  local e src lock live
  e=$(make_env hook-lock)
  src="$e/claude/projects/-proj/sess.jsonl"
  mkdir -p "$e/arch/transcripts/-proj" "$e/arch/.locks"
  # The lock is keyed by the destination path; build it the same way the library does.
  lock="$e/arch/.locks/f-$(printf '%s' "$e/arch/transcripts/-proj/sess.jsonl" | cksum | cut -d' ' -f1)"
  sleep 30 &
  live=$!
  mkdir "$lock"
  printf '%s\n' "$live" > "$lock/pid"
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  kill "$live" 2>/dev/null
  wait "$live" 2>/dev/null || true
  assert_absent "$e/arch/transcripts/-proj/sess.jsonl" "hook-lock: the hook wrote past a live lock"
  # Now the holder is dead: the next run steals the lock and archives.
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  cmp -s "$src" "$e/arch/transcripts/-proj/sess.jsonl" || fail "hook-lock: a dead lock was not stolen"
  pass "the hook skips behind a live lock and steals a dead one"
}

test_hook_parallel_runs_do_not_duplicate_or_lose_lines() {
  local e src i
  e=$(make_env hook-parallel)
  src="$e/claude/projects/-proj/sess.jsonl"
  for i in 1 2 3 4 5 6; do
    printf '%s\n' "{\"line\":$((i + 1))}" >> "$src"
    run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1 &
    run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1 &
  done
  wait
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  cmp -s "$src" "$e/arch/transcripts/-proj/sess.jsonl" || fail "hook-parallel: staged copy differs after parallel hooks"
  pass "parallel hooks neither duplicate nor lose lines"
}

test_hook_respects_floor_and_kill_switch() {
  local e src
  e=$(make_env hook-floor)
  src="$e/claude/projects/-proj/sess.jsonl"
  printf '%s' "{\"transcript_path\":\"$src\"}" | env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" \
    FM_ARCHIVE_MIN_FREE_GIB=99999999 "$HOOK" >/dev/null 2>&1
  assert_absent "$e/arch/transcripts/-proj/sess.jsonl" "hook-floor: the hook wrote below the free-space floor"
  printf '%s' "{\"transcript_path\":\"$src\"}" | env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" \
    FM_ARCHIVE_MIN_FREE_GIB=0 FM_ARCHIVE_HOOK=off "$HOOK" >/dev/null 2>&1
  assert_absent "$e/arch/transcripts/-proj/sess.jsonl" "hook-floor: FM_ARCHIVE_HOOK=off did not disable the hook"
  pass "the hook honours the free-space floor and its kill switch"
}

# -------------------------------------------------------------------- installer

run_install() {  # <env-dir> <args...>
  local e=$1
  shift
  env HOME="$e/fakehome" FM_ARCHIVE_LAUNCHCTL="$e/launchctl" FM_ARCHIVE_ROOT="$e/arch" "$INSTALL" "$@"
}

make_launchctl_stub() {  # <env-dir>
  printf '#!/bin/sh\necho "$*" >> "%s/launchctl.log"\nexit 0\n' "$1" > "$1/launchctl"
  chmod +x "$1/launchctl"
}

test_installer_renders_a_valid_escaped_plist() {
  local e out
  e=$(make_env install-print)
  out=$(run_install "$e" print --archive-root "$e/a&b/arch" --hour 4 --minute 5) || fail "install-print: failed"
  assert_contains "$out" "<string>com.firstmate.archive</string>" "install-print: label missing"
  assert_contains "$out" "$ROOT/bin/fm-archive.sh" "install-print: archiver path missing"
  assert_contains "$out" "a&amp;b/arch" "install-print: path not XML-escaped"
  assert_contains "$out" "<integer>4</integer>" "install-print: hour not rendered"
  assert_not_contains "$out" "@" "install-print: an unfilled placeholder remains"
  if command -v plutil >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$e/p.plist"
    plutil -lint "$e/p.plist" >/dev/null || fail "install-print: plutil rejects the plist"
  fi
  pass "the installer renders a valid, escaped plist"
}

test_installer_install_and_uninstall_drive_launchctl() {
  local e
  e=$(make_env install-run)
  make_launchctl_stub "$e"
  run_install "$e" install --plist-dir "$e/agents" --allow-worktree >/dev/null || fail "install-run: install failed"
  assert_present "$e/agents/com.firstmate.archive.plist" "install-run: plist not written"
  assert_grep "bootstrap" "$e/launchctl.log" "install-run: agent not loaded"
  run_install "$e" install --plist-dir "$e/agents" --allow-worktree >/dev/null || fail "install-run: re-install failed"
  [ "$(grep -c bootout "$e/launchctl.log")" -ge 2 ] || fail "install-run: re-install did not unload the loaded agent first"
  run_install "$e" uninstall --plist-dir "$e/agents" >/dev/null || fail "install-run: uninstall failed"
  assert_absent "$e/agents/com.firstmate.archive.plist" "install-run: plist not removed"
  pass "install is idempotent and uninstall removes the agent"
}

test_installer_no_load_does_not_touch_launchd() {
  local e
  e=$(make_env install-noload)
  make_launchctl_stub "$e"
  run_install "$e" install --plist-dir "$e/agents" --no-load --allow-worktree >/dev/null || fail "install-noload: failed"
  assert_present "$e/agents/com.firstmate.archive.plist" "install-noload: plist not written"
  assert_absent "$e/launchctl.log" "install-noload: launchctl was called"
  pass "--no-load writes the plist without calling launchctl"
}

test_installer_refuses_a_linked_worktree() {
  local e repo wt rc
  e=$(make_env install-wt)
  repo="$e/repo"
  wt="$e/wt"
  fm_git_worktree "$repo" "$wt" fm/x
  mkdir -p "$wt/docs/examples" "$wt/bin"
  cp "$ROOT/docs/examples/com.firstmate.archive.plist.template" "$wt/docs/examples/"
  set +e
  FM_ARCHIVE_INSTALL_ROOT="$wt" run_install "$e" install --plist-dir "$e/agents" --no-load >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "install-wt: a linked worktree must be refused"
  assert_absent "$e/agents/com.firstmate.archive.plist" "install-wt: a plist was written for a worktree"
  FM_ARCHIVE_INSTALL_ROOT="$wt" run_install "$e" install --plist-dir "$e/agents" --no-load --allow-worktree >/dev/null 2>&1 \
    || fail "install-wt: --allow-worktree should override"
  FM_ARCHIVE_INSTALL_ROOT="$repo" run_install "$e" print >/dev/null 2>&1 && fail "install-wt: print without a template should fail"
  pass "the installer refuses a linked worktree unless told otherwise"
}

test_installer_rejects_bad_times() {
  local e rc
  e=$(make_env install-bad)
  set +e
  run_install "$e" print --hour 24 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "install-bad: hour 24 must be rejected"
  pass "the installer rejects an invalid time"
}

# ----------------------------------------------------------------------- ledger

make_ledger_env() {  # <name>: prints the sandbox dir with a task t1, worktree, transcripts
  local name=$1 e slug ts
  e="$TMP_ROOT/$name"
  mkdir -p "$e/state" "$e/data" "$e/fakebin" "$e/claude/projects"
  git init -q "$e/p"
  git -C "$e/p" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$e/p" worktree add -q -b fm/x "$e/wt"
  git -C "$e/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "local only"
  fm_write_meta "$e/state/t1.meta" "window=fm:t1" "worktree=$e/wt" "project=$e/p" \
    "harness=claude" "model=opus" "effort=low" "kind=ship" "mode=no-mistakes"
  printf '%s\n' 'working: a' 'done: b' > "$e/state/t1.status"
  cat > "$e/fakebin/tmux" <<'SH'
#!/bin/sh
if [ "$1" = capture-pane ]; then echo "pane 1"; echo "pane 2"; fi
SH
  chmod +x "$e/fakebin/tmux"
  slug=$(printf '%s' "$e/wt" | sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "$e/claude/projects/$slug/sid1/subagents"
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  # One API message streamed over two lines (same id): counted once, at its last usage.
  printf '%s\n' \
    "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"message\":{\"id\":\"m1\",\"model\":\"opus\",\"usage\":{\"input_tokens\":5,\"output_tokens\":7,\"cache_read_input_tokens\":1,\"cache_creation_input_tokens\":2}}}" \
    "{\"type\":\"assistant\",\"timestamp\":\"$ts\",\"message\":{\"id\":\"m1\",\"model\":\"opus\",\"usage\":{\"input_tokens\":5,\"output_tokens\":9,\"cache_read_input_tokens\":1,\"cache_creation_input_tokens\":2}}}" \
    'not json at all' \
    '{"type":"cost-state","totalCostUSD":1.5,"modelUsage":{}}' > "$e/claude/projects/$slug/sid1.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"id":"s1","usage":{"input_tokens":1,"output_tokens":3}}}' > "$e/claude/projects/$slug/sid1/subagents/agent-1.jsonl"
  # A session from an earlier tenant of the same pooled worktree, long before this task.
  printf '%s\n' '{"type":"assistant","timestamp":"2000-01-01T00:00:00.000Z","message":{"id":"old","model":"opus","usage":{"input_tokens":99,"output_tokens":99}}}' > "$e/claude/projects/$slug/old.jsonl"
  printf '%s\n' "$e"
}

run_ledger() {  # <env-dir> [id]
  local e=$1 id=${2:-t1}
  env FM_NO_LEDGER=0 FM_HOME="$e" FM_STATE_OVERRIDE="$e/state" FM_DATA_OVERRIDE="$e/data" \
    FM_ARCHIVE_CLAUDE_DIR="$e/claude" PATH="$e/fakebin:$PATH" "$LEDGER" "$id"
}

test_ledger_contents() {
  local e led
  e=$(make_ledger_env ledger-contents)
  printf '%s\n' 'untracked text' > "$e/wt/note.txt"
  printf 'a\0b\0c\0' > "$e/wt/blob.bin"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-contents: ledger failed"
  led="$e/data/t1/ledger.json"
  [ "$(jq -r .harness "$led")" = claude ] || fail "ledger-contents: harness missing"
  [ "$(jq -r '.sessions | length' "$led")" = 1 ] || fail "ledger-contents: the earlier tenant's session leaked in, or the task's was missed"
  [ "$(jq -r .totals.output "$led")" = 9 ] || fail "ledger-contents: a streamed message was not counted once at its last usage"
  [ "$(jq -r .totals.input "$led")" = 5 ] || fail "ledger-contents: input tokens wrong"
  [ "$(jq -r .totals.subagent_output "$led")" = 3 ] || fail "ledger-contents: subagent tokens wrong"
  [ "$(jq -r .totals.cost_usd "$led")" = 1.5 ] || fail "ledger-contents: cost wrong"
  [ "$(jq -r '.steers | length' "$led")" = 0 ] || fail "ledger-contents: steers should be an empty list"
  assert_grep "pane 2" "$e/data/t1/scrollback.txt" "ledger-contents: scrollback missing"
  assert_grep "untracked text" "$e/data/t1/scratch/untracked.diff" "ledger-contents: untracked text diff missing"
  assert_no_grep "blob.bin" "$e/data/t1/scratch/untracked.diff" "ledger-contents: a binary file leaked into the untracked diff"
  assert_grep "binary" "$led" "ledger-contents: the skipped binary was not noted"
  assert_present "$e/data/t1/scratch/local-commits.bundle" "ledger-contents: bundle of local-only commits missing"
  pass "the ledger records tokens once per message, windows sessions by time, and snapshots scratch work"
}

test_ledger_caps_untracked_diff() {
  local e
  e=$(make_ledger_env ledger-cap)
  head -c 300000 /dev/zero | tr '\0' 'a' > "$e/wt/huge.txt"
  printf '%s\n' small > "$e/wt/small.txt"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-cap: ledger failed"
  assert_no_grep "aaaaaaaaaaaa" "$e/data/t1/scratch/untracked.diff" "ledger-cap: an oversize file was included"
  assert_grep "small.txt" "$e/data/t1/scratch/untracked.diff" "ledger-cap: the small file was dropped with the big one"
  grep -F 'exceeds the per-file cap' "$e/data/t1/ledger.json" >/dev/null || fail "ledger-cap: the skipped file was not noted"
  pass "the ledger caps untracked file snapshots and says what it skipped"
}

test_ledger_rerun_keeps_the_first_ledger() {
  local e first
  e=$(make_ledger_env ledger-rerun)
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-rerun: first run failed"
  first=$(cksum < "$e/data/t1/ledger.json")
  sleep 1
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-rerun: second run failed"
  [ "$(cksum < "$e/data/t1/ledger.json")" = "$first" ] || fail "ledger-rerun: the first ledger was replaced"
  [ -n "$(ls "$e/data/t1"/ledger-*.json 2>/dev/null)" ] || fail "ledger-rerun: the second ledger was not kept beside the first"
  pass "a rerun keeps the first ledger and writes the next beside it"
}

test_ledger_degrades_without_worktree_or_pane() {
  local e led
  e=$(make_ledger_env ledger-degraded)
  rm -rf "$e/wt"
  printf '#!/bin/sh\nexit 1\n' > "$e/fakebin/tmux"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-degraded: must still succeed"
  led="$e/data/t1/ledger.json"
  assert_present "$led" "ledger-degraded: no ledger"
  [ "$(jq -r .scrollback.status "$led")" != captured ] || fail "ledger-degraded: claimed a scrollback it could not read"
  [ "$(jq -r '.warnings | length' "$led")" -ge 1 ] || fail "ledger-degraded: no warning recorded"
  pass "the ledger still writes, with warnings, when the worktree and pane are gone"
}

test_ledger_refuses_a_planted_symlink_file() {
  local e
  e=$(make_ledger_env ledger-link-file)
  printf '%s\n' keep > "$e/victim"
  mkdir -p "$e/data/t1/scratch"
  ln -s "$e/victim" "$e/data/t1/scratch/local-commits.txt"
  ln -s "$e/victim" "$e/data/t1/scratch/status.txt"
  ln -s "$e/victim" "$e/data/t1/scrollback.txt"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-link-file: ledger must stay fail-soft"
  [ "$(cat "$e/victim")" = keep ] || fail "ledger-link-file: a planted symlink was written through"
  [ ! -L "$e/data/t1/scratch/status.txt" ] || fail "ledger-link-file: the planted link was kept"
  [ ! -L "$e/data/t1/scrollback.txt" ] || fail "ledger-link-file: the planted scrollback link was kept"
  assert_grep "pane 2" "$e/data/t1/scrollback.txt" "ledger-link-file: the scrollback was not written over the link"
  pass "a symlink planted at a ledger output is replaced, never written through"
}

test_ledger_refuses_a_symlinked_scratch_directory() {
  local e
  e=$(make_ledger_env ledger-link-dir)
  mkdir -p "$e/victimdir"
  printf '%s\n' keep > "$e/victimdir/sentinel"
  mkdir -p "$e/data/t1"
  ln -s "$e/victimdir" "$e/data/t1/scratch"
  printf '%s\n' 'untracked text' > "$e/wt/note.txt"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-link-dir: ledger must stay fail-soft"
  [ "$(ls -A "$e/victimdir")" = sentinel ] || fail "ledger-link-dir: files were written into the link target: $(ls -A "$e/victimdir")"
  [ "$(cat "$e/victimdir/sentinel")" = keep ] || fail "ledger-link-dir: the link target was modified"
  [ -L "$e/data/t1/scratch" ] || fail "ledger-link-dir: the planted link was altered"
  assert_grep "symlink" "$e/data/t1/ledger.json" "ledger-link-dir: the refusal was not recorded"
  pass "a symlinked scratch directory is refused and its target left untouched"
}

test_ledger_refuses_a_symlinked_task_folder() {
  local e
  e=$(make_ledger_env ledger-link-task)
  mkdir -p "$e/realdata"
  ln -s "$e/realdata" "$e/data/t1"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-link-task: ledger must stay fail-soft"
  [ -z "$(ls -A "$e/realdata")" ] || fail "ledger-link-task: wrote through a symlinked task folder: $(ls -A "$e/realdata")"
  pass "a symlinked task folder is refused"
}

test_ledger_replaces_stale_scratch_contents() {
  local e
  e=$(make_ledger_env ledger-fresh)
  mkdir -p "$e/data/t1/scratch"
  printf '%s\n' old > "$e/data/t1/scratch/planted.txt"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-fresh: ledger failed"
  assert_absent "$e/data/t1/scratch/planted.txt" "ledger-fresh: scratch was not recreated fresh"
  [ -d "$e/data/t1/scratch" ] && [ ! -L "$e/data/t1/scratch" ] || fail "ledger-fresh: scratch is not a real directory"
  pass "scratch is recreated fresh on every run"
}

test_ledger_excludes_secret_named_files() {
  local e led f
  e=$(make_ledger_env ledger-secret-names)
  for f in .env.local server.pem id_rsa my-credentials.json app.key cert.p12 client_secret.txt login.keychain-db; do
    printf '%s\n' "PLAINVALUE in $f" > "$e/wt/$f"
  done
  printf '%s\n' 'harmless text' > "$e/wt/ok.txt"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-secret-names: ledger failed"
  led="$e/data/t1/ledger.json"
  assert_grep "ok.txt" "$e/data/t1/scratch/untracked.diff" "ledger-secret-names: an ordinary file was dropped"
  assert_no_grep "PLAINVALUE" "$e/data/t1/scratch/untracked.diff" "ledger-secret-names: a secret-named file was captured"
  if grep -rF "PLAINVALUE" "$e/data/t1" >/dev/null 2>&1; then fail "ledger-secret-names: a secret value reached data/<id>"; fi
  for f in .env.local server.pem id_rsa my-credentials.json app.key cert.p12 client_secret.txt login.keychain-db; do
    assert_grep "$f" "$led" "ledger-secret-names: $f was not recorded as skipped"
  done
  pass "secret-named files are left out of the scratch snapshot by name and recorded by name only"
}

test_ledger_drops_files_matching_secret_patterns() {
  local e led token
  e=$(make_ledger_env ledger-secret-content)
  token="AKIA$(printf 'ABCDEFGHIJKLMNOP')"
  printf '%s\n' "aws = $token" > "$e/wt/notes.txt"
  printf '%s\n' 'harmless text' > "$e/wt/ok.txt"
  printf '%s\n' tracked > "$e/wt/tracked.txt"
  git -C "$e/wt" add tracked.txt
  git -C "$e/wt" -c user.email=t@t -c user.name=t commit -q -m "add tracked"
  printf '%s\n' "edited $token" >> "$e/wt/tracked.txt"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-secret-content: ledger failed"
  led="$e/data/t1/ledger.json"
  assert_grep "ok.txt" "$e/data/t1/scratch/untracked.diff" "ledger-secret-content: an ordinary file was dropped"
  if grep -rF "$token" "$e/data/t1" >/dev/null 2>&1; then fail "ledger-secret-content: the credential reached data/<id>"; fi
  assert_absent "$e/data/t1/scratch/tracked.diff" "ledger-secret-content: a tracked diff holding a credential was kept"
  assert_grep "notes.txt" "$led" "ledger-secret-content: the dropped file was not named"
  assert_grep "aws-access-key" "$led" "ledger-secret-content: the pattern name was not recorded"
  pass "files and diffs matching a credential pattern are dropped and only the name and pattern are recorded"
}

test_ledger_drops_a_scrollback_holding_a_secret() {
  local e led token
  e=$(make_ledger_env ledger-secret-scrollback)
  token="AKIA$(printf 'ABCDEFGHIJKLMNOP')"
  mkdir -p "$e/data/t1"
  printf '%s\n' "old pane" > "$e/data/t1/scrollback.txt"
  cat > "$e/fakebin/tmux" <<SH
#!/bin/sh
if [ "\$1" = capture-pane ]; then echo "pane 1"; echo "export KEY=$token"; fi
SH
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-secret-scrollback: ledger failed"
  led="$e/data/t1/ledger.json"
  assert_absent "$e/data/t1/scrollback.txt" "ledger-secret-scrollback: a scrollback holding a credential was kept"
  if grep -rF "$token" "$e/data/t1" >/dev/null 2>&1; then fail "ledger-secret-scrollback: the credential reached data/<id>"; fi
  assert_grep "scrollback.txt" "$led" "ledger-secret-scrollback: the dropped file was not named"
  assert_grep "aws-access-key" "$led" "ledger-secret-scrollback: the pattern name was not recorded"
  pass "a scrollback matching a credential pattern is dropped and only the name and pattern are recorded"
}

test_lock_acquire_gives_up_when_a_stale_lock_cannot_be_moved() {
  local e rc
  e="$TMP_ROOT/lock-stuck"
  mkdir -p "$e/lock"
  printf '%s\n' 999999 > "$e/lock/pid"
  rc=0
  (
    . "$ROOT/bin/fm-archive-lib.sh"
    mv() { return 1; }
    fm_archive_lock_acquire "$e/lock" 3
  ) >/dev/null 2>&1 &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fail "lock-stuck: the acquire loop spun forever"; fi
  wait "$pid" || rc=$?
  [ "$rc" -eq 1 ] || fail "lock-stuck: expected a clean give-up (1), got $rc"
  pass "a stale lock that cannot be moved makes the acquire give up instead of spinning"
}

test_ledger_drops_a_local_commit_bundle_holding_a_secret() {
  local e token
  e=$(make_ledger_env ledger-secret-commit)
  token="AKIA$(printf 'ABCDEFGHIJKLMNOP')"
  printf '%s\n' "aws = $token" > "$e/wt/committed.txt"
  git -C "$e/wt" add committed.txt
  git -C "$e/wt" -c user.email=t@t -c user.name=t commit -q -m "oops"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-secret-commit: ledger failed"
  assert_absent "$e/data/t1/scratch/local-commits.bundle" "ledger-secret-commit: a bundle holding a credential was kept"
  assert_grep "local-commits.bundle dropped" "$e/data/t1/ledger.json" "ledger-secret-commit: the drop was not recorded"
  if grep -rF "$token" "$e/data/t1" >/dev/null 2>&1; then fail "ledger-secret-commit: the credential reached data/<id>"; fi
  pass "a local-commit bundle whose commits hold a credential is dropped"
}

test_ledger_neutralises_worker_controlled_git_config() {
  local e
  e=$(make_ledger_env ledger-git-config)
  printf '%s\n' base > "$e/wt/tracked.txt"
  git -C "$e/wt" add tracked.txt
  git -C "$e/wt" -c user.email=t@t -c user.name=t commit -q -m "add tracked"
  printf '%s\n' changed >> "$e/wt/tracked.txt"
  printf '#!/bin/sh\ntouch "%s/ran-marker"\nexit 0\n' "$e" > "$e/evil.sh"
  chmod +x "$e/evil.sh"
  git -C "$e/p" config core.fsmonitor "$e/evil.sh"
  git -C "$e/p" config diff.external "$e/evil.sh"
  git -C "$e/p" config core.hooksPath "$e/hooks"
  run_ledger "$e" >/dev/null 2>&1 || fail "ledger-git-config: ledger failed"
  assert_absent "$e/ran-marker" "ledger-git-config: a worker-controlled git config command ran"
  assert_grep "changed" "$e/data/t1/scratch/tracked.diff" "ledger-git-config: the tracked diff was not captured"
  pass "git runs in the worker's copy with fsmonitor, hooks, and external diff programs disabled"
}

test_ledger_kill_switch() {
  local e
  e=$(make_ledger_env ledger-off)
  env FM_NO_LEDGER=1 FM_HOME="$e" FM_STATE_OVERRIDE="$e/state" FM_DATA_OVERRIDE="$e/data" "$LEDGER" t1 >/dev/null 2>&1
  assert_absent "$e/data/t1" "ledger-off: FM_NO_LEDGER=1 must write nothing"
  pass "FM_NO_LEDGER=1 skips the ledger"
}

perm_of() {  # <path>: octal permission bits
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

test_archive_without_a_configured_volume_stays_in_staging() {
  local e out rc
  e=$(make_env no-volume mounted)
  set +e
  out=$(env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" FM_HOME="$e/home" \
    FM_CARD_MOUNT_ROOT="$e/volroot" FM_CARD_VOLUMES_FILE="$e/card-volumes" FM_ARCHIVE_VOLUME_FILE="$e/absent-volume-file" \
    FM_ARCHIVE_MIN_FREE_GIB=0 PATH="$e/fakebin:$PATH" "$ARCHIVE" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "no-volume: must exit 0"
  assert_contains "$out" "no archive volume configured" "no-volume: the notice should say no volume is configured"
  assert_present "$e/arch/transcripts/-proj/sess.jsonl" "no-volume: staging must still be written"
  assert_absent "$e/volroot/ARCHVOL/secure" "no-volume: nothing may be mirrored without a configured volume"
  pass "with no archive volume configured the run stays in staging and there is no built-in volume name"
}

test_archive_reads_the_volume_from_private_config() {
  local e out
  e=$(make_env volume-file mounted)
  printf '%s\n' '# private config' 'ARCHVOL' > "$e/volume-file"
  out=$(env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" FM_HOME="$e/home" \
    FM_CARD_MOUNT_ROOT="$e/volroot" FM_CARD_VOLUMES_FILE="$e/card-volumes" FM_ARCHIVE_VOLUME_FILE="$e/volume-file" \
    FM_ARCHIVE_MIN_FREE_GIB=0 FM_ARCHIVE_CARD_MIN_FREE_GIB=0 PATH="$e/fakebin:$PATH" "$ARCHIVE" 2>&1) || fail "volume-file: archiver failed: $out"
  assert_present "$e/volroot/ARCHVOL/secure/archive/transcripts/-proj/sess.jsonl" "volume-file: the mirror did not use the configured volume"
  pass "the archive volume name is read from the private config file"
}

test_installer_creates_a_private_root() {
  local e
  e=$(make_env install-perms)
  make_launchctl_stub "$e"
  (umask 022; run_install "$e" install --plist-dir "$e/agents" --no-load --allow-worktree >/dev/null 2>&1) || fail "install-perms: install failed"
  [ "$(perm_of "$e/arch")" = 700 ] || fail "install-perms: archive root is mode $(perm_of "$e/arch"), want 700"
  mkdir -p "$e/loose"
  chmod 755 "$e/loose"
  (umask 022; env HOME="$e/fakehome" FM_ARCHIVE_LAUNCHCTL="$e/launchctl" "$INSTALL" install --plist-dir "$e/agents" --no-load --allow-worktree --archive-root "$e/loose" >/dev/null 2>&1) || fail "install-perms: install over an existing root failed"
  [ "$(perm_of "$e/loose")" = 700 ] || fail "install-perms: an existing root was left at mode $(perm_of "$e/loose")"
  pass "the installer creates the archive root private and tightens one that exists"
}

test_archiver_tightens_an_existing_root() {
  local e
  e=$(make_env root-perms)
  mkdir -p "$e/arch"
  chmod 755 "$e/arch"
  (umask 022; run_archive "$e" --no-mirror >/dev/null 2>&1) || fail "root-perms: archiver failed"
  [ "$(perm_of "$e/arch")" = 700 ] || fail "root-perms: archive root is mode $(perm_of "$e/arch"), want 700"
  [ "$(perm_of "$e/arch/transcripts/-proj/sess.jsonl")" = 600 ] || fail "root-perms: a staged file is mode $(perm_of "$e/arch/transcripts/-proj/sess.jsonl"), want 600"
  pass "the archiver makes the root private and stages files mode 600"
}

test_archive_rewritten_source_is_saved_beside_the_archive() {
  local e out n
  e=$(make_env rewrite)
  run_archive "$e" >/dev/null 2>&1 || fail "rewrite: first run failed"
  cp "$e/arch/transcripts/-proj/sess.jsonl" "$e/orig"
  printf '%s\n' '{"line":"rewritten and now longer than before"}' > "$e/claude/projects/-proj/sess.jsonl"
  out=$(run_archive "$e" 2>&1) || fail "rewrite: second run failed"
  assert_contains "$out" "rewritten=1" "rewrite: not reported as a distinct result"
  cmp -s "$e/orig" "$e/arch/transcripts/-proj/sess.jsonl" || fail "rewrite: the archived copy was modified"
  n=$(find "$e/arch/transcripts/-proj" -maxdepth 1 -name 'sess.jsonl.rewritten-*' | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "rewrite: expected one saved rewritten copy, got $n"
  cmp -s "$e/claude/projects/-proj/sess.jsonl" "$e/arch/transcripts/-proj/"sess.jsonl.rewritten-* || fail "rewrite: saved copy differs from the new source"
  grep -q "rewritten" "$e/arch/archive.log" || fail "rewrite: not logged"
  run_archive "$e" >/dev/null 2>&1 || fail "rewrite: third run failed"
  n=$(find "$e/arch/transcripts/-proj" -maxdepth 1 -name 'sess.jsonl.rewritten-*' | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "rewrite: repeated runs duplicated the rewritten copy ($n)"
  printf '%s\n' '{"line":"more after the rewrite"}' >> "$e/claude/projects/-proj/sess.jsonl"
  run_hook "$e" "{\"transcript_path\":\"$e/claude/projects/-proj/sess.jsonl\"}" >/dev/null 2>&1
  run_archive "$e" >/dev/null 2>&1 || fail "rewrite: growth run failed"
  n=$(find "$e/arch/transcripts/-proj" -maxdepth 1 -name 'sess.jsonl.rewritten-*' | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "rewrite: growth after a rewrite created another copy ($n)"
  cmp -s "$e/claude/projects/-proj/sess.jsonl" "$e/arch/transcripts/-proj/"sess.jsonl.rewritten-* || fail "rewrite: growth was not appended to the rewritten copy"
  run_hook "$e" "{\"transcript_path\":\"$e/claude/projects/-proj/sess.jsonl\"}" >/dev/null 2>&1
  cmp -s "$e/orig" "$e/arch/transcripts/-proj/sess.jsonl" || fail "rewrite: the hook modified the archived copy"
  pass "a rewritten source keeps the archive untouched and is saved beside it once"
}

test_archive_floor_is_rechecked_while_staging() {
  floor_recheck_case floor-mid 1
}

test_archive_floor_counter_survives_stage_subshells() {
  floor_recheck_case floor-count 5
}

floor_recheck_case() {
  local e out rc
  e=$(make_env "$1")
  cat > "$e/fakebin/df" <<DFEOF
#!/bin/sh
n=\$(cat "$e/df.count" 2>/dev/null || echo 0)
n=\$((n + 1))
echo \$n > "$e/df.count"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
if [ \$n -le 1 ]; then echo "/dev/x 99999999 1 99999999 1% /"; else echo "/dev/x 99999999 1 0 100% /"; fi
DFEOF
  chmod +x "$e/fakebin/df"
  set +e
  out=$(env FM_ARCHIVE_ROOT="$e/arch" FM_ARCHIVE_CLAUDE_DIR="$e/claude" FM_HOME="$e/home" \
    FM_ARCHIVE_MIN_FREE_GIB=1 FM_ARCHIVE_FLOOR_CHECK_EVERY="$2" PATH="$e/fakebin:$PATH" "$ARCHIVE" --no-mirror 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "floor-mid: must stop with exit 3"
  assert_contains "$out" "stopped" "floor-mid: missing the stop message"
  [ -z "$(find "$e/arch" -name '*.tmp.*' 2>/dev/null)" ] || fail "floor-mid: partial files were left"
  if ls "$e/arch"/MANIFEST-*.sha256 >/dev/null 2>&1; then fail "floor-mid: a manifest was written after the stop"; fi
  pass "the free-space floor is rechecked while staging and stops the run cleanly"
}

test_hook_steals_a_pidless_lock_only_when_old() {
  local e src lock
  e=$(make_env hook-pidless)
  src="$e/claude/projects/-proj/sess.jsonl"
  mkdir -p "$e/arch/transcripts/-proj" "$e/arch/.locks"
  lock="$e/arch/.locks/f-$(printf '%s' "$e/arch/transcripts/-proj/sess.jsonl" | cksum | cut -d' ' -f1)"
  mkdir "$lock"
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  assert_absent "$e/arch/transcripts/-proj/sess.jsonl" "hook-pidless: a fresh pidless lock was stolen"
  touch -t 200001010000 "$lock"
  run_hook "$e" "{\"transcript_path\":\"$src\"}" >/dev/null 2>&1
  cmp -s "$src" "$e/arch/transcripts/-proj/sess.jsonl" || fail "hook-pidless: an old pidless lock was not reclaimed"
  assert_absent "$lock.steal" "hook-pidless: the steal guard was left behind"
  pass "a lock whose holder died before writing its pid is reclaimed by age"
}

run_case test_archive_stages_every_source
run_case test_archive_card_absent_stages_and_exits_zero
run_case test_archive_floor_refuses_and_writes_nothing
run_case test_archive_is_idempotent
run_case test_archive_growth_appends_only_new_bytes
run_case test_archive_shrunken_source_never_overwrites
run_case test_archive_changed_report_keeps_previous_version
run_case test_archive_rewritten_source_is_saved_beside_the_archive
run_case test_archive_floor_is_rechecked_while_staging
run_case test_archive_floor_counter_survives_stage_subshells
run_case test_hook_steals_a_pidless_lock_only_when_old
run_case test_archive_never_stages_database_dumps
run_case test_archive_imports_a_raw_clone
run_case test_archive_mirrors_to_a_verified_card
run_case test_archive_wrong_volume_is_treated_as_absent
run_case test_archive_read_only_card_stays_in_staging
run_case test_archive_nearly_full_card_is_not_written
run_case test_archive_card_write_failure_keeps_staging_intact
run_case test_archive_manifest_detects_corruption
run_case test_archive_secret_scan_reports_names_not_values
run_case test_hook_creates_appends_and_stays_silent
run_case test_hook_archives_subagent_transcript
run_case test_hook_and_archiver_share_one_offset
run_case test_hook_exits_zero_on_bad_input
run_case test_hook_refuses_untrusted_paths
run_case test_hook_never_overwrites_with_a_shorter_source
run_case test_hook_skips_behind_a_live_lock_and_steals_a_dead_one
run_case test_hook_parallel_runs_do_not_duplicate_or_lose_lines
run_case test_hook_respects_floor_and_kill_switch
run_case test_installer_renders_a_valid_escaped_plist
run_case test_installer_install_and_uninstall_drive_launchctl
run_case test_installer_no_load_does_not_touch_launchd
run_case test_installer_refuses_a_linked_worktree
run_case test_installer_rejects_bad_times
run_case test_ledger_contents
run_case test_ledger_caps_untracked_diff
run_case test_ledger_rerun_keeps_the_first_ledger
run_case test_ledger_degrades_without_worktree_or_pane
run_case test_ledger_kill_switch
run_case test_ledger_refuses_a_planted_symlink_file
run_case test_ledger_refuses_a_symlinked_scratch_directory
run_case test_ledger_refuses_a_symlinked_task_folder
run_case test_ledger_replaces_stale_scratch_contents
run_case test_ledger_excludes_secret_named_files
run_case test_ledger_drops_files_matching_secret_patterns
run_case test_ledger_drops_a_scrollback_holding_a_secret
run_case test_lock_acquire_gives_up_when_a_stale_lock_cannot_be_moved
run_case test_ledger_drops_a_local_commit_bundle_holding_a_secret
run_case test_ledger_neutralises_worker_controlled_git_config
run_case test_archive_without_a_configured_volume_stays_in_staging
run_case test_archive_reads_the_volume_from_private_config
run_case test_installer_creates_a_private_root
run_case test_archiver_tightens_an_existing_root
fm_case_summary "fm-archive"
