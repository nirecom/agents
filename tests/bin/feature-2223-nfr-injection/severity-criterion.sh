#!/usr/bin/env bash
# tests/bin/feature-2223-nfr-injection/severity-criterion.sh
# Tests: bin/lib/codex-core.sh, bin/project-nfr-block
# Tags: scope:issue-specific, TL2, codex, nfr, security, pwsh-not-required, dup-group-keep:size-hard-limit
# Case file for tests/bin/feature-2223-nfr-injection.sh — sourced from it, never run
# standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# scope 1: the severity-calibration instruction Step 1 appends OUTSIDE the
# [PROJECT NFR END] delimiter, plus C2 byte-equality (codex path vs the CC path
# through bin/project-nfr-block) and C4 single-source (CC path gets the guidance).
NFR_SEVERITY_CRITERION_CASES_LOADED=1
# When run standalone (not sourced), skip — helpers are defined by the parent.
[ "${BASH_SOURCE[0]}" = "$0" ] && exit 77

# WRITE-CODE CONTRACT (C1): Step 1 MUST emit the severity-calibration instruction
# AFTER the [PROJECT NFR END] line (outside the delimited data block), and that
# instruction MUST contain the word "severity". These tests read ONLY the region
# after [PROJECT NFR END], so a project NFR value that itself contains "severity"
# can never produce a false green — the sentinel is judged in the instruction
# region alone, never in the untrusted NFR data. If the instruction's wording
# changes, keep the word "severity" in it (or update SEV_SENTINEL in lockstep).
SEV_SENTINEL="severity"

# post_end_region <block-file> <out-file> — extracts everything AFTER the
# [PROJECT NFR END] line into out-file (the scripted-instruction region).
post_end_region() {
    local block="$1" out="$2" end
    : > "$out"
    end="$(grep -nF -- '[PROJECT NFR END]' "$block" 2>/dev/null | head -1 | cut -d: -f1)"
    [ -n "$end" ] || return 0
    tail -n +"$((end + 1))" "$block" > "$out" 2>/dev/null || true
}

# nfr_block_direct <cfg-dir> <project-root> — raw codex_core_project_nfr_block
# output with no codex_core_init side effects, mirroring exactly what the
# bin/project-nfr-block wrapper is specified to emit (Step 2).
nfr_block_direct() {
    local cfg="$1" root="$2"
    AGENTS_CONFIG_DIR="$cfg" run_with_timeout 30 bash -c '
      source "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 || exit 3
      declare -F codex_core_project_nfr_block >/dev/null || exit 4
      codex_core_project_nfr_block "$2"
    ' _ "$AGENTS_DIR" "$root" 2>/dev/null
}

# nfr_block_cli <cfg-dir> <project-root> — the CC/planner path (the new thin CLI
# calling the same bash function). Absent on a feature branch → empty (RED).
nfr_block_cli() {
    local cfg="$1" root="$2"
    AGENTS_CONFIG_DIR="$cfg" run_with_timeout 30 \
        bash "$AGENTS_DIR/bin/project-nfr-block" "$root" 2>/dev/null
}

# --- SC-1: instruction present in the POST-END region when an NFR is declared --
CFG_SEV="$(make_cfg sev "PROJECT_NFR=$NFR_SENTINEL must hold")"
PROJ_SEV="$(make_project sev)"
SEV_FILE="$TMP_ROOT/sev-block.txt"
SEV_POST="$TMP_ROOT/sev-postend.txt"
nfr_block "$CFG_SEV" "$PROJ_SEV" > "$SEV_FILE"
post_end_region "$SEV_FILE" "$SEV_POST"
if [ -s "$SEV_POST" ] && grep -qF -- "$SEV_SENTINEL" "$SEV_POST"; then
    pass "T2223SC-1-instruction-present-after-end"
else
    fail "T2223SC-1-instruction-present-after-end — no '$SEV_SENTINEL' instruction in the region after [PROJECT NFR END]"
fi

