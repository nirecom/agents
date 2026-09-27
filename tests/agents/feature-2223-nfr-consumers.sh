#!/usr/bin/env bash
# tests/agents/feature-2223-nfr-consumers.sh
# Tests: agents/outline-reviewer.md, agents/detail-reviewer.md, agents/plan-security-reviewer.md, agents/test-reviewer.md, agents/security-scanner.md, agents/outline-planner.md, agents/detail-planner.md, agents/lib/nfr-severity-calibration.md, skills/write-code/SKILL.md, skills/write-tests/SKILL.md
# Tags: scope:issue-specific, TL2, nfr, static, pwsh-not-required
# Static/structural coverage for scope 2/3 consumers: the shared operational doc
# exists and points at the primitive (not a restatement of it), and every symmetric
# consumer references it (CPR-ORTH). RED until the scope 2/3 edits land.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# The distinctive guidance FRAGMENT — the substantive rule ("does not suppress
# specific vulnerabilities") whose single source is codex_core_project_nfr_block.
# The operational doc must reference the primitive, never restate this rule (C4).
GUIDANCE_SENTINEL="does not suppress"

CALIB_DOC="$AGENTS_DIR/agents/lib/nfr-severity-calibration.md"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_exists() {
    local name="$1" file="$2"
    if [[ -f "$file" ]]; then pass "$name"
    else fail "$name — $file does not exist"; fi
}

# Content match — file must exist and be non-empty before the match counts.
assert_has() {
    local name="$1" file="$2" needle="$3"
    if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then pass "$name"
    else fail "$name — '$needle' absent from $(basename "$file")"; fi
}

# Absence over a present, non-empty file (an empty/missing file cannot prove absence).
assert_lacks() {
    local name="$1" file="$2" needle="$3"
    if [[ ! -s "$file" ]]; then
        fail "$name — $(basename "$file") missing or empty; absence not provable"
    elif grep -qF -- "$needle" "$file"; then
        fail "$name — '$needle' unexpectedly present in $(basename "$file")"
    else
        pass "$name"
    fi
}

# The frontmatter must grant the tool in ANY YAML form (mirrors the judge file's
# assert_tools_lacks, CPR-ORTH): inline (`tools: Read, Bash`), list item
# (`  - Bash`), or mapping (`Bash:`). First-line-only matching false-fails when a
# reviewer declares its tools as a multi-line YAML list.
assert_tools_has() {
    local name="$1" file="$2" tool="$3"
    if [[ -f "$file" ]] && { grep -qE "^tools:.*(^|[[:space:],])${tool}([[:space:],]|\$)" "$file" \
        || grep -qE "^[[:space:]]*-[[:space:]]*${tool}[[:space:]]*\$" "$file" \
        || grep -qE "^[[:space:]]*${tool}:[[:space:]]*" "$file"; }; then
        pass "$name"
    else
        fail "$name — frontmatter of $(basename "$file") does not grant $tool"
    fi
}

# --- The shared operational doc (agents/lib/nfr-severity-calibration.md) -------
assert_exists "T2223CO-1-calib-doc-exists" "$CALIB_DOC"
assert_has "T2223CO-2-calib-doc-refs-git-rev-parse" "$CALIB_DOC" "git rev-parse --show-toplevel"
assert_has "T2223CO-3-calib-doc-refs-cli" "$CALIB_DOC" "bin/project-nfr-block"
# C4 — the doc references the primitive; it must NOT restate the guidance sentence.
assert_lacks "T2223CO-4-calib-doc-does-not-restate-guidance" "$CALIB_DOC" "$GUIDANCE_SENTINEL"

# --- Reviewers: reference + Bash (CPR-ORTH over the 4 read-only reviewers) ------
for reviewer in outline-reviewer detail-reviewer plan-security-reviewer test-reviewer; do
    f="$AGENTS_DIR/agents/$reviewer.md"
    assert_has        "T2223CO-5-$reviewer-refs-calib-doc" "$f" "nfr-severity-calibration.md"
    assert_tools_has  "T2223CO-6-$reviewer-tools-has-bash" "$f" "Bash"
done

# --- security-scanner: reference added; Bash was already present (regression) ---
SCANNER="$AGENTS_DIR/agents/security-scanner.md"
assert_has       "T2223CO-7-security-scanner-refs-calib-doc" "$SCANNER" "nfr-severity-calibration.md"
assert_tools_has "T2223CO-8-security-scanner-tools-has-bash" "$SCANNER" "Bash"

# --- Planners: reference the shared doc -----------------------------------------
for planner in outline-planner detail-planner; do
    f="$AGENTS_DIR/agents/$planner.md"
    assert_has "T2223CO-9-$planner-refs-calib-doc" "$f" "nfr-severity-calibration.md"
done

# --- write-code / write-tests SKILLs: OPTIONAL NFR bullet -----------------------
assert_has "T2223CO-10-write-code-optional-nfr" "$AGENTS_DIR/skills/write-code/SKILL.md" "nfr-severity-calibration"
assert_has "T2223CO-11-write-tests-optional-nfr" "$AGENTS_DIR/skills/write-tests/SKILL.md" "nfr-severity-calibration"

# --- C5: the shared primitive every consumer depends on must be callable --------
# The reference checks above prove each consumer POINTS at the doc; this proves the
# seam the doc points at actually runs. bin/project-nfr-block, given a repo root
# whose .env.local declares PROJECT_NFR, must emit that NFR (RED until it exists).
CO_CFG="$TMP_ROOT/cfg"
mkdir -p "$CO_CFG/bin"
cp -R "$AGENTS_DIR/bin/lib" "$CO_CFG/bin/lib" 2>/dev/null || true
: > "$CO_CFG/.env"
CO_PROJ="$TMP_ROOT/proj"
mkdir -p "$CO_PROJ/.git"
CO_NFR="NFRSENTINEL2223CONSUMERS"
printf 'PROJECT_NFR=%s consumer-callability\n' "$CO_NFR" > "$CO_PROJ/.env"".local"
CO_OUT="$TMP_ROOT/cli-out.txt"
AGENTS_CONFIG_DIR="$CO_CFG" run_with_timeout 30 \
    bash "$AGENTS_DIR/bin/project-nfr-block" "$CO_PROJ" > "$CO_OUT" 2>/dev/null || true
if [[ -f "$AGENTS_DIR/bin/project-nfr-block" ]]; then pass "T2223CO-12-cli-exists"
else fail "T2223CO-12-cli-exists — bin/project-nfr-block does not exist"; fi
assert_has "T2223CO-13-cli-emits-nfr" "$CO_OUT" "$CO_NFR"

# TL3 gap: the checks above are static references plus one in-process CLI call.
# What only a RUN_TL3 host catches: spawning a real reviewer/scanner/planner agent
# (claude -p) and confirming the spawned agent reads nfr-severity-calibration.md,
# runs bin/project-nfr-block against the project root, and calibrates severity by
# the returned NFR block end-to-end. That live agent seam belongs in a
# RUN_TL3-gated sibling, not this static runner.

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
