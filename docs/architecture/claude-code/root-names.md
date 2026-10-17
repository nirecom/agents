# Root Names

How code, tests and documents spell a repository root, and what `bin/check-root-names.sh` enforces about it.

The four names — `AGENTS_MAIN_ROOT`, `SCRIPT_CHECKOUT_ROOT`, `TARGET_MAIN_ROOT`, `TARGET_CHECKOUT_ROOT` — are defined in the glossary: `AGENTS_MAIN_ROOT` in [glossary-user.md](../../glossary-user.md), the other three in [glossary-internal.md](../../glossary-internal.md). This document owns the writing rules only.

## Why four names

A script running from a linked worktree has to tell apart two questions that one variable used to answer: "where is my own code" and "where is the user's configuration".
Answering both with one environment variable made a worktree run the installed copy of a tool instead of the copy under test.
The rules below keep the two apart mechanically: code is found from the script's own location, configuration is found through the one name that is an environment variable.

## Which name a file may spell

`bin/check-root-names/classification.json` decides, per file, which of the four names may appear. It holds two lists.

- `rules` — `{repo, glob, allow, sourced, reason}`. The first rule whose glob matches the file applies. A file no rule matches is a violation.
- `exceptions` — per-file entries `{file, allow, forms, reason}` that add names and permitted forms to what the rule gives, and three carrier entries (see "Named exceptions for handing over the checkout root").

The default rules of the agents repository, in the order they apply after the per-directory entries:

| Files | Names allowed |
|---|---|
| `bin/check-root-names/**` | all four |
| `tests/**` | all four |
| `bin/**`, `hooks/**`, `skills/**/scripts/**` | `SCRIPT_CHECKOUT_ROOT` |
| `docs/architecture/claude-code/worker-dispatch/**` | `AGENTS_MAIN_ROOT`, `TARGET_MAIN_ROOT` |
| `install/**`, `install.*` | `SCRIPT_CHECKOUT_ROOT`, `AGENTS_MAIN_ROOT` |
| everything else (`**`) | `AGENTS_MAIN_ROOT` |

A file that needs another name gets a per-file exception with a one-line reason. The table is the only place such a grant is recorded.

Markdown is matched like code: a document or prompt file that spells a name outside its allowance is a violation.

### Spellings

Each name is matched in four spellings — upper snake (`SCRIPT_CHECKOUT_ROOT`), camel, kebab and lower snake — on identifier boundaries.

- For `AGENTS_MAIN_ROOT`, `TARGET_MAIN_ROOT` and `TARGET_CHECKOUT_ROOT`, every spelling counts as the name and needs the allowance.
- For `SCRIPT_CHECKOUT_ROOT`, only the upper-snake spelling is the variable. Any other spelling is accepted only under `tests/` or in a file listed by a carrier, and there only as that carrier's token or as part of the carrier's source path.

## Where a value may be assigned

### `AGENTS_MAIN_ROOT` — environment variable only

- It is never a local variable: no bare shell assignment, no `local` / `readonly` / `declare` / `typeset`, no `read` or `for` target, no JavaScript `const` / `let` / `var` or destructuring binding, no PowerShell `$AGENTS_MAIN_ROOT =`.
- It is given a value (shell `export`, a command prefix, `env NAME=`, a `process.env` assignment, an object key, `$env:` assignment, a YAML or JSON key) only under `tests/` or in a file whose exception carries the form `set-agents-root`. The files holding that form today are the two shell profile snippets, the two CI workflows, the test launcher, the worker spawner and the commit-language linter.
- It is not joined to `bin`, `hooks` or `skills` in a script under `bin/`, `hooks/`, `tests/` or `skills/**/scripts/`: code comes from the script's own checkout. A file that prints or matches a user-facing command line carries the form `agents-root-subpath`.

### `SCRIPT_CHECKOUT_ROOT` — assigned once per file, from the file's own path

A file assigns it at most once, in the standard form for its language, outside any block, with at most 40 lines of code before it. The number of levels climbed must equal the file's depth below the repository root.

| Language | Standard form (file two levels down) |
|---|---|
| bash | `SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"` |
| Node | `const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");` |
| PowerShell | `$SCRIPT_CHECKOUT_ROOT = ...` built from `$PSScriptRoot`, one level per `..` or `Split-Path`; no `$env:` and no `git` in the expression |

