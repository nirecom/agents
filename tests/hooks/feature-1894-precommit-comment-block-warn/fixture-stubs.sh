#!/usr/bin/env bash
# tests/hooks/feature-1894-precommit-comment-block-warn/fixture-stubs.sh
# Tests: hooks/pre-commit
# Tags: comment-block-size, pre-commit, stub, fixture, scope:issue-specific, scope:feature-1894, layer:TL2

# Fixture stubs. #2507: the hook loads bin/review-comment-block-size.d/cli.js and the agents-repo
# gate modules in process, so the stubs stand at those module paths. Sourced by the dispatcher.

# The agents-repo gate modules (hooks/pre-commit.d/registry.js GATE_ROWS). They are not this
# suite's subject and would judge the fixture's partial tree, so each answers rc 0.
FIXTURE_GATE_MODULES=(bin/lib/check-on-demand-rules.js bin/check-session-id-ssot/main.js
    bin/lib/check-migration-blocks.js bin/check-plans-artifacts
    bin/check-plans-dir-isolation/main.js bin/check-root-names/main.js)

stub_agents_repo_gates() {
    local m
    for m in "${FIXTURE_GATE_MODULES[@]}"; do
        printf '%s\n' '"use strict";' 'exports.run = async () => 0;' > "$1/$m"
    done
}

# _stub_js_lines <line>... — the lines as a JS array literal (no line holds `"` or `\`).
_stub_js_lines() {
    local l s=""
    for l in "$@"; do s="${s:+$s, }\"$l\""; done
    printf '[%s]' "$s"
}

# write_stub <cfg> <kind> — block: finding output, rc 1 (the verdict); clean: no finding, rc 0;
# skipped: SKIPPED header, rc 0; rc3: internal error (fail-open); rc7: an unnamed rc (fail-open);
# real: the fixture's own copied cli.js, moved aside. Every stub records the argv it got in
# <cfg>/.scanner-argv, so a hook that calls the scanner wrongly (or not at all) cannot pass.
write_stub() {
    local cli="$1/bin/review-comment-block-size.d/cli.js" kind="$2" lines rc body
    case "$kind" in
        block) rc=1; lines="$(_stub_js_lines "$SCANNER_HEADER" "" \
            "Staged code files scanned: 1 (extensions: js;sh;py; threshold: > 10 comment lines per block)" \
            "$BLOCK_LINE" "  L10-L32 (23 comment lines)" "" \
            "  Compress to a one-line summary + a pointer to the authoritative doc (CPR-SSOT).")" ;;
        clean) rc=0; lines="$(_stub_js_lines "$SCANNER_HEADER" "" \
            "Staged code files scanned: 1 (extensions: js;sh;py; threshold: > 10 comment lines per block)")" ;;
        skipped) rc=0; lines="$(_stub_js_lines "$SKIPPED_HEADER")" ;;
        rc3) rc=3; lines="$(_stub_js_lines "$SCANNER_HEADER" "$ERR_LINE")" ;;
        rc7) rc=7; lines="$(_stub_js_lines "$SCANNER_HEADER")" ;;
        real) mv "$cli" "${cli%cli.js}cli-real.js" ;;
    esac
    if [ "$kind" = real ]; then
        body='return require("./cli-real.js").run(o);'
    else
        body="(o.stdout || process.stdout).write($lines.map((l) => l + \"\\n\").join(\"\")); return $rc;"
    fi
    printf '%s\n' '"use strict";' \
        'const fs = require("fs");' \
        'const path = require("path");' \
        'exports.run = (o = {}) => {' \
        '  const a = o.argv || [];' \
        '  fs.writeFileSync(path.join(__dirname, "..", "..", ".scanner-argv"), [String(a.length), ...a].join("\n") + "\n");' \
        "  $body" \
        '};' > "$cli"
}
