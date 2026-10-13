# Haiku auto-compact cap - verification record

Date: 2026-10-09.
Version: Claude Code 2.1.284, model `claude-haiku-4-5-20251001` (alias `haiku`), `claude-sonnet-5-5` (alias `sonnet`).

## Method

A throwaway headless session (`claude -p --input-format stream-json --output-format stream-json --verbose --dangerously-skip-permissions --model haiku`) in a scratch directory.
Each turn asked the model to read one ~5k-token file (random dictionary words, or repo docs) and reply `done`.
The compaction point is `compact_metadata.pre_tokens` of the first `compact_boundary` event with `trigger: auto`; it matched the last `usage` (input + cache read + cache creation) within about 200 tokens.
Each probe ran only to its first compaction.

## Results

Haiku, `CLAUDE_CODE_AUTO_COMPACT_WINDOW=<W>` (pre_tokens at first auto-compact, to the nearest turn of about 5k tokens):

| W | compacts at |
| --- | --- |
| unset | about 200k-221k (usage 197029 did not fire, 221301 fired) |
| 100000 | 36-38k |
| 132000 | 46-51k |
| 150000 | 58-62k |
| 170000 | 63-68k |
| 185000 | 72-76k |
| 200000 | 77-86k (random words and repo docs alike) |
| 300000 | 81k |
| 1000000 | 81k |

Equivalent knobs, same result as the env var at 100000 (36k): `--autocompact 100000` (36071) and `--settings '{"autoCompactWindow":100000}'` (36324).
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50` with no window: no effect (fired at 202194).
`CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000` plus `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60` or `100`: 83272 and 81580, no change.

## Findings

- The trigger is about 0.4 x W, not W minus a fixed buffer, and the window is clamped to the model's 200k.
  The highest compaction point reachable for Haiku is therefore about 80k; a 95k-99k trigger is not reachable with any of these knobs.
- `modelSettings.<model>.autoCompactWindow` is refuted: the settings schema defines only `effortLevel` and `maxEffortLevel` per model, and the binary never reads an auto-compact window from `modelSettings`.
- "Haiku 5.5" is refuted: the binary carries only `claude-haiku-3-5` and `claude-haiku-4-5` ids.
- The cap is process-wide, not per-model.
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 claude --model sonnet` compacted at 81494.
  A Haiku session that ran `/model sonnet` and then filled context kept the cap and compacted at 81555 on `claude-sonnet-5-5`.
  Subagents spawned in the same process inherit the environment.

## Decision

On 2026-10-09 the captain chose option B: no compaction knob is injected into any worker.
Firstmate instead watches a matching worker's context fill and sends `/compact` itself between turns (`config/compact-at`, `bin/fm-compact-at.sh`, docs/configuration.md), because the process-wide leak above cannot be contained per model.
