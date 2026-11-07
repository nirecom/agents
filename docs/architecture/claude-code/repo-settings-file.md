# Repo settings file (`.agents.json`)

Each target repo carries one `.agents.json` at its root. It tells the test workflow where the repo keeps its tests and records which `/migrate` steps the repo has completed (#2473). Before this file existed, the gates and tools hard-coded the agents repo's own layout.

`.agents.json` is the only canonical place for these facts. Every other location (gates, bash tools, skills) reads it through the reader. None of them keeps its own copy of the category list.

## Readers

| Caller | Entry point |
|---|---|
| Node (hooks, gates) | `hooks/lib/repo-settings.js` (`load`, `validateDoc`, `testDirsIn`); `hooks/lib/test-gates/registry.js` (`layoutFor`, `categoriesFor`, `placementOf`) |
| Bash | `bin/lib/repo-settings.sh` (`rsf_load`, `rsf_categories_into`), which wraps `bin/repo-settings --format shell` |
| Writes | `bin/repo-settings --set-migrate <key>` / `--write-tests <json>`; both refuse a file that is not JSON or not an object. A write lands only when the written section validates, and the tool never commits. Repair: `--reset-malformed` (only with `--root`) copies such a file to `.agents.json.malformed` and leaves `{}`; a valid or absent file is left alone. `/migrate` MG-1 runs it once when `bin/migrate-needs` prints `MALFORMED=1`. |

## Schema

The file holds a JSON object. Each top-level section is validated on its own, and unknown sections are ignored.

### `tests`

| Key | Required | Value |
|---|---|---|
| `dir` | no (default `tests`) | One path segment: the tests root. |
| `categorization` | yes | `flat`, `by-target` or `by-type`. |
| `categories` | not allowed when flat; otherwise at least one | `{ "dir": <segment>, "covers": [<path>...] }`. `covers` is required for `by-target` and not allowed for `by-type`. |
| `supportDirs` | no (default `[]`) | Path segments under `dir` that hold helpers, not tests (for example `lib`, `_archive`). |
| `testHarness` | yes | `on` / `off`. When `off`, new test files are not required to load the language `helperLibrary`. |
| `caseMarker` | yes | `on` / `off`. When `off`, the case marker gate and CLI skip the repo. |

A category `dir` must not also appear in `supportDirs`.

### `migrate`

Keys are `tracker`, `issues` and `tests`, and the only value is `done`. `/migrate` sets each key when the matching sub-skill finishes, and skips that sub-skill on later runs.

## Section states

| State | Meaning |
|---|---|
| `ok` | Present and valid; the defaults are applied. |
| `missing` | The file or the section is absent. |
| `malformed` | The file is not JSON, or the section breaks the schema (`errors` lists why). |

## Placement

A path under `dir` is classified as one of:

- `category`: directly in a category dir
- `flat`: directly in `dir`; this is the entrypoint placement only when categorization is `flat`, and a categorized repo rejects new flat tests
- `support`: under a support dir
- `suite-subfile`: deeper than an entrypoint, whether inside a category dir or in any other subdirectory
- `runner`: `dir/run-all.sh`
- `outside`: not under `dir`

A `by-target` test whose `Tests:` targets all fall outside its category's `covers` draws `WARN ... code=TEST_CATEGORY_MISMATCH`.

## Uninitialized repos (named exception)

When the `tests` section is not `ok`, the gates fall back to the pre-#2473 layout:

- `dir` is `tests`, with `by-target` categories `hooks bin skills agents install tests`, each covering itself
- `supportDirs` is `_archive lib`
- the test harness and case marker requirements are judged by whether the helper file exists

The commit is never blocked for being uninitialized. Each process emits one `WARN: .agents.json: tests section <state>; ... run /migrate code=REPO_SETTINGS_UNINITIALIZED`. `tests/run-all.sh` instead stops with exit 6 and points to `/migrate`.
