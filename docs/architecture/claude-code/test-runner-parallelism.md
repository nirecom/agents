# Test Runner Parallelism

How `tests/run-all.sh` runs the suite in parallel, and why each part is shaped the
way it is. What/Why only — the operator-facing surface reference lives in
`skills/run-tests/SKILL.md`, and the authoring rules for test files live in
`skills/_shared/test-design.md`.

## 1. Why this exists

A full sequential run of the suite takes roughly **56 minutes**. That number is the
whole motivation. At that length the full suite stops being something a session
runs and becomes something a session avoids, so regressions are found late — by the
commit gate, or by a later session, or not at all.

Almost every test in the corpus is I/O-bound rather than CPU-bound: it shells out,
writes into a `mktemp` sandbox, and waits. Wall time is therefore dominated by
latency that overlaps well, which is exactly the shape parallelism helps.

Two things had to survive the change, because the rest of the toolchain depends on
them:

- **The contract line.** `hooks/workflow-run-tests.js` reads the runner's stdout as
  a whole and requires *exactly one* `RUN_CONTRACT:` match with nothing but
  whitespace after it; `bin/worker-dispatch/workers/test-runner.js` concatenates
  stdout and stderr before parsing. If a second contract-shaped line ever appears,
  the commit gate stops being able to mark `run_tests` complete — silently.
- **Byte-identical stdout.** The stdout of `-j 8` must equal the stdout of `-j 1`,
  so that a failure is read the same way regardless of how the run was scheduled.

## 2. The slot scheduler

The scheduler lives inside `tests/run-all.sh` itself rather than delegating fan-out
to an external dispatcher. That choice was made on the contract invariant: with an
in-process scheduler, PASS/FAIL/SKIP tallying stays in the parent's variable space,
so "only the parent ever emits the contract line" is a structural consequence rather
than a rule someone has to remember. The rejected alternative — re-entrant worker
dispatch — would have had to touch both the emitter-identification logic and the
one-contract-line rule downstream, and breaking those fails *quietly*. Shell
compatibility problems, by contrast, fail loudly at startup. Prefer the visible
failure.

All three entry paths (`--all`, an explicit glob, and the default selection) build
one ordered list and feed the same scheduler (CPR-UNV). The list is never reordered.

Each job runs as a background subshell whose stdout and stderr go to separate files
in a `mktemp -d` work directory, and which writes its own exit code to `<i>.rc` via
an atomic `mv`. That `.rc` file — not a liveness check — is the single source of
truth for "this job finished". Liveness probing (`kill -0`) is deliberately not
used: an exited-but-unreaped child is a zombie that `kill -0` still succeeds on, so
it is simply the wrong predicate.

Output is replayed through a **submission-order cursor**: the parent advances
`next_print` and flushes job *i*'s captured streams only when job *i* has completed,
then prints the `PASS:` / `SKIP:` / `FAIL:` summary line. Because only the parent
ever writes to the real stdout, interleaving is structurally impossible rather than
merely unlikely, and the byte-for-byte equality with `-j 1` follows.

The scheduler makes no busy-wait and starts no resident background process — no
progress ticker, no background deadline watcher. Every wait is a blocking `wait`.

**Reaping and cleanup.** `set -m` is enabled just before the scheduler so each job
becomes its own process-group leader, which lets an abort kill a job's whole
descendant tree with `kill -- -<pgid>`; whether job control actually engaged is
*observed* (`case $- in *m*)`) rather than assumed. On abort, `cleanup_all` performs
a bounded escalation — TERM, one fixed `sleep 1`, then unconditional KILL — with no
`wait` and no liveness polling, so it cannot itself hang. It runs at most once per
process and only on the abort paths.

## 3. The serial lane

Some tests cannot share the machine with anything else. The runner never guesses
which ones: a test **declares** it.

    # Serial: <reason>

The declaration is written immediately after the `# Tags:` line, inside the first 10
lines. That position is not cosmetic — `bin/check-table-driven.sh` and
`tests/feature-689-frontmatter-convention.sh` both search only `head -10`, so the
line must not push `# Tests:` or `# Tags:` out of that window. The runner, by
contrast, scans the first **20** lines. Write narrow, read wide: a *missed*
declaration is the one fatal failure mode, so reception is deliberately more lenient
than emission. The narrow writer rule is enforced by
`tests/feature-1832-run-all-parallel/h-serial-header-convention.sh`.

When the cursor reaches a declared file the runner raises a **serial barrier**: it
announces the drain on stderr, reaps until zero jobs are in flight, replays
everything not yet printed, announces the file by name, runs that one file alone
through the same launch path, replays it, and then resumes parallel submission. The
list order is preserved throughout.

