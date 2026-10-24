# Test Language Registry

One declarative table owns every rule that depends on a test's language: which file names are tests, how the header is read, how a test is launched, and which language part reads its case markers or detects the table-driven shape.
Before #2500 these rules were spread over about 30 extension checks that disagreed on which languages they covered.
Every tool now asks the table, so adding a language is one table entry plus, optionally, that language's parts.

The six placement categories (`hooks bin skills agents install tests`) and the "is this an entrypoint" placement rules are not language rules; each tool keeps them (#2473 owns their consolidation).
A tool decides with two inputs: placement (its own) × language (the table).

## Files

| Path | Role |
|---|---|
| `hooks/lib/test-language-registry.json` | The table. Pure data, no code |
| `hooks/lib/test-language-registry.js` | Reader for Node: load, match, glob conversion, shell dump |
| `hooks/lib/test-language-registry/validate.js` | Table validator (`validate(table, repoRoot)`), including the `launch` block rules below |
| `bin/test-language-registry` | CLI over the reader (`--format shell` / `--format json`, `--file <table>`). Needs the executable bit |
| `bin/lib/test-language-registry.sh` | Bash loader (source only). Calls the CLI once per process and answers from arrays |
| `bin/lib/test-language-registry-plain.sh` | `tlr_exec_plain`, the fallback launcher when `run-all-launch.sh` is absent |
| `bin/lib/test-language-parts/<lang>.sh` | A language's parts (e.g. `has_table_driven_sh`, `pester_case_markers`) |
| `bin/lib/test-language-parts/<lang>-case-reader.<ext>` | A language's child reader, run in that language's own runtime (`pester-case-reader.ps1`, `pytest-case-reader.py`, `js-case-reader.js`) |
| `bin/lib/case-reader-bridge.sh` | `crb_run`: runs a child reader and loads what it prints |
| `bin/lib/case-record-reader.sh` | `crr_read`, the one entry to case records |
| `bin/lib/test-route-destination/language.sh` | Which languages a source set may be tested in (`find-tests-for-source.sh --with-language`) |
| `bin/lib/test-wrappers/` | Language wrappers named by `launch.wrapper` (`pester.ps1`, `pytest.py`, `node.js` + `node-reporter.mjs` + `node-guard.cjs`) |
| `tests/lib/harness.<ext>` | Each language's helper library, named by `helperLibrary.path` |

The table is replaced only by an argument (`loadRegistry(file)`, CLI `--file`, `tlr_load <file>`).
There is no environment-variable override, so a test using a fixture table can never leak it to a child, and hooks always read the default table.

## Table shape

Top level: `schema` (1), `headerMaxLines` (10: how many leading lines carry `# Tests:` / `# Tags:` / `# Serial:`), `tableDrivenFallbackEntry` (the entry whose table-driven detector applies to files no entry matches; `bash`), `testLanguageExceptions` (the allowed `test-lang-exception:<value>` values; see below), and `entries` (ordered).

`testLanguageExceptions` (`text-only`, `symmetry`, `e2e`; each `[a-z0-9-]+`) is the single list of values a test may declare in `Tags:` to be exempt from the test-language match. Each value is one exception row of the `rules/test.md` "Test Language" table: `text-only` — inspects the code as text only; `symmetry` — checks symmetry across languages; `e2e` — one end-to-end run crosses processes. The non-code row has no value, because a non-code target is never judged. bash reads the list as `TLR_LANG_EXCEPTIONS` (space-separated) after `tlr_load`; `bin/check-test-language-match.sh` validates declarations against it ([case-marker-gate.md](case-marker-gate.md)).

| Field | Meaning |
|---|---|
| `id` | Entry name, `[a-z0-9-]+`. Supported ids equal the kinds `failing-list.js` reports (`bash`, `pester`, `pytest`, `js`) |
| `status` | `supported` (run and checked) or `recognized-only` (known to be a test, never run) |
| `patterns` | File-name patterns (basename only) |
| `selfIdentifying` | The name alone marks a test, wherever it lives |
| `nameStrip` | `{prefix, suffix}` removed to get the test name (name normalization only) |
| `issueNamePrefix` | String dropped once from the `nameStrip` result before an issue reference is read (`tlr_issue_stem`): pytest `test_`, so `test_feature-<N>-*.py` is issue-specific; every other entry `""`. Kept apart from `nameStrip` because the test name keeps the prefix |
| `siblingSuiteDir` | A same-named directory next to the test holds its sub-files; retire deletes both |
| `header` | `{commentPrefix}` or null. Header readers match `<commentPrefix> Tests:` / `Tags:` / `Serial:` as a fixed string (bash: `tlr_comment_prefix`, which also sets `TLR_COMMENT_PREFIX`); null takes `tableDrivenFallbackEntry`'s |
| `launch` | How to run it (below); null for `recognized-only` |
| `caseMarkerReader` | Part reference that reads the language's case markers, or null. Tools read it through `crr_read` (`bin/lib/case-record-reader.sh`), never directly |
| `caseEmbedRules` | Part reference answering the `sweep-tests --embed-cases` questions (below), or null: the language's files are then skipped as `no-embed-rules` |
| `tableDrivenDetector` | Part reference that detects the table-driven shape, or null |
| `envClearLine` | Part reference that tells whether one line only clears named env vars, in the language's own idiom (`unset`, `Remove-Item Env:`, `os.environ.pop`, `delete process.env`), or null. `bin/check-session-id-ssot.sh` uses it to pass tombstone-clearing lines; a line in a language without it fails closed. Required for a supported entry |
| `helperLibrary` | `{path, sourceRegex}`: the helper library and the grep -E proof a test loads it, or null. Comes as a pair with `caseMarkerReader`: both or neither |
| `codeLanguage` | `{sourcePatterns, shebangInterpreters}`: the code this language's tests are written for — basename patterns, and interpreter names read from the first line of a file without an extension. Required for a supported entry; a pattern belongs to one entry only |
| `newFileNameShape` | What a new test file is called, with `<name>` as the free part (`<name>.Tests.ps1`, `test_<name>.py`). Required for a supported entry |
| `notationDoc` | Repo-relative document that teaches the language's case-marker notation. Required for a supported entry; must exist |
| `diagnostics` | `{nameLabel, flatRejectCode}` used in checker messages (`flatRejectCode` defaults to `FLAT_TEST_REJECTED`), plus the case-marker gate's wording: `markerName`, `markerWrapHint`, `markerMissingHint` (falls back to `markerWrapHint`), `markerUncertainHint`, `markerDoc` (falls back to `notationDoc`) |
| `note` | Why the entry is shaped this way (JSON has no comments) |

`validate.js` demands the four supported-entry fields and the existence of their files only when the full table is checked (tests and the CLI).
The runtime loader (`hooks/lib/test-language-registry.js`) calls it with `{ repoFiles: false, complete: false }`: a checkout that carries the tools without the test tree or the skills, or a fixture table, must still load, so a missing field there degrades the one feature that needs it instead of failing every tool.

Current entries, in order:

| id | status | patterns | launch |
|---|---|---|---|
| `bash` | supported | `*.sh` | file, `bash {path}`, no per-file timeout |
| `pester` | supported | `*.Tests.ps1` | file, requires `pwsh`, `pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File {wrapper} -Path {nativePath} -MinVersion {minVersion}`, Pester wrapper `pester.ps1`, `Pester` 5.0, 180 s |
| `pytest` | supported | `test_*.py` | file, requires `uv`, `uv run --no-project --with pytest>={minVersion} python {wrapper} {nativePath} {minVersion}`, pytest wrapper `pytest.py`, `pytest` 7.0, 180 s |
| `js` | supported | `*.js` | file, requires `node`, `node {wrapper} {nativePath} {minVersion}`, node wrapper `node.js`, `node` 20.0, 180 s |
| `test-naming-convention` | recognized-only | `*.test.*`, `*.spec.*`, `*_test.*`, `test_*` | none |

All four supported entries have a test case reader and a helper library (#2411), so a test can be written in the language of the code it tests (`rules/test.md` "Test Language").
All four supported entries have `caseEmbedRules` (#2502); the pester, pytest and js parts hand each op to an analyzer child process ([test-language-registry/case-embed-ops.md](test-language-registry/case-embed-ops.md)).
Such differences are named in the table, not hidden in code: filling a field for another language changes no shared code (#2481).

## Matching

Two kinds of match, deliberately different:

- **One language** (`matchBasename` / `tlr_match`): supported entries first, then table order. Returns one `{id, status}`.
- **Self-identifying** (`matchesSelfIdentifying`): true when any `selfIdentifying` entry matches. Not reduced to one language, because `test_a.sh` is `bash` (not self-identifying) yet still follows the naming convention.

Conditions select entries by their fields, never by id: `supported`, `recognized-only`, `case-marker` (supported with `caseMarkerReader`), `table-driven` (has `tableDrivenDetector`), `helper-library` (has `helperLibrary`).
Shared code must not compare an id string (`== "js"`); the residue check rejects that.

Header readers take each file's own `header.commentPrefix` as a fixed string (so a `//` header reads like a `#` one) and look only within `headerMaxLines`: `check-test-frontmatter.sh`, `check-case-markers.sh`, `check-table-driven.sh`, `test-frontmatter-fix.sh`, `test-dup-group.sh`, `mutation-probe.sh`, `calibrate-test-parallelism.sh`, the run-all serial-declaration scan, `review-e2e-coverage` and `normalize-harness-position.py`.

## Pattern vocabulary and globs

- Characters `A-Z a-z 0-9 . _ -` and `*`; at most two `*`, never adjacent. Case-sensitive. The reader rejects anything else at load time.
- `*` means **one or more** characters, so a file named just `.sh` or `test_.py` is not a test.
- Node matches with an anchored regex (`*` → `[\s\S]+`); bash matches with `[[ $name == $glob ]]`.
- Tools that take globs (`find -name`, `grep --include`, git `:(glob)`, Python `Path.rglob`) treat `*` as zero or more. They receive only the **converted glob** (`*` → `?*`) from `globsOf` / `tlr_globs`, never a raw pattern. `?` is exactly one character in all of them, so the meaning matches the table.

## Parts

A part reference is `{file, function}`: a repo-relative bash file and the function it defines.
Shared code separates **capability** (is the field non-null) from **ownership** (the field's value); it receives the owner from the table and calls it.
`tlr_call_part <id> <field> <args…>` sources the file if the function is undefined, then calls it; a missing file or function prints one stderr line and returns 70, which callers treat as "cannot check" (never as "no markers").

| Part | Arguments | Result |
|---|---|---|
| `caseMarkerReader` | absolute test path | `TRP_CASE_*` / `TRP_HAS_MARKERS` / `_TRP_MARKER_MALFORMED*` / `_TRP_MARKER_UNCERTAIN` globals (the `trp_parse_case_markers` contract) |
| `tableDrivenDetector` | test path | rc 0 when table-driven |
| `caseEmbedRules` | `<op> <absolute test path> [args]` | one op per call (below); an unknown op returns 2 |

`crr_read <abs>` is the one entry to case records: a `FILE\t<state>\t<line>\t<reason>` line, then one `CASE\t<name>\t<target>\t<begin>\t<end>\t<deps>\t<reason>` line per case of a conforming file. `deps` is `?` when the language has no `caseEmbedRules`. A `deps` op that fails (an analyzer whose case order disagrees with the reader's included) or whose rows break the row contract ([test-language-registry/case-embed-ops.md](test-language-registry/case-embed-ops.md)) makes the file `uncertain` with reason `case-embed` and no CASE lines; a `deps` op with no runtime (69) makes it `unavailable`.
The CASE lines come in file order; a case's order is its line position, with no index column.
States: `none`, `conforming`, `malformed`, `uncertain`, `unsupported` (no reader for the file) and `unavailable` (the reader's runtime is not installed; the last column names the entry's `launch.requires`).
A reader that fails any other way reads as `malformed` with reason `reader`.

**Same-shell contract.** `crr_read` leaves the `TRP_CASE_*` globals of the file it read, and the `deps` / `leftover-defs` ops read them in that shell instead of re-parsing case ranges, so call them right after `crr_read` on the same file, never in a subshell of their own.
An analyzer-backed `deps` op checks the analyzer's case order against those globals; with none set, it runs the file's test case reader into locals first.

| `caseEmbedRules` op | Output (empty = nothing found) |
|---|---|
| `rules-doc` | repo-relative path of the language's embed rules (bash: `skills/sweep-tests/embed-rules/bash.md`) |
| `deps` | `<case idx>\t<csv of top-level functions the case calls>` per case; `<case idx>` is a line-position key used only inside `crr_read` |
| `leftover-defs` | `<line>\t<name>` per top-level function no code line calls |
| `self-impl` | `<line>\t<kind>\t<detail>` per hand-rolled harness piece (bash: `counter-init`, `harness-redef`) |
| `skip-reason` | one reason word when the file must not be embedded (bash: `narrow-harness`, a sourced `tests/lib/*harness*.sh` that is not the entry's `helperLibrary`); the words are listed in each `embed-rules/<lang>.md` |
| `result-summary <rc> <stdout-file>` | `<pass\|fail\|skip>\t<passed>\t<failed>`; counts empty when the output has none |
| `syntax-check` | nothing; rc 0 when the file parses, 1 with the reason on stderr otherwise. Retire's per-case cut runs it on the rewrite, which keeps the original's extension |
| `case-count` | the number of top-level case units; rc 1 when there is none, and always for bash and js (see [test-language-registry/case-embed-ops.md](test-language-registry/case-embed-ops.md)) |

## test case reader

The bash reader is a bash parser in process. The other three are thin bash parts that hand the file to a child reader in the language's own runtime, because only that runtime reads its syntax reliably: the PowerShell and Python readers use the language's parser, the JavaScript reader reads lines. No reader runs the test file.

Child-reader contract (`crb_run <file> <command> [args…]` in `bin/lib/case-reader-bridge.sh`):

- The child gets the test path as its last argument, in a form a non-shell process can open, and prints one `FILE\t<state>\t<line>\t<reason>` line (`none`, `conforming`, `malformed`, `uncertain`), then one `CASE` line per case in the `crr_read` shape — for a conforming file only.
- `crb_run` sets the globals the bash reader sets, so every caller downstream reads one shape.
- rc 79: the command is not on PATH. The part must start the child with the command the entry's `launch.requires` names, because `crr_read` reports that field as the missing runtime.
- rc 1: the child failed or broke the format. Never read as "no markers".

What a case is, per language:

| id | Case | Target |
|---|---|---|
| `bash` | `case_begin "<name>" "<target>"` … `case_end` at column 0, depth 0 | second argument |
| `pester` | a top-level `Describe` | its one `-Tag 'target:<path>'` |
| `pytest` | a module-level `test_*` function or `Test*` class | `@pytest.mark.target("<path>")` |
| `js` | `caseBegin("<name>", "<target>");` … `caseEnd();` at column 0 | second argument |

A case owns its begin and end lines, because retire's per-case cut removes those whole lines.
In `bash`, only redirections and at most one `|| true` or `|| <name>=$?` may follow `case_end`; anything else after it (`|| <command>`, a pipe, `;`, `&&`, a lone `&`) reads `grammar`.
In `pester`, a `Describe` case that shares its first or last line with another top-level statement reads `grammar`.

### Case target path rule

A target is a repo-relative path of `A-Z a-z 0-9 . _ / -` with no leading `/` or `./` and no `..` segment, in every language.
The bash side owns it as `ctp_target_path_valid` (`bin/lib/case-target-path-rule.sh`), which the bash reader and `crb_run` both call; the three child readers restate it in their own runtimes and point here.
`tests/bin/feature-2712-target-path-parity.sh` runs one input table through all four.

Malformed reasons (the word in the gate's `MALFORMED_CASE_MARKER` message):

| Reason | Languages | Meaning |
|---|---|---|
| `grammar` | all | A marker that cannot be read: bash, an unreadable marker line, a `case_end` followed by another command, or a local marker definition; `pester`, a file that does not parse or a case that shares a line with another statement; `pytest`, a file that does not parse; `js`, an empty case name. Also, in every language, a case name or target holding a TAB, CR or LF, judged by the shared state rule (`_trp_reject_record_delimiters`) |
| `target` | all | A target that breaks the path rule |
| `depth` | `bash`, `js` | bash: a marker inside a block, function or group; `js`: a case opened while another is open |
| `balance` | `bash`, `js` | Unpaired markers |
| `constant` | `pester`, `pytest`, `js` | A name or target that is not a string constant |
| `missing-target` | `pester`, `pytest`, `js` | A case without a target in a file that has targets (`js`: a one-argument `caseBegin`) |
| `duplicate-target` | `pester`, `pytest`, `js` | More than one target on a case (`js`: more than two arguments) |
| `nested-target` | `pester`, `pytest`, `js` | A target below the top level |
| `duplicate-name` | all | Two cases of one file share a name; reported on the later case's first line by the shared state rule (`trp_marker_state_from_globals`), not by a reader |
| `reader` | all | The reader itself failed (set by `crr_read`, not by a reader) |

`uncertain` is a state, not a reason: bash reports it for a depth fault after a multi-line quoted string, `js` for a marker-looking line inside a block comment, a multi-line template string or an open `${}`. `crr_read` itself reports `uncertain` with reason `case-embed` when the `deps` op fails or its rows break the row contract.
Retire's per-case cut does not use `deps`: it removes the line ranges of the orphan cases and leaves definitions outside those ranges in place.
The writing rules a test author follows live in each entry's `notationDoc`, not here.

## Helper libraries

Each supported entry's `helperLibrary.path` is `tests/lib/harness.<ext>`: fixture isolation, a hook-free fixture repo, the known-failure form and the TL3 switch, in that language's own idiom. `bin/check-test-frontmatter.sh` rejects a new test whose text does not match the entry's `sourceRegex`.

- **Load rule.** A test loads the library from its own location, one level up into `lib/` (`tests/<category>/<file>` → `../lib/harness.<ext>`); `sourceRegex` matches that spelling. bash is the exception: its expression wants a path ending in `tests/lib/harness.sh`, reached through the test's own checkout root.
- **Line-based proof.** `sourceRegex` is a grep over lines, so the load must sit on a line of its own — the Pester expression wants the dot at the start of the line, so a one-line `BeforeAll { . … }` does not count.
- **Python mark registration.** `harness.py` registers the `target` mark through `pytest.mark._config`, a private attribute of pytest. If a later release drops it, the mark stays unregistered and pytest only warns; the reader, which never runs pytest, is unaffected.
- **`RUN_TL3`.** The PowerShell, Python and JavaScript libraries resolve the switch the same way: a non-empty `RUN_TL3` in the process environment wins; otherwise they ask `bash <library directory>/../../bin/get-config-var RUN_TL3 off` and take its trimmed output. The test is enabled only when the value, lower-cased, is `on`. Any failure of the lookup (no bash, non-zero exit, timeout) reads as off and never throws, so a real-environment test is skipped rather than run by accident.
- The libraries hold no language id and no test-file pattern, so the residue check below applies to them unchanged.

## Launch

| Field | Meaning |
|---|---|
| `unit` | `file` or `suite` |
| `requires` | A tool that must be on PATH, or null |
| `prepare` | argv run before the command on every launch (`file` and `suite` alike), or null |
| `command` | argv |
| `wrapper` | Repo-relative language wrapper (no `..`; must exist under the reader's repo root), or null |
| `minVersion` | `{runtime, version}` (`<major>[.<minor>[.<patch>]]`) the wrapper enforces, or null |
| `timeoutSeconds` | Positive integer, or null (no per-file limit) |
| `suiteRootMarker` | Required for `suite` |

Placeholders in `command` / `prepare`: `{path}`, `{nativePath}` (`cygpath -m` when present), `{nativePathSq}` (the same with ASCII `'` and U+2018..U+201B doubled), `{wrapper}` (the wrapper's native path; needs `wrapper`), `{minVersion}` (the version string only; needs `minVersion`).
The test-path placeholders (`{path}`, `{nativePath}`, `{nativePathSq}`) are rejected in `suite` units; `{wrapper}` and `{minVersion}` are allowed there, because they name the launcher's own file and the entry's version. Every string must be free of tabs and newlines (the shell dump is tab-separated). `validate.js` enforces all of this at load time.

`run_all_exec <script> <out> <err> [<resultdir>]` in `bin/lib/run-all-launch.sh` interprets every entry the same way:

1. Source the loader, `run-all-classify.sh` and `timed-exec.sh` next to itself (the loader's key holds the CLI path, so another checkout's table already in memory is re-read). Any missing: rc 2.
2. Not matched or not supported: write `UNSUPPORTED: <path> (language: <id>; not run)`, rc 78.
3. `requires` missing from PATH: write the tool name to `<resultdir>/unrunnable` and `UNRUNNABLE: missing <tool>`, rc 79.
4. `file`: substitute and run. `{wrapper}` resolves, for either unit, to an absolute path under the launcher's own checkout root, so a base checkout runs its own wrapper and a suite's change of directory does not move it. A path starting with `-` is passed as `./-…`.
5. `suite`: find the root by walking up for `suiteRootMarker` (never above the repo root). No root: `UNSUPPORTED: … no suite root <marker>`, rc 78. Otherwise run in the root; substitutions name the root, and the step 3 lookup of what `prepare` and `command` start with is made from the root, so a root-relative executable (`./runner`) counts as present.
6. `prepare`, when set, runs before `command` for either unit — once per launch, so once per file for `file` and once per suite for `suite`. Its failure is returned and the command is skipped; the executable it starts with must be on PATH like `requires` (step 3).
7. `timeoutSeconds`, capped by a caller-set `RUN_ALL_TIMEOUT_SECONDS`, is one limit for the unit: `prepare` runs under it with `timed_exec` (`bin/lib/timed-exec.sh`) and `command` under what `prepare` left (nothing left: rc 124, TIMEOUT); null with no cap runs them unwrapped, leaving hangs to the caller's `--deadline`.
8. The child alone sees `RUN_ALL_RESULT_DIR` / `RUN_ALL_RESULT_OWNER`; `rac_classify` then sets `RUN_ALL_EXEC_STATE` / `_RC` / `_MISSING` and the returned rc.

`RUN_ALL_EXEC_LAUNCHED` is 1 only when a command actually started; `bin/mutation-probe.sh` uses it and `RUN_ALL_EXEC_STATE` to report `NOT RUN:` instead of counting a mutant as killed.
Exit codes, states, the result directory and the report lines: [test-result-contract.md](test-result-contract.md).
Without `run-all-launch.sh`, `tlr_exec_plain` runs only a bare `bash {path}` file entry with no `requires` or `wrapper`; any other supported entry is rc 2, state FAIL, `not run: … launcher library not found` (a run must not pass over a test it was meant to run), and a file no supported entry matches is rc 78 `UNSUPPORTED: … launcher library not found`.

**Suite dedupe**: `tests/run-all.sh` passes its work list through `tlr_dedupe_suites`, keeping the first file by name per (id, suite root); other files keep their order. The result line names that representative file.
`bin/run-tests-baseline` launches named tests one by one and does not dedupe: naming two files of one suite runs it twice.

**Baseline checkout**: `bin/lib/run-tests-baseline-exec.sh` sources the base checkout's own `run-all-launch.sh`, which loads the base checkout's loader and table (the load key differs), so each side launches with its own table.

**Home-reference scan**: `bin/run-tests-baseline` classifies a failing test `undetermined` (reason `home-claude-ref`) when the test file or its sibling directory names a home-claude path, because such a failure may depend on the host rather than the diff. `rtb_has_home_ref` (`bin/lib/run-tests-baseline-homeref.sh`) skips a whole-line comment only when the registry matches the file and its `header.commentPrefix` is non-null; an unmatched file, a null prefix or any read/`find`/`awk` failure counts as a reference (fail-closed), so a comment alone no longer blocks the baseline verdict.

## Reading the table from other runtimes

Always call `node <path-to>/bin/test-language-registry …`; never rely on the shebang (Windows PowerShell and Python `subprocess` cannot use it).

| Runtime | Form |
|---|---|
| Node | `require('hooks/lib/test-language-registry.js')` in process |
| bash | `. bin/lib/test-language-registry.sh; tlr_load` (one Node process per bash process) |
| PowerShell | `node <CLI> --format json \| ConvertFrom-Json` |
| Python | `json.loads(subprocess.run(["node", CLI, "--format", "json"], …).stdout)` |

`--format shell` is tab-separated, one record per line, never `eval`ed: `entry`, `pattern`, `glob`, `field`, `arg` records, plus one `testLanguageExceptions\t<space-separated values>` line. CLI exit codes: 0 ok, 1 invalid table, 2 bad arguments.

## Unsupported files

An unsupported file is never run and never blocks anything: it is reported, and counted as neither pass, fail nor skip.

- `tests/run-all.sh`: by default / `--all`, files directly in a category that match a `recognized-only` entry; when named, any expanded file no supported entry matches. Since #2501 runs `*.js`, only `test-naming-convention` files remain. The `UNSUPPORTED:` line, its effect on counts and `RUN_CONTRACT:`, and the not-launched rc 78: [test-result-contract.md](test-result-contract.md).
- `bin/run-tests-baseline`: a test the base checkout's launcher does not launch (rc 78 with `RUN_ALL_EXEC_LAUNCHED=0`) is classified `undetermined` with reason `unsupported-at-base`, and nothing is appended to the base-result ledger (`bin/lib/run-tests-baseline-ledger.sh`).
- Pre-commit: a staged category-level `recognized-only` file prints `UNSUPPORTED: <path> (language: <id>; not checked)` to stderr; the commit is not blocked.
## When the table cannot be read

Tools that select, run or audit tests fail closed (an exit code of their own or an explicit `SKIPPED` / note line, never an empty answer that reads as "no tests"); edit-time hooks and pre-commit gates fail open with one stderr line so an unreadable table never blocks work.

| Place | Behaviour |
|---|---|
| `tests/run-all.sh` | exit 5 (`RUN_ALL_REGISTRY_LIB` overrides the loader path) |
| `run_all_exec` | rc 2 |
| `select-tests.sh` | exit 4, nothing selected (an empty list would read as all-green) |
| `find-tests-for-source.sh` | exit 3 (environment error) with one stderr line; the sourced route / dup-group / retire-predicate libraries return 1 |
| `check-table-driven.sh`, `check-test-frontmatter.sh`, `audit-tests.sh`, `audit-tests-common.sh`, `run-tests-baseline`, `mutation-probe.sh`, `calibrate-test-parallelism.sh` | exit 2 with one stderr line |
| `normalize-harness-position.py` | exit 1 with one stderr line |
| `review-e2e-coverage` | prints `SKIPPED` for its section, exit 0 |
| `sweep-issues/verify-candidate.sh` | `EVIDENCE-NOTE` line, no test is run |
| `check-plans-dir-isolation.sh` | one stderr line, nothing scanned |
| `trp_enumerate_cases` | marks the file malformed with reason `reader` |
| pre-commit frontmatter / case-marker gates | one stderr line, gate skipped, commit continues |
| `hooks/block-case-markers.js` | one stderr line, fail open (approve) |
| parallelism corpus count | count 0, cache key falls back |

## Adding a language

1. Add one entry to the table: patterns, `status`, `nameStrip`, `header`, `launch`, `diagnostics.nameLabel`, and a `note`.
2. Optionally write parts in `bin/lib/test-language-parts/<lang>.sh` and reference them (`tableDrivenDetector`, `caseEmbedRules`).
3. To make its multi-path tests case-marker targets, add the reader and the helper library together — the validator rejects one without the other: a `caseMarkerReader` part (with a child reader when bash cannot read the syntax, following the contract above), `tests/lib/harness.<ext>` with its `sourceRegex`, a `notationDoc`, and the `diagnostics` marker wording.
4. For a `supported` entry, fill `codeLanguage` and `newFileNameShape` so `find-tests-for-source.sh --with-language` routes that language's code to it, and `envClearLine` so its test isolation lines pass the session-id tombstone check.
5. No shared code changes. The residue check fails if shared code starts matching the new extension itself.

Gate scope follows from the table too: a new test of that language is judged from then on, and a renamed test file counts as new ([case-marker-gate.md](case-marker-gate.md)).

Worked on paper only (fixture `tests/bin/test-language-registry/fixtures/java-terraform.json`, never the real table):

| id | pattern | launch |
|---|---|---|
| `java-junit` | `*Test.java` | suite, requires `gradle`, root `build.gradle`, prepare `gradle testClasses`, command `gradle test`, 600 s |
| `terraform-test` | `*.tftest.hcl` | suite, requires `terraform`, root `.terraform.lock.hcl`, prepare `terraform init -input=false`, command `terraform test`, 600 s |

The suite path itself is exercised with the fixture-only `fake-suite` entry (`tests/bin/test-language-registry/fixtures/fake-suite.json`).

## Residue check

`tests/tests/test-language-registry-residue.sh` (via `scan.js`) derives its search words from the table: pattern fragments of 3+ characters (`.sh`, `.Tests.ps1`, `test_`, `.py`, `.js`, …) and ids of 4+ characters.
It scans tracked `bin/**`, `hooks/**`, `tests/run-all.sh`, `tests/lib/**`, `skills/*/scripts/**` and the `paths:` headers of `rules/test*.md`, excluding the registry files and registered part files.
It fails when (a) one file uses pattern words of two entries, or one line names two ids; (b) a file using a pattern word also names the test location (`tests`, `TESTS_DIR`); or (c) shared code compares an id string.
`tests/tests/test-language-registry-residue/allowlist.tsv` (`path<TAB>substring<TAB>reason`) records legitimate exceptions; a row without a reason, or matching nothing, fails.
