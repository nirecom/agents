# SO (#2411): codeLanguage.sourcePatterns of two entries must not match a common basename.
# Sourced by tests/hooks/feature-2411-registry-validation.sh, which provides run_rows and the
# base fixture. Globs are star-only (0-2 *, checkPattern), * = zero or more chars as in bash glob;
# overlap inside one entry is allowed; test-file patterns are out of scope.
# shellcheck shell=bash

case_begin "future-source-patterns-overlap-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
overlap-same-single-pattern|pester|sourcePatterns|e.codeLanguage.sourcePatterns = [t.entries.find((o) => o.id === "bash").codeLanguage.sourcePatterns[0]];
overlap-one-of-two-patterns|js|sourcePatterns|e.codeLanguage.sourcePatterns = e.codeLanguage.sourcePatterns.concat(t.entries.find((o) => o.id === "pytest").codeLanguage.sourcePatterns);
ROWS
# Distinct strings across two entries that share a basename: two edits each.
# Witnesses: test_a.py, a.ps1, y_x.js, a_b.py, xy.js, test_a.py, test_.py (only via an empty *),
# test_a.py (only via the earlier entry's second pattern; pester precedes pytest in the table).
run_rows reject 2 <<'ROWS'
glob-overlap-star-vs-prefixed|pester|sourcePatterns|t.entries.find((o) => o.id === "pytest").codeLanguage.sourcePatterns = ["*.py"]; e.codeLanguage.sourcePatterns = ["test_*.py"];
glob-overlap-star-vs-letter-prefix|bash|sourcePatterns|t.entries.find((o) => o.id === "pester").codeLanguage.sourcePatterns = ["*.ps1"]; e.codeLanguage.sourcePatterns = ["a*.ps1"];
glob-overlap-suffix-vs-prefix|pytest|sourcePatterns|t.entries.find((o) => o.id === "js").codeLanguage.sourcePatterns = ["*_x.js"]; e.codeLanguage.sourcePatterns = ["y_*.js"];
glob-overlap-two-star-prefix-vs-infix|pester|sourcePatterns|t.entries.find((o) => o.id === "pytest").codeLanguage.sourcePatterns = ["a*_*.py"]; e.codeLanguage.sourcePatterns = ["*_b*.py"];
glob-overlap-two-star-infix-vs-infix|bash|sourcePatterns|t.entries.find((o) => o.id === "js").codeLanguage.sourcePatterns = ["*x*.js"]; e.codeLanguage.sourcePatterns = ["*y*.js"];
glob-overlap-literal-vs-wildcard|pester|sourcePatterns|t.entries.find((o) => o.id === "pytest").codeLanguage.sourcePatterns = ["test_*.py"]; e.codeLanguage.sourcePatterns = ["test_a.py"];
glob-overlap-star-matches-empty|pester|sourcePatterns|t.entries.find((o) => o.id === "pytest").codeLanguage.sourcePatterns = ["test_*.py"]; e.codeLanguage.sourcePatterns = ["test_.py"];
glob-overlap-earlier-second-pattern|pytest|sourcePatterns|t.entries.find((o) => o.id === "pester").codeLanguage.sourcePatterns = ["*.zz", "*.py"]; e.codeLanguage.sourcePatterns = ["test_*.py"];
ROWS
case_end

# Disjoint by a differing fixed first char or a differing fixed suffix, so no basename fits both.
case_begin "pin-source-patterns-disjoint-globs-accept" "hooks/lib/test-language-registry/validate.js"
run_rows accept <<'ROWS'
glob-disjoint-ps1-vs-psm1|bash|x|t.entries.find((o) => o.id === "pester").codeLanguage.sourcePatterns = ["*.ps1"]; e.codeLanguage.sourcePatterns = ["*.psm1"];
glob-disjoint-a-vs-b-prefix|pytest|x|t.entries.find((o) => o.id === "js").codeLanguage.sourcePatterns = ["a*.zz"]; e.codeLanguage.sourcePatterns = ["b*.zz"];
glob-disjoint-cjs-vs-mjs|js|x|t.entries.find((o) => o.id === "bash").codeLanguage.sourcePatterns = ["*.cjs"]; e.codeLanguage.sourcePatterns = ["*.mjs"];
glob-disjoint-two-star-first-char|pester|x|t.entries.find((o) => o.id === "pytest").codeLanguage.sourcePatterns = ["a*_*.zz"]; e.codeLanguage.sourcePatterns = ["b*_*.zz"];
glob-disjoint-two-star-suffix|bash|x|t.entries.find((o) => o.id === "js").codeLanguage.sourcePatterns = ["*a*.zz"]; e.codeLanguage.sourcePatterns = ["*b*.yy"];
glob-disjoint-literal-vs-wildcard|pester|x|t.entries.find((o) => o.id === "pytest").codeLanguage.sourcePatterns = ["test_*.py"]; e.codeLanguage.sourcePatterns = ["other.py"];
glob-overlap-within-one-entry-allowed|pytest|x|e.codeLanguage.sourcePatterns = ["*.py", "test_*.py"];
ROWS
case_end
