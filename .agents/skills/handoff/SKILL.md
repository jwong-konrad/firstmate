---
name: handoff
description: Combine the /stow sweep with a session-context capture so a long-running session can be cleared without losing mid-discussion reasoning. Use when the captain invokes /handoff (e.g. "/handoff", "hand off before I clear"), before clearing or compacting a session whose conversational state is not yet on disk, or when the captain wants the current reasoning and next steps preserved for the next session.
user-invocable: true
metadata:
  internal: true
---

<!-- maintainers: this is a firstmate-internal skill with no public, installer-facing counterpart yet. If one is ever added it belongs at skills/handoff/SKILL.md as a deliberately separate file, exactly as stow keeps its two tiers independent. Keep them independent if that day comes. -->

# handoff

Capture everything a `/clear` would otherwise destroy, both the durable knowledge `/stow` already files and the mid-discussion reasoning and conversational context that `/stow` deliberately does not.
The goal is a session the captain can clear or reset with confidence that the next session can pick up the same threads at the same depth.

## What it does

1. **Run the stow sweep first.**
   Perform the stow skill's sweep and routing, steps 1 through 4 of that skill, exactly as written there.
   Stow stays the single owner of knowledge routing, so do not restate or vary its rules here.
   Capture stow's own verdict for the combined report in step 6.

2. **Capture the session context to a handoff document.**
   Write `data/handoffs/<YYYY-MM-DD>-<slug>/handoff.md`, where `<slug>` is a short kebab-case description of the session's main thread.
   The document records the reasoning and orientation that stow leaves behind, in these sections:
   - What was worked on and why: the session's goal and the motivation behind it.
   - Decisions made, each with its rationale, so a later session understands not just the choice but why it beat the alternatives.
   - Open threads, each with the CURRENT reasoning state: the options weighed, the current lean, and why that is the lean right now.
     This is the nuance stow deliberately does not file, so capture it in full rather than flattening it to a bare next step.
   - Concrete next steps, specific enough to act on without rereading the whole thread.
   - A where-to-look map: related task ids, key file paths, PR URLs (full `https://...`), status log paths, and scout report paths.
   - The raw-transcript pointer: the current session's id and its `jsonl` path under `~/.claude/projects/<escaped-cwd>/`, where `<escaped-cwd>` is the working directory with each non-path-safe character such as `/` and `.` replaced by `-` (so `/Users/me/.config` becomes `-Users-me--config`), recorded as the full-fidelity record that this document only distills.
     The pointer is a pointer, not a dump; when the session was long, add a distilled conversation-outline section rather than pasting the transcript.
     Harnesses other than claude may not expose a discoverable transcript path; when it cannot be resolved, write "transcript pointer unavailable on this harness" and continue rather than failing the handoff.

3. **Index the handoff.**
   Append one line per handoff to `data/handoffs/INDEX.md`: date, slug, doc path, related task ids, and status `active` or `retired`.
   Create `INDEX.md` on the first handoff if it does not exist.

4. **Surface it through the existing backlog, with no new machinery.**
   For each related backlog item that is still open, add a single pointer line `handoff context: data/handoffs/<dir>/handoff.md` to the item body using the backend's inspect-then-update contract (AGENTS.md section 10).
   Inspect the current body, add or update that one line in place, and never append a second copy.
   The session-start digest already prints the backlog, so the next session finds the handoff naturally through the item it is already reading.
   Do NOT modify `bin/fm-session-start.sh` or the digest format to surface handoffs; the backlog pointer is the whole mechanism.

5. **Retire completed handoffs.**
   Every `/handoff` run also sweeps `INDEX.md` for retention.
   For any active entry whose related tasks are all Done, flip its status to `retired` and move its directory under `data/handoffs/archive/`, updating the doc path in the index line to match.
   This keeps the active handoff set small so the next session sees only live context.

6. **Report to the captain.**
   Summarize, in plain outcome language (section 9): what was stowed and where (stow's own verdict from step 1), what was captured to the handoff document, which backlog items received a pointer, any entries retired this run, and a combined safe-to-clear verdict.
   The combined verdict holds only when both halves hold: every durable finding is on disk per stow, and the session's reasoning and next steps now live in the handoff document.
   If either half is incomplete, say so explicitly rather than reporting the session fully safe to clear.

## Scope exclusion: no skill storage

A handoff capture never writes into a skill, exactly as stow's "Scope exclusion: no skill storage" forbids.
That exclusion is the single owner of this rule; it applies here unchanged and is not restated.
Route durable knowledge through stow's destinations and conversational context into `data/handoffs/`, never into `.agents/skills/` or public `skills/`.
