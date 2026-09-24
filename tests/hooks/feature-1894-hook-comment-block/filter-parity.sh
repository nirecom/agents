#!/usr/bin/env bash
# tests/feature-1894-hook-comment-block/filter-parity.sh
# Tests: hooks/lib/comment-block-scan.js, bin/review-comment-block-size
# Tags: comment-block-size, parity, drift, ssot, static-guard, dual-representation, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 7 — drift net for a deliberate duplication. Approach A moved the SCAN
# CORE into Node so the CLI and Edit-time hook share one implementation, but
# NOT the file-level filter rules (scannable extensions, skipped path
# segments): those stay written twice — bash (`path_ok()`, the
# CODE_FILE_EXTENSIONS default) and Node (EXCLUDED_PATH_SEGMENTS,
# parseExtensions' default) — since the filter runs once per FILE, the core
# once per LINE, and a handshake would cost a node spawn per CLI call to
# dedupe something that changes ~yearly (detail plan C7). This file is the
# only drift net: divergence fails silently at runtime, so assertions here
# are literal and set-based, not "contains".

PARITY_JS="$TMPDIR_BASE/parity.js"
cat > "$PARITY_JS" <<'PARJS'
// <mode> segments|extensions -> one value per line, sorted.
const mod = require(process.argv[2]);
const mode = process.argv[3];
let list;
if (mode === "segments") list = mod.EXCLUDED_PATH_SEGMENTS;
else list = mod.parseExtensions("");
if (!Array.isArray(list)) { process.stderr.write("not an array\n"); process.exit(3); }
process.stdout.write(list.slice().sort().join("\n") + "\n");
PARJS

node_list() {
    if [ ! -f "$SCAN_MODULE" ]; then printf 'MODULE-MISSING'; return; fi
    node "$PARITY_JS" "$(mpath "$SCAN_MODULE")" "$1" 2>/dev/null || printf 'ERROR'
}

# ============================================================================
# F1 — excluded path segments are the same set on both sides
# ============================================================================
f1_excluded_segments_parity() {
    if [ ! -f "$SCANNER_CLI" ]; then
        fail "F1: $SCANNER_CLI not found"
        return
    fi
    # The bash side expresses the rule as a glob case arm:
    #   */node_modules/*|*/.git/*|*/_archive/*|*/_archived/*) return 1 ;;
    # Extract the segment names from between the slashes, so a reordering of the
    # arm is not a failure but a changed membership is.
    local bash_line bash_list
    bash_line="$(grep -n 'node_modules' "$SCANNER_CLI" | head -1 | cut -d: -f2-)"
    if [ -z "$bash_line" ]; then
        fail "F1: no node_modules exclusion found in bin/review-comment-block-size"
        return
    fi
    bash_list="$(printf '%s\n' "$bash_line" | grep -oE '\*/[^/*|]+/\*' \
        | grep -oE '/[^/*]+/' | tr -d '/' | sort)"
    local node_raw; node_raw="$(node_list segments)"
    if [ "$node_raw" = "MODULE-MISSING" ]; then
        fail "F1: hooks/lib/comment-block-scan.js does not exist yet (issue #1894)"
        return
    fi
    local node_sorted; node_sorted="$(printf '%s\n' "$node_raw" | grep -v '^$' | sort)"
    assert_eq "F1/excluded-segments-identical" "$bash_list" "$node_sorted"

    # Named-member floor: whichever direction a future edit drops a value, the
    # set comparison above reports it as a diff without saying what was lost.
    # These four are the ones the repo actually depends on.
    local seg
    for seg in node_modules .git _archive _archived; do
        assert_contains "F1/node-side-has-$seg" "$seg" "$node_sorted"
        assert_contains "F1/bash-side-has-$seg" "$seg" "$bash_list"
    done
}

# ============================================================================
# F2 — the default extension list is the same on both sides
# ============================================================================
f2_default_extensions_parity() {
    local bash_default
    bash_default="$(grep -oE 'CODE_FILE_EXTENSIONS:-[^}"]+' "$SCANNER_CLI" | head -1)"
    bash_default="${bash_default#CODE_FILE_EXTENSIONS:-}"
    if [ -z "$bash_default" ]; then
        fail "F2: no CODE_FILE_EXTENSIONS default found in bin/review-comment-block-size"
        return
    fi
    local bash_sorted
    bash_sorted="$(printf '%s\n' "$bash_default" | tr ';' '\n' | grep -v '^$' | sort)"
    local node_raw; node_raw="$(node_list extensions)"
    if [ "$node_raw" = "MODULE-MISSING" ]; then
        fail "F2: hooks/lib/comment-block-scan.js does not exist yet (issue #1894)"
        return
    fi
    local node_sorted; node_sorted="$(printf '%s\n' "$node_raw" | grep -v '^$' | sort)"
    assert_eq "F2/default-extensions-identical" "$bash_sorted" "$node_sorted"
    # The floor, for the same reason as F1.
    assert_eq "F2/default-is-js-sh-py" "js
py
sh" "$node_sorted"
}

# ============================================================================
# F3 — the duplication stays a decision, in writing
#
# A dual representation with no note beside it reads as an accident, and the
# next person to find it will "fix" it — either by deleting one side (breaking a
# layer) or by adding the runtime handshake the plan rejected. The comment is
# what carries the reasoning forward, and this test is what keeps the comment.
# ============================================================================
f3_duplication_is_declared() {
    if [ ! -f "$SCAN_MODULE" ]; then
        fail "F3: hooks/lib/comment-block-scan.js does not exist yet (issue #1894)"
        return
    fi
    if grep -qiE 'review-comment-block-size|bash|parity|drift' "$SCAN_MODULE"; then
        pass "F3: the Node module points at its bash twin"
    else
        fail "F3: hooks/lib/comment-block-scan.js does not mention its bash counterpart" \
             "The dual representation is intentional; the module must say so and name the drift test."
    fi
}

# ============================================================================
# F4 — the scan core itself is NOT duplicated
#
# The other half of the same decision. Extensions and exclusions may live in two
# places; comment recognition may not — that is what Approach A bought, and the
# awk core it replaced has to be gone rather than merely unused. A leftover awk
# scanner is worse than the duplication above: it would silently disagree about
# what a comment is, which is the judgment itself.
# ============================================================================
f4_scan_core_is_not_duplicated() {
    if [ ! -f "$SCANNER_SH" ]; then
        skip "F4: $SCANNER_SH not found — scan step layout has changed"
        return
    fi
    if grep -qE '^\s*awk |\| *awk ' "$SCANNER_SH"; then
        fail "F4: bin/review-comment-block-size.d/scan.sh still runs awk" \
             "The scan core moved to Node (Approach A); the bash side must delegate, not re-implement."
    else
        pass "F4: scan.sh no longer carries an awk scan core"
    fi
    if grep -q 'scan-cli.js' "$SCANNER_SH"; then
        pass "F4: scan.sh delegates to the Node adapter"
    else
        fail "F4: scan.sh does not reference scan-cli.js" \
             "The bash shell keeps the git plumbing but must call the Node core for scanning."
    fi
}

f1_excluded_segments_parity
f2_default_extensions_parity
f3_duplication_is_declared
f4_scan_core_is_not_duplicated
