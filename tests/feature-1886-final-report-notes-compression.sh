#!/bin/bash
# tests/feature-1886-final-report-notes-compression.sh
# Tests: bin/render-final-report.js, bin/render-final-report/notes.js, skills/session-close/SKILL.md, skills/_shared/final-report-emission.md, rules/mid-workflow-findings.md, skills/worktree-end/SKILL.md
# Tags: final-report, notes-compression, severity, render-cli, prompt-contract, TL2, scope:issue-specific
#
# Why this exists (#1886): WORKTREE_NOTES.md sections were pasted into the Final
# Report verbatim, so one long session could emit thousands of characters of
# notes into the assistant reply. The fix compresses every entry to a title line
# EXCEPT entries tagged `<!-- severity: high -->`, and appends one summary line
# carrying the counts plus a `full text: <backup path>` pointer.
#
# The two silent failure modes this file pins, from opposite directions:
#   under-compression : the CLI still emits the full body -> the Final Report is
#                       unbounded again. Caught by the CONSTANT upper bounds
#                       below, asserted on both a 30-entry and a 300-entry
#                       fixture (same bound for both = bound is input-independent).
#   over-compression  : severity:high bodies get truncated too -> the one class
#                       of finding the reader must see in full is lost.
# Bounds are asserted against the module's own constants (COMPRESSED_LIST_MAX,
# TITLE_MAX_CHARS), never against a ratio of the input size, which would pass
# for any fixture large enough.
#
# The summary line is deliberately EXEMPT from the per-line length bound: it
# embeds the absolute backup path (capture-env.sh writes it under PLANS_DIR), so
# on a real temp dir it exceeds 128 chars by construction. It gets its own,
# path-length-relative bound instead.
#
# The prompt half of the fix is checked by grep on the WORKTREE copies
# (LOCAL_* below, not the deployed ~/.claude copies): compression is only
# useful if session-close emits it under a documented verbatim/translation
# scope, and severity tagging only fires if the biggest producer of findings
# (worktree-end Step WE-10) is wired to the rule that describes it.
#
# TL3 gap (what this test does NOT catch):
# - A real /session-close run: the model reading SC-6 and actually emitting the
#   stdout verbatim (and honoring CONV_LANG) is prompt-following behavior that
#   no grep can verify.
# - A real /worktree-end run appending findings through the CLI with a severity
#   the model itself classified.
# - The real Stop hook accepting the rendered report; only the two checks the
#   guard performs (13 headings, /<[A-Z][A-Z0-9_]+>/) are replayed here.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}
AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

RENDER_JS="${AGENTS_DIR}/bin/render-final-report.js"
NOTES_JS="${AGENTS_DIR}/bin/render-final-report/notes.js"
LOCAL_SESSION_CLOSE_MD="${AGENTS_DIR}/skills/session-close/SKILL.md"
LOCAL_EMISSION_MD="${AGENTS_DIR}/skills/_shared/final-report-emission.md"
LOCAL_MIDWF_MD="${AGENTS_DIR}/rules/mid-workflow-findings.md"
LOCAL_WORKTREE_END_MD="${AGENTS_DIR}/skills/worktree-end/SKILL.md"
LOCAL_APPEND_JS="${AGENTS_DIR}/bin/worktree-notes-append.js"
RWT="${AGENTS_DIR}/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---- fixture isolation (rules/test/fixture-isolation.md) --------------------
unset AGENTS_CONFIG_DIR
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
TMPD_NODE="$(node_path "$TMPD")"

# Dual-pin: pinning only CLAUDE_WORKFLOW_DIR would let a supervisor emit land in
# the developer's real ~/.workflow-plans.
export CLAUDE_WORKFLOW_DIR="${TMPD_NODE}/workflow-state"
export WORKFLOW_PLANS_DIR="${TMPD_NODE}/plans"
mkdir -p "${TMPD}/workflow-state" "${TMPD}/plans" "${TMPD}/proj" "${TMPD}/neutral"
git -C "${TMPD}/proj" init -q 2>/dev/null
git -C "${TMPD}/proj" config core.hooksPath /dev/null 2>/dev/null
export CLAUDE_PROJECT_DIR="${TMPD_NODE}/proj"

SID="f1886-session"
OUTCOME_JSON="${TMPD}/${SID}-issue-close-outcome.json"
INTENT_MD="${TMPD}/${SID}-intent.md"
printf '{"issues":[]}\n' > "$OUTCOME_JSON"
printf '# Intent\n\n## Issues\n- #1886: compress Final Report notes\n' > "$INTENT_MD"

