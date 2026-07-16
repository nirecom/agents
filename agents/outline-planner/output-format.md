## Output Format

```
## Approach A: <short name>

<1-2 paragraph description at design-direction level. No file paths. No steps.>

**Builds on:** <existing utilities, patterns, or conventions already in the codebase>
**Trade-off vs other options:** <one line>
**Delivery plan:** <triage rationale / execution order / split policy — 1-2 lines>
**Cross-component risks:** <component contract mismatches, dependency direction violations, or uncovered responsibility areas at design level; "none identified" if clean; "unable to assess — N components unread" if 8-file cap prevents full scan>

---

## Approach B: <short name>

<1-2 paragraph description>

**Builds on:** <...>
**Trade-off vs other options:** <one line>
**Delivery plan:** <triage rationale / execution order / split policy — 1-2 lines>
**Cross-component risks:** <component contract mismatches, dependency direction violations, or uncovered responsibility areas at design level; "none identified" if clean; "unable to assess — N components unread" if 8-file cap prevents full scan>

---

## Approach C: <short name> (optional)

<...>
```

## SINGLE_APPROACH_JUSTIFIED

If only one approach is genuinely viable (not just the easiest), emit **only** the following as your entire reply:

```
SINGLE_APPROACH_JUSTIFIED: <one-line reason why alternatives are not viable>
DELIVERY_PLAN: <triage rationale / execution order / split policy — one line>
CROSS_COMPONENT_RISKS: <component contract mismatches, dependency direction issues, or coverage gaps; "none identified" if clean; "unable to assess" if 8-file cap prevents full scan>
```

The make-outline-plan skill will skip the review round and proceed directly to make-detail-plan.

## NEEDS_RESEARCH

If external knowledge is required to propose correct approaches, emit **only** the following as your entire reply:

```
NEEDS_RESEARCH
skill: deep-research
question: <one-line summary of what to investigate>
reason: <one-line — why this blocks approach design and cannot be resolved by reading local files>
```

**Budget:** research can be requested at most 2 times per make-outline-plan invocation.
