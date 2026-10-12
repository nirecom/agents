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
Results: PASS=p  FAIL=f  SKIP=s  UNRUNNABLE=u  TIMEOUT=t
RUN_CONTRACT: PASS=p FAIL=f SKIP=s EXECUTED=p+f+s UNRUNNABLE=u TIMEOUT=t
```

`Missing runtimes:` appears only when `UNRUNNABLE > 0`. `TIMEOUT` is a subset of `FAIL`; `UNRUNNABLE` is outside `EXECUTED`. `tests/run-all.sh` exits 1 when `FAIL > 0`; an UNRUNNABLE-only run exits 0, and the readers below are what keep it from counting as green.

## Neutralization of child output

A test's stdout and stderr are replayed before its own result lines, so a test printing a result-shaped line could forge one.
`rar_neutralize` (shell builtins, no fork per line) prefixes `[run-all:neutralized] ` to every child line that, after leading blanks, starts with `RUN_CONTRACT:`, `UNRUNNABLE:`, `TIMEOUT:`, `Missing runtimes:`, `Results:`, `FAIL: … (exit N)`, or `<STATE> <anything>::` for a case state (the file path may hold spaces).
Only lines printed by `rar_unit` / `rar_tail` reach readers unprefixed; readers anchor their patterns at line start.

## Readers and `run_outcome=unrunnable`

| Reader | Reads |
|---|---|
| `hooks/workflow-run-tests.js` | `RUN_CONTRACT:` through `hooks/lib/run-contract.js`, shared with the worker and the renderer. The 6-field line is shape `current`; a 4-field line from an older run-all is shape `legacy`, whose `UNRUNNABLE` / `TIMEOUT` read as null (never 0), so it never completes `run_tests` (demotion `contract-legacy-shape`: rebase onto main and re-run). Anything else after the fields, such as a cut-off `UNRUNNABLE=1 TIMEOUT=`, makes the line no contract; so does a count too long to be an exact integer. A contract is valid only in shape `current` with `UNRUNNABLE=0` |
| `hooks/workflow-run-tests/outcome.js` | trusted contract with `FAIL=0` and `UNRUNNABLE>0` → `run_outcome=unrunnable`; so does an attributed, unvetoed contract with `EXECUTED=0`, `FAIL=0` and `UNRUNNABLE>0`, on the direct route as on the worker route |
| `bin/worker-dispatch/workers/test-runner.js` | exit 0 with `UNRUNNABLE>0` → status `unrunnable`; the summary opens with the last `Missing runtimes:` line, so the renderer's length cap cuts the totals before the remedy; case PASS/SKIP/XFAIL lines are dropped from the log tail |
| `bin/run-tests-baseline` | launcher state: UNRUNNABLE at base → `undetermined` (`unrunnable-at-base`); launcher setup failure (rc 2, not launched) → `undetermined` (`exec-setup-failed`); FAIL 137/143 → ambiguous; other FAIL (124/142 included) → preexisting. The hook records the failing run's `unrunnable_count` beside `failing_tests`, and the baseline completes `run_tests` only when that count is exactly 0: a selected test that never ran is not covered by any classification |
| `bin/mutation-probe.sh` | `RUN_ALL_EXEC_STATE` SKIP / UNRUNNABLE / UNSUPPORTED → `NOT RUN:`, never a killed mutant |

Workflow effect of `unrunnable`:

- The `run_tests` step is not completed: demotion reason `contract-unrunnable` (checked before the worker-status veto) and the message "Selected tests marked UNRUNNABLE: N. Install the runtimes listed on the `Missing runtimes:` output line and run again. If a runtime cannot be installed, accept this run only with `echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>"`."
- `/run-tests` (RNT-9) shows the `Missing runtimes:` line, asks the user to install the runtime, and never runs the baseline. Recovery is a rerun with `UNRUNNABLE=0`, or the accept below.
- It is not a code defect: `unrunnable` is not a failing outcome for `write_code` resume or for the baseline evidence, so it triggers no fix cascade.

## Accepting UNRUNNABLE

When the runtime cannot be installed on this host, `echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>"` completes `run_tests` without a green run. It exists so a missing runtime cannot block a session forever; it is never silent:

- `settings.json` lists it under `permissions.ask` (never `allow`), so the user confirms every use.
- `hooks/workflow-mark/run-tests-accept-handler.js` accepts only a `run_tests` that is pending with `run_outcome=unrunnable`, `unrunnable_count>0` and no failed run — that is, a current-shape contract with `FAIL=0`. It reads the hook's annotations, never stdout. A completed step, `FAIL>0`, no contract, a legacy 4-field contract, or a reason under 3 non-blank characters is rejected with the state unchanged; a reason holding `( ) ; | & >` or a backtick is a malformed sentinel (advisory only).
- An accept records `completion_basis=unrunnable-accepted` and `unrunnable_accept_reason`, and keeps `unrunnable_count`, `unrunnable_runtimes` and `run_outcome=unrunnable`.
- The Final Report (`bin/render-final-report.js`, under Merged PR) and the PR body (`/commit-push` appends `bin/workflow/run-tests-unrunnable-note`) each carry one line with the count, the missing runtimes and the reason, from `hooks/lib/run-tests-unrunnable-note.js`.
- The next run of the hook clears `completion_basis` and `unrunnable_accept_reason`, so an accept never outlives the run it accepted.

## Hardening

- Labels in the marker are validated against the registry, never trusted from the test.
- The result env reaches the child only and is removed by its consumer before test code runs; the pytest wrapper also drops its own directory from `sys.path` so `pytest.py` never shadows the real package.
- The pytest wrapper runs pytest in a child process that receives only a scratch `cases.tsv` path; the wrapper copies the records, checks the version and writes the marker itself, and maps the child's exit code (5 with no record → 77, any other nonzero → 1), so test code can neither write `unrunnable` nor exit 79.
- The registry pins `pytest` only and `uv run` picks the interpreter, so the pytest wrapper keeps to Python 3.8 syntax and library calls; the node reporter relies on node emitting `test:start` in declaration order, which keeps a case under its own suite when sibling suites run concurrently. A result that arrives out of that order is recorded bare as `FAIL` and fails the file, never named under another suite.
- Paths starting with `-` are passed as `./-…` (launcher and `tlr_exec_plain`) or after `--` (pytest) or as an absolute path (node), never as an option.
- Pester's `Run.Path` is wildcard-escaped, so `a[1].Tests.ps1` runs only itself; `{nativePathSq}` doubles ASCII `'` and U+2018..U+201B.
- `timed_exec` (`bin/lib/timed-exec.sh`) returns 124 on both the GNU `timeout -k 2` path and the perl fallback, and kills the whole process group. GNU `timeout` exits 137 when a TERM-ignoring command needed the KILL; `timed_exec` returns 124 for it once the limit has passed (a command that dies of KILL earlier keeps 137), and `rac_classify` reads 137 at the deadline as TIMEOUT (124) as well, so a TIMEOUT means the same on every host.