A shell file that the table marks `sourced` shares its caller's variables, so it assigns `_<STEM>_SCRIPT_CHECKOUT_ROOT` instead, where `<STEM>` is the file name without extension, upper-cased, with every non-alphanumeric character replaced by `_`. `hooks/lib/*`, `bin/**/lib/**` and `tests/lib/**` are marked `sourced` by directory.

A shell file that reads `SCRIPT_CHECKOUT_ROOT` assigns it itself. Only a sourced test library (`sourced` and under `tests/`) may read the value its caller assigned, because the test harness hands it over. A sourced library elsewhere derives `_<STEM>_SCRIPT_CHECKOUT_ROOT` from its own location: a caller's value names the caller's checkout, which need not be the library's.

A file that cannot use the standard form carries the form `own-script-root-form` and its reason in the table.

### `TARGET_MAIN_ROOT`, `TARGET_CHECKOUT_ROOT` — ordinary variables

They name the repository a tool works on, so they are plain variables in the files the table lists. They never become environment variables, under `tests/` included: no shell `export`, command prefix or `env NAME=`, no `process.env` reference, no upper-snake object key, no `$env:` reference.

## Handing a root to another process

- `AGENTS_MAIN_ROOT` reaches a child through the environment it already lives in. A file that builds a child environment from an allow-list sets it explicitly and carries `set-agents-root`.
- `SCRIPT_CHECKOUT_ROOT` stays inside its own process. The gate rejects exporting it, prefixing a command with it, passing it through `env`, assigning it to `process.env`, using it as an object key, and assigning `$env:SCRIPT_CHECKOUT_ROOT`. Reading `process.env.SCRIPT_CHECKOUT_ROOT` or `$env:SCRIPT_CHECKOUT_ROOT` is rejected as well.
- One shell form is accepted: a command prefix whose command takes `-e` or `-c`, because the inline program is the same file's code.
- `TARGET_MAIN_ROOT` and `TARGET_CHECKOUT_ROOT` reach a child as an argument: the flag `--target-main-root <dir>` or `--target-checkout-root <dir>`, or the positional the child documents. A script that falls back to the agents main root does so only when the argument is absent.
- In non-test JavaScript, a function parameter named after the checkout root is rejected: each file derives its own.

### Named exceptions for handing over the checkout root

Three carriers are the only sanctioned ways the checkout root crosses a module or process boundary. Each has one source file and a closed list of files that may mention it.

| Carrier | Kind | Source | What the gate enforces |
|---|---|---|---|
| `anchors.scriptCheckoutRoot` | property | `bin/worker-dispatch/anchor.js` | only the source writes the property |
| `script_checkout_root` | payload key | `hooks/lib/worker-dispatch-registry.js` | the source declares the key; a listed script that reads it also references the property carrier |
| `resolveScriptCheckoutRoot()` | function | `hooks/lib/script-checkout-root.js` | only the source defines the function |

## The decoy tree

A test that reached a tool through `AGENTS_MAIN_ROOT` would pass against the installed copy and prove nothing about the checkout under test. The decoy makes that mistake fail.

- `tests/lib/root-decoy-build.js` builds a stub tree mirroring the tracked files under `bin`, `hooks` and `skills` of its own checkout. A stub script records one hit file under the tree's `hits/` directory and exits 97.
- `tests/lib/harness.sh` calls `root_decoy_ensure` when it is sourced and exits if the decoy cannot be set up. `root_decoy_ensure` exports `AGENTS_MAIN_ROOT` pointing at the stub tree, points the retired variable names at a second stub tree, and keeps the real value in `ROOT_DECOY_REAL_AGENTS_MAIN_ROOT`.
- With no `ROOT_DECOY_DIR` set, the decoy is built once under `<test cache base>/root-decoy/<key>` and shared by every later run; `tests/lib/test-cache-base.js` owns the cache base (the OS temp area, never `$HOME`), and the key follows the tracked path list.
- `bin/lib/run-all-launch.sh` pins the same decoy for a whole run, tags each test with `ROOT_DECOY_TEST_ID`, and turns a hit into a FAIL of the test that made it; a hit no test can be named for is counted as `HITS=` ([test-command-guard.md](test-command-guard.md) "Install points and the hit report").
- The decoy covers reaches through a root name; the command guard and worktree change detection cover git writes and network CLIs that need no root name at all: [test-command-guard.md](test-command-guard.md).
- A test that must read the real main worktree calls `root_decoy_use_real_main_root`. The gate rejects that call in a shell file whose exception does not carry the form `leave-decoy`.

