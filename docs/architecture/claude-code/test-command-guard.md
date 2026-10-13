# Test Command Guard

How a test run is kept from writing to real repositories and from reaching real network CLIs, and how a change to a protected tree is still noticed when something slips past.

The root decoy ([root-names.md](root-names.md) "The decoy tree") catches a test that reaches a tool through a root name. It cannot catch a test that runs `git commit` in the developer's checkout or calls the real `gh`: neither needs a root name. Three layers cover that gap: a run root every test writes in, a command guard that judges each `git`, `gh`, `glab` and `codex` call, and worktree change detection around each test.

## The run root

`tests/lib/test-run-root.sh` (`test_run_root_ensure`) gives a run one directory it may write in.

- `TEST_RUN_ROOT` is reused when set; otherwise a fresh `run-<pid>-<rand>` is made under `<TEST_HOST_TMPDIR>/agents-test-runs-<user>`. `run-*` directories older than a day are removed there first.
- `TEST_HOST_TMPDIR` records the temp area the run started from, before the pin below moves it.
- `TMPDIR`, `TMP` and `TEMP` are pinned to `<run root>/tmp`, so `mktemp`, `make_tmp` and `os.tmpdir()` all land inside the run root. `TMPDIR` stays in POSIX form under MSYS; `TMP` / `TEMP` take the Windows form native tools read.
- Build caches (the root decoy, the guard binaries) sit under `<TEST_HOST_TMPDIR>/agents-test-cache-<user>`, never under `$HOME`. `tests/lib/test-cache-base.js` owns that path.

`test_run_root_ensure` and `command_guard_ensure` record what they pinned (`_TEST_RUN_ROOT_PIN`, `_COMMAND_GUARD_PIN`). When nothing has moved since, a nested harness load reuses the pin without converting any path again, because each `cygpath` call is a process on Windows.

`tests/run-all.sh` passes its own work directory as the run root, so the run root is removed with it. A test started on its own creates a run root through the harness and leaves it behind; the one-day cleanup above removes it on a later run.

## The command guard

`tests/lib/command-guard.sh` (`command_guard_ensure`) puts `<run root>/command-guard/bin` first on `PATH`. That directory answers for `git`, `gh`, `glab` and `codex`. Every binary there reads its settings from `../guard.conf` (the real git, node, the allowed root, the read verbs, the fast write path lists), never from the environment the test controls.

| Call | Outcome |
|---|---|
| `gh`, `glab`, `codex` | always refused |
| `git` with a network URL (push, fetch, pull, ls-remote, clone, submodule) | refused |
| `git` read verb (`status`, `log`, `rev-parse`, `diff`, …) without `--output` | runs the real git directly |
| `git` write whose every target (repository, git dir, index, worktree, output file, global config) sits under the run root | runs the real git |
| any other `git` write | refused |

### The fast write path

Most git writes in tests are `commit`, `add` or `config` in a fixture repo under the run root. Starting node for each of them roughly tripled their cost. So a write whose only target is its own repository skips `main.js` when every one of these holds:

- the verb comes first, or after nothing but `-C <dir>` / `-c <name=value>` pairs, and is in `classify.js` `FAST_WRITE_VERBS`;
- no argument after those pairs starts with a `FAST_DENY_PREFIXES` entry (`--global`, `--file`, `-f`, `--output`, …);
- none of `FAST_DENY_ENV` is set (`GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_COMMON_DIR`, `GIT_CONFIG`).

The binary then asks the real git, with the same pairs (as `main.js` passes its globals), for `rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel`. When all three paths sit under an allowed root, with no symlink or junction between the root and the path, it runs the real git. Any doubt falls through to `main.js`, so the fast path can only allow what `main.js` would allow. The lists reach the binaries through `guard.conf` (`fastverbs=`, `fastdeny=`, `fastdenyenv=`).

A refusal exits 97, prints `command guard: refused …` to stderr, and leaves one hit file under `<guard dir>/hits/` naming the tool, the test (`ROOT_DECOY_TEST_ID`), the target and the arguments. The decision lives in `tests/lib/command-guard/` (`classify.js` for the verb, `resolve-target.js` for the targets, `main.js` for the verdict).

