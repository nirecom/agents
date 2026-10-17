# Glossary — testing terms
<!-- lang-check: ignore -->

The test-runner, test-harness and test-retirement terms of the
[agents glossary](../glossary.md), split out to keep the index under the
documentation size limit. Entry format follows the main glossary.

---

## Test runner

### test lane

- **Full name**: Host test lane
- **Definition**: One of the max jobs per host H (`TEST_MAX_JOBS_PER_HOST`: environment > `.env` > measured record > default 4) shared by `bin/find-tests-for-source.sh` (1 lane) and `tests/run-all.sh` (1 to min(max jobs per run, H−1) lanes); an atomic `mkdir` slot holding an owner record. A caller that finds every lane busy waits, then exits 4 at the cap.
- **Related**: [architecture/claude-code/test-host-lanes.md](../architecture/claude-code/test-host-lanes.md), [bin/test-lanes-status.sh](../../bin/test-lanes-status.sh)

### base segment

- **Full name**: Duration-ledger base segment
- **Definition**: A duration-ledger (`bin/lib/run-all-durations.sh`) term: the one segment per OS attribute, `dur.2.<tok>.<S>-0<k>.log`, that consolidation writes, holding each key's latest duration and the run that measured it (`#run` lines).
- **Related**: [architecture/claude-code/test-runner-parallelism.md](../architecture/claude-code/test-runner-parallelism.md)

### abandoned segment

- **Full name**: Duration-ledger abandoned segment
- **Definition**: A duration-ledger (`bin/lib/run-all-durations.sh`) term: a segment without the closed mark whose last write is older than 6 hours (`RUN_ALL_DUR_ABANDON_MIN`); consolidation takes it in as if its run had closed.
- **Related**: [architecture/claude-code/test-runner-parallelism.md](../architecture/claude-code/test-runner-parallelism.md)

### expired record

- **Full name**: Duration-ledger expired record
- **Definition**: A duration-ledger (`bin/lib/run-all-durations.sh`) term: a key whose latest duration comes from a run started more than 30 days ago (`RUN_ALL_DUR_RETENTION_DAYS`); consolidation does not write it. Distinct from the baseline ledger's 30-day cleanup, which goes by file modification time.
- **Related**: [architecture/claude-code/test-runner-parallelism.md](../architecture/claude-code/test-runner-parallelism.md)

### test language registry

- **Full name**: Test language registry
- **Definition**: The one table that decides, for every test language, which files are tests, how their headers are read and how they are launched. Test tools consult it instead of checking file extensions themselves.
- **Related**: [architecture/claude-code/test-language-registry.md](../architecture/claude-code/test-language-registry.md)

### UNRUNNABLE

- **Full name**: Unrunnable test state
- **Definition**: The state of a test file that could not run because its runtime is missing from PATH or older than the registry's minimum version (exit 79 with a validated `unrunnable` marker), or because an explicitly named test path resolves to no regular file (`missing: test file`). It counts as neither pass, fail nor skip, and it keeps the `run_tests` step from completing until the runtime is installed or the user accepts the gap with the `RUN_TESTS_UNRUNNABLE_ACCEPTED` sentinel.
- **Related**: [architecture/claude-code/test-result-contract.md](../architecture/claude-code/test-result-contract.md)

### case-level result line

- **Full name**: Case-level result line
- **Definition**: The run-all report line `<STATE> <file>::<case> target=<target>` that gives one case's result inside a test file, printed after that file's `PASS:` / `FAIL:` / `SKIP:` line in every test language.
- **Related**: [architecture/claude-code/test-result-contract.md](../architecture/claude-code/test-result-contract.md)

## Run tests recording

### dispatch settlement

- **Full name**: Dispatch settlement
- **Level**: 2
- **Definition**: The process, run on every Bash call, of finding the latest test-runner dispatch for the current session and checking whether its outcome has already been ingested. The result is `settled` (outcome ingested or no dispatch exists) or `unsettled` (a `.dispatched` marker exists with no corresponding `.ingested` marker); while unsettled, a stale `run_tests` complete or fail result is demoted to `pending` on non-test calls.
- **Related**: [hooks/workflow-state/dispatch-settlement.js](../../hooks/workflow-state/dispatch-settlement.js), [hooks/workflow-run-tests/dispatch-outcome.js](../../hooks/workflow-run-tests/dispatch-outcome.js), #2544

