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

One **max jobs per host** (`TEST_MAX_JOBS_PER_HOST`) of "CPU lanes" is shared by
every find-tests and run-all process on the host. A lane is an atomic `mkdir` of
`slots/lane.<i>` under the run-all cache directory, holding an owner record (pid,
environment, kind, start, token) and a heartbeat epoch.

### Resolution order of max jobs per host

This subsection is the single owner of how max jobs per host is resolved; every other
document refers here (CPR-SSOT). The mode comes first: `AUTO_CONFIG_TEST_MAX_JOBS`
resolves environment > `.env` > `on`, case-insensitively, and a value that is neither
`on` nor `off` prints one fixed notice (never the value) and counts as `on`.

| Mode | Value | `source` |
|---|---|---|
| `off` | The pin (`TEST_MAX_JOBS_PER_HOST`, environment > `.env`), else the default 4. The measured record is never read. | `env`, `dotenv` or `default` |
| `on` | The base is the measured record (schema 3, or schema 2 read as legacy), else the default 4. A pin makes the value min(pin, base). | The layer that decided: the pin when it is lower, else `measured` or `default` |

After either row the value is capped at the **logical CPU count** — never rounded up
and never otherwise transformed, so a pin of 7 stays 7. The lanes line then appends
`capped at logical CPU count <n>` (status line: `capped=logical-cpu-count`). When the
count cannot be read, nothing is capped and the line says `logical CPU count unknown;
not capped` (status: `logical_cpus=unknown`). An invalid pin skips its layer with one
fixed notice; a missing or rejected record shows its reason token and the calibrator
hint. The status line also carries `mode=on|off` and `runs=<active run count>`.

The mode switches only the automatic parts: the measured record, the calibration
offer and load scale-in. The fair share below applies in both modes.

When the measured record warrants a new calibration, the lanes, plan and status lines
add advice (`re-run RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh`,
`test-runner-parallelism.md` Section 5) and the status line names the reason:

| `recalibrate=` | When |
|---|---|
| `legacy-record` | The record is schema 2, which lacks the logical CPU count and the width limit |
| `cpu-count-changed` | The record was taken at another logical CPU count than the current one |
| `ladder-truncated` | `width_limit=jobs-list` and the calibration knee is the widest measured width, below the recorded logical CPU count |

A record whose widest width was set by `candidates`, `sample` or `time-limit` gets only
the note `measured up to <n>`: the same corpus would not widen it, so no question is
raised each time. The same OS-version drift note (`measured on X, now Y`) still
applies. The advice shows only while the record decides the value.

### Fair share

Each run-all keeps a presence record `runs/run.<token>` (the lane owner format plus its
demanded max jobs per run and its own max jobs per host) and refreshes it with the same
heartbeat as its lanes. The records, ordered by start, make up the **active run count**,
waiting runs included. Presence records go stale and are reclaimed by exactly the lane
liveness rule below, through the same reclaim function.

