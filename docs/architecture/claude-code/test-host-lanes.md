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
offer and load scale-in. The run-all per-run lane cap below applies in both modes.

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

### Run-all per-run lane cap, slow start and the lane allocation

Each run-all keeps a presence record `runs/run.<token>` (the lane owner format plus its
demanded max jobs per run and its own max jobs per host) and refreshes it with the same
heartbeat as its lanes. The records, ordered by start, make up the **active run count**,
waiting runs included. Presence records go stale and are reclaimed by exactly the lane
liveness rule below, through the same reclaim function.

**One allocator per host.** Each heartbeat, the run that holds the claim on the run-all
lane allocation sample (`load/sample` under the run-all cache directory) measures the
host once and decides every run's width in the same step, then writes one row per run
token (`alloc.<token>=<width> <ssthresh> <cap> <decided_by>`; sample generation 2).
Every other run only reads its own row. Measurement and allocation are serialized by the
claim, so all widths come from the same input and sum to within the pool; no resident
process is needed. A run on pre-#2692 code rejects generation 2 and falls back to the old
per-run computation; lane acquisition is atomic, so lanes are never double-held.

- The run-all lane pool is the smallest max jobs per host among the present records,
  minus 1, minus the load scale-in, capped by the memory limit, never below 1. Taking the
  smallest keeps a worktree whose `.env` differs from widening the budget (#2545).
- Each run's **run-all per-run lane cap** is a max-min split of that pool, capped at its
  max jobs per run (unlimited means the test count). Remainders and the unused part of a
  capped run go one by one to the earliest runs. It is computed from demand, not from
  current widths, so a late run's share stays reserved. Example, max jobs per host 12 and
  no per-run cap: 1 run gets 11, 2 get 6 and 5, 3 get 4, 4 and 3.
- When the active run count exceeds the pool, the first pool runs get 1 and the later
  ones get 0 and wait for a lane.
- **Slow start** (RFC 5681) sets the width inside the cap. A new run starts at 4 lanes,
  limited by its cap and the free lanes. At each new sample the width doubles below
  ssthresh and grows by 1 at or above it, up to the cap. It grows only when the sample is
  measured, the previous sample was fresh, no load scale-in or memory limit applies, a
  host lane is free and the run has used up its current width. It drops straight to a new
  lower cap; a CPU or memory limit also lowers ssthresh to that cap (at least 2). A stale
  or failed sample keeps every width. A run with no row yet takes only its initial width
  from free lanes until the next sample, a delay of one heartbeat at most. Even a lone run
  needs several heartbeats to reach the full cap; the cost is accepted so that a start-up
  burst of sessions cannot promise lanes it cannot give.
- **decided_by** names what set the width: `per-run-cap`, `cpu-load-limit` (load
  scale-in), `memory-limit`, or `slow-start` (still growing). The run-all lanes log
  (`per-run lane cap N among M runs, decided by <x>`) and the status line show the same
  token.
- find-tests takes 1 lane, searching from the max jobs per host downward, so the last
  lane stays free for it; it is not subject to slow start. The single exception to the
  pool formula is a max jobs per host of 1: the pool is still 1, because run-all could
  not move otherwise, and with the find-tests lane the host may briefly hold one lane more.
- A run-all starts its heartbeat before it asks for a lane, so waiting is covered. It
  waits while its start width is 0 (one notice), bounded by the wait cap below.
- A run re-evaluates at each new run-all lane allocation sample and at every entry-script
  end: it reads its own row, then takes free lanes (one reclaim sweep, never a wait) or
  releases the highest-numbered lanes down to the larger of the row's width and the jobs
  still running. Both keep the run's token, so release at exit covers lanes taken later.
- With nothing running and a width of 0, the run polls until a lane is available. The
  wait is not capped by the wait cap but honors the run deadline.
- `--print-plan` applies the same width rule without a lease, and
  `bin/test-lanes-status.sh` lists presence records and their rows beside the lanes.

Running jobs are never stopped, so a run with long entry scripts holds more than its cap
until they finish; later runs get less, or wait, meanwhile.

### Why slots, and why load scale-in on top

Slots stay the one mechanism that enforces concurrency: deterministic, cheap and
OS-independent. Earlier, CPU measurement and external load were out of scope, because
measuring on Windows meant launching PowerShell at every acquisition. That reason does
not hold when the host takes one sample per heartbeat period, so load scale-in was
added **on top of** the lanes: it only lowers the pool.

**External load and reserved cores.** External load is the summed CPU of the live
processes, in logical CPUs, minus the **agents internal** processes: every run-all test
process tree, and processes whose executable name is exactly `claude` (case-insensitive,
optional `.exe`) with their descendants. Names match exactly, never by substring (a
substring match once misclassified third-party tools). Short-lived processes are not
counted, so external load can read low (accepted: the earlier overestimate, which counted
Claude Code and test children as load, shrank the pool far more often). Host-wide CPU is
used only to sanity-check a sample and for the status display. **Reserved cores** are the
logical CPUs minus the calibrated max jobs per host (4 on the reference host); the tests
may run at full width while that many cores stay free for other applications. Load
scale-in therefore ignores external load up to the reserved cores and removes one lane
per whole core above them (1 lane back per core when it falls again).

**Who measures.** The claim holder takes one snapshot per heartbeat (atomic `load/.claim`
directory, reclaimed after 3 heartbeats; the claim records its holder's heartbeat, which
the reclaimer uses). A tick that outlives 2 heartbeats is void and writes nothing, so a
reclaimed holder cannot overwrite its successor's sample. Host-wide quantities (per-CPU
times, free and total memory) come from node's host API on all three OSes; per-process
quantities (pid, parent, name, CPU, memory) come from `/proc` on Linux, one PowerShell
call on Windows (bounded to the shorter of 20 s and one heartbeat) and `ps` on macOS.
Every run reads the sample with the non-evaluating reader and ignores one older than 3
heartbeats (stale: widths are held, never grown).

