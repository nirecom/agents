#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/skill-section-helpers.sh
# Tests: tests/hooks/feature-2099-complexity-stage-routing/_lib.sh
# Tags: complexity, routing, prompt-static, helpers, jev, shared-procedure, scope:issue-specific
# Helper-only, no cases of its own. Sourced by the feature-2099-complexity-stage-routing-*.sh entrypoints
# and by ../feature-2460-jev-call-sites-static.sh, so the stage-1 suite and the
# stage-5 call-site suite read SKILL.md sections through ONE extractor (CPR-SSOT).
# Needs SCRIPT_CHECKOUT_ROOT from the sourcing runner. Single-path # Tests: (the
# first sourcing runner) — the calling cases own the targets.

d2099_has() {
    if grep -qF -- "$2" "$1" 2>/dev/null; then echo "yes"; else echo "no"; fi
}

d2099_has_re() {
    if grep -qE -- "$2" "$1" 2>/dev/null; then echo "yes"; else echo "no"; fi
}

# --- bounded skill-section extraction ---------------------------------------
# `<start regex>|<regex that ENDS the section>` per step id, read off the real
# structure of each SKILL.md: make-detail-plan uses `### MDP-n —` headings,
# write-tests/write-code bare `WT-n.` / `WCD-n.` labels at column 0 (their
# sub-steps are indented, so they do not terminate the section), clarify-intent
# `CI-Cn.` labels and workflow-init `- An.` bullets.
d2099_step_anchors() {
    case "$1" in
        MDP-3)  echo '^### MDP-3 |^### ' ;;
        MDP-4)  echo '^### MDP-4 |^### ' ;;
        MOP-2)  echo '^MOP-2\.|^MOP-[0-9]' ;;
        WT-0)   echo '^WT-0\.|^WT-[0-9]' ;;
        WT-6)   echo '^WT-6\.|^WT-[0-9]' ;;
        WT-7)   echo '^WT-7\.|^WT-[0-9]' ;;
        WCD-0)  echo '^WCD-0\.|^WCD-[0-9]' ;;
        WCD-3)  echo '^WCD-3\.|^WCD-[0-9]' ;;
        WCD-4)  echo '^WCD-4\.|^WCD-[0-9]' ;;
        CI-C1b) echo '^CI-C1b\.|^CI-C[0-9]' ;;
        A3a)    echo '^- A3a\.|^- A[0-9]' ;;
        *) echo "" ;;
    esac
}

# One step's section: its own label line through to (not including) the next
# sibling label. Prints nothing when the anchor matches nothing at all.
d2099_skill_section() {
    local f="$1" step="$2" spec start end
    spec=$(d2099_step_anchors "$step")
    [ -n "$spec" ] || return 0
    start="${spec%%|*}"; end="${spec#*|}"
    awk -v s="$start" -v e="$end" '
        !inside && $0 ~ s { inside = 1; print; next }
        inside && $0 ~ e { exit }
        inside { print }
    ' "$f" 2>/dev/null
}

# One step's OWN section, not the whole file: workflow-init's PM3 bullet names an
# unrelated `/issue-create --verdict`, which a whole-file grep reads as A3a still
# passing a verdict.
d2099_step_has() {
    if d2099_skill_section "$1" "$2" | grep -qF -- "$3"; then echo "yes"; else echo "no"; fi
}

# A step's own section for ids the anchor registry has no entry for (MOP-1d,
# MOP-C1, WCD-2, COS-n, JJ-n): from the line that starts with the id (behind any
# `- `, `#` or `**`) to the next line starting another id of the same prefix.
d2099_raw_section() {
    [ -f "$1" ] || return 0
    awk -v s="$2" -v p="${2%%-*}" '
        function idof(l) {
            sub(/^[-#* ]+/, "", l)
            return match(l, "^" p "-[A-Z]?[0-9]+[a-z]?") ? substr(l, RSTART, RLENGTH) : ""
        }
        { id = idof($0) }
        on && id != "" && id != s { exit }
        !on && id == s { on = 1 }
        on { print }
    ' "$1"
}

# Markdown items of a section ($1, text), one per output line: a bullet, table
# row or numbered item plus its wrapped continuation lines.
d2099_md_items() {
    printf '%s\n' "$1" | awk '
        /^[ \t]*([-*|]|[0-9]+\.)[ \t]/ { if (buf != "") print buf; buf = $0; next }
        /^[ \t]*$/ { if (buf != "") print buf; buf = ""; next }
        { buf = (buf == "" ? $0 : buf " " $0) }
        END { if (buf != "") print buf }
    '
}

d2099_nonblank_count() { printf '%s\n' "$1" | grep -c '[^[:space:]]'; }

# --- #2460 shared-procedure reference -----------------------------------------
D2099_JJ_FILE="$SCRIPT_CHECKOUT_ROOT/skills/_shared/jev-two-stage-judge.md"

# The line of a section ($1, text) that references the shared procedure for one
# point/stage: names the doc and spells `point=<P>` and `stage=<S>`.
d2099_jj_ref_line() {
    printf '%s\n' "$1" | grep -F 'jev-two-stage-judge.md' \
        | grep -E "point[= ]\`?$2\`?([^a-z-]|$)" \
        | grep -E "stage[= ]\`?$3\`?([^a-z-]|$)" | head -1
}

d2099_jj_ref_state() {
    if [ -n "$(d2099_jj_ref_line "$1" "$2" "$3")" ]; then echo "yes"; else echo "no"; fi
}
