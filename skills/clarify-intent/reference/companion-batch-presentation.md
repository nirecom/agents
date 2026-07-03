# Companion-Issue Batch Presentation Procedure

Read the `precheck-companions.sh --output-file <snap>` snapshot before presenting.

## Main-conversation display (before AskUserQuestion)

Present the following in the MAIN CONVERSATION (not inside AskUserQuestion):
- Baseline decomposition verdict (seed-only scope).
- Per-candidate decomposition impact: verdict change and triggering signals.
- `(companion-driven)` annotation on signals that only fire due to the companion candidate.
- If a candidate would trigger `wf-meta`: note "adding #N would propose session decomposition."

## Batch AskUserQuestion

Present all candidates in ONE multiSelect AskUserQuestion batch.
- Maximum 4 options per question; 5+ candidates split into 4+1, 4+4+4... pages.
- Pre-announce page count in main conversation ("X candidates across Y question(s)").
- `low-purity` candidates shown with a "(low-confidence match)" note.
- No side effects at selection time; side effects fire via `clarify-commit-scope.sh` after CI-5.

## wf-meta confirmation (when applicable)

If the selected candidate subset produces a `wf-meta` verdict:
- Announce the sub-deliverable list in the MAIN CONVERSATION first.
- Ask at most ONE wf-meta confirmation AskUserQuestion (pre-announced above).
- Never auto-switch to wf-meta without this confirmation.