**Memory limit.** Free memory means memory available at once (Linux `available`
equivalent on every OS). When it falls below the reserve, max(2048 MB, 10% of total),
the lanes shed are ceil((reserve - free) / per-lane), where per-lane is the larger of
512 MB and the tests' own memory divided by the lanes they hold; the limit is the held
lanes minus that, at least 1, and the smaller of it and the CPU pool wins. Above the
reserve, or when memory cannot be measured, there is no limit.

**Unmeasurable.** An unreadable probe, a malformed snapshot, a missing previous snapshot
or a counter that went backwards makes the sample `unmeasurable`: nothing shrinks and
nothing grows.

**Hysteresis.** The pool shrinks by the whole cores of external load above the reserved
cores once that excess is at least 100 centicores for 2 consecutive samples, and returns
after 3 consecutive samples below 50. Values in between hold the state, so one spike or
one lull does not move the pool.

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
lanes taken after it started are covered, and in mode `on` the claim holder also
drives the run-all lane allocation sample. It holds no fd to the parent, so a worker's `spawnSync` still ends, and it is
stopped on every exit path.

**Waiting.** When every lane is busy, or the start width is 0, the caller waits, prints one notice naming
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
the lane width. Load control is a courtesy between sessions, so a broken cache directory must
never block a test run.

**Write scope.** find-tests is auto-approved as a self-script. With the cache and lanes
it now writes, but only under the run-all cache directory: `corpus/` entries and their
retention, and `slots/` lanes, including reclaiming stale ones. run-all additionally
writes its presence record under `runs/` and the shared run-all lane allocation sample and snapshot
under `load/`. Nothing is written in the repository.

## 4. Where things live

| Path | Role |
|---|---|
| `bin/lib/test-corpus-cache.sh` | Cache key, non-evaluating loader, atomic writer with retention |
| `bin/lib/test-host-lanes.sh` | Max jobs per host, width rule, lease, reclaim, heartbeat, release, status listing |
| `bin/lib/test-host-lanes-share.sh` | Presence records, run-all per-run lane cap, re-evaluation, waiting for a start width |
| `bin/lib/test-host-alloc.sh` | Claim holder's allocation: memory limit, slow start, `decided_by` |
| `bin/lib/test-host-load.sh` | Claim, hysteresis, the pure computation of external load |
| `bin/lib/test-host-load-sample.sh` | Reader and writer of the run-all lane allocation sample (generation 2) |
| `bin/lib/test-host-load-probe.sh` | Per-OS process table (name, CPU, memory) and host quantities |
| `bin/lib/test-host-lanes-status.sh`, `bin/test-lanes-status.sh` | Read-only listing of the pool, the sample, lane holders and presence records |
| `tests/bin/feature-2455-test-load-control/` | Cache, lanes, run-all lease and fork-count cases |
| `tests/bin/feature-2687-test-host-lanes-share/`, `tests/bin/feature-2687-test-host-load/` | Cases for the run-all per-run lane cap, re-evaluation, claim and load scale-in |
| `tests/bin/feature-2692-test-host-alloc/`, `tests/bin/feature-2692-test-lanes-status.sh` | Slow start, memory limit, stale sample, `decided_by` and status cases |
