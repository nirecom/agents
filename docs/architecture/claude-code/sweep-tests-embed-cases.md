# sweep-tests --embed-cases

`case_begin` / `case_end` markers let retire remove one case instead of a whole file, but only tests written after the marker gate carry them.
`--embed-cases` migrates the older marker-less bash tests band by band: the tool picks the files, a subagent rewrites a copy, and the tool decides mechanically whether the rewrite may replace the original.
The rewrite is the only judgment an LLM makes; selection, verification and replacement are deterministic, and a file that fails twice is recorded and left alone.

This document is the single owner of the protocol: worklist columns, item states, gate blocks, `report.txt`, `failure.txt`, `embed-retry.tsv`, and the verifier's arguments and output.
The skill procedure (`skills/sweep-tests/SKILL.md` STE-4) and the code headers point here.

## Files

| Path | Role |
|---|---|
| `bin/audit-tests.sh`, `bin/audit-tests-common.sh` | Entrypoints. Both hand off to `tec_dispatch` before their own argument loop; the output is the same from either |
| `bin/lib/test-embed-cases.sh` | Argument parsing, exclusivity rules, stage dispatch |
| `bin/lib/test-embed-cases/select.sh` | Candidates and skip reasons |
| `bin/lib/test-embed-cases/order.sh` | `frequency` / `priority` ordering |
| `bin/lib/test-embed-cases/stage-plan.sh` | Stage 1: band and workdir |
| `bin/lib/test-embed-cases/stage-apply.sh` | Stage 3: validation, verification, replacement, report |
| `bin/lib/test-embed-cases/codex-band-check.sh` | One codex call over the band's verified rewrites |
| `bin/lib/test-embed-cases/retry-record.sh` | `embed-retry.tsv` |
| `bin/verify-case-embed.sh` (+ `bin/verify-case-embed/`) | The five-check verifier |
| `bin/lib/case-record-reader.sh` | `crr_read`, the case records every check reads |
| registry `caseEmbedRules` part | Per-language answers; contract in [test-language-registry.md](test-language-registry.md) |
| `skills/sweep-tests/embed-rules/<lang>.md` | The rewrite rules the subagent follows (the part's `rules-doc`) |

## Options

`--embed-cases [--band-size N] [--order frequency|priority] [--dry-run] [--fix-headers] [--apply] [--format text]`, and the skill-only `--embed-apply <workdir>`.

| Combination | Result |
|---|---|
| `--embed-cases` + `--fix-headers` | Accepted; `NOTE: --fix-headers is subsumed by --embed-cases (selected files only)` on stderr |
| `--embed-cases` + `--dup-groups`, `--stale-months`, `--offline`, `--format json` | exit 2 |
| `--band-size` / `--order` without `--embed-cases` | exit 2 |
| `--order` other than `frequency` / `priority`; an invalid band size (`sweep_band_count`) | exit 2 |
| `--embed-apply` + any other stage flag | exit 2 |
| An unrecognized option | exit 2 |

## Selection (stage 1)

Candidates are the case-marker-language files directly in `tests/<cat>/` for the six categories, so `tests/_archive/` and suite part files in subdirectories never appear.
Each candidate gets the first matching skip reason, in this order; a file with none is in the band.

| Reason | When |
|---|---|
| `already-conforming` | `crr_read` state is `conforming` |
| `no-embed-rules` | the language's `caseEmbedRules` is null |
| `lang-skip:<word>` | the part's `skip-reason` op answered (bash: `narrow-harness`) |
| `retry-capped` | an `embed-retry.tsv` row matches (below) |
| `no-tests-header` | no `# Tests:` header, or one with no token |
| `header-unfixable:multi-paren` / `header-unfixable:has-ac` | the header cannot be auto-fixed (the `_fix_headers_apply` `SKIP_APPLY_*` conditions) |

So files in state `none`, `malformed` and `uncertain` are rewritten. Resuming needs no bookmark: a migrated file is `already-conforming` on the next run, and the next band comes to the front by itself.

Order (`--order`, default `frequency`):

- `frequency`: how many recent run-all ledger segments ran the test (segments that ran half the corpus or more count as full runs and are ignored), then git churn of the last 1000 non-merge commits (a commit counts when a changed path's stem appears in the test's name), then path.
- `priority`: a header naming a deleted path first, then a single-token header, then the rest; path within each.

The band is the first N (`--band-size`, default 5, validated by `sweep_band_count`) non-skipped files of that order. Only that one band is processed per run.

Output: `BAND\t<idx>\t<relpath>\t<metric>` per band file (`runs=<n>,churn=<n>` or `priority=<n>`) and `SKIP\t<relpath>\t<reason>` per skipped candidate. `--dry-run` stops there and writes nothing.

## Workdir

`<PLANS_DIR>/sweep-tests-embed/<UTC timestamp>-<pid>.<n>/`, where `<PLANS_DIR>` is `bin/workflow-plans-dir` (honours `WORKFLOW_PLANS_DIR`). It lies inside the early-gate write allowlist, so subagents can write there.

| Path | Content |
|---|---|
| `worklist.tsv` | One row per item, 9 tab-separated columns (below) |
| `items/<idx>/input/<basename>` | Copy of the original with the `# Tests:` header fixed by `_fix_headers_apply <relpath> <copy>` |
| `items/<idx>/output/` | Where the subagent writes `<basename>` |
| `items/<idx>/report.txt` | Optional subagent report: `MERGED_TARGET\t<case-name>\t<kept>\t<dropped,...>` lines |
| `items/<idx>/backup/` | The verifier's `--backup-dir`; a file left here means a verification was interrupted |
| `items/<idx>/failure.txt` | `reason: <reason>` plus the verifier or codex output of the last failed try |
| `items/<idx>/verify.out`, `verify.err` | The last verifier run |

`worklist.tsv` columns: `idx relpath input output rules_doc header_status orig_hash state attempts`.
`header_status` is `applied` or `clean`; `orig_hash` is the original's `git hash-object` at stage 1; `attempts` starts at 0.

Stage 1 prints `EMBED_WORKDIR: <path>` and the gate block:

```
<<<EMBED-GATE-STE4
ITEM\t<idx>\t<input>\t<output>\t<rules_doc>\t<report>
>>>
```

`input`, `output` and `report` are absolute paths; `rules_doc` is repo-relative.

## Stage 2 (skill)

One subagent per `ITEM` row reads `input` and `rules_doc` and writes `output/<basename>`. It writes nothing else except `report.txt`, used only when an inseparable multi-target block is folded into one main target (`MERGED_TARGET`).
A retry row adds `failure.txt`, which the subagent reads to fix what failed.

## Stage 3: `--embed-apply <workdir>`

1. Validate, fail-closed (exit 2 before any write): the workdir's real path is under `<PLANS_DIR>/sweep-tests-embed/`, `worklist.tsv` has 9 columns per row, every relpath is relative, has no `..` and is a current candidate, every input / output stays inside `items/<idx>/`, `items/<idx>/` resolves physically to that directory of the workdir, no file stage 3 reads or writes there (`backup/`, `failure.txt`, `verify.out` / `verify.err`, `report.txt`, input, output) and no `worklist.tsv` / `worklist.tsv.tmp` is a symlink, and `rules_doc` equals the language part's `rules-doc` answer (it is echoed in `RETRY` rows).
2. Put back any leftover `items/<idx>/backup/<basename>` to its relpath, then delete it — only when its `git hash-object` equals `orig_hash`. Any other leftover is not restored and stops the run (exit 2), so a planted file never reaches the relpath past the gates.
3. Work only on `pending` and `reverted` items; the others are reported as they were.
4. An original whose hash differs from `orig_hash` becomes `stale` (not a try).
5. Run the verifier on the output (missing output: a failed try, reason `no-output`).
6. Send the verified items to one codex call (`CASE_BOUNDARY: <relpath>: OK|NG <reason>` per file; a missing line or more than one line for a file is NG, and a line naming a file outside the band makes every item of the band NG, since one AFTER file could forge lines for another). Codex unavailable or failed: every verified item becomes `tool-failed` (not a try) and `CODEX_UNAVAILABLE` is printed.
7. Replace each original that passed both, atomically (temp file in the same directory, `mv`, mode kept). Failed originals are never touched.

Item states:

| State | Meaning | Reprocessed in the same workdir |
|---|---|---|
| `pending` | not tried yet | yes |
| `reverted` | one failed try | yes (the retry) |
| `applied` | replaced | no |
| `capped` | two failed tries; recorded in `embed-retry.tsv` | no |
| `stale` | the original changed after stage 1 | no |
| `tool-failed` | codex was unavailable | no; the file is picked again by the next run |

Report lines: `APPLIED\t<relpath>`, `REVERTED\t<relpath>\t<reason>` (`verify:CHECK<n>`, `codex:<reason>`, `no-output`), `CAPPED\t<relpath>`, `STALE\t<relpath>`, `TOOL_FAILED\t<relpath>`, `CODEX_UNAVAILABLE`, `MERGED_TARGET\t<relpath>\t<case-name>\t<kept>\t<dropped>` (copied from `report.txt`), `EXEMPT\t<relpath>\t<token>`.
A second `--embed-apply` on the same workdir re-reports `APPLIED` / `CAPPED` items and never turns them `STALE`.

When an item became `reverted`, the retry block follows:

```
<<<EMBED-RETRY-STE4
RETRY\t<idx>\t<input>\t<output>\t<rules_doc>\t<report>\t<failure.txt>
>>>
```

The skill dispatches once more for those rows and reruns `--embed-apply` on the same workdir, so both tries happen within one run and the try count lives only in the worklist.

Accepted risks:

- Check 2 executes the LLM-authored after-file with the user's privileges before the codex gate sees it; comparing real runs is the check, so the order stays (single local admin, the subagent is the only author).
- The codex call sends the full before / after contents of every band file to the external codex service without a secret scan, the same exposure as the other codex review paths.

## embed-retry.tsv

`${SWEEP_TESTS_STATE_DIR:-$HOME/.claude/sweep-tests}/embed-retry.tsv`, written only by stage 3 when an item is capped, never by a subagent.
Row: `<orig_hash>\t<relpath>\t<attempts>\t<reason>`; the reason ends in ` (repo <toplevel>)`.

A row caps a candidate when its hash equals the file's current `git hash-object`, its relpath equals the file's, and its repo is the current one (a row without the ` (repo …)` suffix matches any repo).
Editing the file changes its hash, so the record expires by itself. The relpath and repo keep identical boilerplate in another file or another repository from being capped with it.

## Verifier: `bin/verify-case-embed.sh`

`verify-case-embed.sh <after-file> --relpath <repo-relpath> [--before <before-file>] [--merged-report <report.txt>] [--backup-dir <dir>]`, run from the judged repo.
The after-file stands in at `<relpath>` while it is judged; the original waits in `--backup-dir` (default: a fresh temp directory named on stderr) and is put back on exit, INT and TERM. A non-empty or symlinked backup dir at start is exit 2, so a pending restore is never overwritten and the backup is never written through a link. Stage 3 always passes `items/<idx>/backup/`.

Output: `CHECK<n>\t<PASS|FAIL|SKIP>\t<detail>` per check and `EXEMPT\t<token>\t<case-name>` per exempted token. Exit 0 = no FAIL, 1 = a FAIL, 2 = usage error, unusable library, or a non-empty or symlinked backup dir.
Without `--before` only checks 1, 3, 4 and 5 run.

| # | Passes when |
|---|---|
| 1 | `crr_read` state is `conforming`, and with 2+ header paths `bin/check-case-markers.sh` reports no HIGH |
| 2 | before and after give the same result class (`result-summary`), and the same pass / fail counts when both have them (else detail `count-unavailable`); a not-launched or timed-out run is `FAIL inconclusive` |
| 3 | the part's `leftover-defs` is empty (SKIP without the op) |
| 4 | header tokens minus exemptions ⊆ case targets, and case targets ⊆ header tokens. Tokens naming deleted paths stay in the header set |
| 5 | the language's `helperLibrary.sourceRegex` matches and `self-impl` is empty (SKIP `no-helper-library` when the language has none) |

**MERGED_TARGET exemption (check 4).** A token is exempt only when a `MERGED_TARGET` row lists it as dropped, it is in the header, it is no case's target, and the row's case exists with target equal to `kept`, which is in the header. Any row failing that is itself a check 4 FAIL (`bad-merge-report`).
