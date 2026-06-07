---
globs: "rules/**/*.md,skills/**/SKILL.md,agents/**/*.md"
---

# Prompt-Content Quality Criteria

SSOT for prompt-style content quality. Applies to: `rules/*.md`, `skills/*/SKILL.md`, `agents/*.md`.
Referenced by: `bin/review-skill-size`, `/refactor-prompts` skill, future review skills.

## 1. Form

### 1.1 Directives, not prose

Write imperative directives. Prose explanations belong in architecture docs, not in prompt files.

### 1.2 One line per directive

Each directive occupies exactly one line. Do not run two rules into a single sentence.

### 1.3 Multi-step procedures live in CLI

If a procedure has more than 3 steps, move it to `bin/<tool>` or `skills/<name>/lib/`.
SKILL.md calls the CLI; it does not inline the steps.

### 1.4 Every token counts

Remove every word that does not change meaning or add constraint. Prefer the shorter form.

### 1.5 No inline code blocks in prompt files

Code blocks (3+ contiguous lines fenced with ```) are PROHIBITED in `rules/*.md`,
`skills/*/SKILL.md`, and `agents/*.md` for NEW additions and edits.

When a procedure needs an executable snippet of 3 lines or more:
1. Move the snippet into `skills/<skill-name>/scripts/<verb>.sh`
2. Replace the prompt-file content with a one-line reference

Existing violations in files not touched by the current change are out of scope — apply this rule at the point of addition or edit, not retroactively to the whole file.

> Note: examples in this section illustrate the rule itself and are not subject to it.

## 2. Examples discipline

### 2.1 No redundant hook examples

The hooks layer already enforces specific command literals:
- `hooks/lib/bash-write-patterns.js` WRITE_PATTERNS — blocked command patterns
- `settings.json` `deny` array — blocked tool invocations
- `hooks/enforce-system-ops.js` — blocked system-state-changing operations

Rules and SKILL.md files **must not** re-enumerate the same literals as illustrative examples.

**Allowed:**
- One representative example per **category** to anchor the reader's mental model
- Explicit process triggers — sentinel literals the reader must reproduce verbatim
  (e.g. `<<WORKFLOW_USER_VERIFIED: reason>>`)

**Prohibited:**
- Bullet lists that enumerate multiple hook-blocked literals as separate items

### 2.2 Few examples per concept

At most 2 examples per concept. More examples belong in the hook source (machine-checked)
or in a `bin/` script (executable and testable).

### 2.3 "See issue" only for complex background

Omit `see issue #N` (and similar "see X.md" pointers) unless the topic requires complex background or many examples that cannot be inlined.

### 2.4 No post-invocation skill explanations

After instructing to run a skill, do not describe what the skill does. The skill name is self-documenting.
Exception: unexpected behavior or out-of-scope cases the reader must anticipate.

## 3. SSOT (specialization of `core-principles.md` §2 for prompt content)

### 3.1 Reference the master — never copy

Never reproduce content from another authoritative file. Link or reference instead.

### 3.2 No echo in references

When pointing to a master file, do not restate its content. A one-line pointer is enough.

