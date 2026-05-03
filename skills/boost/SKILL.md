---
name: boost
description: Delegate the current task to an Opus subagent for maximum reasoning power. Use when a task is too complex, ambiguous, or high-stakes for Sonnet.
model: sonnet
argument-hint: "<task description>"
---

Delegate the task described in args to a one-shot Opus subagent.

## Procedure

1. If args are empty, output `No task provided. Usage: /boost <task description>` and stop.

2. Output the following notice as Claude text (NOT via Bash echo):

   > **Boosting to Opus.** Delegating this task to a one-shot Opus subagent.
   > Task: `<args>`

3. Spawn a subagent using the Agent tool with:
   - `subagent_type: general-purpose`
   - `model: opus`
   - `mode: auto`
   - Prompt: the task description from args, plus relevant conversation context
     (recent user messages, file paths mentioned, intent/outline file contents if any).

4. Return the subagent's output to the user.

## Rules

- Do not call `judge-task-complexity` — boost always uses Opus unconditionally.
- This skill delegates **a single task**. It does not change session state or affect future skill calls.
- Pass enough context in the prompt so the subagent can act without further clarification.