### Sentinel and git write guard on POSIX

On Linux and macOS each binary is a small bash script written by `tests/lib/command-guard-build.js`. A git read, or a write that passes the fast write path, is classified in bash and `exec`s the real git without starting node; everything else runs `main.js`. Without node the script still records a hit and exits 97, so a broken guard fails closed.

### The Windows launcher

On Windows the binaries are one C# launcher (`tests/lib/command-guard/launcher.cs`, built once with the .NET Framework `csc.exe` and copied to `git.exe`, `gh.exe`, `glab.exe`, `codex.exe`). An executable is needed because:

- Node's shell-less `spawn` / `execFile` on Windows resolves only `.exe` and `.com`, so a script on `PATH` would be skipped and the real tool found behind it.
- `cmd /c` and PowerShell resolve through `PATHEXT`, which an exe also satisfies.
- The guard cannot rely on `NODE_OPTIONS` (a preload that patches `child_process`): a worker-dispatch child drops it, and `env -i` or a test's own `NODE_OPTIONS` replaces it.

The launcher passes the rest of its command line on verbatim, so quoting is never rebuilt. It moves `NODE_OPTIONS` aside before starting `main.js` (a test's preload must not run inside the guard) and hands it back to the real git. A job object ties the child to the launcher, so a timeout that kills the launcher also stops node and git.

### Leaving the guard

`command_guard_use_real` takes every guard bin off `PATH`. Only TL3 / TL4 tests that must reach the real tools call it.

## Worktree change detection

`bin/lib/run-all-worktree-change-detect.sh` protects the main worktree (the parent of the common git dir) and the checkout the launcher was loaded from; the two collapse to one when they are the same. Around every test the launcher takes a fingerprint of each tree with the real git:

- `git --no-optional-locks status --porcelain=v2 --branch -uno`;
- the blob hash (`hash-object --stdin-paths`) of each tracked file modified in the worktree;
- the repository's local `config` and the worktree's `config.worktree`.

A difference is logged as `<tree><TAB><test id><TAB><kind>`:

| Kind | What changed |
|---|---|
| `tracked` | the set of changed tracked paths, or their status letters |
| `content` | the content of a file that was already modified |
| `head` | `HEAD` or the branch |
| `index` | a staged object, with the status letters unchanged |
| `config` | the local or worktree config |

With more than 500 modified tracked paths the content comparison is skipped and the report says so. When tests ran in parallel, every test whose interval saw the change is named, with a note that each is only a candidate.

## Install points and the hit report

| Where | What is pinned |
|---|---|
| `tests/lib/harness.sh`, on load | the run root, then the guard (after the root decoy) |
| `bin/lib/run-all-launch.sh` `run_all_pin_test_env <work dir>` | the work dir as the run root, the decoy, the guard (`run_all_pin_command_guard`), worktree change detection |
| `bin/lib/run-tests-baseline-exec.sh` | the same per base test, with the run root in the test's isolation dir |

`run_all_hit_report` runs once per run and prints three kinds of lines to stderr, each counting as a failure of the run:

```
[run-all] root decoy hit: <tree>/<stub><TAB><test id>
[run-all] command guard hit: <tool><TAB><test id><TAB><target>
[run-all] worktree change: <tree><TAB><test id><TAB><kind>
```

`tests/run-all.sh`, `bin/lib/run-tests-baseline-exec.sh` and `experimental/test-jail/run-jailed.sh` call it.

## Limits

- R2: a test that rebuilds `PATH` from scratch, or calls git by an absolute path, bypasses the guard. Worktree change detection still sees what it did to a protected tree.
- R8: untracked files are not watched (`-uno`), so a test that only creates an untracked file in a protected tree is not named. A developer editing a protected tree while the run is going makes the report name whatever test was running at the time.
- A repository or fixture made outside `TMPDIR` (for example under a hard-coded `/tmp`) is outside the run root, so git writes into it are refused.
