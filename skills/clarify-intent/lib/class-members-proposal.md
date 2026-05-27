# Class Members Proposal Flow

## Phase A — Text proposal

Present the deduplicated candidate list (from `aggregate-class-members.md`) to
the user as plain text in the main conversation (NOT inside AskUserQuestion):

    ## Proposed class members triage

    - <name>: <description> — proposed triage: <MUST | OPTIONAL | NA>
      rationale: <one line>
    - ...

If the list is empty, write `- (none detected)` to `## Class members` in
intent.md and skip Phases B/C.

## Phase B — AskUserQuestion (Accept / Modify)

Call AskUserQuestion with one question and two options:
- Question: "Accept this class members triage proposal?"
- Option 1 (recommended): "Accept proposal as-is"
- Option 2: "Modify — I want to change one or more triage values"

On **Accept**: record every candidate in intent.md `## Class members` using the
proposed triage values verbatim.

On **Modify**: proceed to Phase C.

## Phase C — Resolve the Modify path

Ask one free-text follow-up via AskUserQuestion:
- Question: "Which triage values should change? Describe per member in natural
  language (e.g. 'change X to NA, promote Y to MUST')."

Parse the free-text response:

1. Named members with a new triage → override; all others keep their proposed triage.
2. Named members to remove → set `triage: NA` with rationale "user-removed during clarify-intent".
3. Members added by the user but not in the merged list → append with user-specified triage
   and rationale `"user-added during clarify-intent"`.
4. Ambiguous input: re-issue the free-text question once. On the second ambiguity:
   record the user's last input verbatim in intent.md `## Constraints` with note
   `"triage assignment could not be parsed after 2 attempts"`, then proceed with
   the partially-parsed triage list (parsed members keep their values; ambiguous
   members keep their proposed default).

The recorded triage value in `## Class members` is ALWAYS one of `MUST`,
`OPTIONAL`, or `NA`. The Modify parse never produces an out-of-enum value;
ambiguous input falls through to the proposed default (a valid enum value).

## Round budget

Phases A + B + C (including re-issue) count as exactly **1** of the 5 interview
rounds in clarify-intent. A skipped proposal (empty list) consumes 0 rounds.
