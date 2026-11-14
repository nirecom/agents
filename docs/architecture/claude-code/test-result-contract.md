# Test Result Contract

Every test language reports its result the same way, so `tests/run-all.sh`, `bin/run-tests-baseline`, `bin/mutation-probe.sh` and the `/run-tests` workflow read one vocabulary instead of one per runner (#2501).
Before #2501 each runner spoke its own dialect: Pester's exit code was a failure count (256 failures read as a pass), a missing runtime read as SKIP and so as success, a hung Pester or pytest file differed between GNU `timeout` (124) and the perl fallback (142), and only bash tests said which case failed.

The contract has three layers, each with one owner:

| Layer | Owner | Answers |
|---|---|---|
| Unit state | `bin/lib/run-all-classify.sh` (`rac_classify`) | What happened to one test file (PASS / FAIL / SKIP / UNRUNNABLE / TIMEOUT / UNSUPPORTED) |
| Case records | language wrappers, `tests/lib/harness.sh` | What happened to each case inside it (`cases.tsv`) |
| Report | `bin/lib/run-all-report.sh` | The lines a reader parses (file-level, case-level, `Results:`, `RUN_CONTRACT:`) |

How a test is launched (registry `launch` block, placeholders, wrappers): [test-language-registry.md](test-language-registry.md) §Launch.
Scheduling, lanes and the deadline: [test-runner-parallelism.md](test-runner-parallelism.md).

## Unit states and exit codes

A test file (or a language wrapper standing in for its runner) exits with one of these codes; `rac_classify` turns the code into a state, in this order:

| Exit code | Condition | State | Counted as |
|---|---|---|---|
| 78 | not launched (no supported entry, no suite root) | UNSUPPORTED | nothing |
| 79 | result dir holds an `unrunnable` marker whose whole content is exactly one valid label | UNRUNNABLE | `UNRUNNABLE`, not `EXECUTED` |
| 79 | no marker, or a marker that is not a valid label | FAIL | `FAIL` |
| any | result dir holds `prepare-failed`: `launch.prepare` failed, so the command never ran (a 0 / 77 becomes 1) | FAIL | `FAIL` |
| any | result dir holds `timed-out`, written only by `timed_exec` when its own timer fired (the rc is not read) | TIMEOUT (rc normalized to 124) | `TIMEOUT`, inside `FAIL` |
| 2 | not launched: the launcher's own setup failed (launcher libraries missing, unreadable registry table, no temporary result dir) | FAIL | `FAIL` |
| 0, 77 | `cases.tsv` holds a resolved FAIL record, or an XPASS record the bash harness resolved (its seq has an `OPEN` line; `tests/lib/xfail.sh` counts XPASS as a failure, and the harness never forces a non-zero exit). A wrapper's XPASS (pytest, non-strict) stays a pass | FAIL (rc 1) | `FAIL` |
| 0 | `cases.tsv` holds resolved records other than `OPEN`, and all are SKIP (an `UNOBSERVED` record keeps it PASS) | SKIP (rc 77) | `SKIP` |
| 0 | otherwise | PASS | `PASS` |
| 77 | otherwise | SKIP | `SKIP` |
| other | — | FAIL | `FAIL` |

A **file result** is the triple (verdict, termination, duration) the duration ledger records per test file (#2932); `run_all_dur_file_result` in `bin/lib/run-all-durations.sh` maps the unit state by this table:

| Unit state | Verdict | Termination |
|---|---|---|
| PASS / FAIL / SKIP | same name | `completed` |
| TIMEOUT | `-` | `timeout` |
| UNRUNNABLE | `-` | `unrunnable` |
| UNSUPPORTED | `-` | `unsupported` |
| anything else | `?` | `?` |

How `runContract.hits` enters this triple is decided in #2727.

- **Valid label**: depends on who could have written the marker. Before the launch (the launcher's own marker): the entry's `launch.requires` (`pwsh`, `uv`, `node`), or the executable its `launch.prepare` or `launch.command` starts with. After the launch (a wrapper's marker): only the entry's minimum-version label `<runtime>>=<version>` (`Pester>=5.0`, `pytest>=7.0`, `node>=20.0`). Test code runs only after the launch and a wrapper hides the result directory from it, so a test cannot turn its failure into "runtime missing" — a bash test that writes `bash` and exits 79 stays a FAIL.
- **Effective timeout**: the smaller of the entry's `launch.timeoutSeconds` and a positive-integer `RUN_ALL_TIMEOUT_SECONDS`; either alone when the other is absent (`rac_effective_timeout`). Empty means no per-file kill. Without the `timed-out` marker, 124 / 137 / 142 / 143 are an ordinary FAIL — a test that exits 124 by itself is not a TIMEOUT, whatever the elapsed time.
- `bash` has `timeoutSeconds: null`: in a normal run a single hung bash test is stopped only by the suite `--deadline` (a per-test bash limit is deferred, #2557); only a caller that sets `RUN_ALL_TIMEOUT_SECONDS`, such as `bin/run-tests-baseline`, gives it a file-level limit.
- The launcher writes the `unrunnable` marker itself when `launch.requires`, or the executable `launch.prepare` or `launch.command` starts with, is not on PATH (out line `UNRUNNABLE: missing <tool>`); a language wrapper writes it when the runtime is absent or below `launch.minVersion`. A runtime that is installed at a sufficient version but fails to import (a broken package or dependency) is a FAIL, not UNRUNNABLE.
- pytest availability through uv is ensured at install time (the agents installers pre-fetch pytest into uv's cache), so a uv that still cannot supply it is the test's own FAIL: the pytest wrapper writes the marker only for a version below the minimum, and any `import pytest` failure, absent package included, exits 1 with no marker.

Exit codes of the language wrappers (`bin/lib/test-wrappers/`), independent of the runner's own convention:

| Exit | Meaning |
|---|---|
| 0 | at least one case passed, none failed |
| 1 | any failure (any count — Pester's failure-count exit is never passed through) |
| 77 | no case ran, or every case was skipped |
| 79 | runtime absent (Pester) or below the minimum version, with the `unrunnable` marker |

A bash test keeps the harness convention (0 / 77 / other); `exit 79` from a bash test is always a FAIL — its entry has no minimum-version label, so no marker it writes is valid.

## Result directory and case records

The launcher gives each launched file a result directory and passes it to the child only, as `RUN_ALL_RESULT_DIR` (native path form) and `RUN_ALL_RESULT_OWNER` (the script path as launched: a relative path starting with `-` gains a `./` prefix).
The consumer of the variables (a wrapper, or `tests/lib/harness.sh`) reads them and removes both before any test code runs, so a nested `tests/run-all.sh` or a child script never writes into its parent's directory.
`harness.sh` writes only when `RUN_ALL_RESULT_OWNER` equals its own `$0`.

| File | Writer | Content |
|---|---|---|
| `cases.tsv` | wrapper or harness | one record per case |
| `unrunnable` | launcher or wrapper | one label line |
| `prepare-failed` | launcher, when `launch.prepare` fails (a failed prepare, of a file or a suite unit, also sets `RUN_ALL_EXEC_LAUNCHED=0`) | empty |
| `timed-out` | `timed_exec`, only when its timer fired | empty |
| `testResults.xml` | Pester wrapper | NUnit XML for CI (#2483) |

`tests/run-all.sh` uses `<workdir>/<i>.res/`; a caller passing no directory gets a temporary one that is removed after classification.

A `cases.tsv` record is `<seq>\t<STATE>\t<case>\t<target>`; tabs and newlines inside a field become spaces.

| State | Source |
|---|---|
| `PASS`, `FAIL`, `SKIP` | all languages |
| `XFAIL`, `XPASS` | bash (`tests/lib/xfail.sh`), pytest (`wasxfail`) |
| `OPEN`, `UNOBSERVED` | bash harness only: a case begun but never ended, or ended with no assertion |

How each language fills it:

- **bash**: `case_begin` writes an `OPEN` record and snapshots the counters; `case_end` (or the next `case_begin`) resolves it by priority FAIL, XPASS, XFAIL, PASS, SKIP, else UNOBSERVED. `fail` inside an open case writes its FAIL record at once, so a file that exits 0 or 77 before `case_end` still reports the failure.
- **Pester**: `Passed`→PASS, `Failed`→FAIL, `Skipped`/`Inconclusive`→SKIP, `NotRun` omitted; a failed container or block adds a synthetic `(container)` FAIL. `exit 77` inside an `It` or `BeforeAll` is a failure; skip with `-Skip` or `Set-ItResult -Skipped`.
- **pytest**: call, setup, teardown and collection reports, one seq per test, so a teardown failure after a passing call replaces that test's PASS with FAIL; pytest's "no tests collected" (5) is 77 only when pytest itself ended the session with that status and wrote no record — a test that exits the process with 5 leaves no such proof and is a FAIL.
- **node**: every `.js` file runs exactly once, without `--test`, preloaded with `node-guard.cjs` and with `node-reporter.mjs` writing to a scratch directory the wrapper owns (nested names joined with ` > `, skip/todo → SKIP (a failing todo too, as node exits 0 for it), suites and the file-level event omitted). Which exit table applies is read from what the run did, never from the source text: a run that loaded `node:test` by any route (the guard's marker, from `process.moduleLoadList`) or left a record is a node:test run — well-formed records are copied into `cases.tsv` (one malformed record fails the file), all-skipped or no test is 77, and a nonzero exit with no FAIL record adds a synthetic `(file)` FAIL. Any other run is a plain script: no case records, exit 0 / 77 kept, anything else 1. A literal import in code that never runs therefore leaves the file a plain script.

### fail-details.tsv (#2956)

`cases.tsv` carries no failure text, so each language writer adds `fail-details.tsv` to the result directory: one record `<seq>\t<case>\t<text>` per failure call, in call order. `<seq>` and `<case>` match the `cases.tsv` record; a failure outside any case is seq `0`, case `-`. The writers are the bash harness (`fail`), pytest, node and Pester, and all fold `<text>` by one rule, pinned by the fixture `tests/fixtures/fail-detail-fold.tsv`:

- CRLF and lone CR become LF; trailing spaces and tabs of each line are removed; trailing blank lines are removed; leading whitespace is kept.
- `\` becomes `\\`, a tab becomes `\t`, a newline becomes `\n`, so the record stays one line.
- Text longer than 8192 characters after folding is cut there and ends with `\n[cut]`.

For the bash harness `<text>` is what `fail` prints after `FAIL: ` — `$1` for a one-argument call, `$1 — $2` for a two-argument call — so the `fail` name is part of the line. A case still `OPEN` at the end (cut off by an abnormal exit, with no `fail` call) counts in the comparison as an empty failure line of that case; it is never listed as seen.

The comparison unit of `bin/run-tests-baseline` is this folded text, compared as a multiset per case: two failures of one case with the same text are two lines, so one more on the branch than on the base is a new line, and a branch line absent from the base makes the case `new-case-failure-on-branch`.

Two markers let a test report a large or unstable set compactly: `[count=N]` and `[list total=M: a | b]` (`\`, `|` and `]` inside an item are backslash-escaped). A branch line that differs from the base line only by marks that went down is the same failure: each count is at most the base's, and each list holds all its M items on both sides and is a sub-multiset of the base's. A list with fewer items than M, or a line ending in the fold's `\n[cut]`, is not comparable and counts as a new line (fail-closed). A line pair without any marker is compared as plain text.

## Report lines

`rar_unit` prints, per unit in submission order, one file-level result line and then its case-level result lines.

| Line | When |
|---|---|
| `PASS: <file>` / `SKIP: <file>` | unit PASS / SKIP |
| `FAIL: <file> (exit <rc>)` | unit FAIL; the SSOT for `hooks/workflow-run-tests/failing-list.js` |
| `FAIL: <file> (exit 124)` + `TIMEOUT: <file> (<N>s)` | unit TIMEOUT |
| `UNRUNNABLE: <file> (missing: <label>)` | unit UNRUNNABLE; no case lines, launcher note dropped |
| `UNSUPPORTED: <file> (language: <id>; not run)` | not launched; listed again at the end |
| `<STATE> <file>::<case> target=<target>` | case-level result line, one per resolved record |

Case-level rules:

- Only `PASS FAIL SKIP XFAIL XPASS` are printed. `OPEN` becomes `FAIL` when the unit failed or timed out, and is dropped otherwise; `UNOBSERVED` is dropped.
- A unit with no records prints one `<STATE> <file>::(file) target=<file>` line; a FAIL unit with no FAIL record adds a `(file)` FAIL line, so a failed file always names at least one failing case.
- `failing-list.js` reads only file-level `FAIL:` lines; its pattern never matches a case-level, `TIMEOUT:` or `UNRUNNABLE:` line.

The tail (`rar_tail`):

```
UNSUPPORTED: <file> (language: <id>; not run)
Missing runtimes: Pester>=5.0 (2 files), pwsh (1 file)
HIT: <detail>
Results: PASS=p  FAIL=f  SKIP=s  UNRUNNABLE=u  TIMEOUT=t  HITS=h
RUN_CONTRACT: PASS=p FAIL=f SKIP=s EXECUTED=p+f+s UNRUNNABLE=u TIMEOUT=t HITS=h
```

`Missing runtimes:` appears only when `UNRUNNABLE > 0`; a unit a late hit turned into a FAIL leaves it.
`HIT:` lines and ` HITS=h` appear only when `h > 0`: guard, decoy or worktree-change hits no test could be named for ([test-command-guard.md](test-command-guard.md) "Install points and the hit report"). Absent `HITS=` and `HITS=0` mean the same. A run with `HITS > 0` exits 1 and never completes `run_tests`; `bin/run-tests-baseline` refuses to classify it (exit 6, `BASELINE_HITS: count=N` then the `HIT:` lines). `TIMEOUT` is a subset of `FAIL`; `UNRUNNABLE` is outside `EXECUTED`. `tests/run-all.sh` exits 1 when `FAIL > 0`; an UNRUNNABLE-only run exits 0, and the readers below are what keep it from counting as green.

## Neutralization of child output

A test's stdout and stderr are replayed before its own result lines, so a test printing a result-shaped line could forge one.
`rar_neutralize` (shell builtins, no fork per line) prefixes `[run-all:neutralized] ` to every child line that, after leading blanks, starts with `RUN_CONTRACT:`, `UNRUNNABLE:`, `TIMEOUT:`, `Missing runtimes:`, `Results:`, `FAIL: … (exit N)`, or `<STATE> <anything>::` for a case state (the file path may hold spaces).
Only lines printed by `rar_unit` / `rar_tail` reach readers unprefixed; readers anchor their patterns at line start.

## Readers and `run_outcome=unrunnable`

| Reader | Reads |
|---|---|
| `hooks/workflow-run-tests.js` | `RUN_CONTRACT:` through `hooks/lib/run-contract.js`, shared with the worker and the renderer. The 6-field line is shape `current`; a 4-field line from an older run-all is shape `legacy`, whose `UNRUNNABLE` / `TIMEOUT` read as null (never 0), so it never completes `run_tests` (demotion `contract-legacy-shape`: rebase onto main and re-run). Anything else after the fields, such as a cut-off `UNRUNNABLE=1 TIMEOUT=`, makes the line no contract; so does a count too long to be an exact integer. A contract is valid only in shape `current` with `UNRUNNABLE=0` |
| `hooks/workflow-run-tests/outcome.js` | trusted contract with `FAIL=0` and `UNRUNNABLE>0` → `run_outcome=unrunnable`; so does an attributed, unvetoed contract with `EXECUTED=0`, `FAIL=0` and `UNRUNNABLE>0`, on the direct route as on the worker route |
| `bin/worker-dispatch/workers/test-runner.js` | exit 0 with `UNRUNNABLE>0` → status `unrunnable`; the summary opens with `Missing test files: N; ` when N column-0 `UNRUNNABLE: <path> (missing: test file)` lines were printed (`hooks/lib/missing-test-files.js`), then the last `Missing runtimes:` line, so the renderer's length cap cuts the totals before the remedy; case PASS/SKIP/XFAIL lines are dropped from the log tail |
| `bin/run-tests-baseline` | launcher state: UNRUNNABLE at base → `undetermined` (`unrunnable-at-base`); launcher setup failure (rc 2, not launched) → `undetermined` (`exec-setup-failed`); FAIL 137/143 → ambiguous; other FAIL (124/142 included) → compared case by case with the branch (table 1 under "Baseline acceptance of failing tests"; the disposition of each result: "Baseline acceptance of failing tests"). The hook records the failing run's `unrunnable_count` beside `failing_tests`, and the baseline completes `run_tests` only when that count is exactly 0: a selected test that never ran is not covered by any classification |
| `bin/mutation-probe.sh` | `RUN_ALL_EXEC_STATE` SKIP / UNRUNNABLE / UNSUPPORTED → `NOT RUN:`, never a killed mutant |

Workflow effect of `unrunnable`:

- The `run_tests` step is not completed: demotion reason `contract-unrunnable` (checked before the worker-status veto) and the message "Selected tests marked UNRUNNABLE: N. Install the runtimes listed on the `Missing runtimes:` output line and run again. An `UNRUNNABLE: <path> (missing: test file)` line is a wrong test path and cannot be accepted: fix the path and run again. If a runtime cannot be installed, accept this run only with `echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>"`."
- `/run-tests` (RNT-9) shows the `Missing runtimes:` line, asks the user to install the runtime, and never runs the baseline. Recovery is a rerun with `UNRUNNABLE=0`, or the accept below.
- A run with a missing test file (`UNRUNNABLE: <path> (missing: test file)`, or a worker summary opening with `Missing test files: N; `) is a wrong selection: fix the test path and re-run; the accept below refuses it.
- It is not a code defect: `unrunnable` is not a failing outcome for `write_code` resume or for the baseline evidence, so it triggers no fix cascade.

**Dispatch settlement** is the check, run on every Bash call, of whether the session's latest test-runner dispatch has had its outcome ingested: `settled` (ingested, or no dispatch) or `unsettled` (a `.dispatched` marker without its `.ingested` marker); while unsettled, a stale `run_tests` result is demoted to `pending` on non-test calls.
**`outcome_source`** is the `run_tests` state field holding the stem, `payload_sha256` and `outcome_sha256` of the worker outcome file the state was last written from; the baseline evidence checks it before accepting a failing baseline as pre-existing.

## Accepting UNRUNNABLE

When the runtime cannot be installed on this host, `echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>"` completes `run_tests` without a green run, only for a run whose every UNRUNNABLE test lacks a runtime. It exists so a missing runtime cannot block a session forever; it is never silent:

- `settings.json` lists it under `permissions.ask` (never `allow`), so the user confirms every use.
- `hooks/workflow-mark/run-tests-accept-handler.js` accepts only a `run_tests` that is pending with `run_outcome=unrunnable`, `unrunnable_count>0` and no failed run — that is, a current-shape contract with `FAIL=0`. It reads the hook's annotations, never stdout. `unrunnable_missing_files` — the count of missing test files the hook records on a `contract-unrunnable` run (run-all: the column-0 lines; worker: the summary token) — of 1 or more is rejected with "fix the test path(s) and re-run"; a state without the key reads as 0. A completed step, `FAIL>0`, no contract, a legacy 4-field contract, or a reason under 3 non-blank characters is rejected with the state unchanged; a reason holding `( ) ; | & >` or a backtick is a malformed sentinel (advisory only).
- An accept records `completion_basis=unrunnable-accepted` and `unrunnable_accept_reason`, and keeps `unrunnable_count`, `unrunnable_runtimes`, `unrunnable_missing_files` and `run_outcome=unrunnable`.
- The Final Report (`bin/render-final-report.js`, under Merged PR) and the PR body (the `commit-push` worker's `prBody` appends it unless the template already holds it) each carry one line with the count, the missing runtimes and the reason, from `hooks/lib/run-tests-completion-note.js`.
- The next run of the hook clears `completion_basis` and `unrunnable_accept_reason`, so an accept never outlives the run it accepted.

## Baseline acceptance of failing tests

`bin/run-tests-baseline` completes a failing `run_tests` when every failure is either proven pre-existing at the merge base or has a cause on a fixed allow-list. There is no user grant: the #2517 design (a `permissions.ask` sentinel the user confirmed on every use) is withdrawn (#2688), because the CLI's mechanical verdict was what decided and no grant was ever refused. What the machine cannot prove reaches a human at release through the `Unverified tests:` line instead.

- **Stages**, in order, each classifying only the tests the earlier ones left open: failing list, then a solo re-run on the branch (the budget minus a reserve kept for the base; result cached per input version in a `branch.v2` segment, so a re-run skips finished tests; a timeout the budget did not shorten is cached too, as `timeout-after-<N>s` with N = REQUESTED_TEST_TIMEOUT of the test file, #3015), then the rename source (a test renamed on the branch is looked up in the ledger and run at base under its old path), then the ledger, then the base run.
- **Case comparison (#2956)**: a test failing on both sides counts as pre-existing only when the branch shows no failure line the base did not (`bin/lib/run-tests-baseline-compare.sh` and `.js`). Table 1, first match wins:

  | Condition | Class | Detail |
  |---|---|---|
  | the comparer failed | `undetermined` | `compare-failed` |
  | the test file changed since the base (or git cannot tell) | `file-verdict-preexisting` | `test-file-changed` |
  | no new line | `preexisting` | the base detail (`fails-at-base-exit-N`, `ledger-same-base`, `inherited-from-<b1>`) |
  | neither side wrote case records | `file-verdict-preexisting` | `no-case-records` |
  | records on one side only | `new-case-failure-on-branch` | `case-records-missing-on-branch` / `-at-base` |
  | new lines | `new-case-failure-on-branch` | `<base detail>-new-lines` |

  Table 2 (the branch solo run, `bin/lib/run-tests-baseline-branch.sh`): a pass is flaky / passes-alone; kill 137/143 is `undetermined` `ambiguous-exit-N`; a failure whose only hits are command guard hits claimed for it is that test's own failure (#2669) and is compared like any other; a root decoy hit, a worktree change or UNRUNNABLE leaves no branch records, so the base still runs and its own decoy / unrunnable / timeout row stands, and any other base result is `new-case-failure-on-branch` `case-records-missing-on-branch`; rc 124/142 is compared as an interrupted run (a base case it never reached is not a fix); a timeout the budget did not shorten leaves no branch records and goes to the base: base pass is `broken`, a base timeout the budget did not shorten is `timeout-at-base` (no `-via-rename:` suffix even through a rename; the rename is told on stderr), a base failure is `case-records-missing-on-branch`; not run, a timeout the budget shortened, and a timeout under an explicit `--per-test-timeout` below the derived one are `budget-exhausted`; skip and unsupported compare as no branch records.
- **Non-converging range (#3015)**: a timeout is never recorded when the explicit `--per-test-timeout` is below the derived value, or when REQUESTED_TEST_TIMEOUT exceeds what the branch stage can apply (a test file measured above about 200 s); it stays `budget-exhausted` (exit 8) and stderr names the way out in one `run-tests-baseline: timeout not recorded: <t> requested <R>s; <reason>` line (drop or raise the explicit value; shorten or split the test).
- **Ledger v3**: a row is `v3 <sha> <host> <rel> <result> <fp|-> <epoch> <attr>`; a fail row's `<fp>` is the sha256 of its row file `v3.lines.<fp>` (the base's normalized failure lines), shared with the branch cache. A hit counts only when that file verifies and was not written by the current run; otherwise the base runs again. Inheritance from an earlier base needs the same comparison to say `preexisting`. A row's path is the one the base ran (the rename source for a renamed test). `und:timeout-at-base-after-<N>s` is reused only while N >= the current REQUESTED_TEST_TIMEOUT (read back as `timeout-at-base`) and is never inherited.
- **Exit 5**: a merge base older than the current root names, or whose `tests/lib/harness.sh` writes no `fail-details.tsv`, gives no baseline: merge main (or rebase) and re-run.
- **Cause allow-list**: `bin/workflow/lib/run-tests-baseline-evidence/disposition.js` is the single source; this document does not copy the table. It maps each classification to `proof` (pre-existing, or inherited from an earlier base), `auto` (a cause that is no evidence against the change: a timeout on the branch that passes alone, or a base side that could not be run, such as a timeout, skip or unsupported language at base), `rerun` (the classification did not finish: budget exhausted, worktree or setup failure, state moved) and `pending` (anything else: `broken`, a pass-alone with a non-timeout or unknown exit, a missing test at base, an unknown detail). Unknown details fall to `pending`. Unrunnable tests and hits keep their earlier refusals.
- **Aggregation**: one `pending` entry makes the CLI exit 1; otherwise one `rerun` entry makes it exit 8 (re-run the same command, or `/run-tests` again when no failing list was recorded); otherwise it records. `--note <text>` stores one line (newlines removed, 200 characters at most) as `baseline_note`.
- **Recorded basis**: `completion_basis` is `baseline-preexisting` when every failure was proven, `baseline-auto-accepted` when at least one was auto-accepted, and the legacy `baseline-user-accepted` only in states written before #2688 (never written now). The CLI prints `RECORDED completion_basis=<basis>`; `record` is reachable only through the CLI, as before, and `accept` no longer exists.
- **Disclosure**: the Final Report and the PR body carry one `Unverified tests:` line from `hooks/lib/run-tests-completion-note.js`: the count, the distinct causes and the note for `baseline-auto-accepted`, and a fixed legacy line for `baseline-user-accepted`. The next run of the hook clears `baseline_note` and `failing_test_exits`. A record that saw new failure lines keeps them per path in `baseline_new_lines_seen`, which no later run clears; once `run_tests` completes, by any basis, each path adds a `- Baseline new failure lines:` line (200 characters at most).
- **Output**: each `BASELINE:` line ends ` new=<N> head=<json>` when the comparer found new lines (N counts them all; the head holds the first three, also written to the `new failure lines:` file named on stderr); `BASELINE_SUMMARY:` adds `file_verdict=` and `new_on_branch=`. The classification file has five columns: path, class, detail, new-line count, head JSON.

### Partial re-run (#2803)

- A run-all HIT that is not this session's change is not a HIT: a change to the shared `$common/config`, or to the head of a tree other than the run's own checkout (a main worktree fast-forward), is printed as a `worktree-change (foreign, not a hit)` line and not counted. `config.worktree` of the own checkout still counts. The same library serves the base run, so both sides treat it alike.
- `run-tests-baseline-evidence rerun-list --session <sid>` prints the failed tests of the latest run plus the tests named by HIT lines, one path per line; exit 9 means a HIT names no test and only a full re-run is safe. `/run-tests` passes the list as `test_args`.
- The hook merges each run's result with the earlier ones (`run_parts`) so a partial run does not discard the rest. The selection is taken from the run's own evidence (the dispatch payload's `test_args`, or the trigger command's arguments) and trusted only when the executed-plus-unrunnable count matches it and the failing paths are inside it; otherwise it is `unknown` and the run stands alone. Runs whose input version differs from the latest are dropped from the merge. Per-test exit codes are kept as `failing_test_exits`.

### Run evidence for `run_tests` (#2472)

Completing `run_tests` through the sentinel, `--advance` or `MARK_STEP` (the declaring routes of `recordStepVerdict`) requires evidence. Observing routes (the hook's `recordPass`, the baseline CLI, the UNRUNNABLE accept) do not pass through it; a step already `complete` stays accepted.

| Refusal kind | Meaning | Recovery |
|---|---|---|
| `no-run-evidence` | no recorded run supports the completion | re-run `/run-tests` (the baseline CLI for remaining failures) |
| `run-evidence-ingest-pending` | a dispatch outcome exists but has not been ingested | run `skills/run-tests/scripts/show-dispatch-outcome.sh --session <sid>`, then repeat the operation |

A refused operation ingests nothing itself; only the read-only script's own PostToolUse does. The declared-pass annotation (`run_outcome=pass`, `provenance=declared`) on complete is gone; a skip still clears `run_outcome`. The remaining deliberate exits are `WORKFLOW_RUN_TESTS_NOT_NEEDED`, `WORKFLOW_OFF`, the UNRUNNABLE accept and `RESET_FROM`. `write_tests` evidence is narrowed alike: a changed file counts only under `tests/` or `test/` with a basename of a registered test language.

## Hardening

- Labels in the marker are validated against the registry, never trusted from the test.
- The result env reaches the child only and is removed by its consumer before test code runs; the pytest wrapper also drops its own directory from `sys.path` so `pytest.py` never shadows the real package.
- The pytest wrapper runs pytest in a child process that receives only a scratch `cases.tsv` path; the wrapper copies the records, checks the version and writes the marker itself, and maps the child's exit code (5 with no record → 77, any other nonzero → 1), so test code can neither write `unrunnable` nor exit 79.
- The registry pins `pytest` only and `uv run` picks the interpreter, so the pytest wrapper keeps to Python 3.8 syntax and library calls; the node reporter relies on node emitting `test:start` in declaration order, which keeps a case under its own suite when sibling suites run concurrently. A result that arrives out of that order is recorded bare as `FAIL` and fails the file, never named under another suite.
- Paths starting with `-` are passed as `./-…` (launcher and `tlr_exec_plain`) or after `--` (pytest) or as an absolute path (node), never as an option.
- Pester's `Run.Path` is wildcard-escaped, so `a[1].Tests.ps1` runs only itself; `{nativePathSq}` doubles ASCII `'` and U+2018..U+201B.
- `timed_exec` (`bin/lib/timed-exec.sh`) returns 124 on both the GNU `timeout -k 2` path and the perl fallback, and kills the whole process group. GNU `timeout` exits 137 when a TERM-ignoring command needed the KILL; `timed_exec` returns 124 for it once the limit has passed (a command that dies of KILL earlier keeps 137), and `rac_classify` reads 137 at the deadline as TIMEOUT (124) as well, so a TIMEOUT means the same on every host.