# --- SC-1b: false-green guard — an NFR value that CONTAINS "severity" must not
# make the case pass on its own. The whole block then holds "severity" (from the
# NFR data), but the verdict is taken from the post-END region only. ------------
CFG_SEVIN="$(make_cfg sevin "PROJECT_NFR=$NFR_SENTINEL this NFR mentions severity on purpose")"
PROJ_SEVIN="$(make_project sevin)"
SEVIN_FILE="$TMP_ROOT/sevin-block.txt"
SEVIN_POST="$TMP_ROOT/sevin-postend.txt"
nfr_block "$CFG_SEVIN" "$PROJ_SEVIN" > "$SEVIN_FILE"
post_end_region "$SEVIN_FILE" "$SEVIN_POST"
# Control: the sentinel really is in the NFR data (so a naive whole-block grep
# WOULD false-green), which is exactly what the region-scoping defeats.
assert_file_has "T2223SC-1b-control-nfr-data-has-sentinel" "$SEVIN_FILE" "$SEV_SENTINEL"
if [ -s "$SEVIN_POST" ] && grep -qF -- "$SEV_SENTINEL" "$SEVIN_POST"; then
    pass "T2223SC-1b-instruction-in-region-not-from-nfr-data"
else
    fail "T2223SC-1b-instruction-in-region-not-from-nfr-data — instruction region carries no '$SEV_SENTINEL' (NFR data alone must not satisfy the case)"
fi

# --- SC-2: the instruction sits AFTER the [PROJECT NFR END] line ----------------
end_line="$(grep -nF -- '[PROJECT NFR END]' "$SEV_FILE" 2>/dev/null | head -1 | cut -d: -f1)"
sev_line="$(grep -nF -- "$SEV_SENTINEL" "$SEV_FILE" 2>/dev/null | tail -1 | cut -d: -f1)"
if [ -n "$end_line" ] && [ -n "$sev_line" ] && [ "$sev_line" -gt "$end_line" ]; then
    pass "T2223SC-2-instruction-after-end-delimiter"
else
    fail "T2223SC-2-instruction-after-end-delimiter — end=${end_line:-none} instruction=${sev_line:-none}"
fi

# --- SC-3: NFR undeclared → empty block, so no instruction either ---------------
CFG_SEV_EMPTY="$(make_cfg sevempty "CODE_LANG=english")"
PROJ_SEV_EMPTY="$(make_project sevempty)"
SEV_EMPTY_FILE="$TMP_ROOT/sev-empty.txt"
nfr_block "$CFG_SEV_EMPTY" "$PROJ_SEV_EMPTY" > "$SEV_EMPTY_FILE"
sev_empty_out="$(trim "$(cat "$SEV_EMPTY_FILE" 2>/dev/null)")"
if [ -z "$sev_empty_out" ]; then
    pass "T2223SC-3-no-instruction-when-nfr-unset"
elif grep -qF -- "$SEV_SENTINEL" "$SEV_EMPTY_FILE"; then
    fail "T2223SC-3-no-instruction-when-nfr-unset — instruction present with no NFR declared"
else
    fail "T2223SC-3-no-instruction-when-nfr-unset — block non-empty without an NFR: $(printf '%q' "$sev_empty_out")"
fi

# --- SC-4: caps regression — a 250-line NFR keeps the instruction while the NFR
# data stays capped at CODEX_NFR_MAX_LINES=200 (cap applies to $nfr, not the
# scripted instruction). --------------------------------------------------------
SEV_LONG_VALUE="$NFR_SENTINEL line 1"
i=2
while [ "$i" -le 250 ]; do SEV_LONG_VALUE="$SEV_LONG_VALUE\\nfiller line $i"; i=$((i + 1)); done
CFG_SEV_LONG="$(make_cfg sevlong "PROJECT_NFR=\"$SEV_LONG_VALUE\"")"
PROJ_SEV_LONG="$(make_project sevlong)"
SEV_LONG_FILE="$TMP_ROOT/sev-long.txt"
SEV_LONG_POST="$TMP_ROOT/sev-long-postend.txt"
nfr_block "$CFG_SEV_LONG" "$PROJ_SEV_LONG" > "$SEV_LONG_FILE"
post_end_region "$SEV_LONG_FILE" "$SEV_LONG_POST"
if [ -s "$SEV_LONG_POST" ] && grep -qF -- "$SEV_SENTINEL" "$SEV_LONG_POST"; then
    pass "T2223SC-4-instruction-survives-truncation"
