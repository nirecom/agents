#!/bin/bash
# tests/fix-1899-parse-remote-url/_lib.sh — shared scaffolding
#
# Sourced by each split file (via a BASH_SOURCE-relative path) so they can also
# run standalone. Provides the scaffolding common to all split files:
#   - AGENTS_DIR + PRU_JS / IPR_JS module paths (cygpath-normalized)
#   - PASS / FAIL counters and pass / fail / assert_eq helpers
#   - run_with_timeout wrapper
#   - call_fn / call_fail_message / call_redact_expr node harnesses
#   - finish() — prints "Results: N passed, M failed" and exits
#
# Tests: hooks/lib/parse-remote-url.js, hooks/lib/is-private-repo.js
# Tags: parse-remote-url, origin-resolution, table-driven, parser, regex, security, path-traversal, secret-redaction, TL1, scope:issue-specific
#
# NOT a test file: no # Tests:/# Tags: frontmatter; excluded from the
# dispatcher's SPLIT_GROUPS.
#
# Idempotent — guarded so multiple sources do not redefine state.

if [ -n "${_FIX1899_PRU_LIB_SOURCED:-}" ]; then
    return 0
fi
_FIX1899_PRU_LIB_SOURCED=1

set -u

# Repo root, resolved relative to this lib (tests/fix-1899-parse-remote-url/).
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

PRU_JS="$(nodepath "$AGENTS_DIR/hooks/lib/parse-remote-url.js")"
IPR_JS="$(nodepath "$AGENTS_DIR/hooks/lib/is-private-repo.js")"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# call_fn <module-path> <fn> <input>
#   __EMPTY__ input means the empty string (the table cannot carry it directly).
#   Scalar results print verbatim; null/undefined prints "null".
#   Object results (parseOriginOwnerRepo) print:
#       ok:<ownerRepo>:<owner>:<repo>:<host>   on success
#       fail:<code>                            on failure
#   Any load/shape problem prints ERR:<what> so a missing module is a FAIL with
#   a readable reason rather than a crash.
call_fn() {
    run_with_timeout 20 node -e '
const p = process.argv[1], fn = process.argv[2];
let arg = process.argv[3];
if (arg === "__EMPTY__") arg = "";
if (arg === "__NULL__") arg = null;
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require-failed"); process.exit(0); }
if (!m || typeof m[fn] !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m[fn](arg); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
if (r === null || r === undefined) { process.stdout.write("null"); process.exit(0); }
if (typeof r === "object") {
  if (r.ok === true) {
    process.stdout.write("ok:" + r.ownerRepo + ":" + r.owner + ":" + r.repo + ":" + r.host);
  } else {
    process.stdout.write("fail:" + r.code);
  }
  process.exit(0);
}
process.stdout.write(String(r));
' "$1" "$2" "$3" 2>/dev/null
}

# call_fail_message <url> -> the .message of a parseOriginOwnerRepo FAILURE.
#   Prints ERR:not-a-failure when the call unexpectedly succeeded, so an F2 case
#   can never go green by way of the input parsing differently than intended.
#   The url is passed as an argv value (never through the table's xargs pass),
#   so leading whitespace survives — that whitespace IS the F2 trigger.
call_fail_message() {
    run_with_timeout 20 node -e '
const p = process.argv[1];
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require-failed"); process.exit(0); }
if (!m || typeof m.parseOriginOwnerRepo !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m.parseOriginOwnerRepo(process.argv[2]); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
if (!r || r.ok !== false) { process.stdout.write("ERR:not-a-failure"); process.exit(0); }
process.stdout.write(String(r.message));
' "$PRU_JS" "$1" 2>/dev/null
}

# call_redact_expr <js-expression> -> redactUserinfo(<expr>), type-tagged.
#   The table path can only deliver strings; this covers the non-string edge rows
#   (null / undefined / 123), which must come back unchanged, not coerced.
call_redact_expr() {
    run_with_timeout 20 node -e '
const p = process.argv[1];
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require-failed"); process.exit(0); }
if (!m || typeof m.redactUserinfo !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let input;
try { input = eval("(" + process.argv[2] + ")"); } catch (e) { process.stdout.write("ERR:bad-expr"); process.exit(0); }
let r;
try { r = m.redactUserinfo(input); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
if (r === null) { process.stdout.write("NULL"); process.exit(0); }
if (r === undefined) { process.stdout.write("UNDEFINED"); process.exit(0); }
process.stdout.write(typeof r + ":" + String(r));
' "$PRU_JS" "$1" 2>/dev/null
}

# Print results summary and exit with appropriate code.
finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}
