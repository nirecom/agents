> `skills/_shared/test-design.md` の詳細ファイル。対象がパーサ・正規表現定数・allowlist ファイルの場合に読む。

## Table-Driven Tests (required when changing parsers, regex constants, or allowlists)

When modifying parsers, regex constants, or allowlists (e.g. sentinel-patterns.js,
bash-write-patterns.js, command-parser.js, scan-outbound.sh), use table-driven patterns
in the corresponding test file.

### Standard bash pattern

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got=$(eval_subject "$input")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
case-name-1 | input value 1 | expected-1
case-name-2 | input value 2 | expected-2
TABLE

Define assert_eq inline in each test file (no shared library):

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

- The first column `name` is injected into every assertion message (equivalent to Go's `t.Run(name)`).
- `IFS='|'` allows spaces inside fields without quoting. `read -r` prevents backslash expansion.
- Blank lines and `#` comment lines in the heredoc are skipped.

### Equivalent JS pattern

A JS test is considered table-driven when it uses:
- `cases.forEach()` iteration, or
- `for (const {name, input, want} of cases)` iteration,
- with `name` included in the assertion message inside each iteration.

### When this rule applies

Apply when any of the following is true:
- Adding or modifying regex constants in a pattern file.
- Testing the same function with 2 or more different inputs.
- An existing test file for a parser/regex/allowlist target has fewer than 2 cases per logical path.

## Mutation Probe (lightweight regex kill verification)

Run a mutation probe against parser/regex files when:
- Adding a new regex constant (verify the test FAILs when that constant is removed).
- Fixing a regex bug (verify the regression test FAILs against the unpatched code).

### Running the probe

bin/mutation-probe.sh <target-js-file>

Probe behavior:
1. Identifies regex constants in the target file (single-line `const NAME = /regex/;` form).
2. Replaces each constant with `/(?!)/` (never-match) in a temporary copy and runs the tests.
3. Records PASS and FAIL counts.
4. Computes mutation score = (FAIL count / total) × 100% and reports it.

Required threshold: at least 80% of probed regex constants must cause a test FAIL.

### Known limitation (partial coverage)

`bin/mutation-probe.sh` targets single-line form (`const NAME = /regex/;`) only.
Not covered in the current version:
- Two-line form (`const NAME =\n  /regex/;`): common in sentinel-patterns.js.
- Patterns inside object literals (`regex` field of `WRITE_PATTERNS` array): bash-write-patterns.js.

When the probe runs against these files it prints the detected constant count and a
"partial coverage" warning. Full coverage is planned for T1-E2 (Stryker).

### Relationship to table-driven tests

- Table-driven: parametrically covers input/output cases.
- Mutation probe: verifies that each regex constant is actually exercised by tests (not dead code).

Run both when adding to a parser/regex file.
