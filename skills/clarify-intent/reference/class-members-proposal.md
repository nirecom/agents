# Class Members Proposal Flow

## Phase A — Text proposal (auto-accept)

Sort the deduplicated candidate list (from `aggregate-class-members.md`) by
triage priority: MUST → OPTIONAL → NA. Within the same triage, preserve the
upstream order from aggregation.

Present the sorted list to the user as plain text in the main conversation
(NOT inside AskUserQuestion):

    ## Proposed class members triage

    - <name>: <description> — proposed triage: <MUST | OPTIONAL | NA>
      rationale: <one line>
    - ...

Then record every candidate in intent.md `## Class members` using the proposed
triage values verbatim. No user confirmation is requested at this stage —
disposition refinement happens at the outline / detail planning stages.

If the list is empty, write `- (none detected)` to `## Class members` in
intent.md.
