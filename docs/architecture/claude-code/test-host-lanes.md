# Test Host Lanes and the Corpus Cache

Why `bin/find-tests-for-source.sh` and `tests/run-all.sh` share one host-wide load
budget, and why find-tests caches its corpus parse. What/Why only — the runner's own
scheduler is in `test-runner-parallelism.md`.

## 1. Why this exists

After the corpus grew to about 2,400 test files (#2396), one find-tests call cost
seconds of forks on Windows, and review-tests called it once per test file. Several
parallel sessions then saturated the PC (#2455).

The root cause is that every session sees only its own load. find-tests (parsing)
and run-all (test execution) are the same class of problem: k concurrent sessions
multiply the load by k. Four independent layers reduce it, each worth keeping on its
own:

| Layer | Reduces |
|---|---|
| Batched calls (`--sources` / `--test-file` repeated in one call) | Number of calls |
| Fork reduction (result globals instead of `$(...)`, one awk per batch) | Cost per call |
| Corpus cache (`bin/lib/test-corpus-cache.sh`) | Repeated parsing |
| Host lanes (`bin/lib/test-host-lanes.sh`) | Host-wide concurrency |

## 2. Corpus cache

find-tests keys a serialized copy of the parsed corpus by git state, not by mtime:
the `HEAD:tests` tree, the porcelain status of the corpus paths, the content hash of
every dirty corpus file, and the hash of the parser libraries themselves. The key costs
a constant number of git calls, independent of the corpus size.

Why git and not an external cache tool: mtime-keyed tools miss changes in the nested
`tests/<category>/<name>.sh` layout and add a binary dependency. The git key
invalidates exactly and adds nothing.

Branch headers are excluded from the key and stored paths are root-relative, so
worktrees at the same content share one entry.

The cache file is untrusted input, read with the same discipline as the measured
parallelism record: a `read` loop that never evaluates a value, a fixed header, a per-row token
count, and an `#end` row count. Any mismatch regenerates the entry. Paths holding LF,
TAB or CR are never stored. Every failure is fail-soft: the result equals an uncached
scan. `FIND_TESTS_CORPUS_CACHE=off` bypasses the cache.

## 3. Host lanes

One **max jobs per host** H (`TEST_MAX_JOBS_PER_HOST`) of "CPU lanes" is shared by
every find-tests and run-all process on the host. The first valid layer wins:
environment > `.env` > the calibrator's measured record > default 4, and the lanes
line names which one (`source env|dotenv|measured|default`). An invalid value skips
its layer with one fixed notice; a missing or rejected record shows its reason token
and the calibrator hint. A lane is an atomic `mkdir` of `slots/lane.<i>` under the
run-all cache directory, holding an owner record (pid, environment, kind, start,
token) and a heartbeat epoch.

- find-tests takes 1 lane, searching from H downward.
- run-all asks for min(max jobs per run, H−1) lanes (1 when H<2) from lane 1 upward,
  once at start, and never changes its share while running. Lane H is therefore
  always left for find-tests, and the scheduler's blocking `wait -n` needs no change.
- A partial grant runs at the narrower width instead of waiting.
- `--print-plan` applies the same rule without taking a lease, and
  `bin/test-lanes-status.sh` shows H and its source on its first line.

When the measured record was taken on another OS version than the current one, the
value is still used and the lanes, plan and status lines add `measured on X, now Y;
re-run RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh` (`test-runner-parallelism.md`
Section 5). On a host with the never-ask record (`calibration-never-ask.conf`) the lines
keep the advice but omit the command.

Why slots and not CPU measurement: measuring CPU on Windows means launching
PowerShell each time and is noisy under changing load. Slots are deterministic,
cheap and OS-independent. External load (a browser build) is out of scope.

**Liveness.** A lane whose pid fails `kill -0` in the same environment is reclaimed at
once; a lane from another environment, or whose heartbeat is older than the TTL, is
reclaimed by age. Reclaim is an atomic `mv` to a grave name plus a token re-check, so
two reclaimers never both win. The remaining race can exceed the budget by one lane
for a moment — never deadlock or corrupt — which the single-user NFR accepts.

**Heartbeat.** Only run-all, whose lease can outlive the TTL, runs a background
heartbeat. It holds no fd to the parent, so a worker's `spawnSync` still ends, and it
is stopped on every exit path.

**Waiting.** When every lane is busy the caller waits, prints one notice naming
`bash bin/test-lanes-status.sh`, and fails closed with **exit 4** at the cap: 540 s
for find-tests (inside the 600 s Bash tool limit) and 1800 s for run-all, lowered to
`--deadline` when that is smaller. Exit 4 emits no `Results:` or `RUN_CONTRACT:` line.

**Nesting.** A holder exports `TEST_LANES_HELD`; its children skip the lease and run
at their requested width, so a test run under run-all never waits on its own parent.
`TEST_LANES=off` disables the lease, and the calibrator sets it so its measurements
are not narrowed. These two are the only cases where the rule does not apply, and
each prints `not applied (TEST_LANES=off|nested under a lane holder); jobs N as
requested`.

**Unwritable cache directory.** When `slots/` cannot be created, the caller prints one
notice and runs without a lane at the width the rule allows. Load control is a
courtesy between sessions, so a broken cache directory must never block a test run.

**Write scope.** find-tests is auto-approved as a self-script. With the cache and lanes
it now writes, but only under the run-all cache directory: `corpus/` entries and their
retention, and `slots/` lanes, including reclaiming stale ones. It writes nothing in
the repository.

## 4. Where things live

| Path | Role |
|---|---|
| `bin/lib/test-corpus-cache.sh` | Cache key, non-evaluating loader, atomic writer with retention |
| `bin/lib/test-host-lanes.sh` | Max jobs per host, width rule, lease, reclaim, heartbeat, release, status listing |
| `bin/test-lanes-status.sh` | Read-only listing of lane holders |
| `tests/bin/feature-2455-test-load-control/` | Cache, lanes, run-all lease and fork-count cases |
