#!/usr/bin/env bash
# tests/skills/feature-1643-worker-dispatch-callers/commit-push-background.sh
# Sourced part: the parent's Tests:/Tags: header and case markers cover these groups.
# Group E of tests/skills/feature-1643-worker-dispatch-callers.sh — sourced from it, never run
# standalone (uses its helpers, SHARED_MD and counters; the parent holds the case markers).
# Split off for the 500-line HARD limit (rules/coding/file-split.md, sibling-folder form).
CP_DISPATCH_MD="$SCRIPT_CHECKOUT_ROOT/skills/_shared/commit-push-dispatch.md"
HANDOFF_MD="$SCRIPT_CHECKOUT_ROOT/skills/_shared/handoff-record.md"

# Group E (#2762) — commit-push is always dispatched in the background (WD-CP).
# The worker's commit timeout limit can exceed the 600 s foreground Bash cap, so the
# caller must background every commit-push dispatch and read the completion output.
# TL3 gap: a real run_in_background completion notice reaching the model, and the model
# following WD-CP, are not exercised here (same as feature-2544-run-tests-background-procedure.sh).

# wd_block <label> — the WD-<label> paragraph of worker-dispatch.md, up to the next WD-/RNT- label
# or `## ` heading (the same closing rule as feature-2544's md_block).
wd_block() {
    awk -v s="WD-$1." '
        inb && ($0 ~ /^(WD|RNT)-[0-9A-Z]+[.: ]/ || $0 ~ /^## /) { exit }
        !inb && substr($0, 1, length(s)) == s { inb = 1 }
        inb { print }
    ' "$SHARED_MD"
}

# wd_cp_missing <block> — the WD-CP requirements the block text breaks; empty when all hold.
# The read line must follow the background-run line and name all three output fields.
wd_cp_missing() {
    local block="$1" missing="" tok bg_line read_line read_text
    for tok in commit-push 'run_in_background: true' WORKFLOW_NEXT_STEP_PAUSE WORKFLOW_NEXT_STEP_RESUME 'status:' release-steps.js --seq; do
        printf '%s\n' "$block" | grep -qF -- "$tok" || missing="$missing [$tok]"
    done
    if printf '%s\n' "$block" | grep -qF 'run_in_background: false'; then
        missing="$missing [no run_in_background: false]"
    fi
    bg_line="$(printf '%s\n' "$block" | grep -nF 'run_in_background: true' | head -n 1 | cut -d: -f1)"
    read_line="$(printf '%s\n' "$block" | grep -nE '^- Read the output the completion notice points to' | head -n 1 | cut -d: -f1)"
    if [[ -z "$read_line" ]]; then
        missing="$missing [read-completion-output line]"
    else
        read_text="$(printf '%s\n' "$block" | sed -n "${read_line}p")"
        for tok in '`status:`' '`summary:`' '`artifact_path:`'; do
            printf '%s\n' "$read_text" | grep -qF -- "$tok" || missing="$missing [read line names $tok]"
        done
        if [[ -z "$bg_line" || "$read_line" -le "$bg_line" ]]; then
            missing="$missing [read line after the background run]"
        fi
    fi
    printf '%s' "$missing"
}

group_wd_cp_block() {
    local block missing
    block="$(wd_block CP)"
    if [ -z "$block" ]; then
        fail "E1: $SHARED_REL has a WD-CP. paragraph" "no line starts with 'WD-CP.'"
        return
    fi
    missing="$(wd_cp_missing "$block")"
    if [ -z "$missing" ]; then
        pass "E1: WD-CP names commit-push, run_in_background: true, PAUSE/RESUME, the status:/summary:/artifact_path: read after the notice, release-steps.js and --seq"
    else
        fail "E1: WD-CP paragraph incomplete" "missing:$missing"
    fi
}

# Mutation probe for E1: each mutated copy of the real WD-CP block must be rejected
# for the named reason, so E1 cannot pass on a matcher that never fires.
# Columns: name | sed expression | reason the matcher must report
group_wd_cp_matcher_probe() {
    local block name expr want got
    block="$(wd_block CP)"
    if [[ -z "$block" ]]; then
        fail "E1b: WD-CP block missing; matcher probe cannot run"
        return
    fi
    while IFS='|' read -r name expr want; do
        [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        expr="$(printf '%s' "$expr" | sed 's/^ *//; s/ *$//')"
        want="$(printf '%s' "$want" | sed 's/^ *//; s/ *$//')"
        got="$(wd_cp_missing "$(printf '%s\n' "$block" | sed "$expr")")"
        if [[ "$got" == *"$want"* ]]; then
            pass "E1b/$name: the WD-CP matcher rejects the mutation ($want)"
        else
            fail "E1b/$name: the WD-CP matcher accepts the mutation" "want=$want got=[$got]"
        fi
    done <<'TABLE'
bg-false          | s/run_in_background: true/run_in_background: false/       | [no run_in_background: false]
bg-false-appended | $a\- Or run it with `run_in_background: false`.         | [no run_in_background: false]
bg-bare           | s/run_in_background: true/run_in_background/             | [run_in_background: true]
no-summary        | s/ \/ `summary:`//                                       | [read line names `summary:`]
no-artifact-path  | s/ \/ `artifact_path:`//                                 | [read line names `artifact_path:`]
no-status-on-read | /^- Read the output/s/`status:` \/ //                    | [read line names `status:`]
no-read-line      | /^- Read the output/d                                    | [read-completion-output line]
read-before-run   | /^- Emit/{h;d};/^- Read the output/G                     | [read line after the background run]
TABLE
    if [[ -z "$(wd_cp_missing "$block")" ]]; then
        pass "E1b/unmutated: the WD-CP matcher accepts the real block"
    else
        fail "E1b/unmutated: the WD-CP matcher rejects the real block" "$(wd_cp_missing "$block")"
    fi
}

group_wd_bg_unmixed() {
    local block
    block="$(wd_block BG)"
    if [ -z "$block" ]; then
        fail "E2: $SHARED_REL has a WD-BG. paragraph" "no line starts with 'WD-BG.'"
    elif printf '%s\n' "$block" | grep -qF 'commit-push'; then
        fail "E2: WD-BG stays test-runner only" "WD-BG paragraph mentions commit-push"
    else
        pass "E2: WD-BG stays test-runner only (no commit-push text inside its range)"
    fi
}

group_shared_size() {
    local n
    n=$(wc -l < "$SHARED_MD" | tr -d ' ')
    if [ "$n" -le 100 ]; then
        pass "E3: $SHARED_REL stays within 100 lines ($n)"
    else
        fail "E3: $SHARED_REL exceeds 100 lines" "lines=$n"
    fi
}

group_cp_dispatch_section() {
    local block
    block="$(extract_block "$CP_DISPATCH_MD" "## Dispatch" "## Outcomes")"
    if printf '%s\n' "$block" | grep -qF 'WD-CP' && ! printf '%s\n' "$block" | grep -qF 'timeout: 600000'; then
        pass "E4: commit-push-dispatch.md ## Dispatch points at WD-CP and sets no foreground timeout: 600000"
    else
        fail "E4: commit-push-dispatch.md ## Dispatch must reference WD-CP without timeout: 600000" "$(printf '%s' "$block" | head -n 3 | tr '\n' ' ')"
    fi
}

group_cp_outcome_commit_timeout() {
    local outcomes line
    outcomes="$(awk '/^## Outcomes/ { inb = 1; next } inb && /^## / { exit } inb { print }' "$CP_DISPATCH_MD")"
    line="$(printf '%s\n' "$outcomes" | grep -F '`commit_timeout`' | head -n 1)"
    if [ -n "$line" ] && printf '%s\n' "$line" | grep -qF 'never assume nothing was committed'; then
        pass "E5: ## Outcomes has a commit_timeout line that forbids assuming nothing was committed"
    else
        fail "E5: ## Outcomes commit_timeout line" "line=[$line]"
    fi
    # The caller's action on the outcome: surface the facts, record blocked, stop, keep the lock.
    local missing="" tok
    for tok in 'summary' 'artifact_path' 'record blocked' 'stop' 'Never delete index.lock'; do
        printf '%s\n' "$line" | grep -qF -- "$tok" || missing="$missing [$tok]"
    done
    if [ -n "$line" ] && [ -z "$missing" ]; then
        pass "E8: the commit_timeout line says surface summary + artifact_path, record blocked, stop, never delete index.lock"
    else
        fail "E8: commit_timeout caller action incomplete" "missing:$missing line=[$line]"
    fi
    if printf '%s\n' "$outcomes" | grep -qF 'On `commit_timeout`: nothing was committed;'; then
        fail "E6: ## Outcomes never asserts nothing was committed on commit_timeout"
    else
        pass "E6: ## Outcomes never asserts nothing was committed on commit_timeout"
    fi
}

group_handoff_blocked_list() {
    if grep -E 'gate_blocked' "$HANDOFF_MD" | grep -qF 'commit_timeout'; then
        pass "E7: handoff-record.md blocked outcome list includes commit_timeout"
    else
        fail "E7: handoff-record.md blocked outcome list lacks commit_timeout" "$(grep -E 'gate_blocked' "$HANDOFF_MD" | head -n 1)"
    fi
}
