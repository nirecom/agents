#!/usr/bin/env bash
# Tests: hooks/workflow-gate/early-gate.js, hooks/workflow-gate/early-gate-allowlist.js, hooks/lib/workflow-plans-dir.js
# Tags: workflow-gate, early-gate, plans-dir, allowlist, containment, path-traversal, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section A21 — PLANS_DIR CONTAINMENT (review C1). Section A proves the allowlist
# says "yes" inside the plans dir and "no" to unrelated geography; it never attacks
# the plans boundary itself, so a refactor that lands a naive prefix check keeps every
# Section A row green while opening `<plans>-evil/` to any blocked session. The
# predicate under attack is the case-folded `startsWith(plansRoot + sep)` at
# early-gate.js:57-58, which #2108 moves into a shared allowlist module.

# _a21_target <shape> -> absolute forward-slash target for that attack shape
_a21_target() {
    case "$1" in
        # --- attacks -----------------------------------------------------------
        traversal-up)      printf '%s/../escape-2108.md' "$PLANS_FWD" ;;
        traversal-deep)    printf '%s/sub/../../escape-2108-deep.md' "$PLANS_FWD" ;;
        sibling-prefix)    printf '%s-evil/file.md' "$PLANS_FWD" ;;
        sibling-deep)      printf '%s-evil/deep/file.md' "$PLANS_FWD" ;;
        root-itself)       printf '%s' "$PLANS_FWD" ;;
        case-variant)      printf '%s/case-variant-2108.md' "$A21_UPPER_FWD" ;;
        # --- discriminators ----------------------------------------------------
        flat-descendant)   printf '%s/2108-containment.md' "$PLANS_FWD" ;;
        nested-descendant) printf '%s/sub/dir/artifact-2108.md' "$PLANS_FWD" ;;
        traversal-inside)  printf '%s/sub/../inside-2108.md' "$PLANS_FWD" ;;
        *)                 printf '/dev/null/unknown' ;;
    esac
}

