# Language Directives

Users who set `CONV_LANG` or `PLAN_LANG` expect every model-written sentence to arrive in that
language — narration between tool calls, subagent reports, plan artifacts, and codex review text
alike. Drift back to English happens where the directive is far away in context (long autonomous
tool runs, fresh subagent contexts, post-compaction, codex prompts). This document owns the
wording source, the injection points, the user-local instruction file, and the systemMessage
contract that keeps hook output language-neutral.

## Template SSOT

`hooks/lib/lang-directives.txt` is the single source of the directive wording. Each line is
`KEY=value`; `#` lines are comments.

| Key | Purpose |
|-----|---------|
| `TERMS` | Shared sentence about keeping glossary terms and engineering identifiers untranslated |
| `CONV_LANG` | Conversation-language directive (main conversation and subagents) |
| `PLAN_LANG` | Planning-artifact language directive |
| `CODEX_FREE_TEXT` | Free-text field directive for codex prompts |

Placeholders:
- `{lang}` — the normalized language name. Required in every directive key.
- `{terms}` — replaced by the rendered `TERMS` sentence, so the terms policy is written once and
  referenced by every directive.

`hooks/lib/lang-directive.js` renders the templates (`renderDirective(key, lang)`).

### Validation and fallback

Each key falls back independently to a fixed built-in sentence (`FALLBACK`) when its template is
missing or unusable, so a broken edit to the file degrades one directive, never the whole chain.

- A directive template is unusable when it lacks `{lang}`, contains a line break, or exceeds 600
  characters (measured without the `{terms}` placeholder; `TERMS` has its own cap).
- `CONV_LANG` must also begin with `Respond to the user in {lang}.` — that sentence is the
  trigger the conv-lang-fallback lines in agent and skill prompts key on.
- A broken `TERMS` line (empty, over 300 characters, multi-line, or containing a placeholder)
  only drops the terms sentence; the directives still render.

### Codex CLI

`node hooks/lib/lang-directive.js --codex conv|plan` prints the `CODEX_FREE_TEXT` line for the
conversation or planning language, resolved through `resolveConvLang()` (`hooks/lib/conv-lang.js`)
or `resolvePlanLang()` (`hooks/lib/lang-config.js`). It prints nothing when the policy is noop or
the language is invalid, and always exits 0. `bin/lib/codex-lang.sh` (`codex_lang_line`) is the
shell wrapper the codex prompt builders call, so language-name validation is never re-implemented
in bash.

## Injection points

| Event | Hook | Injects | Why here |
|-------|------|---------|----------|
| SessionStart | `session-start.js` | `CONV_LANG`, `VERBOSE_PROMPT`, user instructions | Fresh context |
| UserPromptSubmit | `lang-inject.js` | `CONV_LANG` every turn; `PLAN_LANG` while `isPlanning()` | Counters lost-in-the-middle per turn |
| PostCompact | `post-compact.js` | `CONV_LANG`, `PLAN_LANG` (gated by `isPlanning()`), `VERBOSE_PROMPT`, user instructions | Compaction drops earlier injections |
| SubagentStart | `subagent-start.js` | `CONV_LANG`, `PLAN_LANG`, `VERBOSE_PROMPT` (parent session's flag) | A subagent starts with an empty context |
| UserPromptSubmit + PostToolUse | `conv-lang-reinject.js` | `CONV_LANG` once per 128 KB of transcript growth | Long autonomous tool runs (below) |

`isPlanning()` lives in `hooks/lib/planning-phase.js` (any of `clarify_intent`/`outline`/`detail`
not complete or skipped; fails open to false) and is shared by `lang-inject.js` and
`post-compact.js`.

### Autonomous-run re-injection (`conv-lang-reinject.js`)

Between human prompts the per-turn injection never fires, and drift concentrates there. The hook
keeps a per-session baseline (`conv-lang-reinject.json` sidecar via `hooks/lib/control-sidecar.js`)
of the transcript size:
- UserPromptSubmit resets the baseline (`lang-inject.js` already injected for this turn).
- PostToolUse stats the transcript; once growth since the baseline reaches
  `REINJECT_BYTES = 128 * 1024`, it moves the baseline and emits the `CONV_LANG` directive as
  `additionalContext` (only when the baseline write succeeded, so a write failure cannot cause an
  injection on every tool call). A shrunken transcript resets the baseline.
- Subagent calls, a noop policy (english/any/unset), and any error yield `{}`.

The 128 KB constant (not an environment variable) is chosen for three reasons:
- **Drift position:** measured English rate rises to 22.0% 5-19 turns after a human prompt; at
  roughly 5-20 KB of transcript per tool call, 128 KB is 7-25 tool calls, overlapping that band.
- **Cost:** one injection is about 120 tokens against about 32k tokens of growth — roughly 0.4%.
- **Cheap check:** throttling by bytes, not by counting, means each PostToolUse costs one `stat`
  and one small read; state is written only on injection and on UserPromptSubmit.

`VERBOSE_PROMPT` is deliberately not injected per turn: it is long, and SessionStart, PostCompact
and SubagentStart already cover every point where the context is replaced.

## User-local instruction file

`user-instructions.md` at the agents checkout root (next to `.env` and `CLAUDE.local.md`;
gitignored) holds free-form per-user instructions. `hooks/lib/user-instructions.js` injects it
under a `[user-instructions]` header line at SessionStart and PostCompact only — not per turn and
not into subagents (#2774 tracks static auto-inject and SubagentStart).

- Setup mirrors `.env` / `.env.example`: copy the tracked template `user-instructions.example.md`
  to `user-instructions.md` and write the instructions below its comments.
- HTML comments (`<!-- ... -->`) are stripped on the whole text before anything else, so the
  template's explanation never reaches the model; an unclosed `<!--` runs to the end of the file.
- Cap: 4096 bytes after comment stripping, cut on a UTF-8 character boundary, followed by
  `[user-instructions truncated at 4096 bytes]` when cut.
- A missing, unreadable, or blank-after-stripping file injects nothing, so an untouched copy of
  the template injects nothing.
- It is not documented in `.env.example`: it is a file, not an environment variable, so it does
  not fit the one-block-per-variable form of `rules/docs/env-example.md`.

## systemMessage contract

A hook's `systemMessage` is shown to the user verbatim and never passes through the model, so it
cannot follow `CONV_LANG`. Every systemMessage line therefore carries language-neutral facts only:
it starts with a bracketed tag (`[<stage>]`, `[pr-created]`, …), and after the tag only
identifiers, paths, URLs, numbers, enum values, sentinels, command strings, and `key=value` pairs
(lowercase-and-hyphen keys) may follow — no English sentences and no natural-language labels such
as `Plan file:` or `Staged files:`. Explanations move to the model-facing channel (block `reason`
or `additionalContext`) wrapped once by `withConvLang`, and the model relays them in `CONV_LANG`.
Facts the user needs at a PreToolUse approval dialog (stage, path, URL) stay in the systemMessage.
