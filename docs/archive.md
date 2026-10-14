# Cold archive and agent-activity capture

This document owns where the archive lives, what goes in it, how long it is kept, who may see it, and what happens when storage fails.
Each script's header owns its flags and mechanics; the rows below point at them.

The archive exists because the agents' own records are short-lived.
Claude Code deletes transcripts, subagent transcripts, and file-edit snapshots on a schedule, and firstmate's teardown deletes a task's status history, model, effort, PR link, and scratch work.
The archive copies the record out before either happens, and `bin/fm-recall.sh` makes the written part searchable.

## What captures what

| Source | Captured by | Lands in |
| --- | --- | --- |
| Claude transcripts, subagents included | `bin/fm-archive.sh` nightly, and `bin/fm-transcript-archive-hook.sh` at every Stop, SubagentStop, and SessionEnd | `transcripts/` |
| `~/.claude/file-history` | `bin/fm-archive.sh` | `file-history/` |
| `data/<id>/report.md` and `brief.md` | `bin/fm-archive.sh` | `tasks/<id>/` |
| Teardown ledger, pane scrollback tail, scratch snapshot | `bin/fm-teardown.sh` through `bin/fm-ledger.sh`, then `bin/fm-archive.sh` | `data/<id>/` and `tasks/<id>/` |
| `data/handoffs/` | `bin/fm-archive.sh` | `handoffs/` |
| Task screenshots, `data/<id>/shots/` | `bin/fm-archive.sh` | `evidence/<id>/shots/` |

Not captured: tool-result files and other `~/.claude` scratch (a transcript already holds the tool output it produced), the captain's `history.jsonl` (Claude Code never sweeps it), and database dumps, which are excluded by construction because only the paths above are ever read.

## Layout

Staging lives outside the repo and outside `data/`, so nothing that walks the repo or `data/` touches it.
The default root is `~/Code/firstmate-archive/`, set with `FM_ARCHIVE_ROOT`.

```
firstmate-archive/
  transcripts/<project dir>/<session>.jsonl          same relative path as under ~/.claude/projects
  transcripts/<project dir>/<session>/subagents/agent-<id>.jsonl
  file-history/<session>/<hash>@v<n>
  tasks/<id>/{report.md,brief.md,ledger.json,scrollback.txt,scratch/}
  handoffs/<handoff>/...
  evidence/<id>/shots/...
  MANIFEST-YYYY-MM.sha256                            append-only, one file per month
  reports/secret-scan-YYYY-MM.txt                    monthly scan, names and counts only
  index/archive.db                                   derived search index, rebuildable
  archive.log  .state/  .locks/                      run log, last-run record, per-file locks
```

The mirror is `<archive volume>/secure/archive/`, the same tree minus `index/`, the log, and the locks.
A one-off raw copy of `~/.claude` taken by hand can sit beside these directories; `bin/fm-archive.sh --import <dir>` folds its transcripts and file-history into staging.

Transcripts are stored raw, not compressed, so the Stop hook can append to them and a search can read them with no decompression step.
New files are copy-on-write clones on APFS, so a file costs almost no extra disk until its original changes.

## Capture rules