# Attack 1 TRAVERSAL `<plans>/../escape.md` — the string names the root; the resolved
#          path does not live under it.
# Attack 2 PREFIX-SIBLING `<plans>-evil/file.md` — a real sibling whose absolute path
#          has the plans root as a string prefix (a startsWith that forgot the sep).
# Attack 3 CASE-VARIANT `<PLANS>/file.md` — a genuinely different directory that a
#          case-folded compare equates with the real one; constructible only on a
#          case-sensitive fs, so A21-9 probes for that (Pattern 3 records it otherwise).
# Each attack is paired with a nested descendant and with a traversal landing back
# INSIDE the root, so a block is attributable to containment (Pattern 4). Both tiers
# carry every row (CPR-ORTH): the allowlist sits before Tier 1 and Tier 2 alike.
run_A21_plans_containment() {
    local label tier tool shape want sid target evil upper_base

    # The prefix-sibling and the escape landing zone are REAL directories, so the
    # Pattern 1 negative assertions below can tell "blocked" from "written".
    evil="${PLANS_SH}-evil"
    rm -rf "$evil" 2>/dev/null || true
    mkdir -p "$evil/deep" "$PLANS_SH/sub/dir" 2>/dev/null || true

    # The uppercase twin is derived from the plans BASENAME, so it stays correct if the
    # dispatcher's fixture layout ever changes.
    upper_base="$(printf '%s' "${PLANS_FWD##*/}" | tr '[:lower:]' '[:upper:]')"
    A21_UPPER_FWD="${PLANS_FWD%/*}/$upper_base"

    # A21-0 — harness guard: without a distinct uppercase spelling the case rows below
    # would compare a string with itself and prove nothing.
    if [ "$PLANS_FWD" = "$A21_UPPER_FWD" ]; then
        fail "A21-0 plans basename has no distinct uppercase twin ($PLANS_FWD) - case rows would be vacuous"
    else
        pass "A21-0 plans-dir fixture and its uppercase twin are distinct strings"
    fi

    while IFS='|' read -r label tier tool shape want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; tier="${tier//[[:space:]]/}"
        tool="${tool//[[:space:]]/}"; shape="${shape//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        case "$tier" in T1) sid="$SID_T1" ;; *) sid="$SID_T2" ;; esac
        target="$(_a21_target "$shape")"
        assert_eq "A21 $label [$tier $tool $shape]" "$want" \
            "$(gate_decision "$(run_gate "$(mk_edit_input "$tool" "$sid" "$target")" "$SCRATCH_A")")"
    done <<'TABLE'
# label                    | tier | tool      | shape             | want
# --- DISCRIMINATORS: the allowlist really does say yes inside the root, at depth, and
# --- even when the written path carries `..` that resolves back inside. Without these
# --- the block rows would also be satisfied by an allowlist that blocks everything.
A21-1-flat-descendant      | T1 | Write     | flat-descendant   | approve
A21-1-flat-descendant      | T2 | Write     | flat-descendant   | approve
A21-2-nested-descendant    | T1 | Write     | nested-descendant | approve
A21-2-nested-descendant    | T2 | Write     | nested-descendant | approve
A21-2-nested-descendant    | T1 | Edit      | nested-descendant | approve
A21-2-nested-descendant    | T2 | MultiEdit | nested-descendant | approve
A21-3-traversal-inside     | T1 | Write     | traversal-inside  | approve
A21-3-traversal-inside     | T2 | Write     | traversal-inside  | approve
# --- ATTACK 1: traversal OUT of the plans root.
A21-4-traversal-up         | T1 | Write     | traversal-up      | block
A21-4-traversal-up         | T2 | Write     | traversal-up      | block
A21-4-traversal-up         | T1 | Edit      | traversal-up      | block
A21-4-traversal-up         | T2 | MultiEdit | traversal-up      | block
A21-5-traversal-deep       | T1 | Write     | traversal-deep    | block
A21-5-traversal-deep       | T2 | Write     | traversal-deep    | block
# --- ATTACK 2: prefix-sibling. `<plans>-evil` is not `<plans>/`.
A21-6-sibling-prefix       | T1 | Write     | sibling-prefix    | block
A21-6-sibling-prefix       | T2 | Write     | sibling-prefix    | block
A21-6-sibling-prefix       | T1 | Edit      | sibling-prefix    | block
A21-6-sibling-prefix       | T2 | MultiEdit | sibling-prefix    | block
A21-7-sibling-deep         | T1 | Write     | sibling-deep      | block
A21-7-sibling-deep         | T2 | Write     | sibling-deep      | block
# --- The root DIRECTORY itself is not a write target (mirrors A18-bad-sp-root-itself).
A21-8-root-itself          | T1 | Write     | root-itself       | block
A21-8-root-itself          | T2 | Write     | root-itself       | block
TABLE

    # A21-9 — ATTACK 3, the case-variant sibling. On a case-SENSITIVE filesystem
    # `<PLANS>/x.md` is a different directory that the case-folded compare at
    # early-gate.js:58 would wrongly accept; on a case-INSENSITIVE one it names the SAME
    # directory, so `approve` is correct there and asserting `block` would pin a
    # falsehood. Probe the fixture fs for real rather than branching on $OSTYPE
    # (CPR-UNV: never branch implicitly on an environment assumption).
    local probe_lc probe_uc fs_case t
    probe_lc="$PLANS_SH/casecheck-a21"
    probe_uc="$PLANS_SH/CASECHECK-A21"
    rm -rf "$probe_lc" "$probe_uc" 2>/dev/null || true
    mkdir -p "$probe_lc" 2>/dev/null || true
    if [ -d "$probe_uc" ]; then fs_case=insensitive; else fs_case=sensitive; fi
    rm -rf "$probe_lc" "$probe_uc" 2>/dev/null || true

    if [ "$fs_case" = sensitive ]; then
        pass "A21-9 fixture filesystem is case-sensitive: the case-variant sibling is a real directory"
        for t in T1 T2; do
            case "$t" in T1) sid="$SID_T1" ;; *) sid="$SID_T2" ;; esac
            assert_eq "A21-9 case-variant plans sibling is blocked [$t]" "block" \
                "$(gate_decision "$(run_gate "$(mk_edit_input Write "$sid" "$(_a21_target case-variant)")" "$SCRATCH_A")")"
        done
        # Counterweight on the SAME filesystem: the correctly-cased root still allows,
        # so the rows above prove case discrimination and not a dead allowlist.
        assert_eq "A21-9 control: correctly-cased plans descendant still allowed" "approve" \
            "$(gate_decision "$(run_gate "$(mk_edit_input Write "$SID_T1" "$(_a21_target flat-descendant)")" "$SCRATCH_A")")"
    else
        # SKIPPED: `<PLANS_UPPERCASED>/file.md` must block as a distinct directory.
        # Because: this fixture's filesystem is case-INSENSITIVE (probed above, not
        # assumed), so the uppercase path names the very same directory as the real
        # plans root — no genuine collision is constructible and `approve` is correct.
        # L3 gap: only a case-sensitive host (Linux / case-sensitive APFS CI) can
        # observe a case-folded containment compare over-allowing a sibling directory.
        skip "A21-9 case-variant plans sibling: fixture filesystem is case-insensitive (no genuine collision constructible)"
    fi

    # A21-10 — Pattern 1 negative assertion. Every blocked row above must have left its
    # target ABSENT: a "block" verdict beside a file on disk is not a block. The escape
    # landing zone sits OUTSIDE the plans root, which is exactly the property the
    # traversal rows claim the gate preserved.
    local victim
    for victim in "$TMPBASE_SH/escape-2108.md" "$TMPBASE_SH/escape-2108-deep.md" \
                  "$evil/file.md" "$evil/deep/file.md"; do
        if [ -e "$victim" ]; then
            fail "A21-10 blocked containment target was created at $victim"
        else
            pass "A21-10 blocked containment target remains absent ($victim)"
        fi
    done

    # SKIPPED: a SYMLINK inside the plans root redirecting a write outside it.
    # Because: the containment predicate is lexical by contract (claude-scratchpad-base.js
    # records the same residual for the scratchpad root) and symlink creation needs
    # elevation on the Windows fixture host, so the case would skip more often than run.
    # L3 gap: a filesystem where an allowed-looking path resolves to a different inode —
    # only a realpath-based containment check closes it.
}