- The run-all lane pool is the smallest max jobs per host among the present records,
  minus 1, minus the load scale-in, never below 1. Taking the smallest keeps a worktree
  whose `.env` differs from widening the budget (#2545).
- Each run's **fair share** is a max-min split of that pool, capped at its max jobs per
  run (unlimited means the test count). Remainders and the unused part of a capped
  run go one by one to the earliest runs. Example, max jobs per host 12 and no per-run
  cap: 1 run gets 11, 2 get 6 and 5, 3 get 4, 4 and 3.
- When the active run count exceeds the pool, the first pool runs get 1 and the later
  ones get 0 and wait for a lane. The shares never sum to more than the pool.
- find-tests takes 1 lane, searching from the max jobs per host downward, so the last
  lane stays free for it. The single exception to the pool formula is a max jobs per
  host of 1: the pool is still 1, because run-all could not move otherwise, and with the
  find-tests lane the host may briefly hold one lane more — the behaviour that existed
  before.
- A run-all starts its heartbeat before it asks for a lane, so waiting is covered. It
  waits while its fair share is 0 (one notice), bounded by the wait cap below, then
  takes its first lanes through `thl_acquire`.
- The share is re-evaluated at every entry-script end. Growing takes lanes that are free
  now (one reclaim sweep, never a wait); shrinking releases the highest-numbered lanes
  down to the larger of the new share and the jobs still running. Both paths keep the
  run's token and its set of held lanes, so release at exit covers lanes taken later.
- With nothing running and a share of 0 (the pool shrank under load), the run polls
  until a lane is available. The wait is not capped by the wait cap but honors the run
  deadline.
- A partial grant runs at the narrower width instead of waiting. `--print-plan` applies
  the same width rule without a lease, and `bin/test-lanes-status.sh` lists presence
  records beside the lanes.

The deviation from the share comes only from the moment of re-evaluation. Running jobs
are never stopped, so a run with long entry scripts holds more than its fair share until
they finish; later runs get less, or wait, meanwhile.

### Why slots, and why load scale-in on top

Slots stay the one mechanism that enforces concurrency: deterministic, cheap and
OS-independent. Earlier, CPU measurement and external load were out of scope, because
measuring on Windows meant launching PowerShell at every acquisition. That reason does
not hold when the host takes one sample per heartbeat period, so load scale-in was
added **on top of** the lanes: it only lowers the pool.

**Estimate.** External load is the host's busy CPU time minus the CPU time of the tests'
own process tree. Subtracting the held-lane count instead would count tests that wait
on I/O as load and shrink the pool for no reason. One heartbeat per host (guarded by an
atomic `load/.claim` directory, reclaimed after 3 heartbeats) takes a snapshot, compares
it with the last one and writes `load/sample`; every run reads it with the
non-evaluating reader and ignores a sample older than 3 heartbeats.

**Counters per OS.**

| OS | Host busy counter | Own tree |
|---|---|---|
| Linux | `/proc/stat` | `/proc/<pid>/stat` descendants of the lane and presence owners |
| Windows | Per-processor idle counters from one PowerShell call (bounded to 20 s) | Process table of the same call; owner pids mapped through `/proc/<pid>/winpid` |
| macOS | None readable without a compiled helper: `host_counter=process-sum` | `ps` table |

Only macOS takes the process-sum path by design; it is also the fallback when the
Windows counters cannot be read. The sample records which was used (`host_counter`).

**Limits.** With the system counter, short-lived children of the tests that start and
exit inside the interval count in the host total but not in the own share, so external
load can be overestimated (shrinking too much). With the process sum, external
processes that exit inside the interval are missed (shrinking too little, the safe
side). An unreadable probe, a malformed snapshot, a missing previous snapshot, no
resolvable own root or a host counter that went backwards makes the sample
`unmeasurable`, and nothing shrinks.

**Hysteresis.** The pool shrinks by the whole cores of external load once the load is at
least 100 centicores for 2 consecutive samples, and returns after 3 consecutive samples
below 50. Values in between hold the state, so one spike or one lull does not move the
pool.

The calibrator is untouched by this: the load sample is not a calibration and writes no
record (`test-runner-parallelism.md` Section 5).

**Liveness.** A lane or presence record whose pid fails `kill -0` in the same
environment is reclaimed at once; one from another environment, or whose heartbeat is
older than the TTL, is reclaimed by age. Reclaim is an atomic `mv` to a grave name plus
a token re-check, so two reclaimers never both win. The remaining race can exceed the
budget by one lane for a moment — never deadlock or corrupt — which the single-user NFR
accepts.

**Heartbeat.** Only run-all, whose lease can outlive the TTL, runs a background
heartbeat. It refreshes every lane and presence record that carries the run's token, so
lanes taken after it started are covered, and in mode `on` it also drives the load
sample. It holds no fd to the parent, so a worker's `spawnSync` still ends, and it is
stopped on every exit path.

**Waiting.** When every lane is busy, or the fair share is 0, the caller waits, prints one notice naming
`bash bin/test-lanes-status.sh`, and fails closed with **exit 4** at the cap: 540 s
for find-tests (inside the 600 s Bash tool limit) and 1800 s for run-all, lowered to
`--deadline` when that is smaller. Exit 4 emits no `Results:` or `RUN_CONTRACT:` line.

**Nesting.** A holder exports `TEST_LANES_HELD`; its children skip the lease and run
at their requested width, so a test run under run-all never waits on its own parent.
`TEST_LANES=off` disables the lease, and the calibrator sets it so its measurements
are not narrowed. These two are the only cases where the rule does not apply: no
presence record is made and nothing is re-evaluated. Each prints `not applied
(TEST_LANES=off|nested under a lane holder); jobs N as requested`; with no per-run
cap the width is bounded by the run-all lane pool instead and the note says so.

**Unwritable cache directory.** When `slots/` cannot be created, the caller prints one
notice and runs without a lane at the width the rule allows, and it stops re-evaluating
the share. Load control is a courtesy between sessions, so a broken cache directory must
never block a test run.

**Write scope.** find-tests is auto-approved as a self-script. With the cache and lanes
it now writes, but only under the run-all cache directory: `corpus/` entries and their
retention, and `slots/` lanes, including reclaiming stale ones. run-all additionally
writes its presence record under `runs/` and the shared load sample and snapshot under
`load/`. Nothing is written in the repository.

## 4. Where things live

| Path | Role |
|---|---|
| `bin/lib/test-corpus-cache.sh` | Cache key, non-evaluating loader, atomic writer with retention |
| `bin/lib/test-host-lanes.sh` | Max jobs per host, width rule, lease, reclaim, heartbeat, release, status listing |
| `bin/lib/test-host-lanes-share.sh` | Presence records, fair share, re-evaluation, waiting for a share |
| `bin/lib/test-host-load.sh` | Load sample reader and writer, hysteresis, the pure external-load computation |
| `bin/lib/test-host-load-probe.sh` | Per-OS snapshot of the host counter and the process table |
| `bin/test-lanes-status.sh` | Read-only listing of lane holders and presence records |
| `tests/bin/feature-2455-test-load-control/` | Cache, lanes, run-all lease and fork-count cases |
| `tests/bin/feature-2687-test-host-lanes-share/`, `tests/bin/feature-2687-test-host-load/` | Fair share, re-evaluation and load scale-in cases |
