---
name: draw-mermaid
description: Generate or update a Mermaid diagram in a subagent to keep the main context clean. Dark-mode-safe colors and accessibility built in.
model: sonnet
argument-hint: "<what to diagram — or 'update: <change description>' to revise an existing diagram>"
---

Generate a diagram without loading diagram logic into the main context window.
Two modes depending on what's available:

- **Gemini CLI present** → `bin/draw-diagram-gemini` produces an SVG file
- **Gemini CLI absent** → Claude subagent produces a Mermaid code block (fallback)

## Procedure

DM-1. If args are empty, output:
   > No description provided. Usage: `/draw-mermaid <what to diagram>`

   and stop.

DM-2. **Check for Gemini CLI:**
   Run via Bash: `command -v gemini > /dev/null 2>&1 && echo GEMINI_AVAILABLE || echo GEMINI_ABSENT`

DM-3. **If GEMINI_AVAILABLE** — generate SVG:
   - Determine output path: default `docs/workflow.svg`; use a path from args if specified (e.g. `--output docs/foo.svg`)
   - Run via Bash (single line, no `&&` chaining):
     ```
     printf '%s' "<prompt>" | draw-diagram-gemini --output <output-path>
     ```
     Where `<prompt>` is the user's description from args, plus any existing Mermaid diagram
     from conversation context if this is an "update" request.
   - Report the output path to the user and suggest embedding as `![diagram](<output-path>)`.

DM-4. **If GEMINI_ABSENT** — generate Mermaid (fallback):
   - Spawn a subagent (Agent tool, `subagent_type: general-purpose`, `model: sonnet`) with
     a self-contained prompt that includes:
     - The diagram conventions below (copy verbatim into the prompt)
     - The user's description from args
     - Any existing diagram being updated (copy from conversation context if present)
     - This instruction: **Output only the fenced `mermaid` code block — no prose, no explanation.**
   - Present the subagent's output to the user.

## Rules

- Do not generate the diagram in the main session — always delegate (bin or subagent).
- Inserting the output into a file is the caller's responsibility after reviewing.
- If the user says "update" or pastes an existing diagram, include it verbatim in the prompt
  so it revises rather than creates from scratch.

---

## Diagram conventions (copy into subagent prompt verbatim)

### Line breaks

Use `<br/>` inside node labels — never `\n`. Mermaid treats `\n` as a literal string.

```
P2a["2a · survey-code<br/>skippable"]   ✓
P2a["2a · survey-code\nskippable"]      ✗
```

### Colors — classDef only

Define all colors in `classDef` blocks at the top; apply with `class`. Never inline `fill:`
on individual nodes.

```
classDef required fill:#1d4ed8,stroke:#1e3a8a,color:#fff
class S1,S2 required
```

### Dark-mode-safe palette (WCAG 2.1 AA)

GitHub renders Mermaid in light and dark themes. Use dark fills + white text so contrast
holds in both (≥ 4.5:1 on white, ≥ 3:1 on dark). Never use light pastels for text-bearing nodes.

| Role | Fill | Stroke | Text |
|------|------|--------|------|
| Terminal (start/end) | `#16a34a` | `#14532d` | `#fff` |
| Required step | `#1d4ed8` | `#1e3a8a` | `#fff` |
| Skippable step | `#475569` | `#334155` | `#fff` |
| Decision | `#b45309` | `#92400e` | `#fff` |
| Parallel | `#6d28d9` | `#4c1d95` | `#fff` |

Avoid red/green pairings — deuteranopia (8% of male users) makes them indistinguishable.

### Subgraph backgrounds

Use `style` (not `classDef`) for subgraphs. Pick a tint of the dominant color:

```
style Plan   fill:#1e3a8a,stroke:#1d4ed8,color:#fff
style Review fill:#4c1d95,stroke:#6d28d9,color:#fff
```

### Accessibility beyond color

Color alone must not be the only signal. Back it up with:

1. **Shape** — terminals `([])`, decisions `{}`, steps `[]`
2. **Text** — include "(skippable)" or "(optional)" inside the node label
3. **Edge labels** — label branches ("Yes / No", "worktree / branch / main")
