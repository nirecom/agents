# tests/feature-2134-bash-guard/forbidden-literals-doc-sync.sh
# Tests: hooks/bash-guard/forbidden-literals.js, bin/print-forbidden-literals, rules/shell-commands.md
# Tags: hook, bash-guard, forbidden-literals, ssot, docs-code-consistency, scope:issue-specific, pwsh-not-required, TL2
# S5-3 (detail.md): rules/shell-commands.md is a Read tool, so nothing here may write to it --
# this file pins the SSOT's 7 human-authored rows against the 10 machine ids, and the
# generator that is supposed to keep the two in sync. Sourced by the dispatcher, which owns
# PASS/FAIL/ROWS, assert_eq, probe, node_path, run_with_timeout, AGENTS_DIR.

DOC_SYNC_FILE="$AGENTS_DIR/rules/shell-commands.md"

# Extract the 7 data rows of the "Prohibited literal | Form" table verbatim -- this table has
# no GENERATED marker today (S5-3 is what would add one); parsing the literal markdown keeps
# this pin honest about the CURRENT document rather than a marker convention nobody wrote yet.
doc_sync_extract_rows() {
    run_with_timeout 30 node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const lines = src.split(/\r?\n/);
const start = lines.findIndex((l) => /^\|\s*Prohibited literal\s*\|\s*Form\s*\|/.test(l));
if (start === -1) { process.stdout.write("<NO-TABLE>"); process.exit(0); }
const rows = [];
for (let i = start + 2; i < lines.length; i++) {
  const l = lines[i];
  if (!l.startsWith("|")) break;
  rows.push(l.replace(/^\|\s*/, "").replace(/\s*\|\s*$/, ""));
}
process.stdout.write(JSON.stringify(rows));
' "$(node_path "$DOC_SYNC_FILE")" 2>/dev/null
}

DOC_ROWS="$(doc_sync_extract_rows)"
ROWS=$((ROWS + 1))
assert_eq "DS1: rules/shell-commands.md carries exactly 7 forbidden-literal table rows" \
    '["`&&` / `;` | command chaining","`\\|` | pipe","`` ` `` / `$(...)` | command substitution, variable capture","`{ ... }` | grouping","`<<` | heredoc","`>` / `>>` | redirect","`FOO=1 BAR=2 cmd` | leading environment-variable prefixes"]' \
    "$DOC_ROWS"

# DS2: the 10-ids-fold-to-7-rows MAPPING, not merely the count cases-not-forbidden.sh F3
# already pins. Two ids sharing a row (chain-and+chain-semicolon, backtick+cmd-subst,
# redirect-out+redirect-append) must fold onto the SAME row index; a generator that emitted
# the right row COUNT by accident (e.g. one id per row plus three blanks) would still fail here.
IDS_ORDER="$(probe ids '')"
ROWS=$((ROWS + 1))
assert_eq "DS2: forbidden-literals.js ids are in the exact order the doc's rows assume" \
    "chain-and,chain-semicolon,pipe,backtick,cmd-subst,brace-group,heredoc,redirect-out,redirect-append,env-prefix" \
    "$IDS_ORDER"

# id -> doc-row-index map this test asserts (0-based, matching DOC_ROWS above). DS3_GOT is read
# straight off forbidden-literals.js's own per-entry `.row` field via the id-row-map probe mode
# -- never re-derived from DS2's id order plus a guessed fold, so a generator that emitted the
# right ROW COUNT (DS2) by accident but assigned a wrong row to one id still fails here.
DS_MAP='{"chain-and":0,"chain-semicolon":0,"pipe":1,"backtick":2,"cmd-subst":2,"brace-group":3,"heredoc":4,"redirect-out":5,"redirect-append":5,"env-prefix":6}'
DS3_GOT="$(probe id-row-map '')"
ROWS=$((ROWS + 1))
assert_eq "DS3: the 10-id-to-7-row fold is exactly this mapping (chain-and/chain-semicolon, backtick/cmd-subst, redirect-out/redirect-append share a row)" \
    "$DS_MAP" \
    "$DS3_GOT"

# DS4: bin/print-forbidden-literals --markdown-table must reproduce these same 7 rows
# byte-for-byte (mirrors tests/feature-2099-complexity-stage-routing/rubric-table-consistency.sh's
# generated-block byte-compare) -- RED until the tool exists (S5-3's deliverable), reported
# attributably rather than as a silent empty-string equality.
PFL="$AGENTS_DIR/bin/print-forbidden-literals"
ROWS=$((ROWS + 1))
if [ -x "$PFL" ] || [ -f "$PFL" ]; then
    DS4_GOT="$(run_with_timeout 30 node "$(node_path "$PFL")" --markdown-table 2>/dev/null)"
else
    DS4_GOT="<MISSING:bin/print-forbidden-literals>"
fi
DS4_WANT="$(run_with_timeout 30 node -e '
process.stdout.write(JSON.parse(process.argv[1]).map((r) => "| " + r + " |").join("\n"));
' "$DOC_ROWS" 2>/dev/null)"
assert_eq "DS4: print-forbidden-literals --markdown-table matches rules/shell-commands.md byte-for-byte" \
    "$DS4_WANT" "$DS4_GOT"
