#!/usr/bin/env bash
# Tests: hooks/lib/forge-write-extract.js, hooks/lib/parse-remote-url.js, hooks/lib/bash-write-patterns/segment-utils.js, hooks/lib/bash-write-patterns/patterns.js
# Tags: hook, bin, git, pr, github, ownership, scope:common
# Part of tests/feature-forge-write-scan-extract.sh (rules/coding/file-split.md).
# Shared expression probe for the section-2053 part files.

# WHY it is shared: cases-2053-additive-exports.sh and cases-2053-tables.sh both
# evaluate JS expressions against the same four modules. Two copies of the probe
# would be two definitions of "how a module that failed to load reports itself",
# and the two files would drift on what a red case looks like (CPR-SSOT).

# init_2053_probe — writes the probe and sets PROBE_2053 / LIB_M_2053.
init_2053_probe() {
    PROBE_2053="$TMPBASE/additive-probe.js"
    if command -v cygpath >/dev/null 2>&1; then
        LIB_M_2053="$(cygpath -m "$DOTFILES_DIR/hooks/lib")"
    else
        LIB_M_2053="$DOTFILES_DIR/hooks/lib"
    fi
    cat > "$PROBE_2053" <<'PROBE_EOF'
"use strict";
// argv[2] = node-style path to hooks/lib, argv[3] = expression source.
// Modules bind as m/p/s/g; one that fails to load binds to a proxy throwing
// MODULE-MISSING:<name>, so unrelated cases still report their own real result.
const path = require("path");
const LIB = process.argv[2];
function load(rel, name) {
    try {
        return require(path.join(LIB, rel));
    } catch (e) {
        const reason = "MODULE-MISSING:" + name + (e && e.code === "MODULE_NOT_FOUND" ? "" : ":" + (e && e.message));
        return new Proxy({}, { get() { throw new Error(reason); } });
    }
}
const m = load("forge-write-extract.js", "forge-write-extract");
const p = load("parse-remote-url.js", "parse-remote-url");
const s = load("bash-write-patterns/segment-utils.js", "segment-utils");
const g = load("bash-write-patterns/patterns.js", "patterns");
let v;
try {
    // eslint-disable-next-line no-new-func
    v = new Function("m", "p", "s", "g", "return (" + process.argv[3] + ");")(m, p, s, g);
} catch (e) {
    process.stdout.write("THREW:" + (e && e.message ? e.message : String(e)));
    process.exit(0);
}
// Always JSON — a string result therefore arrives quoted, which keeps `"true"`
// (a string) distinguishable from `true` (a boolean) in the expected values.
process.stdout.write(v === undefined ? "undefined" : JSON.stringify(v));
PROBE_EOF
}

# expect_expr <name> <want> <js-expression>
expect_expr() {
    local name="$1" want="$2" expr="$3" got
    got="$(run_with_timeout node "$PROBE_2053" "$LIB_M_2053" "$expr" 2>&1 || true)"
    if [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name (want=$want got=$got)"
    fi
    if [ -z "$name" ]; then
        fail "expect_expr called with an empty case name"
    fi
}

# expr_table <label> — reads `name|want|expr` rows on stdin and runs each through
# expect_expr with the label prefixed, so every assertion line carries both the
# table it came from and its own row name. Blank lines and #-comments are skipped.
# The expression is the LAST field, so a `|` inside it survives intact.
expr_table() {
    local label="$1" name want expr rows=0
    while IFS='|' read -r name want expr; do
        case "$name" in ""|"#"*) continue ;; esac
        rows=$((rows + 1))
        expect_expr "$label [$name]" "$want" "$expr"
    done
    if [ "$rows" -eq 0 ]; then
        fail "$label — the table was empty, so it asserted nothing"
    fi
}
