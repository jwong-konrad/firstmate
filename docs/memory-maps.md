# Memory maps (data/learnings/ and data/captain/)

This doc owns the format and curation contract for firstmate's two growing memory files, `data/learnings.md` and `data/captain.md`, once they are split into a map plus topic files.
`bin/fm-memory-map.sh` owns the exact validate and split commands; `bin/fm-session-start.sh` owns what the digest prints; `docs/configuration.md` owns the home layout.

## Why

Both files are printed in full at every session start, and they grow without a size gate by captain decision, so they cost tens of thousands of tokens per session.
A map keeps the digest small and the knowledge intact: the digest prints one short `MAP.md`, and a topic file is read only when its trigger applies.
Nothing about the entries changes - they move verbatim, they are never summarized.

## Layout

```
data/learnings/MAP.md        printed by session start in place of data/learnings.md
data/learnings/<topic>.md    entries, read on demand
data/captain/MAP.md          printed by session start in place of data/captain.md
data/captain/<topic>.md      entries, read on demand
```

All of it is local and gitignored like the files it replaces.
`data/captain-shared.md` stays a single file because secondmate propagation owns it.
Session start prints the map when `MAP.md` exists and otherwise prints the flat file exactly as before, so a home that has not migrated, such as a fresh install or an older secondmate home, is unchanged.
The flat file may remain beside a map as a pre-migration snapshot; the map wins while both exist.

## MAP.md format

```
# <Title>

## Rules that always apply

- <lead of the entry, verbatim, at most about 115 characters> -> <topic>.md

## Topics

- [<topic>](<topic>.md) - read when: <trigger>
```

- The Topics dash may be an em dash or a hyphen; the validator accepts both.
- Every topic file in the directory is listed exactly once, and every listed file exists.
- `Rules that always apply` holds the entries whose omission would cause a breach, a destroyed work product, a leaked secret, or a false claim to the captain, and that no trigger would announce.
  Each line is the entry's own lead copied verbatim, never a paraphrase, plus the topic file that holds the full entry.
  The captain reviews this list before a cutover and may veto or extend it; a wrong omission is cheap to fix because the entry itself never moves.
- Everything else is on demand: the trigger names the situation, not the subject, so the agent can recognize it.

`bin/fm-memory-map.sh validate <dir>` checks all of this and prints an advisory note for a topic file past 30 KB.

## Curation

Inspect-then-update applies per topic file, not per home.
To add or change an entry, read the map, open the one topic file it points to, find the entry the new fact duplicates or supersedes, and rewrite it in place; otherwise add at the end of that file.
A genuinely new topic is a new file plus a new Topics line in the same edit, and the validator should pass afterwards.
Start every new entry with a title of at most about 110 characters (a bold title or a dated clause), then the dated body, so its lead can be copied into the map.
Never block work on size: past about 30 KB, prune that one file when convenient.
An entry whose retirement condition has landed moves to `data/learnings-archive/<topic>.md` rather than being deleted, and a `Retire: never` entry is the first candidate for the always-loaded rules.
When the always-loaded list or a trigger no longer matches reality, fix the map line in the same edit.
Skills are never a destination for these entries.

## Migrating a flat file

1. Snapshot the flat file verbatim first, because `data/` has no history.
2. `bin/fm-memory-map.sh entries <file>` lists each entry's start line, size, and lead.
3. Write an assignment file mapping entries to declared topics (format in the script header) and mark the always-loaded ones.
4. `bin/fm-memory-map.sh split <file> <assignment> <out-dir>` writes the topic files and `MAP.md` into a new directory, and refuses, writing nothing, if any entry would be lost or duplicated.
   Text outside entries (the old title, section headings, an old archive index) is kept in `.residue.txt`; non-heading text there needs `--allow-unowned`.
5. Move the result into `data/`, leave the old file as the snapshot, and confirm the next session start prints the map.
Rollback is moving the snapshot back and deleting the map directory.
