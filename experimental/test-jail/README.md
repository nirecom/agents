# test-jail (experimental)

Status: **experimental — under trial, not a finished tool.** Tracking issue: #2585.
Nothing here is installed, put on `PATH`, or called by the workflow. Interfaces may change.

## What it is

Runs tests one at a time inside a light jail, without a virtual machine: only environment
variables and `PATH` are swapped. It was written during #2561 to compare a changed tree with
an export of the pre-change commit while `tests/run-all.sh` could not be used.

| Script | Role |
|---|---|
| `run-jailed.sh` | One test in the jail. `--pin none\|state\|full` selects how much of the `tests/run-all.sh` pinning is applied (`full` = state/plans dirs + root decoy). `--allow-weaker-pin` lets a tree that cannot give that pin run under the strongest one it has. |
| `run-list.sh` | A list of tests through `run-jailed.sh`, in parallel on leased host test lanes. The 7th argument `[weaker-pin]` is `deny` (default) or `allow`. Copies the list to `<run-dir>/requested.txt`. |
| `run-one.sh` | Worker of `run-list.sh`: one log + one `results.tsv` line per test (`rc`, seconds, test, and the pin really obtained: `full`, `state`, `none` or `unknown`). |
| `compare-runs.sh` | Classifies the red tests of one run against a baseline run and ends with a `VERDICT:` line; see [Reading a comparison](#reading-a-comparison). |
| `jail-marker.sh` | Source-only part of `run-list.sh` and `compare-runs.sh`: writes the `.test-jail-dir` marker into an output directory the tool itself made, and lets only such a directory be replaced. |
| `new-fail-digest.sh` | First new FAIL lines per test of a `compare-runs.sh` result. |
| `decoy-summary.sh` | Root decoy hits of a run. |
| `time-pin-cost.sh` | Times one test under each pin mode and prints the pin each run obtained. `JAIL_ALLOW_WEAKER_PIN=1` passes `--allow-weaker-pin`. |
| `trace-stub.js` | Used by `run-jailed.sh --trace` to record who reached a decoy file. It records the four root names of `docs/architecture/claude-code/root-names.md` and the retired ones, by exact name. |

## What the jail does

- Replaces the real `gh`, `glab`, `codex` and `claude` with stubs that print a `SAFE-RUN:` line and exit 97; refuses to start when the replacement did not take effect (exit 96).
- Points `HOME` and `USERPROFILE` at a temp dir.
- Unsets forge tokens, agent API keys, the ssh agent socket and the live session id; disables git credential prompts and git over ssh.
- Unsets the retired root-name variables. The names are read from this checkout's `tests/lib/root-decoy-build.js`, never from `--tree`; the jail refuses to start when it cannot read them (exit 96). Under `--pin none` and `--pin state` they stay unset; under `--pin full` the root decoy sets them again, pointing at the decoy.
- Refuses by name the tests that reach outside by design, and any test path that is not a plain tree-relative path (exit 95).
- Applies the per-run pins of `tests/run-all.sh` from the tree's own `bin/lib/run-all-launch.sh`; a test that passes but reached the root decoy exits 92.
- Stops with a `SAFE-RUN: pin unmet` line and exit 94 when the tree's launcher lacks the pin function asked for. Only `--allow-weaker-pin` lets the run go on under a weaker pin.
- Prints the pin it applied as the first `PINNED:` line of the log: `PINNED: obtained=<full|state|none> requested=<full|state|none> <detail>`.

A `SAFE-RUN:` line in a log is a breach or a refusal: read it before trusting that run.

## Known gaps

- Not a filesystem jail: a test that writes to an absolute path is not stopped.
- Native spawns of the agent CLIs are stopped only in part:
  - `--pin full`: the command guard of `tests/run-all.sh` sits first on `PATH`, refuses a spawn that names `codex` or `codex.exe` (exit 97) and reports the hit, so a test that would otherwise pass ends with exit 92 (a test that passes the 97 on keeps it).
  - `--pin state` and `--pin none`: no guard. `codex` is shadowed by name only, and a native spawn that names `codex.exe` is not stopped.
  - `claude` is outside the guard: under every pin it is shadowed by name only, and a native spawn that names `claude.exe` is not stopped.
  - A spawn by absolute path is stopped by nothing here, the guard included (`docs/architecture/claude-code/test-command-guard.md`).
- Shims on `PATH` that forward to another checkout still run code outside the jailed tree.
- `run-list.sh` records a breach and keeps going; it lists the affected logs only at the end.

## Usage

```bash
bash experimental/test-jail/run-jailed.sh --probe
bash experimental/test-jail/run-jailed.sh --timeout 600 tests/bin/<name>.sh
bash experimental/test-jail/run-jailed.sh --pin full --allow-weaker-pin tests/bin/<name>.sh
bash experimental/test-jail/run-list.sh <list-file> <run-dir> <tree> 15 full 300
bash experimental/test-jail/run-list.sh <list-file> <run-dir> <tree> 15 full 300 allow
bash experimental/test-jail/compare-runs.sh <changed-run-dir> <baseline-run-dir> <out-dir>
```

`<tree>` may be a checkout or a plain export of a commit; it defaults to this checkout.

### Output directories

`<run-dir>` and `<out-dir>` are deleted and made again on each run. That happens only when the
path is missing, is an empty directory, or holds the `.test-jail-dir` marker of the same kind
(`run` or `compare`) that the tool wrote when it made the directory. Any other existing path
stops the run with an `ABORT:` line and exit 2: choose a new output path, or delete the
directory yourself. A run dir or compare dir made before the marker existed is such a path.
The directories `compare-runs.sh` only reads need no marker.

### Comparing against an old tree

A tree without the pin functions (an export of an old commit) cannot give `--pin full` or
`--pin state`, so a run of it ends each test with exit 94 and a `SAFE-RUN:` line.

- To compare such a tree with another, take **both** sides with `--pin none` (5th argument of
  `run-list.sh`). Both then obtain the pin they asked for, and the comparison is usable.
- `--allow-weaker-pin` (`allow`) is not a way to compare. It only lets a run finish and be
  recorded: `compare-runs.sh` lists its tests as `WEAK-PIN` and does not compare them, so that
  comparison always ends `INCOMPLETE`.

### Reading a comparison

`compare-runs.sh` ends with one of three verdicts:

| Verdict | Exit | Meaning |
|---|---|---|
| `NEW-RED` | 1 | At least one trusted comparison is red in the changed run (`summary.tsv`). |
| `INCOMPLETE` | 3 | No trusted red, but `not-compared.tsv` holds at least one line. |
| `NO-NEW-RED` | 0 | Neither. |

A comparison that cannot be trusted is listed in `not-compared.tsv` with one reason and has
no `summary.tsv` row: it is counted neither red nor green, so it can never make the verdict
`NEW-RED`. The one exception is a red test of a refused run: it keeps a `REFUSED` row in
`summary.tsv`, which is not a red class. The count in the `NEW-RED` line covers trusted comparisons only. Reasons, in the
order they are tried (a test gets the first that applies):

| Reason | When |
|---|---|
| `REFUSED` | The jail refused the red test in either run (exit 95 or 96). |
| `SAFE-RUN-LINE` | Either log holds a `SAFE-RUN:` line, whatever the exit code. |
| `NO-LOG` | A result row of either run has no log file, so the run cannot be shown free of a `SAFE-RUN:` line. |
| `SKIPPED-IN-CHANGED` | The changed run skipped the test (exit 77). A skip in the baseline alone still counts as a green baseline. |
| `UNVERIFIED-PIN` | The 4th `results.tsv` column of either run is `unknown` or missing. |
| `WEAK-PIN` | A run obtained another pin than it asked for, or the two runs obtained different pins. |
| `NO-RESULT-ROW` | The test is in `requested.txt` and present in the changed tree, but one of the runs has no result row for it. |
| `NO-REQUESTED-LIST` | The changed run dir has no `requested.txt`; one line for the whole run. |
| `ABSENT-IN-CHANGED-TREE` | The test file is not in the changed tree. |
| `BASELINE-ONLY` | Only the baseline run has a result row. |

Run dirs made before the 4th column existed (three columns, no `requested.txt`) therefore
always compare as `INCOMPLETE`: take both runs again.