# 300 ASCII chars, well past TITLE_MAX_CHARS (120).
LONG="$(printf 'ABCDEFGHIJ%.0s' $(seq 1 30))"

# make_notes <path> <untagged-count> [high-count]
make_notes() {
    local p="$1" n="$2" hi="${3:-0}" i
    {
        printf '# Worktree Notes\n\n## BugsFound\n'
        for ((i = 1; i <= hi; i++)); do
            printf -- '- HIGH%02d %s <!-- severity: high -->\n' "$i" "$LONG"
        done
        for ((i = 1; i <= n; i++)); do
            printf -- '- untagged%03d %s\n' "$i" "$LONG"
        done
        printf '\n## RelatedTasks\n- related one %s\n\n## NextTasks\n- next one %s\n' "$LONG" "$LONG"
    } > "$p"
}

write_env() { # write_env <env-path> <notes-path-or-empty>
    local ep="$1" np="$2"
    cat > "$ep" <<EOF
{
  "PR_NUMBER": "1886",
  "PR_TITLE": "Compress Final Report notes",
  "PR_URL": "https://example.com/pr/1886",
  "PR_STATE": "MERGED",
  "BRANCH": "fix/final-report-severity-compress",
  "WORKTREE_PATH": "",
  "CREATED_DATE": "",
  "BACKUP_MANIFEST_PATH": "",
  "NOTES_BACKUP_PATH": "${np}",
  "BRANCH_DELETED": "",
  "CLAUDE_CODE_RESTART_REQUIRED": "",
  "CC_RESTART_REQUIRED": "",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "",
  "OS_REBOOT_REASON": ""
}
EOF
}

# Run the real CLI from a neutral CWD so hooks/libs cannot resolve the real repo.
render() { # render <env-path>
    (cd "${TMPD}/neutral" && "$RWT" 120 node "$RENDER_JS" "$SID" \
        "$(node_path "$1")" "$(node_path "$OUTCOME_JSON")" "$(node_path "$INTENT_MD")")
}

# Lines between "### <name>" and the next "### " heading, blanks dropped.
block_of() { # block_of <stdout> <heading>
    printf '%s\n' "$1" | awk -v h="$2" '$0 == h {f=1; next} f && /^### / {exit} f {print}' \
        | grep -v '^[[:space:]]*$'
}

# NOTE: the prefix starts with "-", so every grep below must pass it via -e.
# NOTE: this repo runs on msys grep 3.0, where "-i" combined with "-F" aborts
# (SIGABRT). Case-insensitive greps here use -i with a literal pattern instead.
SUMMARY_PREFIX='- (compressed: '

# ============================================================================
# A. Compression upper bounds — constant in the input size
# ============================================================================

