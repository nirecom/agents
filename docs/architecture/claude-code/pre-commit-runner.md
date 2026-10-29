# Pre-commit Runner

`hooks/pre-commit` used to be a bash script that sourced several libraries and spawned git and a
checker process per check and often per file; on a large staged set the hook ran for minutes
(#2507). The checks now run in one Node process over one read of the index, so the cost
grows with the staged bytes, not with the number of processes.

## Layout

| Path | Role |
|---|---|
| `hooks/pre-commit` | Bash entry. Blocks when `node` is missing, runs `hooks/pre-commit.d/main.js`, and keeps only the `/dev/tty` y/N confirmation of a warn-only outbound-scan hit, which Node on Windows cannot open |
| `hooks/pre-commit.d/main.js` | Loads the settings `.env` (`loadEnv` of `hooks/lib/load-env.js`, no `.env.local` layer), builds the context and the snapshot, starts the visibility probe, runs the registry |
| `hooks/pre-commit.d/registry.js` | The registry: check order, fail mode and read source of each check, and the agents-repo gate children. SSOT for every value this document names in general terms |
| `hooks/pre-commit.d/orchestrator.js` | Runs the registry entries in order and maps each result to an exit code |
| `hooks/pre-commit.d/snapshot.js` | The staged snapshot |
| `hooks/pre-commit.d/output.js` | Synchronous writers and the pre-commit section marker |
| `hooks/pre-commit.d/checks/<name>.js` | One module per check |

## Check contract

Every `checks/<name>.js` exports `run({ context, snapshot, files, narrowed })`; the contract text
lives in the header of `hooks/pre-commit.d/registry.js`. `files` is the snapshot's staged,
non-deleted paths, narrowed at merge time (below). A check returns a verdict and its messages:

| Verdict | Effect |
|---|---|
| `pass`, `warn` | Print the messages and continue |
| `block` | Print the messages, stop, exit 1 |
| `confirm-warn` | Continue; the hook exits 10 at the end, and the bash entry asks on `/dev/tty` (no TTY blocks) |
| `skip-rest` | Stop with no further check; only `repo-visibility` returns it |

The registry declares, per check: `failMode`, `agentsRepoOnly` (the check runs only in the agents
repository), `mergeNarrowable`, `visibilityGated` (it must come after `repo-visibility`),
`readSource` and `mutatesIndex`. `validate()` in the registry refuses a declaration that breaks
these rules, and `main.js` calls it before any check runs.

## Fail mode

A check that throws (or whose module is missing) is mapped by its `failMode`:

| failMode | On a throw | Commit |
|---|---|---|
| `closed` | `pre-commit: <name> failed (<error>). Commit blocked.` | Blocked |
| `open` | `pre-commit: <name> skipped (<error>) — check failed open (commit continues)` | Continues |

Which check carries which mode is the registry's. A check whose skipped run could let a leak or a
broken invariant through (worktree enforcement, `.env` files, outbound scan, the agents-repo gates)
is closed; a check whose outage must not stop work is open. Some open checks also turn their own inner failure into a
one-line `skipped` notice; `code-lang` keeps its `pre-commit: lint-commit-lang skipped (<error>)`.
Snapshot or context errors outside any check block the commit (`main.js`). A missing `node` blocks
too: an unrun check cannot vouch for the commit. `git commit --no-verify` is the emergency exit.

## The staged snapshot

`snapshot.js` reads the index once: one `git diff --cached --raw -z --no-renames` for the names,
modes and blob ids, and one `git cat-file --batch` for both blob sides (index and `HEAD`). Any gap
in the batch reply throws, so a scan never reads a missing blob as clean. `git` inherits
`GIT_INDEX_FILE`, so a `git commit <paths>` temporary index is the one read. A check with
`mutatesIndex` (`settings-effort-unstage`) reports `indexChanged`, and the orchestrator rebuilds
the snapshot before the next check.

`readSource: snapshot` means the check judges the staged content. Known exceptions, each named
here so that it is a decision rather than drift:

- Working-tree reads (#2507 D7): the `check-session-id-ssot` gate (`working-tree`, the only gate
  `validate()` allows that value), and the `check-on-demand-rules` and `check-plans-artifacts` gates
  (`working-tree-whole`: they judge the whole tree). The `tests-frontmatter` check reads the shebang
  of an extensionless code target from the working tree.
- External runtimes (D7): the pytest and Pester case readers and analyzers stay child processes of
  their own runtime (`hooks/lib/test-gates/parts/external-runtime.js`).
- Own index reads with a fixed process count: `prompt-extraction` and `comment-block-size` run their
  CLI in process with `--staged` and read the index with a batched listing and blob read.
- Index-wide reads: the `check-root-names` gate reads its own table and the index modes, and the
  `check-plans-dir-isolation` gate judges every `tests/*.sh` blob of the index when one is staged;
  neither fits the staged snapshot, so both still read the index per file. The
  `check-migration-blocks` gate takes the snapshot's blobs through the `readStaged` option that
  `checks/agents-repo-gates.js` hands every gate.

## Repository visibility

`main.js` starts `gh api repos/<owner>/<repo>` in the background while the context is built.
`repo-visibility` waits for the answer: a private repository, or an origin that is not
`github.com`, ends the hook (`skip-rest`) before the `visibilityGated` checks (`env-file-block`,
`outbound-scan`). No origin, no answer, or any `gh` failure means scan. A blocking verdict kills the
probe so it does not outlive the hook.

## Merge-time narrowing

During a merge, a staged path whose index state equals `MERGE_HEAD`'s is a merge-incoming file
(`detectMergeIncoming` in `hooks/lib/merge-incoming.js`): the commit only takes it over from the
other branch. Checks marked `mergeNarrowable` (the quality checks) drop those paths and receive
`narrowed: true`; an undecidable merge state narrows nothing. The security checks are never
narrowed: `outbound-scan` always scans every staged file, since a secret is no less leaked for
having arrived by merge.

## Agents-repo gates

`agents-repo-gates` runs each gate CLI module of the registry in process, in order, with a
`agents-repo-gate-<checker name without .sh>` section marker before each. rc 0 is clean, rc 1 or 2
blocks with the gate's report and `Commit blocked: <what> (checker rc=<rc>).`; a missing module, a
throw or any other rc fails closed.

## code-lang

`code-lang` applies `CODE_LANG` to the staged added, copied and modified files through
`check({ files, read })` of `hooks/lib/lint-commit-lang.js`, reading content from the snapshot.
An unset `CODE_LANG` loads nothing. `CODE_LANG_EXCLUDE` is a repository-root opt-out matched by
`isCoveredByEntryList()` of `hooks/lib/path-coverage-match.js` — not the basename-aware matcher of
`shared-cmd-utils`, which a root comparison does not want; glob entries must be OS-native absolute
paths. Without `files` / `read`, `check()` lists and reads the index through git itself.

## Section markers

Before each check, even one `agentsRepoOnly` skips, `output.marker()` writes
`pre-commit-section: <name>` to stderr with a synchronous write, so the last marker names the check
that was running when a commit was stopped. The line format and how the commit-push worker reads
it: [worker-dispatch/commit-push.md](worker-dispatch/commit-push.md).
