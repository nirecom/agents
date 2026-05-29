# Aggregating Class Members from Survey Outputs

1. Collect all `## Candidate class members` blocks from survey-code and
   survey-history outputs in the current session (skip missing or invalid artifacts).
2. Deduplicate by `<name>` (case-sensitive exact match on the identifier).
   When the same member appears in both artifacts:
   - Keep the higher-precedence proposed triage (MUST > OPTIONAL > NA).
   - Concatenate distinct rationales with `; `.
3. For members with no `proposed triage:` second line (legacy single-line survey
   entries): default to `OPTIONAL` with rationale
   `"legacy survey artifact — no triage proposed; defaulted to OPTIONAL"`.
4. If no candidates remain: the Class members proposal is skipped; write
   `- (none detected)` to `## Class members` in intent.md.
5. Otherwise emit the deduplicated list as input to Phase A in
   `class-members-proposal.md`.
