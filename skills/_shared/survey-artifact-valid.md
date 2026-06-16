# Survey Artifact Validity — Shared Contract

SSOT for validating that `survey-code` / `survey-history` subagents actually wrote a
usable artifact rather than returning findings only in chat.

Consumers (which MUST reference this file with a one-line pointer, never duplicate):
- `skills/workflow-init/SKILL.md` Step 6.5
- `skills/clarify-intent/SKILL.md` Completion CI-C3

## Validity criteria

An artifact at absolute path `<PLANS_DIR>/<session-id>-survey-{code|history}.md` is
**valid** when BOTH conditions hold:

1. The file exists.
2. The file contains the string `## Verified Claims` (the canonical section
   defined by `agents/survey-code.md` / `agents/survey-history.md` output schema).

Both conditions are applied symmetrically to `survey-code.md` and `survey-history.md` —
they share the same output contract.

Substring (not line-anchored) match is intentional: any subagent that emitted the
literal string `## Verified Claims` clearly produced the canonical schema. False
positives from quotes/code fences are not a realistic failure mode for these
artifacts.

## Reference Bash check

```bash
artifact_valid() {
  local f="$1"
  [ -f "$f" ] && grep -qF "## Verified Claims" "$f"
}
```

## Failure handling

A caller that detects an invalid artifact MUST treat the corresponding subagent as
failed and emit `<<WORKFLOW_SURVEY_AGENT_FAILED: survey-{code|history}>>`. Fall-through
behavior (do NOT abort; the downstream consumer handles missing/invalid artifacts by
re-invoking the affected survey) is unchanged from the existence-only check that
preceded this contract.

## Rationale

A subagent that ignored its write directive may have created a placeholder or partial
file. Requiring `## Verified Claims` ensures the file carries the canonical output
schema rather than a stub.
