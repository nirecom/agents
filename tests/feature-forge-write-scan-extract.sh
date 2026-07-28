#!/bin/bash
# Tests: hooks/lib/forge-write-extract.js
# Tags: hook, bin, git, pr, github, scope:common
# Unit tests for hooks/lib/forge-write-extract.js
#
# The module exports two functions:
#   - isForgeScanTarget(command) -> boolean
#       true for: gh issue (create|edit|close|comment), gh pr (create|edit|close|comment|review)
#                 gh repo create|edit,
#                 gh api -X POST/PATCH/PUT/DELETE, gh api --method POST/PATCH/PUT/DELETE
#       false for: gh repo rename|archive|delete|view, gh issue list, git commit,
#                  gh api -X GET, gh api (no method flag)
#   - extractTexts(command) -> { inline: string[], filePaths: string[] }
#       --body "x" / --title "x" / --body 'x'   -> inline[]
#       --description "x" / --homepage "x"      -> inline[]
#       --body-file /path                        -> filePaths[]
#       heredoc <<'EOF'\n...\nEOF                -> inline[]
#       -f key=value / -F key=value / --field key=value -> inline[] (gh api fields)
#       --input @/path                           -> filePaths[]
#       --input - (stdin)                        -> empty (no extraction)
#       gh api -X GET (read-only)                -> empty (no extraction)
#       no match                                 -> { inline: [], filePaths: [] }
#
# These tests target the POST-implementation behavior. While the module does
# not yet exist, the driver detects MODULE_NOT_FOUND and reports every case as
# failing with the same "not yet implemented" diagnostic instead of crashing.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_REL="../hooks/lib/forge-write-extract.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

DRIVER="$TMPBASE/driver.js"

# Node driver that requires the module relative to the tests dir, then prints
# JSON results for the case identified by argv[2]. argv[1] = "target" or "extract".
cat > "$DRIVER" <<'NODE'
"use strict";
const path = require("path");
const TESTS_DIR = process.argv[2];
const MODE = process.argv[3];           // "target" | "extract"
const PAYLOAD = process.argv[4] || "";  // the command string

let mod;
try {
    mod = require(path.join(TESTS_DIR, "..", "hooks", "lib", "forge-write-extract.js"));
} catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND") {
        console.log(JSON.stringify({ ok: false, missing: true, error: "forge-write-extract.js not yet implemented" }));
        process.exit(0);
    }
    console.log(JSON.stringify({ ok: false, missing: false, error: String((e && e.message) || e) }));
    process.exit(0);
}

try {
    if (MODE === "target") {
        const v = mod.isForgeScanTarget(PAYLOAD);
        console.log(JSON.stringify({ ok: true, value: v }));
    } else if (MODE === "extract") {
        const v = mod.extractTexts(PAYLOAD);
        console.log(JSON.stringify({ ok: true, value: v }));
    } else {
        console.log(JSON.stringify({ ok: false, missing: false, error: "unknown mode: " + MODE }));
    }
} catch (e) {
    console.log(JSON.stringify({ ok: false, missing: false, error: String((e && e.message) || e) }));
}
NODE

TESTS_DIR="$DOTFILES_DIR/tests"

call_driver() {
    local mode="$1" payload="$2"
    run_with_timeout node "$DRIVER" "$TESTS_DIR" "$mode" "$payload"
}

# ---- isForgeScanTarget assertions ----
expect_target_true() {
    local desc="$1" cmd="$2"
    local out
    out="$(call_driver target "$cmd")"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$desc — forge-write-extract.js not yet implemented"
    elif echo "$out" | grep -q '"ok":true' && echo "$out" | grep -q '"value":true'; then
        pass "$desc"
    else
        fail "$desc — expected true, got: $out"
    fi
}

expect_target_false() {
    local desc="$1" cmd="$2"
    local out
    out="$(call_driver target "$cmd")"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$desc — forge-write-extract.js not yet implemented"
    elif echo "$out" | grep -q '"ok":true' && echo "$out" | grep -q '"value":false'; then
        pass "$desc"
    else
        fail "$desc — expected false, got: $out"
    fi
}

