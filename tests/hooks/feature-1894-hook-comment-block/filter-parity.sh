#!/usr/bin/env bash
# tests/hooks/feature-1894-hook-comment-block/filter-parity.sh
# Tests: hooks/lib/comment-block-scan.js, bin/review-comment-block-size
# Tags: comment-block-size, parity, drift, ssot, static-guard, dual-representation, scope:issue-specific, scope:feature-1894, layer:TL2, node-precommit

# Part 7: the file-level filters and the scan core have one owner. Since #2507 the commit-time
# review is Node (hooks/lib/comment-block-review) and reuses comment-block-scan.js, so the bash
# twin this file once drift-netted is gone; what remains pinned is that no second copy returns.

PARITY_JS="$TMPDIR_BASE/parity.js"
cat > "$PARITY_JS" <<'PARJS'
// <module> segments|extensions|config-extensions -> one value per line, sorted.
const mod = require(process.argv[2]);
const mode = process.argv[3];
let list;
if (mode === "segments") list = mod.EXCLUDED_PATH_SEGMENTS;
else if (mode === "extensions") list = mod.parseExtensions("");
else list = mod.parseExtensions(require(process.argv[4]).readConfig(process.argv[5]).extensionsRaw);
if (!Array.isArray(list)) { process.stderr.write("not an array\n"); process.exit(3); }
process.stdout.write(list.slice().sort().join("\n") + "\n");
PARJS

REVIEW_DIR="$SCRIPT_CHECKOUT_ROOT/hooks/lib/comment-block-review"

node_list() {
    if [ ! -f "$SCAN_MODULE" ]; then printf 'MODULE-MISSING'; return; fi
    node "$PARITY_JS" "$(mpath "$SCAN_MODULE")" "$@" 2>/dev/null || printf 'ERROR'
}

# F1: the excluded path segments live only in comment-block-scan.js.
f1_excluded_segments_single_owner() {
    local node_raw; node_raw="$(node_list segments)"
    if [ "$node_raw" = "MODULE-MISSING" ]; then
        fail "F1: hooks/lib/comment-block-scan.js does not exist"
        return
    fi
    assert_eq "F1/excluded-segments" "$(printf '%s\n' .git _archive _archived node_modules | sort)" \
        "$(printf '%s\n' "$node_raw" | grep -v '^$' | sort)"
    if grep -rqE 'node_modules|_archived' "$SCANNER_CLI" "$REVIEW_DIR" "$SCRIPT_CHECKOUT_ROOT/bin/review-comment-block-size.d"; then
        fail "F1: a second excluded-segment list exists outside comment-block-scan.js" \
             "The commit-time review must call scan.isExcludedPath, not re-list the segments."
    else
        pass "F1: no second excluded-segment list"
    fi
}

# F2: the default extension list is js/py/sh, and the review's config default agrees with it.
f2_default_extensions_parity() {
    local node_raw; node_raw="$(node_list extensions)"
    if [ "$node_raw" = "MODULE-MISSING" ]; then
        fail "F2: hooks/lib/comment-block-scan.js does not exist"
        return
    fi
    local want="js
py
sh"
    assert_eq "F2/default-is-js-sh-py" "$want" "$(printf '%s\n' "$node_raw" | grep -v '^$' | sort)"
    local cfg_raw
    # An empty cfg dir (no .env) yields the review's built-in default.
    mkdir -p "$TMPDIR_BASE/parity-cfg"
    cfg_raw="$(node "$PARITY_JS" "$(mpath "$SCAN_MODULE")" config-extensions "$(mpath "$REVIEW_DIR/config.js")" "$(mpath "$TMPDIR_BASE/parity-cfg")" 2>&1)"
    assert_eq "F2/review-config-default-matches" "$want" "$(printf '%s\n' "$cfg_raw" | grep -v '^$' | sort)"
}

# F4: the scan core is not duplicated; the bash entry delegates and the review reuses the core.
f4_scan_core_is_not_duplicated() {
    if grep -qE '^\s*awk |\| *awk ' "$SCANNER_CLI"; then
        fail "F4: bin/review-comment-block-size still runs awk" \
             "The scan core is Node (Approach A); the bash side must delegate, not re-implement."
    else
        pass "F4: bin/review-comment-block-size carries no awk scan core"
    fi
    if grep -q 'review-comment-block-size.d/cli.js' "$SCANNER_CLI"; then
        pass "F4: bin/review-comment-block-size delegates to the Node CLI"
    else
        fail "F4: bin/review-comment-block-size does not exec review-comment-block-size.d/cli.js"
    fi
    if [ -f "$REVIEW_JS" ] && grep -q 'require("../comment-block-scan")' "$REVIEW_JS"; then
        pass "F4: the commit-time review scans through comment-block-scan.js"
    else
        fail "F4: $REVIEW_JS does not require ../comment-block-scan"
    fi
}

f1_excluded_segments_single_owner
f2_default_extensions_parity
f4_scan_core_is_not_duplicated
