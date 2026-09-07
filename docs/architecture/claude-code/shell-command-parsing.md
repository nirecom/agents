# Shell Command Parsing — Ownership Map

Three shell-command parsers live in this repository. This page is the single place
that says which one owns what, who consumes each, and in what order the duplication
is being retired. Any hook that reads a Bash command string starts here.

## Why three

`hooks/lib/command-ir/` is the intended long-term owner. The other two predate it and
still back consumers that cannot be migrated mechanically:

- `command-parser.js` backs `checkBashCommand`, which returns a bare boolean and
  therefore has no IR contract to pin an equivalence test against. Its two
  `checkBashCommand` consumers are fail-closed credential boundaries, and
  `docs/security-policy.md` records the choice of that engine as an explicit security
  policy — swapping it is a policy change, not a refactor.
- `shell-segments.js` is a 40-line quote-aware splitter whose remaining consumers are
  scheduled for migration under `#1253`.

Keeping the duplication visible here is deliberate: the alternative is three parsers
that nobody knows are three.

## Lineage 1 — `hooks/lib/command-ir/` (owner)

The only parser that produces the IR. `parse(cmd, opts)` returns
`{ segments, separators, cmd0, argv, redirects, kind, rawText, parseFailure }` plus a
**non-enumerable** frozen `analysis` side-channel read through `analysisOf(ir)`.

Scope: quotes (`'`, `"`, `$'...'`), backslash escapes, heredoc openers and bodies,
command substitution, brace groups and subshells, and the full redirect-operator set.

Consumers are every production module that calls `parse()` — roughly 25 files under
`hooks/enforce-worktree/`, `hooks/lib/bash-write-patterns/`,
`hooks/lib/bash-write-targets/`, `hooks/block-clearance-token-write/`,
`hooks/confirm-forge-target-ownership/`, plus `hooks/block-shell-config.js` and
`hooks/bash-guard/`. They are not enumerated line-by-line here because `parse()` is a
public contract pinned by `tests/feature-2134-command-ir-equivalence/`; the two
lineages below are enumerated because their consumer sets are meant to shrink to zero.

Known gap: newlines are still not recorded as separators (`#2121` Changes 3, moved to
`#1253`).

### The `analysis` side-channel

`analysis` is non-enumerable so `JSON.stringify(parse(cmd))` and deep-equal snapshots
stay byte-identical to the pre-migration shape — the same reason `redirects[].targetRaw`
is hidden. The cost is that a spread copy (`{ ...ir }`) or a serialization round-trip
loses it. `analysisOf()` therefore degrades to a neutral default rather than throwing,
and every fail-closed consumer must pass `parse()`'s return value **directly**.

## Lineage 2 — `hooks/lib/command-parser.js` (frozen)

Logic frozen; no new consumers. Retired by follow-up issue (see below).

<!-- BEGIN CONSUMERS: command-parser -->
`checkBashCommand` (whole-engine) consumers:

- `hooks/block-credentials.js`
- `hooks/block-dotenv.js`

Partial-API consumers (`extractSubstitutionContents`, `stripTrailingRedirects`,
tokenizer internals):

- `hooks/block-clearance-token-write/bash-scan/scan.js`
- `hooks/confirm-forge-target-ownership/nested-commands.js`
- `hooks/enforce-worktree/branch-delete-guard.js`
- `hooks/lib/command-head.js`

Lineage 1 also reuses this module's tokenizer and separator walk rather than forking a
second lexer, so the IR parser appears here as a consumer:

- `hooks/lib/command-ir/parse.js`
- `hooks/lib/command-ir/segments.js`
<!-- END CONSUMERS: command-parser -->

Known gaps that survive this PR: `stripSubstitutions` removes substitutions with a
regex, and `splitSegmentsWithSeparators` is heredoc-unaware, so the `#2121`
mis-segmentation class still applies on this path.

## Lineage 3 — `hooks/lib/shell-segments.js` (shrinking)

Quote-aware splitter on `;`, `&&`, `||` only. Not deleted, not extended.

<!-- BEGIN CONSUMERS: shell-segments -->
- `hooks/enforce-worktree/bash-write-scope.js`
- `hooks/enforce-worktree/main-worktree-allows/worker-script.js`
<!-- END CONSUMERS: shell-segments -->

canary-1 (`hooks/lib/merge-detect.js`) migrated to lineage 1; the two above migrate
under `#1253`.

## Migration order

1. Lineage 3 → lineage 1, under `#1253`.
2. Lineage 2 → lineage 1, under the follow-up issue filed with this PR. Its charter is
   all six consumers listed above plus the `#2121`-type mis-segmentation that remains
   on that path. Because `checkBashCommand` returns a boolean, that migration needs its
   own behavioural test design — it cannot ride the IR equivalence suite.

## Staying honest

`tests/feature-2134-command-ir-equivalence/ownership-doc.sh` scans `hooks/`, `bin/`,
`install/` and `lib/` for `require()` of each lineage and compares the result against
the marker blocks above, in both directions. Adding or removing a consumer without
editing this page turns that test red.
