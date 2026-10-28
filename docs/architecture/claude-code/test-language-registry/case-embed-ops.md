# caseEmbedRules analyzer parts (pester, pytest, js)

The op table and the same-shell contract live in [../test-language-registry.md](../test-language-registry.md) "Parts".
This page owns how the three non-bash parts answer those ops, and why they can be trusted to answer about the same cases the test case reader saw.

## Shape

Each language has a thin bash part and an analyzer child process in the language's own runtime:

| id | part (`caseEmbedRules`) | analyzer | shared case enumeration |
|---|---|---|---|
| `pester` | `pester-case-embed.sh` (`pester_case_embed`) | `pester-case-analyzer.ps1` | `pester-case-scan.ps1` (dot-sourced) |
| `pytest` | `pytest-case-embed.sh` (`pytest_case_embed`) | `pytest-case-analyzer.py` | `pytest_case_scan.py` (module) |
| `js` | `js-case-embed.sh` (`js_case_embed`) | `js-case-analyzer.js` | `js-case-scan.js` (module) |

All files sit in `bin/lib/test-language-parts/`; `case-embed-common.sh` holds the parts' shared body.
The analyzer parses the file with the same parser as the test case reader and never runs it.
The analyzer is called as `<op> <native file path> [args]` and prints the op's TSV; `self-impl` also gets the entry's `helperLibrary` path.

## Part results

- `rules-doc` answers without a runtime: `skills/sweep-tests/embed-rules/<id>.md`.
- `result-summary <rc> <stdout-file>` also answers without a runtime (below).
- An unknown op, or an op without a file, returns 2.
- Any other op returns 69 when the runtime (the launch command's first word) is not on PATH.
- An analyzer that fails returns 1.

## skip-reason and syntax-check

| id | `skip-reason` word | `syntax-check` parser |
|---|---|---|
| `pester` | `nested-describe`: a `Describe` inside another | `[System.Management.Automation.Language.Parser]::ParseFile`, no errors |
| `pytest` | `parametrized-case`: a test decorated with `parametrize` | `ast.parse` |
| `js` | `custom-runner`: no `node:test` require or import | `node --check` |

`syntax-check` always launches the analyzer, never the pester cache, because it judges a temp rewrite rather than the file the cache holds.

## result-summary

The class comes from the wrapper's exit code, as in run-all: 0 `pass`, 77 `skip`, anything else `fail`.
The counts come from the wrapper's stdout; with no count line both stay empty and the verifier reports `count-unavailable`.

| id | Counted line |
|---|---|
| `pester` | the last `Tests Passed: <n>, Failed: <m>` line |
| `pytest` | the last `-q` summary line (`<n> passed, <m> failed in <t>s`); `error` counts as failed, a missing word as 0 |
| `js` | `PASS: <name>` / `FAIL: <name>` lines of `node-reporter.mjs` |

## self-impl

`self-impl` prints `line\tkind\tdetail`, one row per finding, with the same two kinds in every language:

- `counter-init`: a hand-made pass/fail counter set to 0 (bash `PASS=0`; pester a `$script:` or top-level `$PASS`/`$FAIL`/`$Passed`/`$Failed`; pytest a module-level `PASS`/`FAIL`/`passed`/`failed`; js a top-level `let`/`var` of the same names). Each analyzer keeps its pattern in one constant.
- `harness-redef`: a top-level definition whose name the entry's helper library defines, read with the same parser (pester `function` names, pytest top-level `def` names, js `module.exports` keys).

The helper library path comes from the registry entry the part belongs to, under the checkout's root, so a temp copy under any name finds it.
A self-implementation under a different name (for example `ok_count = 0`, or a helper copied under a new name) is not detected; that is an accepted limit.
Callers reach the op through `tsi_report` (`bin/lib/test-self-impl-window.sh`): rc 3 means the language has no `caseEmbedRules`.

## Case-order contract

The `deps` rows are keyed by case index, so the analyzer must enumerate the cases in the reader's order.
Two layers keep that true:

1. Structure: the reader and the analyzer call one shared enumeration (table above).
2. Check: the analyzer's `deps` output starts with one `ORDER\t<idx>\t<begin>\t<end>` line per case. The part compares them with `TRP_CASE_BEGIN_LINES` / `TRP_CASE_END_LINES` and strips them. On any disagreement it prints `case-embed: order mismatch` on stderr and returns 1.

`crr_read` then holds the rows to a contract: exactly one `<idx>\t<csv>` row per case, each index `0..n-1` once, no CR, no empty csv element.
A failed op (other than 69) or a row that breaks the contract is `FILE uncertain` with reason `case-embed` and no `CASE` lines, never a `?` deps column that would read as "no dependencies".

## case-count

`case-count <file>` prints the number of case units at top level: pytest top-level tests, pester top-level `Describe` blocks — the same units the test case reader marks, counted with or without markers.
A file with no unit returns 1.
For bash and js the unit is the marker itself, so a file that is not conforming has no countable unit outside its markers: their `case-count` always returns 1 with no output.
`bin/lib/test-language-match/case-addition.sh` compares the counts of `HEAD` and the working copy when either one is not conforming, and compares code lines when either count fails, so a case added there is still caught. When this comparison is skipped: [case-marker-gate.md](../case-marker-gate.md).

`crr_read` calls the op inside `$(...)`, and that subshell sees the reader's globals.
A direct call with no case globals runs the test case reader into locals first, so the check still holds.

## Pester cache (`CASE_EMBED_CACHE_DIR`)

A pwsh start is slow, so the pester part can answer every op from one analyzer run:

- Set `CASE_EMBED_CACHE_DIR` to a directory the entry point created with `mktemp -d` and removes with `trap`. Never use a fixed name in shared temp space.
- The first op runs the analyzer's `all` once and writes `pester-case-embed.cache`. Its first line is `KEY\t<abs path>\t<cksum>`; then come `OP\t<op>` blocks (`OP\t<op>\tfail` marks an op that failed).
- Later ops whose key matches read the cache; a new key rewrites it. Only the last file is kept.
- Without the variable, every op launches the analyzer. The answers are the same; only the speed differs.

pytest and js start fast and launch once per op.
