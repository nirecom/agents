#!/bin/bash
# Tests: agents/refactor-prompts-judge.md, bin/refactor-prompts/extract-keywords.js, bin/refactor-prompts/index.sh, skills/refactor-prompts/SKILL.md
# Tags: refactor-prompts-skill
# Tests for /refactor-prompts — skill + agent + wrapper smoke + handoff contract
#
# Files exercised:
#   skills/refactor-prompts/SKILL.md
#   agents/refactor-prompts-judge.md
#   bin/refactor-prompts/index.sh
#
# TC1–TC5 are smoke tests on the static artifacts.
# TC6 is the handoff contract: target.md + judge-output.json → expected.md.
#
# RED: this suite fails clean while any of the above is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_FILE="$AGENTS_DIR/skills/refactor-prompts/SKILL.md"
JUDGE_FILE="$AGENTS_DIR/agents/refactor-prompts-judge.md"
WRAPPER="$AGENTS_DIR/bin/refactor-prompts/index.sh"
EXTRACT_CLI="$AGENTS_DIR/bin/refactor-prompts/extract-keywords.js"
HANDOFF_DIR="$AGENTS_DIR/tests/fixtures/refactor-prompts/handoff"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

export AGENTS_CONFIG_DIR="C:/git/agents"

# --- Existence gate ---------------------------------------------------------
missing=()
[ -f "$SKILL_FILE"   ] || missing+=("skills/refactor-prompts/SKILL.md")
[ -f "$JUDGE_FILE"   ] || missing+=("agents/refactor-prompts-judge.md")
[ -f "$WRAPPER"      ] || missing+=("bin/refactor-prompts/index.sh")
[ -f "$EXTRACT_CLI"  ] || missing+=("bin/refactor-prompts/extract-keywords.js")
[ -d "$HANDOFF_DIR"  ] || missing+=("tests/fixtures/refactor-prompts/handoff/")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# ============================================================================
# TC1: SKILL.md and judge agent file exist (covered by existence gate above;
# this case asserts both are non-empty regular files).
# ============================================================================
if [ -s "$SKILL_FILE" ] && [ -s "$JUDGE_FILE" ]; then
    pass "TC1: SKILL.md and judge agent file exist and are non-empty"
else
    fail "TC1: SKILL.md or judge agent file is empty"
fi

# ============================================================================
# TC2: SKILL.md body ≤ 50 lines (skills are CLI-orchestrating, must be tight).
# ============================================================================
SKILL_LC=$(wc -l <"$SKILL_FILE" | tr -d '[:space:]')
if [ "$SKILL_LC" -le 50 ]; then
    pass "TC2: SKILL.md is ≤ 50 lines (actual=$SKILL_LC)"
else
    fail "TC2: SKILL.md exceeds 50-line budget (actual=$SKILL_LC)"
fi

# ============================================================================
# TC3: SKILL.md frontmatter declares name: refactor-prompts.
# ============================================================================
if head -10 "$SKILL_FILE" | grep -qE '^name:\s*refactor-prompts\s*$'; then
    pass "TC3: SKILL.md frontmatter has 'name: refactor-prompts'"
else
    fail "TC3: SKILL.md frontmatter missing 'name: refactor-prompts'"
fi

# ============================================================================
# TC4: wrapper has the executable bit (POSIX). Skip on Windows-only file
# systems where the bit is not meaningful; in that case fall back to a
# shebang check.
# ============================================================================
if [ -x "$WRAPPER" ]; then
    pass "TC4: bin/refactor-prompts/index.sh is executable"
elif head -1 "$WRAPPER" | grep -qE '^#!.*(bash|sh)\b'; then
    pass "TC4: bin/refactor-prompts/index.sh has bash shebang (executable bit unavailable on this FS)"
else
    fail "TC4: wrapper missing executable bit and shebang"
fi

# ============================================================================
# TC5: `bin/refactor-prompts/index.sh --keywords-only` exits 0.
# ============================================================================
TC5_OUT="$(mktemp -t skill-tc5.XXXXXX.json)"
TC5_ERR="$(mktemp -t skill-tc5.XXXXXX.log)"
run_with_timeout bash "$WRAPPER" --keywords-only >"$TC5_OUT" 2>"$TC5_ERR"
TC5_RC=$?

if [ "$TC5_RC" -eq 0 ]; then
    pass "TC5: index.sh --keywords-only exits 0"
else
    fail "TC5: index.sh --keywords-only exit=$TC5_RC stderr=$(cat "$TC5_ERR")"
fi
rm -f "$TC5_OUT" "$TC5_ERR"

# ============================================================================
# TC6: handoff contract — apply judge-output.json edits to target.md
# and assert byte-equal with expected.md. Deferred regions are reported
# as a markdown section.
#
# This re-implements the SKILL.md edit-application step in-process so
# the test does not depend on the live skill execution surface.
# ============================================================================
TC6_TMP_DIR="$(mktemp -d)"
TC6_TARGET="$TC6_TMP_DIR/target.md"
TC6_EXPECTED="$HANDOFF_DIR/expected.md"
TC6_JUDGE="$HANDOFF_DIR/judge-output.json"
TC6_DEFERRED="$TC6_TMP_DIR/deferred.md"
cp "$HANDOFF_DIR/target.md" "$TC6_TARGET"

# Inline driver — apply edits, then emit deferred regions section.
node -e '
    const fs = require("fs");
    const targetPath = process.argv[1];
    const judgePath  = process.argv[2];
    const deferredOut = process.argv[3];

    const judge = JSON.parse(fs.readFileSync(judgePath, "utf8"));
    let body = fs.readFileSync(targetPath, "utf8");

    const deferred = [];
    for (const edit of judge.edits || []) {
        switch (edit.verdict) {
            case "delete":
                if (typeof edit.old_text === "string" && edit.old_text.length > 0) {
                    body = body.replace(edit.old_text, "");
                }
                break;
            case "category-rewrite":
                if (typeof edit.old_text === "string"
                    && typeof edit.new_text === "string") {
                    body = body.replace(edit.old_text, edit.new_text);
                }
                break;
            case "defer":
                deferred.push(edit);
                break;
            default:
                // keep-* / unknown: no-op
                break;
        }
    }
    fs.writeFileSync(targetPath, body);

    // Emit deferred-regions markdown section.
    let md = "";
    if (deferred.length > 0) {
        md += "## Deferred regions\n\n";
        for (const d of deferred) {
            md += `- ${d.file}:${d.line} — ${d.reason}\n`;
            if (d.context_excerpt) {
                md += `  > ${d.context_excerpt}\n`;
            }
        }
    }
    fs.writeFileSync(deferredOut, md);
' "$TC6_TARGET" "$TC6_JUDGE" "$TC6_DEFERRED"
TC6_DRIVER_RC=$?

# Byte-compare target.md after edits with expected.md.
if [ "$TC6_DRIVER_RC" -ne 0 ]; then
    fail "TC6: handoff driver exited non-zero ($TC6_DRIVER_RC)"
elif cmp -s "$TC6_TARGET" "$TC6_EXPECTED"; then
    # And verify deferred section was produced with the git-commit defer entry.
    if grep -q 'git commit --amend' "$TC6_DEFERRED"; then
        pass "TC6: handoff produces expected.md byte-equal output + deferred section"
    else
        fail "TC6: handoff target matches but deferred section missing git commit entry"
    fi
else
    fail "TC6: handoff output does not match expected.md (see diff)"
    diff -u "$TC6_EXPECTED" "$TC6_TARGET" || true
fi

rm -rf "$TC6_TMP_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
