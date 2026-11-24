# Review Threat Metrics

What and why for `bin/review-threat-metrics` (#2020), the measurement CLI for the
threat boundary that scopes codex security reviews.
The boundary itself (axes A0–A6 / B0–B3, the `[NOT-CONCERN]` marker line, the
`Version: vN` declaration) is owned by the `## Threat boundary` section of
[review-criteria.md](../../../skills/_shared/review-criteria.md).
The concern journal row contract (columns, the boundary version column) is owned by
[concern-ledger.md](../../../skills/_shared/concern-ledger.md); this file does not
restate either.

## Why measure

Before the threat boundary, codex raised security concerns that assumed an external
attacker against a local, single-user toolchain; most were rejected by hand.
The boundary tells codex which threats are in scope, but whether it actually reduces
out-of-boundary and no-input-path concerns is an empirical question.
The CLI answers it per boundary version, so each revision of the boundary is judged
against the version before it rather than against a fixed baseline.

## Two modes

| Mode | Population | Source of truth |
|---|---|---|
| `pre-boundary` | v0 sessions: created before the boundary time and holding no journal row of v1 or later | rejected concern records and filed issues, classified once by an LLM into a v0 cache |
| `post-boundary` | sessions created at or after the boundary time, plus earlier sessions holding a v1+ journal row | the concern journal, attributed per review round to the boundary version codex was sent |

v0 has no journal, so it can only be measured from what survived: a seeded sample
(60 rejected concern records + 40 issues, each side topping up the other, capped at 100).
The v0 classification runs once and its cache is never appended, so the v0 numbers
stay fixed while later versions are compared against them.
The cache stores one item per distinct concern text with a `count`, and every ratio
weighs each item by that count, so findings that share a text are not collapsed into one.
A run whose classifications are all invalid still writes the cache (the invalid count is
the measurement); a run where the classifier answered no class at all writes nothing and
fails, so the next run classifies again instead of freezing an empty v0.

## Reading the metric blocks

Every block carries `population_kind`, because the denominators differ and must
never be summed across kinds:

- `v0-population` (`pre-boundary` mode) — the sampled rows with a valid classification;
  `weighted` re-weights the carrier and issue sides by their population size.
- `all` (`post-boundary` mode) — every journal row of one version, folded per
  (session, DISCRIM); counts split into `out_of_boundary`, `no_path`, `concern`,
  `untagged`.
- `sample` (`post-boundary` mode) — the comparison subset, drawn by the `pre-boundary` mode's rules
  from the same version's rejected concern records and issues and classified the same way, so it is
  the only block comparable with v0. `calibration` reports how often the classifier
  agrees with codex's own axis tag.

### Exclusions

Each mode reports `excluded` as reason → count, so a shrinking population is
visible rather than silent: `no-state`, `out-of-period`, `post-boundary-rows`,
`no-marker`, and the issue-side reasons (`no-findings`, `ambiguous-origin`,
`origin-no-state`, `no-created-at`).
`journal_excluded` counts rows that cannot be attributed to a single version
(`unmatched`, `unknown`, `multi-version`).

### Comparability and boundary baseline

- `v0_comparison.status` is `comparable` only when the v0 cache was built by the
  same classifier (`classifierId`); otherwise it is `not-comparable` and the numbers
  are shown but not compared.
- `boundary_baseline` for v1 is the v0 cache (subset only); for vN it is the vN-1
  `sample` and `all` blocks. A version with no rows reports `status: no-data`.

## Output and exit codes

Text output is a `# review-threat-metrics <mode> model=… classifierId=…` header
followed by `key=value` lines; `--json` prints one JSON object. Exit 0 is success,
2 a usage error, 5 a source read or write failure — including a source file that
exists but cannot be read (named on stderr, nothing printed on stdout), because counting
it as empty would silently shrink the population.
