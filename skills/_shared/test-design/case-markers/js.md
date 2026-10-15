> Notation file of `skills/_shared/test-design/case-markers.md` (common rules there). Read it when writing or editing a `.js` test.

# Case markers in JavaScript tests

## Helper library

- Load line: `const { caseBegin, caseEnd } = require("../lib/harness");` — `require("../lib/harness")` is the one canonical form.
- Place it at the top of the file, before the first marker; list the further helpers you use in the same braces.
- Skip a real-environment test with `{ skip: !tl3Enabled() }`.
- Write a known failure as `xfail("<name>", fn)`.
- The helper library also checks the pairing at run time: an unclosed or doubled marker fails the run.

## Notation

- Open a case with `caseBegin("<name>", "<target>");` and close it with `caseEnd();`.
- Write both directly at column 0, each on one line.
- Call them by those names: a call through a variable or another object is not seen, and the file then reads as having no markers.
- Write name and target as one-line string literals with no `${...}` and no escape other than a quote or a backslash.
- Never write a marker call inside a block comment or a multi-line template string.
- The reader reads lines and never parses or runs the file, so JavaScript syntax is not checked here.
- The range runs from the `caseBegin` line to the `caseEnd` line.

## Malformed reasons

| Reason | Cause |
|---|---|
| `grammar` | An empty case name |
| `constant` | An argument that is not a one-line string literal |
| `missing-target` | `caseBegin` with a name only |
| `duplicate-target` | `caseBegin` with more than two arguments |
| `target` | A target that breaks the common path rule |
| `depth` | `caseBegin` while a case is still open |
| `balance` | `caseEnd()` without an open case, or a case never closed |
| `nested-target` | An indented `caseBegin` with a name and a target |

- A marker-looking line inside a block comment or a multi-line template string is reported as `UNCERTAIN_CASE_MARKER` (WARN).
- A machine without `node` gets `CASE_MARKER_RUNTIME_UNAVAILABLE` (WARN): the markers are not checked there.

## Examples

Correct — after the load line, three lines, each at column 0:

- `caseBegin("missing-header-blocks", "hooks/block-case-markers.js");`
- `test("rejects a file without a Tests header", () => assert.equal(run(FIXTURE), 1));`
- `caseEnd();`

Incorrect (indented marker — `nested-target`): the same `caseBegin` line indented inside a `describe("header", () => { ... });` body.