# ---- extractTexts assertions ----
# Each assertion uses a node sub-call to inspect the JSON value precisely
# (substring/membership checks avoid quoting hell in bash).
expect_extract() {
    local desc="$1" cmd="$2" check_js="$3"
    local out
    out="$(call_driver extract "$cmd")"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$desc — forge-write-extract.js not yet implemented"
        return
    fi
    if ! echo "$out" | grep -q '"ok":true'; then
        fail "$desc — driver error: $out"
        return
    fi
    # Hand the JSON output to a tiny node verifier
    local verdict
    verdict="$(node -e "
        const out = JSON.parse(process.argv[1]);
        const v = out.value;
        const ok = (function(){ ${check_js} })();
        console.log(ok ? 'PASS' : 'FAIL:' + JSON.stringify(v));
    " "$out")"
    if [ "$verdict" = "PASS" ]; then
        pass "$desc"
    else
        fail "$desc — assertion failed, value=${verdict#FAIL:}"
    fi
}

echo "=== isForgeScanTarget: TRUE cases ==="
expect_target_true "gh issue create -> true"               'gh issue create --title "T" --body "B"'
expect_target_true "gh issue edit -> true"                 'gh issue edit 5 --body "B"'
expect_target_true "gh issue close -> true"                'gh issue close 5'
expect_target_true "gh issue comment -> true"              'gh issue comment 5 --body "B"'
expect_target_true "gh pr create -> true"                  'gh pr create --body "B"'
expect_target_true "gh pr edit -> true"                    'gh pr edit 5 --body "B"'
expect_target_true "gh pr close -> true"                   'gh pr close 5'
expect_target_true "gh pr comment -> true"                 'gh pr comment 5 --body "B"'
expect_target_true "gh pr review -> true"                  'gh pr review 5 --body "B"'
expect_target_true "gh api -X POST -> true"                'gh api -X POST /repos/owner/repo/issues -f title=Test'
expect_target_true "gh api --method PATCH -> true"         'gh api --method PATCH /repos/owner/repo/issues/5 -f state=closed'
expect_target_true "gh api --method=PUT -> true"           'gh api --method=PUT /repos/owner/repo/labels/1 -f name=bug'
expect_target_true "gh api -X DELETE -> true"              'gh api -X DELETE /repos/owner/repo/issues/5/labels/bug'

echo ""
echo "=== isForgeScanTarget: FALSE cases ==="
expect_target_false "gh issue list -> false"               'gh issue list'
expect_target_true "gh repo create -> true"                'gh repo create myrepo'
expect_target_true "gh repo edit -> true"                  'gh repo edit --description "d"'
expect_target_false "gh repo rename -> false"              'gh repo rename old new'
expect_target_false "gh repo archive -> false"             'gh repo archive myrepo'
expect_target_false "gh repo delete -> false"              'gh repo delete myrepo'
expect_target_false "git commit -> false"                  'git commit -m "msg"'
expect_target_true "gh api -X PATCH -> true"               'gh api -X PATCH repos/owner/repo/issues/5'
expect_target_false "bare gh -> false"                     'gh'
expect_target_false "gh api -X GET -> false"               'gh api -X GET /repos/owner/repo/issues'
expect_target_false "gh api implicit GET -> false"         'gh api /repos/owner/repo/issues'
expect_target_false "gh api no method flag -> false"       'gh api /repos/owner/repo -f body=secret'

echo ""
echo "=== extractTexts: cases ==="

expect_extract "--body double-quoted -> inline" \
    'gh issue create --body "hello world"' \
    'return Array.isArray(v.inline) && v.inline.includes("hello world") && Array.isArray(v.filePaths) && v.filePaths.length === 0;'

expect_extract "--title + --body -> both in inline" \
    'gh issue create --title "My title" --body "body text"' \
    'return v.inline.includes("My title") && v.inline.includes("body text");'

expect_extract "--body single-quoted -> inline" \
    "gh issue create --body 'single-quoted body'" \
    'return v.inline.includes("single-quoted body") && v.filePaths.length === 0;'