else
    fail "T2223SC-4-instruction-survives-truncation — instruction lost when the NFR is truncated"
fi
assert_file_has  "T2223SC-4-nfr-keeps-head" "$SEV_LONG_FILE" "$NFR_SENTINEL line 1"
assert_file_lacks "T2223SC-4-nfr-drops-tail" "$SEV_LONG_FILE" "filler line 250"

# --- SC-C2: byte-equality between the CC-path CLI and the direct function call --
CFG_EQ="$(make_cfg seveq "CODE_LANG=english")"
PROJ_EQ="$(make_project seveq)"
printf 'PROJECT_NFR=%s byte-equal probe\n' "$NFR_SENTINEL" > "$PROJ_EQ/$LOCAL_ENV_BASENAME"
EQ_CLI_FILE="$TMP_ROOT/sev-eq-cli.txt"
EQ_DIRECT_FILE="$TMP_ROOT/sev-eq-direct.txt"
nfr_block_cli "$CFG_EQ" "$PROJ_EQ" > "$EQ_CLI_FILE"
nfr_block_direct "$CFG_EQ" "$PROJ_EQ" > "$EQ_DIRECT_FILE"
if [ -s "$EQ_DIRECT_FILE" ] && cmp -s "$EQ_CLI_FILE" "$EQ_DIRECT_FILE"; then
    pass "T2223SC-C2-cli-bytes-equal-direct-call"
else
    fail "T2223SC-C2-cli-bytes-equal-direct-call — bin/project-nfr-block output differs from codex_core_project_nfr_block (or CLI is absent)"
fi

# --- SC-C4: the CC path receives the same guidance (single source) --------------
if [ -s "$EQ_CLI_FILE" ] && grep -qF -- "$SEV_SENTINEL" "$EQ_CLI_FILE"; then
    pass "T2223SC-C4-cli-carries-guidance"
else
    fail "T2223SC-C4-cli-carries-guidance — CC path (bin/project-nfr-block) does not carry the severity instruction"
fi

# --- SC-C7: hostile repo-root path (spaces + literal $() ) must not be evaluated;
# the primitive resolves the NFR from that path or safely emits nothing. ---------
CFG_META="$(make_cfg sevmeta "CODE_LANG=english")"
META_ROOT="$TMP_ROOT/weird \$(echo pwned) dir"
mkdir -p "$META_ROOT/.git"
printf 'PROJECT_NFR=%s meta-path\n' "$NFR_SENTINEL" > "$META_ROOT/$LOCAL_ENV_BASENAME"
META_DIRECT_FILE="$TMP_ROOT/sev-meta-direct.txt"
META_CLI_FILE="$TMP_ROOT/sev-meta-cli.txt"
nfr_block_direct "$CFG_META" "$META_ROOT" > "$META_DIRECT_FILE"
nfr_block_cli    "$CFG_META" "$META_ROOT" > "$META_CLI_FILE"
# Security invariant (holds now, via the existing function): the $() in the path
# is never executed, so "pwned" can never appear in the output.
assert_file_lacks "T2223SC-C7-direct-no-command-injection" "$META_DIRECT_FILE" "pwned"
assert_file_has   "T2223SC-C7-direct-reads-nfr-from-meta-path" "$META_DIRECT_FILE" "$NFR_SENTINEL meta-path"
# The CLI (RED until it exists) must behave identically: no injection, NFR present.
if grep -qF -- "pwned" "$META_CLI_FILE" 2>/dev/null; then
    fail "T2223SC-C7-cli-no-command-injection — CLI evaluated \$() in the repo-root path"
else
    pass "T2223SC-C7-cli-no-command-injection"
fi
assert_file_has "T2223SC-C7-cli-reads-nfr-from-meta-path" "$META_CLI_FILE" "$NFR_SENTINEL meta-path"