### outcome_source

- **Full name**: Run-tests outcome source
- **Level**: 2
- **Definition**: A field in the `run_tests` state entry that records the stem, payload SHA-256 (`payload_sha256`), and outcome SHA-256 (`outcome_sha256`) of the worker outcome file from which the state was last written. `bin/workflow/lib/run-tests-baseline-evidence.js` reads it to verify that the recorded outcome bytes have not been replaced before accepting a failing baseline as pre-existing.
- **Related**: [hooks/workflow-run-tests/dispatch-outcome.js](../../hooks/workflow-run-tests/dispatch-outcome.js), [bin/workflow/lib/run-tests-baseline-evidence.js](../../bin/workflow/lib/run-tests-baseline-evidence.js), #2544

## Test harness

### run root

- **Full name**: Test run root
- **Definition**: The per-run isolation directory that every test in a run writes inside. Set via `TEST_RUN_ROOT`; created under `<TEST_HOST_TMPDIR>/agents-test-runs-<user>/run-<pid>-<rand>` when not already set. `TMPDIR`, `TMP` and `TEMP` are pinned to its `tmp/` subdirectory so that `mktemp` and temp-file helpers land inside it. Build caches (root decoy, command-guard binaries) sit under `<TEST_HOST_TMPDIR>/agents-test-cache-<user>`, owned by `tests/lib/test-cache-base.js`.
- **Related**: [architecture/claude-code/test-command-guard.md](../architecture/claude-code/test-command-guard.md), `tests/lib/test-run-root.sh`

### command guard

- **Full name**: Command guard
- **Definition**: The layer that puts stub binaries for `git`, `gh`, `glab` and `codex` first on `PATH` during a test run. Each stub reads its policy from `../guard.conf` and either runs the real tool, delegates to `tests/lib/command-guard/main.js`, or exits 97 (refused) and writes a hit file. On POSIX the stubs are bash scripts; on Windows a single compiled C# launcher (`launcher.cs`) serves all four tools. A refused call is a test failure, reported by `run_all_hit_report`.
- **Related**: [architecture/claude-code/test-command-guard.md](../architecture/claude-code/test-command-guard.md), `tests/lib/command-guard.sh`

### spawn record

- **Full name**: Spawn record
- **Definition**: A Node.js `--require` preload (`tests/fixtures/spawn-record-preload.js`) that patches `child_process` to record every `spawn`/`execFile` call. A test that needs to assert on what commands a script invokes loads it via `NODE_OPTIONS=--require <preload>`, then reads the hit files after the run. The preload stores hits in the command guard's `hits/` directory so they are co-located with guard hits and cleaned up together.
- **Related**: `tests/fixtures/spawn-record-preload.js`, `tests/lib/spawn-record.sh`

## Test retirement

### case marker

- **Full name**: Case marker (`case_begin` / `case_end`)
- **Definition**: The column-0 pair that wraps one case of a multi-path `.sh` test. `case_begin` names the target path the case protects, so retire can drop that case alone when the target is gone.
- **Related**: [skills/_shared/test-design/case-markers.md](../../skills/_shared/test-design/case-markers.md), [architecture/claude-code/case-marker-gate.md](../architecture/claude-code/case-marker-gate.md)

### marker conformance

- **Full name**: Case-marker conformance verdict
- **Definition**: The retire parser's judgement of a file's markers: `none` (no markers), `conforming` (retire can split the file), `malformed` (a marker retire cannot use; blocked for new files), or `uncertain` (a depth problem after a multi-line quoted string, warned but not blocked). Computed by `trp_marker_conformance`; the case-marker gate consumes it via `bin/check-case-markers.sh`.
- **Related**: [architecture/claude-code/case-marker-gate.md](../architecture/claude-code/case-marker-gate.md), #2388
