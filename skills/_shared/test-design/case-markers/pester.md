> Notation file of `skills/_shared/test-design/case-markers.md` (common rules there). Read it when writing or editing a `.Tests.ps1` test.

# Case markers in Pester tests

## Helper library

- Load line: `. (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')`.
- Place it inside a top-level `BeforeAll`, on a line of its own that starts with the dot (`bin/check-test-frontmatter.sh` looks for that spelling).
- Never load it at file top level: functions defined during discovery are gone at run time.
- Call a helper function only at run time, inside `It` or `BeforeAll`.
- Call `Skip-HarnessUnlessTL3` as the first statement of an `It`; it cannot feed an `It`'s `-Skip:` argument.
- Wrap a known failure in `Invoke-HarnessKnownFailure -Because '<why>' -ScriptBlock { ... }`.

## Notation

- A case is a top-level `Describe` — a direct statement of the file, not one inside `if`, a function, or another block.
- Give every top-level `Describe` one tag `-Tag 'target:<path>'`; other tags may sit beside it.
- Write the `Describe` name and every tag as a string constant, never a variable or an expression.
- Never put a `target:` tag on a nested `Describe` or a `Context`.
- The case name is the `Describe` name; the range runs from the `Describe` line to its closing brace.
- The reader parses the file and never runs it, so a target built at run time is not seen.

## Malformed reasons

| Reason | Cause |
|---|---|
| `grammar` | The file does not parse |
| `constant` | A `Describe` name or a tag that is not a string constant |
| `duplicate-target` | Two `target:` tags on one `Describe` |
| `target` | A target that breaks the common path rule |
| `missing-target` | A top-level `Describe` without a target beside one that has it |
| `nested-target` | A `target:` tag below the top level, or on any `Context` |

- A machine without `pwsh` gets `CASE_MARKER_RUNTIME_UNAVAILABLE` (WARN): the markers are not checked there.

## Examples

Correct:

- A top-level `BeforeAll { ... }` holding the load line on its own line.
- A top-level `Describe 'missing header blocks' -Tag 'target:install/win/setup.ps1' { ... }`.
- Inside it, `It 'rejects a file without a Tests header' { $result | Should -Be 1 }`.

Incorrect (target on a nested block — `nested-target`): `Context 'missing header' -Tag 'target:install/win/setup.ps1' { }` inside `Describe 'setup' { ... }`.