## The gate

`bin/check-root-names.sh` runs `bin/check-root-names/main.js`. Exit 0 is clean, 1 is a violation, 2 is a usage error or unreadable input.

| Check | What it rejects |
|---|---|
| `residue` | a retired name, in file content or in a file path |
| `table-match` | a root name the classification table does not allow in that file |
| `structural` | the agents root joined to a code directory; the checkout root leaving its process; a carrier written outside its source (test files are exempt); an unlisted exit from the decoy |
| `script-root-form` | a checkout-root assignment that is repeated, conditional, non-standard, of the wrong depth, or too far from the top |
| `env-name` | the agents root as a local variable or set outside the permitted files; another root name as an environment variable |
| `reference-role` | a root name in a role the syntax decides that belongs to another name (see "What the gate guarantees") |

### What the gate guarantees

Two kinds of occurrence are judged per reference; every other occurrence is judged per file, by the table.

| Role (decided by the syntax) | The one name that fits |
|---|---|
| a definition from the script's own location (`dirname "${BASH_SOURCE[0]}"`, `dirname "$0"`, `__dirname`, `$PSScriptRoot`) | `SCRIPT_CHECKOUT_ROOT`, or a sourced library's `_<STEM>_SCRIPT_CHECKOUT_ROOT` |
| a definition from the main worktree (`worktree list`, `--git-common-dir`, `bin/main-worktree-root`, the main-worktree helper of `hooks/lib/main-worktree.js`) | `TARGET_MAIN_ROOT` |
| a definition from a checkout top (`rev-parse --show-toplevel`) | `TARGET_CHECKOUT_ROOT` |
| a config read (`<name>/.env`, `<name>/.env.local`, `<name>/docs/private-info`, or the same target as the next argument of a path join) | `AGENTS_MAIN_ROOT` |

A main-worktree marker wins over the script's location, and the script's location wins over a checkout top: the top of the script's own checkout is the script checkout root.
An occurrence whose role the syntax does not decide — an argument, a flag value, `cd && pwd`, an echo, a join to a code directory — passes this check and stays with the file's table rule.
A file that reads its configuration from its own checkout by design carries the form `config-from-script-checkout` and its reason in the table.

### Pre-commit gates fail closed

In the agents repository the pre-commit hook runs six checkers, this gate among them (`hooks/lib/precommit-agents-repo-gates.sh`). Only exit 0 lets a commit through.
Exit 1 or 2 is a violation. A missing checker, a missing interpreter, or any other exit is an outage the gate cannot vouch for, so it blocks as well and says which checker failed.
The emergency bypass is `git commit --no-verify`.

The retired names are listed between the `retired-names:begin` and `retired-names:end` markers of `tests/bin/feature-2561-root-names-residue.sh`. `docs/history*`, `CHANGELOG.md`, `changelog/` and the list file itself are exempt from `residue`.

| Invocation | Input |
|---|---|
| no argument | the tracked files of the gate's own checkout |
| `--staged` | the staged files (`--diff-filter=ACMRT`: added, copied, modified, renamed, type-changed) of the repository at the current directory, read from its index — in a linked worktree, that worktree's index — with the retired-name list and the table also read from that index |
| `--root <dir>` | the tracked files of `<dir>`, or every file when it is not a git tree; paths are reported from the repository root |
| `<file>...` | the named files only |

`--staged`, `--root` and file arguments exclude each other. `--repo agents|dotfiles` selects the rule set, `--only <check>` runs one check, `--scope <prefix>` keeps the files under a prefix, and `--retired-names-from <file>` reads the list from another file.

An untracked file is not part of the no-argument run; it is judged once it is staged or named.
A tracked entry that is not a regular file (a symlink, a gitlink) has its path judged and no content.