expect_extract "no body flags -> empty arrays" \
    'gh issue close 5' \
    'return Array.isArray(v.inline) && v.inline.length === 0 && Array.isArray(v.filePaths) && v.filePaths.length === 0;'

expect_extract "--body-file -> filePaths" \
    'gh issue create --body-file /tmp/issue.txt' \
    'return v.filePaths.includes("/tmp/issue.txt") && v.inline.length === 0;'

expect_extract "--title + --body-file -> inline + filePaths" \
    'gh issue create --title "T" --body-file /tmp/f.md' \
    'return v.inline.includes("T") && v.filePaths.includes("/tmp/f.md");'

# heredoc — pass the command on a single argv but with real newlines via $'...'
HEREDOC_CMD=$'gh issue create --body "$(cat <<\'EOF\'\nhello there\nEOF\n)"'
expect_extract "heredoc <<'EOF' ... EOF -> inline contains content" \
    "$HEREDOC_CMD" \
    'return v.inline.some(s => s.indexOf("hello there") !== -1);'

expect_extract "--body= equals form -> inline" \
    'gh issue create --body="equals form value"' \
    'return v.inline.includes("equals form value") && v.filePaths.length === 0;'

expect_extract "--title= equals form -> inline" \
    'gh pr create --title="equals title" --body "body here"' \
    'return v.inline.includes("equals title") && v.inline.includes("body here");'

expect_extract "--body unquoted single-token -> inline" \
    'gh issue create --body unquotedvalue' \
    'return v.inline.some(s => s.indexOf("unquotedvalue") !== -1);'

HEREDOC_NONEOF_CMD=$'gh issue create --body "$(cat <<\'END\'\nhello with non-eof\nEND\n)"'
expect_extract "heredoc with non-EOF delimiter -> inline" \
    "$HEREDOC_NONEOF_CMD" \
    'return v.inline.some(s => s.indexOf("hello with non-eof") !== -1);'

echo ""
echo "=== extractTexts: gh api field cases (fail-before-fix #714) ==="

# gh api field extraction — fails before #714 fix (isForgeScanTarget returns
# false for all gh api commands so extractTexts is never reached)
expect_extract "gh api -f key=value -> inline" \
    'gh api -X POST /repos/owner/repo/issues -f title=MyTitle -f body=MyBody' \
    'return v.inline.includes("MyTitle") && v.inline.includes("MyBody");'

expect_extract "gh api -F uppercase -> inline" \
    'gh api -X PATCH /repos/owner/repo/issues/5 -F body=UpdatedBody' \
    'return v.inline.includes("UpdatedBody");'

expect_extract "gh api --field key=value -> inline" \
    'gh api -X POST /repos/owner/repo/issues --field title=LongTitle' \
    'return v.inline.includes("LongTitle");'

expect_extract "gh api --input @file -> filePaths" \
    'gh api -X POST /repos/owner/repo/issues --input @/tmp/issue-body.md' \
    'return v.filePaths.includes("/tmp/issue-body.md") && v.inline.length === 0;'

expect_extract "gh api --input - (stdin) -> empty" \
    'gh api -X POST /repos/owner/repo/issues --input -' \
    'return v.filePaths.length === 0 && v.inline.length === 0;'

expect_extract "gh api GET -> no extraction" \
    'gh api -X GET /repos/owner/repo/issues -f filter=all' \
    'return v.inline.length === 0 && v.filePaths.length === 0;'

echo ""
echo "=== extractTexts: gh repo description/homepage cases ==="

expect_extract "gh repo create --description -> inline" \
    'gh repo create foo/bar --description "secret-desc"' \
    'return Array.isArray(v.inline) && v.inline.some(s => s.indexOf("secret-desc") !== -1) && Array.isArray(v.filePaths);'

expect_extract "gh repo edit --homepage -> inline" \
    'gh repo edit foo/bar --homepage "https://internal.example.com"' \
    'return Array.isArray(v.inline) && v.inline.some(s => s.indexOf("internal.example.com") !== -1) && Array.isArray(v.filePaths);'

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi
