#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Section X - M-3 (.tmp symmetry) and CROSS-FILE DRIFT DETECTION.
#
# hooks/lib/protected-basenames.js is the SSOT for "which basenames hold clearance
# state" (CPR-2), but it is only a real SSOT while its consumers agree with it. The
# marker list is protected precisely BECAUSE hooks/lib/session-markers.js grants
# authorization on a marker's mere existence; if a future kind is added there and
# not here, that kind becomes forgeable the moment it starts granting anything, and
# no test written against a HARDCODED list would notice. So the checks below derive
# both sides from the source files and compare them.
#
# M-3 is the same argument one level down: the sanctioned writer creates a marker
# by writing `<marker>.tmp` and renaming. If only the final name is protected, the
# intermediate is a free write and the attacker just supplies the `mv` - which is
# why the token list has always carried `.off-clearance.tmp`, and why the marker
# list must carry `.tmp` for every kind (CPR-5 symmetry).

run_X_ssot() {
    local probe="$SANDBOX/ssot-probe.js" out line

    cat > "$probe" <<'PROBE_EOF'
"use strict";
const p = require(process.argv[2]);
const out = [];
// M-3: for every marker kind, BOTH the bare and the .tmp form must classify as a
// marker, and both must arm the mention gate. Derived from the SSOT, so a kind
// added later is checked automatically.
for (const kind of p.SESSION_MARKER_KINDS) {
  out.push(`classify .${kind}=${p.classifyProtectedPath("s1." + kind)}`);
  out.push(`classify .${kind}.tmp=${p.classifyProtectedPath("s1." + kind + ".tmp")}`);
  out.push(`suffixlist .${kind}=${p.PROTECTED_MARKER_SUFFIXES.includes("." + kind)}`);
  out.push(`suffixlist .${kind}.tmp=${p.PROTECTED_MARKER_SUFFIXES.includes("." + kind + ".tmp")}`);
  out.push(`mention .${kind}=${p.mentionsProtectedName("s1." + kind)}`);
  out.push(`mention .${kind}.tmp=${p.mentionsProtectedName("s1." + kind + ".tmp")}`);
  out.push(`re .${kind}=${p.PROTECTED_MARKER_BASENAME_RE.test("s1." + kind)}`);
  out.push(`re .${kind}.tmp=${p.PROTECTED_MARKER_BASENAME_RE.test("s1." + kind + ".tmp")}`);
}
// Token side of the same symmetry, also derived.
for (const sfx of p.OFF_CLEARANCE_TOKEN_SUFFIXES) {
  out.push(`tokclassify ${sfx}=${p.classifyProtectedPath("s1" + sfx)}`);
  out.push(`tokre ${sfx}=${p.TOKEN_BASENAME_RE.test("s1" + sfx)}`);
}
// Every non-terminal token suffix has a .tmp sibling in the list; that pairing is
// what the marker list mirrors.
const tokPairs = p.OFF_CLEARANCE_TOKEN_SUFFIXES
  .filter((s) => !s.endsWith(".tmp") && !s.endsWith(".claimed"))
  .every((s) => p.OFF_CLEARANCE_TOKEN_SUFFIXES.includes(s + ".tmp"));
out.push(`tokentmp-pairing=${tokPairs}`);
// The marker list must be exactly {.kind, .kind.tmp} for every kind - no more, no
// less. A stray entry means a hand-edit crept into a derived list.
const want = p.SESSION_MARKER_KINDS.reduce((a, k) => a.concat(["." + k, "." + k + ".tmp"]), []);
out.push(`markerlist-exact=${JSON.stringify([...p.PROTECTED_MARKER_SUFFIXES].sort()) === JSON.stringify(want.sort())}`);
// The mention gate must stay off the DOCUMENTATION of the escape hatch (the
// Section N failure mode, asserted here at regex level too).
out.push(`mention rules/workflow-off.md=${p.mentionsProtectedName("rules/workflow-off.md")}`);
out.push(`mention skills/enforce-workflow-off/SKILL.md=${p.mentionsProtectedName("skills/enforce-workflow-off/SKILL.md")}`);
out.push(`emergencykind-listed=${p.SESSION_MARKER_KINDS.includes(p.EMERGENCY_PROVENANCE_MARKER_KIND)}`);
process.stdout.write(out.join("\n"));
PROBE_EOF

    out=$("$RWT" 15 node "$probe" "$PB_NODE" 2>/dev/null)
    if [ -z "$out" ]; then
        fail "X1 SSOT probe produced no output (node or hooks/lib/protected-basenames.js unusable)"
        return
    fi

    local kind
    for kind in $MARKER_KINDS; do
        assert_eq "X1 [$kind] bare classifies as marker"    "classify .$kind=marker"        "$(printf '%s\n' "$out" | grep -F "classify .$kind=" | head -1)"
        assert_eq "X1 [$kind] .tmp classifies as marker (M-3)" "classify .$kind.tmp=marker" "$(printf '%s\n' "$out" | grep -F "classify .$kind.tmp=" | head -1)"
        assert_eq "X2 [$kind] .tmp present in suffix list"  "suffixlist .$kind.tmp=true"    "$(printf '%s\n' "$out" | grep -F "suffixlist .$kind.tmp=" | head -1)"
        assert_eq "X2 [$kind] .tmp matches marker regex"    "re .$kind.tmp=true"            "$(printf '%s\n' "$out" | grep -F "re .$kind.tmp=" | head -1)"
        assert_eq "X3 [$kind] .tmp arms the mention gate"   "mention .$kind.tmp=true"       "$(printf '%s\n' "$out" | grep -F "mention .$kind.tmp=" | head -1)"
    done

    local sfx
    for sfx in $TOKEN_SUFFIXES; do
        assert_eq "X4 token [$sfx] classifies as token"  "tokclassify $sfx=token" "$(printf '%s\n' "$out" | grep -F "tokclassify $sfx=" | head -1)"
        assert_eq "X4 token [$sfx] matches token regex"  "tokre $sfx=true"        "$(printf '%s\n' "$out" | grep -F "tokre $sfx=" | head -1)"
    done

    assert_eq "X5 token list pairs every writable form with .tmp"  "tokentmp-pairing=true"   "$(printf '%s\n' "$out" | grep -F 'tokentmp-pairing=' | head -1)"
    assert_eq "X5 marker list is exactly {.kind,.kind.tmp} per kind" "markerlist-exact=true" "$(printf '%s\n' "$out" | grep -F 'markerlist-exact=' | head -1)"
    assert_eq "X5 emergency-provenance kind is in the marker set"  "emergencykind-listed=true" "$(printf '%s\n' "$out" | grep -F 'emergencykind-listed=' | head -1)"
    assert_eq "X6 mention gate ignores rules/workflow-off.md"      "mention rules/workflow-off.md=false" "$(printf '%s\n' "$out" | grep -F 'mention rules/workflow-off.md=' | head -1)"
    assert_eq "X6 mention gate ignores skills/enforce-workflow-off/" "mention skills/enforce-workflow-off/SKILL.md=false" "$(printf '%s\n' "$out" | grep -F 'mention skills/enforce-workflow-off/SKILL.md=' | head -1)"

    rm -f "$probe" 2>/dev/null || true

    # --- drift vs hooks/lib/session-markers.js ------------------------------
    # This is the file whose existence checks GRANT clearance. Every dotted
    # suffix literal it uses to build a marker path must be protected by the
    # SSOT; a new kind added there without a matching SSOT entry is immediately
    # forgeable, and this assertion is what catches it.
    if [ -f "$SESSION_MARKERS_SRC" ]; then
        local lits lit unprotected=""
        lits=$(grep -o '"\.[A-Za-z][A-Za-z0-9.-]*"' "$SESSION_MARKERS_SRC" | tr -d '"' | sort -u)
        for lit in $lits; do
            if ! "$RWT" 10 node -e \
                'const p=require(process.argv[1]);process.exit(p.classifyProtectedPath("s1"+process.argv[2])?0:1)' \
                "$PB_NODE" "$lit" >/dev/null 2>&1; then
                unprotected="$unprotected $lit"
            fi
        done
        assert_eq "X7 every suffix literal in session-markers.js is protected by the SSOT" "" "$unprotected"
    else
        skip "X7 hooks/lib/session-markers.js not found"
    fi

    # --- drift vs hooks/workflow-state/state-io/zombie-cleanup.js -----------
    # A protected marker kind that the sweep does not know about never expires,
    # so a stale grant survives indefinitely. Both directions are checked: every
    # SSOT kind is swept, and every marker-ish suffix swept there is an SSOT kind
    # (".json" / ".tmp" are the sweep's own generic branches, not marker kinds).
    if [ -f "$ZOMBIE_SRC" ]; then
        local swept missing="" k extra=""
        swept=$(grep -o 'endsWith("\.[A-Za-z][A-Za-z0-9.-]*")' "$ZOMBIE_SRC" | sed 's/.*("//; s/")$//' | sort -u)
        for k in $MARKER_KINDS; do
            printf '%s\n' "$swept" | grep -qx "\.$k" || missing="$missing $k"
        done
        assert_eq "X8 every protected marker kind is swept by zombie-cleanup" "" "$missing"

        for lit in $swept; do
            case "$lit" in
                .json|.tmp) continue ;;
            esac
            if ! "$RWT" 10 node -e \
                'const p=require(process.argv[1]);process.exit(p.classifyProtectedPath("s1"+process.argv[2])?0:1)' \
                "$PB_NODE" "$lit" >/dev/null 2>&1; then
                extra="$extra $lit"
            fi
        done
        assert_eq "X9 every marker suffix swept by zombie-cleanup is protected by the SSOT" "" "$extra"
    else
        skip "X8/X9 hooks/workflow-state/state-io/zombie-cleanup.js not found"
    fi

    # --- registration: the guard must be wired to the write tools ----------
    # A perfect classifier that settings.json never invokes protects nothing.
    # Static check only - see the "# TL3 gap" block in the dispatcher.
    if [ -f "$SETTINGS" ]; then
        local matcher
        matcher=$(grep -B4 'block-off-clearance-write' "$SETTINGS" | grep -o '"matcher": *"[^"]*"' | tail -1)
        case "$matcher" in
            *Edit*Write*Bash*|*Edit*Bash*Write*|*Bash*Edit*Write*) pass "X10 settings.json wires the guard to Edit/Write/MultiEdit/Bash ($matcher)" ;;
            "") fail "X10 settings.json has no matcher for block-off-clearance-write" ;;
            *)  fail "X10 settings.json matcher does not cover Edit+Write+Bash: $matcher" ;;
        esac
        # marker-gate.js must keep re-exporting the SSOT rather than owning a
        # second copy of the regex (CPR-2 defence in depth, not a fork).
        if [ -f "$AGENTS_DIR/hooks/enforce-worktree/bash-write-scope/marker-gate.js" ]; then
            if grep -q 'protected-basenames' "$AGENTS_DIR/hooks/enforce-worktree/bash-write-scope/marker-gate.js"; then
                pass "X11 marker-gate.js sources its marker set from the SSOT"
            else
                fail "X11 marker-gate.js no longer references hooks/lib/protected-basenames - marker set has forked"
            fi
        else
            skip "X11 marker-gate.js not found"
        fi
    else
        skip "X10/X11 settings.json not found"
    fi
}
