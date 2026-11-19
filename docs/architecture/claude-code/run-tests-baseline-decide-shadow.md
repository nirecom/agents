# run-tests-baseline Decide Shadow

`bin/run-tests-baseline` re-runs each failing test file alone on the branch and at the merge base, and classifies it by comparing the two runs (#2688, [test-result-contract.md](test-result-contract.md) "Baseline acceptance of failing tests").
Each half of that comparison is a comparison side: the branch side or the merge base side.

Today the two comparison sides read the same `RTB_EXEC_*` outputs of `rtb_exec_one` in two separate case statements (`rtb_branch_run_one` in `bin/lib/run-tests-baseline-branch.sh`, and the base stage written inline in `bin/run-tests-baseline`), and Table 1 / Table 2 are spread over shell functions.
The same fact is read differently by the branch side and the merge base side in six places, and only one of them was documented as intended.

Group #3066 replaces this with one parser and one table. This document covers its second stage (S2: #3068, #3069, #3070), which adds them **as a shadow only**:

- the live classification is unchanged: `rtb_branch_run_one`, the merge base side case statement, Table 1 / Table 2, `disposition.js`, the timeout lib (`bin/lib/run-tests-baseline-timeout.sh`) and [test-result-contract.md](test-result-contract.md) all stay as they are;
- the new code runs next to the live path, compares its answer with the live answer, and writes a divergence log;
- switching the live path to the new table is #3071 (S4, canary one layer at a time). Until then two sets of reading rules exist on purpose: the old code is the oracle the shadow compares against.

## Comparison side result (#3068)

`parseComparisonSideResult(execOutputs, errHitLines)` in `bin/lib/run-tests-baseline-comparison-side-result.js` turns one `rtb_exec_one` call into a comparison side result: the facts of re-running one test file alone on one comparison side.

- Input: the `rtb_exec_one` return code, `RTB_EXEC_{RC,STATE,TIMEDOUT,UNSUPPORTED,DECOY,UNRUNNABLE}`, and the hit lines of the run's err file.
- Output: exactly four fields, `{verdict, termination, exitCode, hitKind}`.
  - `verdict` / `termination` reuse the file result vocabulary of [test-result-contract.md](test-result-contract.md); only `launcher-setup-failed` (return code 2) and `interrupted-by-outer-watchdog` (the `rtb_exec_one` watchdog fired without a launcher `TIMEOUT` state) are added.
  - An empty or unknown launcher state reads as `?` / `?`; the state string itself is not kept.
  - `hitKind` is `none`, `command-guard-hit-only`, or `root-decoy-or-worktree-change`, using the same regular expression as `rtb_branch_guard_only_fail`.
- The parser takes no comparison side argument: the branch side and the merge base side get the same facts from the same input. How a comparison side reads those facts (interrupted, ambiguous, and so on) belongs to the decide table, not to the comparison side result.
- "Could not be observed" is a `termination` other than `completed`; no new word is coined (#3072 relies on this). It is distinct from the case-level `UNOBSERVED`.

## Decide table (#3069)

`decide(input)` in `bin/lib/run-tests-baseline-decide.js` maps two comparison side results to the live `(class, detail)`.

- Input, exactly four keys: `branchResult` (the branch side comparison side result), `baseResult` (the merge base side comparison side result, or `null` when the merge base side did not run), `testFileChange` (`changed` / `unchanged` / `unknown`, from `rtb_test_changed`), and `caseComparison` (the case comparison verdict read three ways: branch records as a normal run, as an interrupted run, and ignored).
- Output: `{class, detail}`; `{needsBaseResult: true}` when the merge base side result is required; or `{decidedOutsideDecide: <id>}` when the four inputs cannot decide it.
- The detail vocabulary is the live one; `disposition.js` (proof / auto / rerun / pending, approvable) is outside decide.

**The table is data.** Why: a classification spread over shell case statements cannot be checked for gaps or overlaps; a table of rows can.

- `bin/lib/run-tests-baseline-decide/rows.js` holds the rows. Each row is `{id, group, discrepancyId?, fieldRead?, when: {anyOf: [conj]}, output}`. Groups: (i) decided by the branch result alone, (ii) merge base side readings, (iii) each branch result kind entering Table 1, (iv) Table 1 case comparison rows.
- Rows are mutually exclusive and order-independent: `evaluate.js` is a pure interpreter (`matchDecideRows(rows, input)` returns every matching row), and `decide` throws unless exactly one row matches. A test enumerates the whole input domain and asserts exactly one row for each input.
- `when-builder.js` holds the and/or builders that keep `rows.js` compact.
- `bin/lib/run-tests-baseline-decide.js` is dispatch and re-export only.
- Neither decide nor the parser depends on the shell libs or on `disposition.js`.

**Details decided outside decide** (`details-decided-outside-decide.js`, a closed list with the deciding input of each entry):

- decided before any run: `worktree-create-failed`, `missing-at-base`, `home-claude-ref`, `budget-exhausted`, `exceeds-budget`, `exec-setup-failed`;
- needing an input decide does not have: `exit-<N>-then-pass` (the first failing exit of the branch side), `base-launcher-predates-result-conversion` (the language's `launch.wrapper`), `state-<X>-at-base` (the unknown launcher state string);
- produced only by the reuse paths (a separate list): `ledger-same-base`, `inherited-from-*`, `preexisting-inherited`.

Keeping these three input-bound details outside decide keeps the decide input and the comparison side result fields as the intent fixed them; the cost is that the shadow does not compare them (they are counted as `no_comparison`).

## Recorded discrepancies

`recorded-discrepancies.js` records the six places where the branch side and the merge base side read the same fact differently. Each record holds the combination, the live reading of each comparison side, a judgment (`intended` / `inconsistent`), its reason and evidence, who confirmed it, and the hand-off to #3071.

| # | Combination | Judgment | Explains a shadow mismatch |
|---|---|---|---|
| 1 | FAIL with rc 124/142 | intended | no |
| 2 | no state, rc 124/137/142/143 | intended | no |
| 3 | FAIL whose only hits are command guard hits | inconsistent | yes |
| 4 | no state, wrapper language | inconsistent (merge base side reading is outside decide) | yes |
| 5 | SKIP (state SKIP or rc 77) | intended | no |
| 6 | unknown launcher state | intended (merge base side reading is outside decide) | yes |

- For an `intended` record decide splits its rows by comparison side and matches the old code on both.
- For an `inconsistent` record decide takes one reading, so the other comparison side mismatches.
- `findRecordForMismatch(input, live)` returns a record only when all three hold: the record has `explainsShadowMismatch` (3, 4, 6), its combination matches the input, and the live `(class, detail)` equals the record's reading for the matching comparison side. A mismatch that no record explains is `unrecorded`.
- Changing details, `disposition.js` or [test-result-contract.md](test-result-contract.md) for records 3, 4 and 6 is #3071's decision, not S2's.

## In-run shadow (#3070)

The shadow is two insertions into `bin/run-tests-baseline`, both in `bin/lib/run-tests-baseline-decide-shadow.sh`; neither changes the live path's behavior.

1. `rtb_decide_shadow_install`, right after the libs are sourced, wraps `rtb_exec_one`. The wrapper calls the original (`rtb_exec_one_unwrapped`), appends one TSV line per call to a capture file (`${LOGDIR}.decide-shadow-capture.tsv`: comparison side, rel, logdir, `RTB_EXEC_SEQ`, return code, `RTB_EXEC_*`), and returns the original return code. It does not read stdin, start node, or touch any `RTB_EXEC_*` value; a failed append is ignored.
2. `rtb_decide_shadow_compare_before_handoff`, after the classification file is written and before the hand-off to state, runs the comparer. The parent only copies `CLS` / `DET` into an input TSV; a background subshell writes the rename map and the test file changes, then runs `bin/lib/run-tests-baseline-decide-shadow.js` (`main.js` reads the inputs and writes the log, `compare-one.js` compares one test) once.

**Why it cannot change the live result:** by the time the comparer starts, every budget decision and every `CLS` / `DET` is final; the comparer writes neither the classification file nor stdout, its exit is ignored, and the function always returns 0. Exit, stdout, state and the classification file are therefore the same with the shadow on, off, failing or hanging; the isolation tests assert exactly this.

**Time bound:** the comparer is capped at 10 seconds by a process-group watchdog, and it is skipped (`budget-short`) unless the run budget still holds those 10 seconds plus 15 seconds for the hand-off and output. The budget values are only read from the timeout lib; the CLI as a whole stays inside the 600-second `/run-tests` Bash call.

**Per-test comparison**, in order:

1. the live detail (without `-via-rename:<old>`) is in an outside-decide list: `outside-decide`;
2. no branch side capture line: `branch-result-reused-from-cache`;
3. decide needs the merge base side result and there is no merge base side capture line: `base-result-reused-from-ledger-or-inheritance`;
4. the capture line cannot be read: `capture-unreadable`;
5. otherwise the test is COMPARED: `match`, `recorded:<id>`, or `unrecorded`.

The case comparison uses the same `run-tests-baseline-compare/` modules as the live path; `run-tests-baseline-lines.js` row files only feed the reuse paths, which are never compared.

**Run-level skips** count every test as `no_comparison` and name the reason in `SUMMARY`: `budget-short`, `timed-out`, `failed`.

**Kill switch:** `RUN_TESTS_BASELINE_DECIDE_SHADOW=off` makes both insertions no-ops: no wrapper, no capture, no log, no stderr line. `RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST=fail|hang` is a test seam that acts only inside the background subshell.

## Divergence log

- Location: `$(run_all_cache_dir)/baseline/decide-shadow/divergence-<host-token>-<epoch>-<pid>.tsv`, one file per run. Nothing is written to state.
- Retention: when the comparer starts it deletes `divergence-*.tsv` older than `RTB_LEDGER_RETENTION_DAYS` (30 days). A capture file left by a run that exits before the comparer sits under `TMP_BASE` and is removed by the existing 30-day sweep; no new `trap` is added.
- Format (first line `# run-tests-baseline decide shadow v1`):
  - `RUN	<epoch>	<HEAD>	<merge base|->`
  - `COMPARED	<path>	<live class>	<live detail>	<decide class>	<decide detail>	<match|recorded:<id>|unrecorded>	<branch result JSON>	<base result JSON|null>`
  - `NO_COMPARISON	<path>	<reason>`
  - `SUMMARY	compared=N	matched=N	recorded=N	unrecorded=N	no_comparison=N	skipped=<reason|->	elapsed_ms=N`
- `compared + no_comparison` equals the number of tests in the failing list.
- stderr gets one line per run: `run-tests-baseline: decide shadow: compared=N unrecorded=N no_comparison=N log=<path>`.
- Collecting for #3071: glob `divergence-*.tsv` in that directory and count the `unrecorded` COMPARED lines and the `SUMMARY` lines. A collecting CLI is #3071's scope.

## Corpus

- Synthetic corpus: ten `tests/bin/bin-run-tests-baseline-decide-corpus-*.sh` files drive the real CLI against stub launchers over four groups (decided without a merge base side result, merge base side readings, branch result kinds, Table 1 case comparison × test file change) and assert `unrecorded=0`, the expected `compared` / `no_comparison` counts, and `elapsed_ms < 10000`.
- Existing reproduction tests (#2956 / #3015 / #3037 / #3047 / #3055, rename source, branch cache) run the same divergence-log check after each CLI call.
- Past state: the `(class, detail)` pairs seen in past `baseline_classification` records, collected once as data, must each be reachable by decide or listed outside decide (the inputs are not kept in state, so this checks reachability only).

Related: [test-result-contract.md](test-result-contract.md) owns Table 1 / Table 2 and the acceptance rules; [state-dirs.md](state-dirs.md) owns the state directories.
