# Sourced by tests/feature-skill-shrink-renumber-sweep.sh
# Requires: check_literal, check_absent, check_re, check_absent_regex, pass, fail
# Tags: renumber, step-rename, sweep, issue-966

# Helper for regex absence check
check_absent_regex() {
    local label="$1"
    local pattern="$2"
    local rel="$3"
    local path="$AGENTS_DIR/$rel"
    if [ ! -f "$path" ]; then
        fail "$label: $rel missing"
        return
    fi
    if grep -qE "$pattern" "$path"; then
        fail "$label: pattern '$pattern' still matches in $rel (should be absent)"
    else
        pass "$label: pattern '$pattern' absent from $rel"
    fi
}

# --- #966 inline-prefix sweep (R33–R57) ---

# R33: aws-scan → AS
check_literal "R33" "AS-1" "skills/aws-scan/SKILL.md"

# R34: aws-scan-apps → ASA
check_literal "R34" "ASA-1" "skills/aws-scan-apps/SKILL.md"

# R35: aws-scan-cost → ASC
check_literal "R35" "ASC-1" "skills/aws-scan-cost/SKILL.md"

# R36: aws-scan-resources → ASR
check_literal "R36" "ASR-1" "skills/aws-scan-resources/SKILL.md"

# R37: aws-scan-security → ASE
check_literal "R37" "ASE-1" "skills/aws-scan-security/SKILL.md"

# R38: commit-push → CP
check_literal "R38" "CP-1" "skills/commit-push/SKILL.md"

# R39: deep-research → DR
check_literal "R39" "DR-1" "skills/deep-research/SKILL.md"

# R40: draw-mermaid → DM
check_literal "R40" "DM-1" "skills/draw-mermaid/SKILL.md"

# R41: issue-create → IC
check_literal "R41" "IC-1" "skills/issue-create/SKILL.md"

# R42: migrate-repo → MR
check_literal "R42" "MR-1" "skills/migrate-repo/SKILL.md"

# R43: review-code-security → RCS
check_literal "R43" "RCS-1" "skills/review-code-security/SKILL.md"

# R44: review-plan-security → RPS
check_literal "R44" "RPS-1" "skills/review-plan-security/SKILL.md"

# R45: review-tests → RT
check_literal "R45" "RT-1" "skills/review-tests/SKILL.md"

# R46: run-tests → RNT
check_literal "R46" "RNT-1" "skills/run-tests/SKILL.md"

# R47: save-research → SR
check_literal "R47" "SR-1" "skills/save-research/SKILL.md"

# R48: survey-code → SVC
check_literal "R48" "SVC-1" "skills/survey-code/SKILL.md"

# R49: survey-history → SH
check_literal "R49" "SH-1" "skills/survey-history/SKILL.md"

# R50: sweep → SW
check_literal "R50" "SW-1" "skills/sweep/SKILL.md"

# R51: sweep-branches → SB
check_literal "R51" "SB-1" "skills/sweep-branches/SKILL.md"

# R52: sweep-worktrees → SWT
check_literal "R52" "SWT-1" "skills/sweep-worktrees/SKILL.md"

# R53: update-docs → UD
check_literal "R53" "UD-1" "skills/update-docs/SKILL.md"

# R54: update-infrastructure → UI
check_literal "R54" "UI-1" "skills/update-infrastructure/SKILL.md"

# R55: worktree-start → WS
check_literal "R55" "WS-1" "skills/worktree-start/SKILL.md"

# R56: write-code → WCD
check_literal "R56" "WCD-1" "skills/write-code/SKILL.md"

# R57: write-tests → WT
check_literal "R57" "WT-1" "skills/write-tests/SKILL.md"

# --- Special-case checks (C1/C2/C4 resolution locks) ---

# R-SH-extra: survey-history Step 2.5 fix
check_literal "R-SH-extra" "SH-3" "skills/survey-history/SKILL.md"
check_absent "R-SH-extra-a" "Step 2.5" "skills/survey-history/SKILL.md"

# R-IC-extra: issue-create globally-unique IC-N (C1 resolution lock)
check_literal "R-IC-extra-a" "IC-4a" "skills/issue-create/SKILL.md"
check_absent "R-IC-extra-b" "IC-MWG-" "skills/issue-create/SKILL.md"
check_absent_regex "R-IC-extra-c" "^1\\. Resolve session intent" "skills/issue-create/SKILL.md"

# R-UD-extra: update-docs §4.2 letter-suffix under integer parents (C2 resolution lock)
check_literal "R-UD-extra-a" "UD-8a" "skills/update-docs/SKILL.md"
check_literal "R-UD-extra-b" "UD-9a" "skills/update-docs/SKILL.md"
check_absent "R-UD-extra-c" "UD-A1" "skills/update-docs/SKILL.md"
check_absent "R-UD-extra-d" "UD-B1" "skills/update-docs/SKILL.md"

# R-CP-extra: commit-push compound collapse (C4 resolution lock)
check_literal "R-CP-extra-a" "CP-2" "skills/commit-push/SKILL.md"
check_absent "R-CP-extra-b" "step 2-6" "skills/commit-push/SKILL.md"
check_absent "R-CP-extra-c" "CP-2-6" "skills/commit-push/SKILL.md"

# R-CPW-ref: commit-push-worker prose reference updated; worker's own 1.5. retained (C4 scope)
check_literal "R-CPW-ref-a" "Step CP-2" "agents/commit-push-worker.md"
check_literal "R-CPW-ref-b" "1.5." "agents/commit-push-worker.md"