Authoring guidance and the canonical reason phrasings are in
`skills/_shared/test-design.md`; this document does not repeat them (CPR-SSOT).

### How the initial inventory was built

The first population of the serial lane was a one-time, three-layer exercise, and
the scripts were deliberately **not** committed — a permanent serial-detection
scanner is a non-goal, because it would drift into a second, competing source of
truth alongside the header itself.

- **Layer 1 — static detection.** A high-precision scan for shared-state hazards.
- **Layer 2 — measured real-tree contamination.** A sequential full run taking a
  `git status --porcelain` plus untracked-file snapshot before and after every test;
  anything that moved the working tree was declared serial. This is behavioural, so
  it is blind to neither quoting style nor helper indirection.
- **Layer 3 — measured order dependency.** Full sequential runs in forward and
  reverse order; any test whose verdict differed between them was declared serial.
  Two further `-j auto` full runs caught verdict flakiness.

When in doubt, the call goes to the serial side.

### Accepted Tradeoff

> Serial-lane static detection is deliberately limited to three high-precision axes.
> The fixed-ports and execution-order-dependency axes are **not** added: the full
> audit flags 114–225 files at roughly a 90% false-positive rate, and over-wide
> serial classification would cancel the parallelism gain this change exists to
> deliver. Residual risk is carried by human review plus the empirical layers.

## 4. Operator surfaces

| Surface | Accepted forms | Purpose |
|---|---|---|
| `-j` | `-j <N>`, `-j auto`, `--jobs <N>`, `--jobs=<N>` | Parallelism. `-j 1` is the retreat to the previous sequential behaviour. |
| `RUN_ALL_JOBS` | Same grammar as `-j` | Same setting from the environment. |
| `--deadline` | `--deadline <secs>`, `--deadline=<secs>`, `RUN_ALL_DEADLINE` | Whole-run wall-clock ceiling. |
| `RUN_ALL_PROGRESS` | `off` | Suppresses the stderr progress lines. |
| `RUN_ALL_REAP` | `auto` (default), `waitn`, `fifo` | Selects the slot-reaping mechanism. |
| `--print-plan` | — | Prints the plan and exits 0 without running anything. |

Precedence is **CLI > environment > default**. There is deliberately no `.env` or
`bin/get-config-var` layer for these (CPR-SSOT): one more place a parallelism value
could come from is one more place to look when a run behaves unexpectedly. Invalid
values produce one stderr line and **exit 2**, and never a contract line.

**Why the runner defaults to `-j auto` rather than requiring a flag.** The official
path into the suite is `/run-tests` → worker dispatch, and
`bin/worker-dispatch/spawn.js` builds a child environment from a fixed
`CHILD_ENV_ALLOWLIST` that contains no `RUN_ALL_*` entries. Any design where the
speedup depended on passing a new env var or a new payload field would therefore be
unreachable from the path that actually matters. Resolution is instead entirely
internal to `tests/run-all.sh`, and the only external input it needs — the
calibration cache — lives under `$HOME/.claude/run-all`, reachable because `HOME`
and `USERPROFILE` *are* on the allowlist.

**`--deadline` and why it exists.** `spawnSync` in the dispatcher passes a timeout
but no `detached` and no `killSignal`. On win32, libuv maps the default SIGTERM to
`TerminateProcess`, so bash's `trap` never runs and the descendants outlive the
parent. A trap cannot fix a problem that consists of traps not running, and a
post-mortem `taskkill /F /T` is unreliable in principle (the root is already dead, so
the PPID chain it walks is stale) and would require widening the dispatcher's
`EXTERNAL_COMMANDS` allowlist for every worker. So the runner folds itself up from
the inside instead: the worker derives `--deadline max(30, timeout_seconds − 5)` and
the runner checks the clock at two points — after each reap and before each launch.
On trip it prints one stderr line, runs `cleanup_all`, and **exits 3 emitting
neither a `Results:` line nor a `RUN_CONTRACT:` line**, because a partial run must
never present itself as a verdict. Downstream this is safe by construction: the hook
demotes `run_tests` to `pending` on a missing contract, and the worker renders it as
`status: fail` with `runContract: null`.

**Why `RUN_ALL_REAP` is user-visible at all.** `wait -n` does not exist before bash
4.3, so `auto` picks `waitn` at 4.3+ and the `fifo` path otherwise. The env var
exists so the fallback path can be exercised from any host — a portability fallback
that only runs on machines nobody develops on is a fallback nobody has tested.

## 5. Calibration, and why not core count

Parallelism is **not** derived from the CPU core count. Core count answers "how many
things can compute at once", but this corpus is I/O-bound: throughput is governed by
filesystem latency, antivirus scanning, and process-spawn cost, and on a Windows host
with real-time scanning enabled the knee of the throughput curve sits nowhere near
`nproc`. A core-count heuristic would be a confident number derived from the wrong
variable.

