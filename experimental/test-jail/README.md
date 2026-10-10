# test-jail (experimental)

Status: **experimental — under trial, not a finished tool.** Tracking issue: #2585.
Nothing here is installed, put on `PATH`, or called by the workflow. Interfaces may change.

## What it is

Runs tests one at a time inside a light jail, without a virtual machine: only environment
variables and `PATH` are swapped. It was written during #2561 to compare a changed tree with
an export of the pre-change commit while `tests/run-all.sh` could not be used.

| Script | Role |
|---|---|
| `run-jailed.sh` | One test in the jail. `--pin none\|state\|full` selects how much of the `tests/run-all.sh` pinning is applied (`full` = state/plans dirs + root decoy). |
| `run-list.sh` | A list of tests through `run-jailed.sh`, in parallel on leased host test lanes. |
| `run-one.sh` | Worker of `run-list.sh`: one log + one result line per test. |
| `compare-runs.sh` | Classifies the red tests of one run against a baseline run, and lists the tests the changed run has no result for. |
| `new-fail-digest.sh` | First new FAIL lines per test of a `compare-runs.sh` result. |
| `decoy-summary.sh` | Root decoy hits of a run. |
| `time-pin-cost.sh` | Times one test under each pin mode. |
| `trace-stub.js` | Used by `run-jailed.sh --trace` to record who reached a decoy file. |

## What the jail does

- Replaces the real `gh`, `glab`, `codex` and `claude` with stubs that print a `SAFE-RUN:` line and exit 97; refuses to start when the replacement did not take effect (exit 96).
- Points `HOME` and `USERPROFILE` at a temp dir.
- Unsets forge tokens, agent API keys, the ssh agent socket and the live session id; disables git credential prompts and git over ssh.
- Refuses by name the tests that reach outside by design, and any test path that is not a plain tree-relative path (exit 95).
- Applies the per-run pins of `tests/run-all.sh` from the tree's own `bin/lib/run-all-launch.sh`; a test that passes but reached the root decoy exits 92.

A `SAFE-RUN:` line in a log is a breach or a refusal: read it before trusting that run.

## Known gaps

- Not a filesystem jail: a test that writes to an absolute path is not stopped.
- `codex` and `claude` are shadowed by name only: a native spawn that names `codex.exe` or `claude.exe` is not stopped.
- Shims on `PATH` that forward to another checkout still run code outside the jailed tree.
- `run-list.sh` records a breach and keeps going; it lists the affected logs only at the end.

## Usage

```bash
bash experimental/test-jail/run-jailed.sh --probe
bash experimental/test-jail/run-jailed.sh --timeout 600 tests/bin/<name>.sh
bash experimental/test-jail/run-list.sh <list-file> <run-dir> <tree> 15 full 300
bash experimental/test-jail/compare-runs.sh <changed-run-dir> <baseline-run-dir> <out-dir>
```

`<tree>` may be a checkout or a plain export of a commit; it defaults to this checkout.