- Transcripts are append-only: the staged size is the offset, shared by the archiver and the hook, so each byte is copied once, a still-open session is captured as it grows, a source that shrank never overwrites what is archived, and a source that grew is appended only when the staged bytes are still its prefix (first and last 4 KiB compared); a rewritten source leaves the archive untouched and is saved beside it as one `<name>.rewritten-<UTC time>` copy that later growth is appended to (a new copy starts only if that copy stops matching the source's prefix), logged, and reported as `rewritten=N`.
- `file-history` and screenshots are copied once and never rewritten.
- Reports, briefs, ledgers, and handoffs are copied when they differ, and the previous copy stays beside the new one as `<name>.<UTC time>.bak`.
- Each run appends `sha256 size time path` lines to the month's manifest for every staged file whose size differs from its latest entry; `bin/fm-archive.sh --verify` re-checks them and names a corrupt, truncated, or missing file.
- The archiver refuses to run below the internal free-space floor (`FM_ARCHIVE_MIN_FREE_GIB`, default 15 GiB, exit 3, nothing written), rechecks it every `FM_ARCHIVE_FLOOR_CHECK_EVERY` files (default 100) while staging, and stops cleanly with exit 3 and no partial files when it is crossed, and the hook skips silently below it.

## The nightly job

`bin/fm-archive-install.sh install` renders `docs/examples/com.firstmate.archive.plist.template` into `~/Library/LaunchAgents/` and loads it.
It runs `bin/fm-archive.sh` at 03:17 and once at every login, so a reboot or a sleeping laptop catches up at the next opportunity, and the agent is reloaded by launchd at login with nothing else to do.
Run it from the primary checkout, because the plist records that checkout's path; a linked worktree is refused.
The captain runs the installer, `status` shows what launchd and the last run recorded, and `uninstall` removes it.

## The transcript hook

Register the hook once at user level so every Claude session on the machine is covered.
Merge these entries into the existing `hooks` object of `~/.claude/settings.json`, adding to any `Stop`, `SubagentStop`, or `SessionEnd` array already there rather than replacing it, and use the absolute path of the primary checkout in place of `<checkout>`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "<checkout>/bin/fm-transcript-archive-hook.sh", "timeout": 10 } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "command": "<checkout>/bin/fm-transcript-archive-hook.sh", "timeout": 10 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "<checkout>/bin/fm-transcript-archive-hook.sh", "timeout": 10 } ] }
    ]
  }
}
```

The hook reads the event JSON on stdin (`transcript_path`, and `agent_transcript_path` on a subagent stop), prints nothing, and always exits 0, so it can never block or fail a session.
The event JSON is untrusted input, so the hook copies only a path that passes every check: absolute, no `.` or `..` component, ending in `.jsonl`, a regular file and not a symlink, and resolving (symlinks in its directory included) to a place under `~/.claude/projects/`.
Anything else is skipped and the log records only the reason, never the path or the content.
Set `FM_ARCHIVE_HOOK=off` in the environment to disable it without editing settings.
With the hook registered the nightly job is a safety net, not the only capture.
Uninstalling the nightly job does not remove the hook; delete its three entries from `~/.claude/settings.json` by hand.

## The teardown ledger

`bin/fm-teardown.sh` calls `bin/fm-ledger.sh` after the landed-work checks have passed and before any destructive step, for ship and scout tasks but not secondmates.
It writes `data/<id>/ledger.json` (task, kind, project, harness, model, effort, mode, PR, worktree, start and end, the full status history, and each Claude session found for the worktree with token and cost totals counted once per API message), `scrollback.txt` (the pane's last 2000 lines), and `scratch/` (`git status --porcelain`, a git bundle of commits no remote has, `git diff HEAD`, and a size-capped diff of untracked text files).
A forced teardown that discards work therefore leaves that work recoverable from `scratch/`.

The task folder is writable by the worker, so the ledger treats it as untrusted.
It refuses when `data/<id>` or `scratch/` is a symlink, recreates `scratch/` fresh and checks that it is a real directory owned by the user, and writes every output to a new temporary file inside it before moving it into place, so a planted link can neither redirect a write nor have its target overwritten.
Git runs against the worker's copy with the file-system monitor, hooks, external diff drivers, and text conversion switched off.
The snapshot never keeps secrets: files named `.env*`, `*.pem`, `*.key`, `*.p12`, `id_*`, `*credential*`, `*secret*`, or `*.keychain*` are left out by name, the same credential patterns the monthly scan uses are run over what remains, and a matching file is dropped, with only its name and the pattern name recorded.
Steer history is not recorded anywhere today, and the ledger says so rather than leaving it blank.

The ledger is fail-soft by construction: it runs as a separate bounded process, every step is best effort, and a failure is a warning that never changes whether teardown proceeds.
It cannot weaken the landed-work refusal, because it runs only after that check has passed and a refused teardown never reaches it.
`FM_NO_LEDGER=1` skips it, and `tests/lib.sh` sets that for every suite so only the suites that test the ledger write one.

## Search

`bin/fm-recall.sh index` builds a SQLite FTS5 index over reports, handoffs, decisions, learnings, captain notes, and ledgers from `data/` and the archive, and `bin/fm-recall.sh query "<words>"` returns ranked sections with their paths and states when the index was built.
`index --transcripts` adds a digest of user prompts and assistant text, never tool output.
`bin/fm-recall.sh grep "<regex>"` searches the raw archived transcripts with ripgrep, or grep when ripgrep is absent.
There are no embeddings: a miss is cured by indexing more, or by trying other words, not by a model.

## Retention

- Transcripts, ledgers, reports, handoffs, scrollback tails, scratch snapshots, and manifests are kept forever.
- Screenshots are copied, not moved, and are kept; moving them out of `data/` after 30 days and the one-year citation-only trim are not implemented here.
- Staging is the working copy and the card is its mirror, so nothing is deleted from staging by any script in this repo.
- Claude Code's own cleanup of `~/.claude` is a separate setting (`cleanupPeriodDays`) and does not touch the archive.

## Privacy

The archive is private to the captain's machine and the encrypted card volume.
It is never synced, uploaded, attached, shared with a collaborator, or placed in a cloud-synced folder or in git, and nothing in this repo sends it anywhere.

- Transcripts and screenshots contain real names, internal data, and possibly credentials, and they are stored unredacted, because redaction destroys forensic value and misses secrets.
- The mirror target is the encrypted volume named in private configuration (`FM_ARCHIVE_VAULT_VOLUME` or `~/.config/firstmate/archive-volume`; there is no built-in name), and staging sits on the encrypted internal disk; files are created mode 0600 and the root mode 0700, which the installer and the archiver both enforce, so an archive made earlier with looser permissions is tightened on the next run.
- Database dumps stay on the internal disk and are never archived.
- Exclude the archive from any backup, or confirm the backup is encrypted, because a backup that copies it unencrypted defeats the rest of this section.
- Once a month the archiver scans the archive for credential patterns and writes `reports/secret-scan-YYYY-MM.txt`, which lists the pattern name, the match count, and the file, and never the match.
  The scan is a report only; acting on a hit, such as rotating a credential, is the captain's call.
- Any outward use of archived material needs a separately produced, redacted extract.

## Failure modes

| Failure | What the scripts do |
| --- | --- |
| Card absent, locked, or the wrong volume | The mount check needs the pinned volume mounted, carrying the UUID in `~/.config/firstmate/card-volumes`, and passing a write test; otherwise the run prints `card absent, staging only`, exits 0, and writes nothing under any `/Volumes` path |
| Card mounted read-only | The write test fails, the run stays in staging and names the reason in the log |
| Card nearly full (`FM_ARCHIVE_CARD_MIN_FREE_GIB`, default 2) | Text mirrors first, so file-history and screenshots are skipped before the small, high-value set stops syncing |
| Card write fails or the card is pulled mid-run | The mirror stops, reports `card write failed`, leaves staging intact, and removes the partial file; the next run resumes |
| Card dies | Staging holds a complete copy; restore by copying staging to a new volume and running the archiver |
| Internal disk full | The archiver refuses below the floor and the hook skips below it; nothing is written, and the Claude originals stay in place |
| Source shrank | The archived copy is kept and the run log names the file |
| Source rewritten (longer, but no longer starts with the archived bytes) | The archived copy is kept, the new source is saved as a single `<name>.rewritten-<UTC time>` copy kept current by appending, and the log and `rewritten=` count name it |
| Hook and archiver run together | A per-file lock serialises them; the hook waits two seconds then skips, and the next event or run catches up; a lock whose process is dead, or that never got a pid and is older than `FM_ARCHIVE_LOCK_STALE_SECS` (30), is stolen under a guard so two waiters cannot remove a freshly taken lock |

The card mount check is `fm_card_ok` in `bin/fm-archive-lib.sh`.
With no archive volume configured the run stays in staging and says so.

## Environment reference

| Variable | Default | Meaning |
| --- | --- | --- |
| `FM_ARCHIVE_ROOT` | `~/Code/firstmate-archive` | Staging root |
| `FM_ARCHIVE_CLAUDE_DIR` | `~/.claude` | Where transcripts and file-history are read from |
| `FM_ARCHIVE_VAULT_VOLUME` | none | Card volume the mirror targets; when unset, the first word of `FM_ARCHIVE_VOLUME_FILE` |
| `FM_ARCHIVE_VOLUME_FILE` | `~/.config/firstmate/archive-volume` | Private file holding that volume name |
| `FM_ARCHIVE_MIRROR_SUBDIR` | `secure/archive` | Directory on the volume |
| `FM_ARCHIVE_MIN_FREE_GIB` | `15` | Internal free-space floor |
| `FM_ARCHIVE_FLOOR_CHECK_EVERY` | `100` | Files staged between free-space rechecks |
| `FM_ARCHIVE_LOCK_STALE_SECS` | `30` | Age after which a pidless lock is reclaimed |
| `FM_ARCHIVE_CARD_MIN_FREE_GIB` | `2` | Card free-space floor |
| `FM_CARD_VOLUMES_FILE` | `~/.config/firstmate/card-volumes` | Pinned `<NAME> <Volume UUID>` lines |
| `FM_ARCHIVE_HOOK` | `on` | `off` disables the transcript hook |
| `FM_NO_LEDGER` | unset | `1` skips the teardown ledger |
| `FM_RECALL_DB` | `<root>/index/archive.db` | Search index location |