Instead the knee is **measured once, deliberately, by a separate tool** —
`bin/calibrate-test-parallelism.sh` — and the result is cached.

The hard rule is that a **normal run never falls through into measurement**
(invariant 4). The runner holds the calibrator's name only as a hint string in a
message; there is no code path from `run-all.sh` to the calibrator. A test run that
silently turned into a two-hour benchmark would be a far worse failure than a
slightly suboptimal `-j`.

The calibrator samples a deterministic, evenly-spaced subset of non-serial tests,
runs a warmup pass whose numbers are discarded (so filesystem and scanner warm-up
lands outside the measured region), repeats each `-j` value three times with
alternating ascending/descending order to cancel ordering bias, and aggregates by
**median** wall time rather than mean. The chosen `-j` is the smallest one reaching
95% of peak throughput. A stability gate refuses to write the cache — stderr reason,
exit 1 — when the spread across repeats exceeds 1.5×, or when the FAIL count moved
between trials. An unstable measurement is worse than no measurement, because it
would be trusted.

**The cache is untrusted input.** It is the one thing `-j auto` reads from outside
the repository, so `bin/lib/run-all-parallelism.sh` parses it without `source`,
without `eval`, and without `.` — a `read -r` loop plus `case` glob matching that
never expands a value and never does arithmetic on an unvalidated token. Exactly
seven keys are allowed (`schema`, `host_id`, `count_bucket`, `jobs`, `measured_at`,
`sample_size`, `repeat`); an unknown key, a duplicate key, a missing key, or an
out-of-class value invalidates the whole file. Injection payloads are rejected as
data.

Failure is reported as exactly one **fixed enum token** (`missing`, `unreadable`,
`malformed`, `unknown-key`, `duplicate-key`, `schema-mismatch`, `host-mismatch`,
`bucket-mismatch`, `bad-jobs`) and the run continues at the conservative fixed
`RUN_ALL_FALLBACK_JOBS=4`. Fixed tokens matter for two reasons: they keep untrusted
file content out of the runner's own output, and they keep that output structurally
incapable of resembling a contract line.

`host_id` is `<os>|<arch>|<digest-of-hostname>` and is **compared, never displayed** —
the hostname is digested so that no machine name, user name, or filesystem path can
reach a file in a public repo. `count_bucket` is `floor(log2(corpus size))`, coarse
on purpose: adding a handful of tests should not invalidate a measurement, while a
change of an order of magnitude should.

## 6. Historical duration ledger and LPT ordering

Submission order inside the parallel lane is Longest-Processing-Time-first (LPT):
the slowest tests start first, so they run alongside everything else instead of
being the lone straggler that decides the wall-clock floor at the end of a run.
LPT needs a duration to sort by, so the runner keeps a small cross-run ledger of
its own — `bin/lib/run-all-durations.sh`, sourced only after
`bin/lib/run-all-parallelism.sh` (it reuses that library's host/repo identity
helpers) and only best-effort: any failure to load, read, or write the ledger
degrades to the pre-existing glob order, never to an error.

**Keying and identity.** Every test file resolves to a repo-relative key (or a
bare basename when it falls outside `TESTS_DIR`); a byte class that would break
the on-disk record format (`|`, TAB, CR) rejects the key outright rather than
mangling it. Segments are namespaced by a 16-character host token and a
16-character repo id, both digests — never the hostname or the repo path — so
records from a different machine or a different checkout of a same-named repo
can never be misread as this one's history, mirroring the parallelism cache's
own host-digest discipline (Section 5).

**Read path (before the sort).** For every test in the plan, `init_tiers`
looks up its key's most recent duration across the newest
`RUN_ALL_DUR_MAX_SEGMENTS_READ` segment files and buckets it into a tier —
`floor(log2(seconds))`, coarse for the same reason `count_bucket` is coarse in
the parallelism cache: small timing noise should not reshuffle the plan. A key
with no history gets the sentinel `UNMEASURED` tier. `sort_work_lpt` then
bucket-sorts the parallel-lane slots unmeasured-first, then longest-tier-first,
stable within a tier — so a ledger with no history yet reproduces the original
glob order exactly, and the ordering only ever affects the parallel lane: the
serial lane's positions are pinned before the sort runs, because the barrier
semantics in Section 3 are positional.