# assert_bounds <label> <untagged-count>
assert_bounds() {
    local label="$1" n="$2"
    local notes="${TMPD}/notes-${n}.md" envp="${TMPD}/env-${n}.json"
    make_notes "$notes" "$n" 0
    local notes_node; notes_node="$(node_path "$notes")"
    write_env "$envp" "$notes_node"
    local out rc block
    out="$(render "$envp" 2>/dev/null)"; rc=$?
    if [ "$rc" != "0" ]; then
        fail "${label}: render exited ${rc} (expected 0)"
        return
    fi
    block="$(block_of "$out" "### Bugs Found")"
    if [ -z "$block" ]; then
        fail "${label}: '### Bugs Found' block is empty"
        return
    fi
    local problems=""

    # (a) line count <= COMPRESSED_LIST_MAX + 1
    local lines; lines="$(printf '%s\n' "$block" | grep -c .)"
    [ "$lines" -le 11 ] || problems="${problems} line-count=${lines}>11"

    # (b) every NON-summary line <= TITLE_MAX_CHARS + 8 (= 128)
    local over
    over="$(printf '%s\n' "$block" | grep -v -F -e "$SUMMARY_PREFIX" \
        | awk 'length($0) > 128 {print length($0)}' | head -3 | tr '\n' ',')"
    [ -z "$over" ] || problems="${problems} entry-line-too-long=[${over}]"

    # (c) exactly one summary line
    local sumn; sumn="$(printf '%s\n' "$block" | grep -c -F -e "$SUMMARY_PREFIX")"
    [ "$sumn" = "1" ] || problems="${problems} summary-lines=${sumn}(want 1)"

    # (d) summary line: fixed prose + path + slack. Path length is environment
    #     dependent, so it is added to the bound rather than bounded itself.
    if [ "$sumn" = "1" ]; then
        local sline slen bound
        sline="$(printf '%s\n' "$block" | grep -F -e "$SUMMARY_PREFIX" | head -1)"
        slen="${#sline}"
        bound=$((110 + ${#notes_node} + 32))
        [ "$slen" -le "$bound" ] || problems="${problems} summary-len=${slen}>${bound}"
        # the pointer must actually point somewhere
        case "$sline" in *"full text: ${notes_node})") : ;; *)
            problems="${problems} summary-missing-backup-path" ;;
        esac
    fi

    # the raw 300-char body must not survive anywhere in the report
    if printf '%s' "$out" | grep -qF -- "untagged001 ${LONG}"; then
        problems="${problems} full-body-leaked"
    fi

    if [ -z "$problems" ]; then
        pass "${label}: bounded block (lines=${lines}, 1 summary, no full body)"
    else
        fail "${label}:${problems}"
    fi
}

test_bounds_30() { assert_bounds "bounds_30_untagged" 30; }
test_bounds_300() { assert_bounds "bounds_300_untagged" 300; }

# Same bound for 30 and 300 entries is the direct proof of input-independence.
test_bounds_identical_shape() {
    local a b
    a="$(block_of "$(render "${TMPD}/env-30.json" 2>/dev/null)" "### Bugs Found" | grep -c .)"
    b="$(block_of "$(render "${TMPD}/env-300.json" 2>/dev/null)" "### Bugs Found" | grep -c .)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
        pass "bounds_identical_shape: 30-entry and 300-entry blocks both ${a} lines"
    else
        fail "bounds_identical_shape: 30-entry=${a} lines, 300-entry=${b} lines (want equal)"
    fi
}

# ============================================================================
# B. severity:high survives in full (over-compression guard)
# ============================================================================

test_high_kept_verbatim() {
    local notes="${TMPD}/notes-high.md" envp="${TMPD}/env-high.json"
    make_notes "$notes" 12 2
    write_env "$envp" "$(node_path "$notes")"
    local out block problems=""
    out="$(render "$envp" 2>/dev/null)" || { fail "high_kept_verbatim: render failed"; return; }
    block="$(block_of "$out" "### Bugs Found")"
    printf '%s' "$block" | grep -qF -- "HIGH01 ${LONG}" || problems="${problems} HIGH01-truncated"
    printf '%s' "$block" | grep -qF -- "HIGH02 ${LONG}" || problems="${problems} HIGH02-truncated"
    # markers themselves must never reach the report
    printf '%s' "$out" | grep -q -- '<!-- severity:' && problems="${problems} severity-marker-leaked"
    printf '%s' "$out" | grep -q -- '<!-- promoted:' && problems="${problems} promoted-marker-leaked"
    # ... and the untagged neighbours are still compressed
    printf '%s' "$block" | grep -qF -e "$SUMMARY_PREFIX" || problems="${problems} no-summary-line"
    printf '%s' "$out" | grep -qF -- "untagged001 ${LONG}" && problems="${problems} untagged-body-leaked"
    if [ -z "$problems" ]; then
        pass "high_kept_verbatim: both severity:high bodies full, rest compressed, markers stripped"
    else
        fail "high_kept_verbatim:${problems}"
    fi
}

# ============================================================================
# C. fail-open: no backup path / missing file -> (none), exit 0
# ============================================================================

# assert_fail_open <label> <notes-path-value>
assert_fail_open() {
    local label="$1" np="$2" envp="${TMPD}/env-open.json"
    write_env "$envp" "$np"
    local out rc problems="" h
    out="$(render "$envp" 2>/dev/null)"; rc=$?
    [ "$rc" = "0" ] || problems="${problems} rc=${rc}(want 0)"
    for h in "### Bugs Found" "### Related Tasks" "### Next Tasks"; do
        local b; b="$(block_of "$out" "$h")"
        [ "$b" = "(none)" ] || problems="${problems} [${h}]=[${b}](want (none))"
    done
    if [ -z "$problems" ]; then
        pass "${label}: all three notes sections '(none)', exit 0"
    else
        fail "${label}:${problems}"
    fi
}

test_fail_open_unset() { assert_fail_open "fail_open_unset" ""; }
test_fail_open_missing_file() {
    assert_fail_open "fail_open_missing_file" "${TMPD_NODE}/does-not-exist-notes.md"
}

# ============================================================================
# D. Stop-guard contract replayed on CLI output
# ============================================================================

test_thirteen_headings_survive() {
    local out headings missing="" h
    out="$(render "${TMPD}/env-high.json" 2>/dev/null)"
    headings="$("$RWT" 120 node -e "
        const s=require('${AGENTS_DIR_NODE}/hooks/lib/final-report-schema');
        process.stdout.write(s.getSectionHeadings('${SID}').join('\n'));
    " 2>/dev/null)"
    if [ -z "$headings" ]; then
        fail "thirteen_headings_survive: could not load schema headings"
        return
    fi
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        printf '%s' "$out" | grep -qF "$h" || missing="${missing}${h} "
    done <<< "$headings"
    if [ -z "$missing" ]; then
        pass "thirteen_headings_survive: every schema heading present after compression"
    else
        fail "thirteen_headings_survive: missing: ${missing}"
    fi
}

# A finding body may legitimately mention <BUGS_FOUND>; unsanitized it matches
# the guard's tokenRegex and the session can never be closed.
test_no_token_leak() {
    local notes="${TMPD}/notes-token.md" envp="${TMPD}/env-token.json"
    {
        printf '# Worktree Notes\n\n## BugsFound\n'
        printf -- '- guard blocks on <BUGS_FOUND> and <PR_NUMBER> tokens <!-- severity: high -->\n'
        printf -- '- untagged mentions <NEXT_TASKS> too\n'
        printf '\n## RelatedTasks\n- (none)\n\n## NextTasks\n- (none)\n'
    } > "$notes"
    write_env "$envp" "$(node_path "$notes")"
    local out toks
    out="$(render "$envp" 2>/dev/null)" || { fail "no_token_leak: render failed"; return; }
    toks="$(printf '%s' "$out" | grep -oE '<[A-Z][A-Z0-9_]+>' | sort -u | tr '\n' ' ')"
    if [ -z "$toks" ]; then
        pass "no_token_leak: no <TOKEN> survives, incl. tokens written inside notes bodies"
    else
        fail "no_token_leak: guard-matching tokens in stdout: ${toks}"
    fi
}

# ============================================================================
# E. Prompt contract (worktree copies — LOCAL_*, not the deployed ~/.claude)
# ============================================================================

# assert_max_lines <label> <file> <max>
assert_max_lines() {
    local label="$1" f="$2" max="$3" n
    if [ ! -f "$f" ]; then fail "${label}: ${f#$AGENTS_DIR/} missing"; return; fi
    n="$(grep -c '' "$f")"
    if [ "$n" -le "$max" ]; then
        pass "${label}: ${n} lines (<= ${max})"
    else
        fail "${label}: ${n} lines (> ${max} HARD/WARN limit)"
    fi
}

test_notes_module_exists() {
    if [ -f "$NOTES_JS" ]; then
        pass "notes_module_exists: bin/render-final-report/notes.js present"
    else
        fail "notes_module_exists: bin/render-final-report/notes.js missing (pending write-code)"
    fi
}

test_session_close_size() {
    assert_max_lines "session_close_size" "$LOCAL_SESSION_CLOSE_MD" 200
}

# SC-6 block only: a reference sitting in some other step must not pass.
sc6_block() {
    awk '/^## Step SC-6 /{f=1} f && /^## Step SC-7/{exit} f' "$LOCAL_SESSION_CLOSE_MD" 2>/dev/null
}

test_sc6_points_at_emission_contract() {
    local b; b="$(sc6_block)"
    if [ -z "$b" ]; then fail "sc6_points_at_emission_contract: SC-6 block not found"; return; fi
    if printf '%s' "$b" | grep -qF 'skills/_shared/final-report-emission.md'; then
        pass "sc6_points_at_emission_contract: SC-6 references the shared emission contract"
    else
        fail "sc6_points_at_emission_contract: SC-6 has no pointer to skills/_shared/final-report-emission.md"
    fi
}

# The old inline wording contradicts the new contract (severity:high bodies and
# machine-generated summary fields must stay untranslated); it must be gone.
test_sc6_stale_translate_wording_removed() {
    local b; b="$(sc6_block)"
    if [ -z "$b" ]; then fail "sc6_stale_translate_wording_removed: SC-6 block not found"; return; fi
    if printf '%s' "$b" | grep -qi 'translate the body text'; then
        fail "sc6_stale_translate_wording_removed: stale 'translate the body text' still in SC-6"
    else
        pass "sc6_stale_translate_wording_removed: stale inline translation wording gone"
    fi
}

test_emission_contract_four_scopes() {
    local f="$LOCAL_EMISSION_MD" missing=""
    if [ ! -f "$f" ]; then
        fail "emission_contract_four_scopes: skills/_shared/final-report-emission.md missing (pending write-code)"
        return
    fi
    # (1) verbatim scope
    grep -qi 'verbatim' "$f" || missing="${missing} verbatim-scope"
    # (2) CONV_LANG scope
    grep -q 'CONV_LANG' "$f" || missing="${missing} CONV_LANG-scope"
    # (3) severity:high excluded from translation
    grep -i 'severity' "$f" | grep -qiE 'translat|verbatim|original' \
        || missing="${missing} severity-high-translation-exclusion"
    # (4) C15: summary-line counts + path stay as-is
    grep -iE 'full text|path' "$f" | grep -qiE 'translat|verbatim|as-is|unchanged|original' \
        || missing="${missing} summary-path-not-translated"
    if [ -z "$missing" ]; then
        pass "emission_contract_four_scopes: all four scopes documented"
    else
        fail "emission_contract_four_scopes: missing:${missing}"
    fi
}

test_midworkflow_rule_wires_cli_and_severity() {
    local f="$LOCAL_MIDWF_MD" problems=""
    if [ ! -f "$f" ]; then fail "midworkflow_rule_wires_cli_and_severity: rule file missing"; return; fi
    grep -qF 'worktree-notes-append.js' "$f" || problems="${problems} no-append-cli"
    grep -qF 'high|low|none' "$f" || problems="${problems} no-severity-values"
    # SSOT: the three severity conditions live in skills/issue-create/SKILL.md and
    # must NOT be transcribed here (rules/prompt.md 3.1).
    grep -qi 'Security breach' "$f" && problems="${problems} severity-conditions-transcribed"
    grep -qi 'Primary feature rendered completely unusable' "$f" \
        && problems="${problems} severity-conditions-transcribed-2"
    if [ -z "$problems" ]; then
        pass "midworkflow_rule_wires_cli_and_severity: CLI + severity values present, conditions not copied"
    else
        fail "midworkflow_rule_wires_cli_and_severity:${problems}"
    fi
}

# WE-10 is the largest producer of BugsFound entries. If it is not wired to the
# rule, severity tags never fire and compression degrades to "compress all".
test_we10_wired_to_rule() {
    local b
    b="$(awk '/^### Step WE-10 /{f=1} f && /^### Step WE-11/{exit} f' "$LOCAL_WORKTREE_END_MD" 2>/dev/null)"
    if [ -z "$b" ]; then fail "we10_wired_to_rule: Step WE-10 block not found"; return; fi
    if printf '%s' "$b" | grep -qF 'rules/mid-workflow-findings.md'; then
        pass "we10_wired_to_rule: WE-10 block references rules/mid-workflow-findings.md"
    else
        fail "we10_wired_to_rule: WE-10 block has no reference to rules/mid-workflow-findings.md"
    fi
}

test_midworkflow_size() { assert_max_lines "midworkflow_size" "$LOCAL_MIDWF_MD" 100; }
test_append_cli_size() { assert_max_lines "append_cli_size" "$LOCAL_APPEND_JS" 300; }
test_worktree_end_size() { assert_max_lines "worktree_end_size" "$LOCAL_WORKTREE_END_MD" 200; }

# ============================================================================
run_all() {
    test_notes_module_exists
    test_bounds_30
    test_bounds_300
    test_bounds_identical_shape
    test_high_kept_verbatim
    test_fail_open_unset
    test_fail_open_missing_file
    test_thirteen_headings_survive
    test_no_token_leak
    test_session_close_size
    test_sc6_points_at_emission_contract
    test_sc6_stale_translate_wording_removed
    test_emission_contract_four_scopes
    test_midworkflow_rule_wires_cli_and_severity
    test_we10_wired_to_rule
    test_midworkflow_size
    test_append_cli_size
    test_worktree_end_size
}

run_all
echo "----"
echo "PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