**Write path (after each test).** Each job now measures its own wall time
(`$SECONDS` before and after the child, in `launch`) and writes it to `<i>.dur`
*before* `<i>.rc` — `.rc` stays the sole completion signal (Section 2), so a
harvest that observes `.rc` always finds a finished `.dur` beside it. On
harvest, `ledger_record` lazily creates this process's own segment file on the
first completed test (a run that executes nothing leaves no ledger behind) and
appends one `<repo_id>|<seconds>|<key>` line. Segments are one-per-writer-process
and append-only — never rewritten in place — so concurrent `run-all` invocations
(nested suites, parallel sessions) cannot corrupt each other's history; a
retention sweep trims each host/schema class to the newest
`RUN_ALL_DUR_KEEP_SEGMENTS` segments whenever a new one is created.

**Why this is safe to bolt onto an already-deterministic scheduler.** The
byte-identical-stdout invariant (Section 1) constrains *output*, not
*submission order* — LPT only changes which slot a test lands in among the
parallel lane, never what it prints or how the contract line is assembled.
`--print-plan` reports the resolved tier per test so a reordering is auditable
before a real run commits to it.

## 7. Contract-line neutralization

A child test may legitimately print a line that looks like a contract line — some
tests exist precisely to exercise the contract parser. Under the old sequential
runner such a line was already a latent hazard; under replay it is guaranteed to
reach the parent's stdout. Since the downstream parsers require *exactly one* match,
one such line is enough to break the commit gate.

Replay therefore never uses `cat`. Every captured stream goes through
`neutralize_stream`, a single awk process that prefixes `[run-all:neutralized] ` onto
any line matching `^[ \t]*RUN_CONTRACT:` — applied to **both** the stdout and the
stderr replay, because the worker concatenates the two before parsing.

Three properties make this the right shape:

- The match condition ignores the numeric fields entirely. It is a deliberate
  superset of both downstream regexes, so it cannot be narrower than what it must
  defend.
- Only a prefix is added; the original bytes remain intact behind it, so a run
  remains auditable with `grep -n 'run-all:neutralized'`.
- It cannot break a child's assertions. Only bytes the parent replays *after* the
  child has already exited are rewritten; every child decides its own verdict inside
  its own process. The only tests that could be affected are those that run
  `run-all` as a child and count contract lines in its output.

Two costs are accepted: a file with no trailing newline gains one, and output
containing NUL bytes is not covered. Both apply uniformly regardless of `-j`, so
determinism is preserved, and awk costs no extra process over the `cat` it replaced.

## 8. Known residual risks

- **A single hung test occupies a slot indefinitely.** A per-test timeout ceiling is
  a non-goal here; the mitigations are the stderr progress lines (which name the
  occupying file) and the whole-run `--deadline`.
- **Windows worker timeout, fully in-flight hang.** `--deadline` covers "the suite is
  merely slower than the budget". The one uncovered case is every in-flight job
  hanging at once so that the reap never returns, at which point `spawnSync`'s
  timeout terminates the parent bash without a trap.
- **Exit 2 and exit 3 are new.** Both are safe downstream: any non-zero exit demotes
  `run_tests` to `pending`, and via the worker both surface as `status: fail` with a
  null contract.

## 9. Where things live

| Path | Role |
|---|---|
| `tests/run-all.sh` | Scheduler, argument surface, serial barrier, progress, `--print-plan`, `--deadline`, `neutralize_stream`, process-group reaping, bounded abort, cache read, LPT sort, duration measurement |
| `bin/lib/run-all-parallelism.sh` | SSOT for the cache schema and its non-evaluating parser; sourced, never executed |
| `bin/lib/run-all-durations.sh` | SSOT for the per-test duration ledger schema, key/tier computation, and the append-only segment reader/writer; sourced, never executed |
| `bin/calibrate-test-parallelism.sh` | The measurement tool; unreachable from a normal run |
| `bin/worker-dispatch/workers/test-runner.js` | Prepends `--deadline` and `-j` when building the runner argv |
| `tests/feature-1832-run-all-parallel/` | The suite covering every invariant above |
| `skills/_shared/test-design.md` | Author-facing `# Serial:` rules |
| `skills/run-tests/SKILL.md` | Operator-facing `/run-tests` procedure and payload rules |

## 9. Corollary: per-test-file spawn discipline

§1 established that the corpus is I/O/process-generation-bound, not CPU-bound, at the
runner level. The same argument applies inside a single test file's own process-spawn
budget: a dispatcher-plus-cases suite can independently multiply its own wall-clock by
orders of magnitude regardless of `-j`. Three criteria decide whether a given test file
is subject to this:

1. The shell library under test must not be re-sourced once per assertion/case —
   sourcing forks and re-parses on every call.
2. Fixture git repositories must not be created once per test case — `git init` and its
   companion setup calls must be confined to a fixture helper the case files call
   through, never issued directly by each case.
3. Both are mechanically observable, not a matter of taste: counting per-call helper
   invocations (e.g. `dirname`) and counting `git init` occurrences across a run
   distinguishes a per-suite/per-helper-call cost from a per-case one.
