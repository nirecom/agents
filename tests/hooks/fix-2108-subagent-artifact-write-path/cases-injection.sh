#!/usr/bin/env bash
# Tests: hooks/workflow-gate/early-gate.js, hooks/workflow-gate/early-gate-allowlist.js, hooks/lib/claude-scratchpad-base.js
# Tags: workflow-gate, early-gate, scratchpad, allowlist, path-traversal, separator, injection, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section E — ATTACK SHAPES against the new scratchpad allowlist
# (skills/_shared/test-design/protection-fix-tests.md Pattern 2). Section A proves the
# allow root works; this file proves it is a PATH BOUNDARY, not a string prefix.

# _e_gate <target> -> approve | block | unrecognized  (SCRATCHPAD pinned to session A)
_e_gate() { gate_decision "$(run_gate "$(mk_edit_input Write "$SID_T1" "$1")" "$SCRATCH_A")"; }

# Every case below is written to fail against the naive implementation this feature
# invites — `path.resolve(target).startsWith(process.env.SCRATCHPAD)`:
#   E1/E2  `../` traversal          - compares before resolving
#   E3     `<root>-evil/` sibling   - prefix carries no trailing separator
#   E4     mixed `\` / `/`          - compares raw spellings
# E5 is the paired allow control (Pattern 4). E6 asks the same boundary questions of
# hooks/lib/claude-scratchpad-base.js, which EXISTS today, so the requirement is
# observable before the early-gate wiring lands.
run_E_injection() {
    local sib_fwd bs deep out pred plat

    # A REAL sibling directory, not just a path string: an attacker who can create
    # `<scratchpad>-evil` next to the allowed root is the whole point of the case.
    sib_fwd="${SCRATCH_A_FWD}-evil"
    node -e "require('fs').mkdirSync(process.argv[1],{recursive:true})" "$sib_fwd" 2>/dev/null || true
    deep="$SCRATCH_A_FWD/nested/deeper"
    node -e "require('fs').mkdirSync(process.argv[1],{recursive:true})" "$deep" 2>/dev/null || true

    # Backslash spelling of the allow root. On win32 `\` is a real separator, so this
    # is a genuine alternate spelling of the same directory; on POSIX it is one literal
    # filename component, and the traversal therefore lands outside the root either way
    # — the case blocks on both platforms for platform-appropriate reasons (CPR-UNV).
    bs="${SCRATCH_A_FWD//\//\\}"

    # E1 — the plain `../` escape: one level up is the SESSION dir, not the scratchpad.
    assert_eq "E1 ../ traversal out of the scratchpad is blocked" "block" \
        "$(_e_gate "$SCRATCH_A_FWD/../escaped.md")"

    # E2 — traversal that lands in ANOTHER session's scratchpad. Same shape as A7/A8
    # (cross-session block) but reached by traversal instead of by naming, so an
    # allowlist that normalizes only the leading segment is caught.
    assert_eq "E2 ../ traversal into another session's scratchpad is blocked" "block" \
        "$(_e_gate "$SCRATCH_A_FWD/../../sessB/scratchpad/steal.md")"

    # E3 — sibling-prefix directory. `<root>-evil` shares every character of `<root>`,
    # so a prefix test without a trailing separator allows it. This is the single case
    # most likely to pass on a buggy implementation and must not be dropped.
    assert_eq "E3 sibling-prefix dir <root>-evil is NOT under the allow root" "block" \
        "$(_e_gate "$sib_fwd/steal.md")"

    # E4 — mixed separators. The prefix is spelled with `\`, the traversal with `/`.
    assert_eq "E4 mixed \\ and / separators cannot walk out of the allow root" "block" \
        "$(_e_gate "$bs/../../escaped.md")"

    # E5 — PAIRED ALLOW CONTROL. Same allow root, a legitimate nested descendant.
    # Without this, E1..E4 would also pass on an allowlist that blocks everything.
    assert_eq "E5 control: a deep descendant of the allow root is still allowed" "approve" \
        "$(_e_gate "$deep/notes.md")"

    # E5b — the win32 alternate spelling of a LEGITIMATE target. A separator-sensitive
    # comparison that folds nothing would reject the agent's own natural Windows path.
    # POSIX has no second spelling of this path, so the case is skipped there rather
    # than asserted with a platform-specific expectation (CPR-UNV: name the exception).
    plat="$(uname -s 2>/dev/null || printf 'unknown')"
    case "$plat" in
        MINGW*|MSYS*|CYGWIN*)
            assert_eq "E5b control: backslash-spelled descendant is allowed on win32" "approve" \
                "$(_e_gate "$bs\\ok.md")" ;;
        *)
            skip "E5b backslash spelling is not a path separator on $plat - win32-only case" ;;
    esac

    # E6 — the same boundary questions asked of the predicate that already exists, with
    # findRepoRoot stubbed to null so the F1 repo clause is out of the way and ONLY the
    # allow-root boundary is under test. One comma-joined line: traversal, sibling
    # prefix, mixed separator, root itself, valid descendant.
    pred="$(
        export SCRATCHPAD="$SCRATCH_A"
        run_probe -e "const m=require(process.argv[1]);const R=process.argv[2];const no=()=>null;process.stdout.write([m.isAllowedScratchpadTarget(R+'/../escaped.md',no),m.isAllowedScratchpadTarget(R+'-evil/steal.md',no),m.isAllowedScratchpadTarget(R.replace(/\//g,'\\\\')+'/../../escaped.md',no),m.isAllowedScratchpadTarget(R,no),m.isAllowedScratchpadTarget(R+'/nested/deeper/notes.md',no)].join(','))" \
            "$AGENTS_NODE/hooks/lib/claude-scratchpad-base.js" "$SCRATCH_A_FWD" 2>/dev/null
    )"
    if [ -n "$pred" ]; then
        assert_eq "E6 isAllowedScratchpadTarget boundary matrix (traversal,sibling,mixed-sep,root-itself,descendant)" \
            "false,false,false,false,true" "$pred"
    else
        fail "E6 isAllowedScratchpadTarget produced no output - the boundary predicate is unusable"
    fi

    # E7 — Pattern 1 negative assertion for the sibling-prefix attack: a blocked write
    # must leave nothing behind. The verdict alone would not catch a gate that resolved
    # the path by touching it.
    out="$sib_fwd/steal.md"
    if node -e "process.exit(require('fs').existsSync(process.argv[1])?0:1)" "$out" 2>/dev/null; then
        fail "E7 blocked sibling-prefix target was created at $out"
    else
        pass "E7 blocked sibling-prefix target remains absent (Pattern 1)"
    fi

    # SKIPPED: a symlink/junction planted INSIDE the allow root that redirects the
    # write elsewhere.
    # Because: the allow-root check is lexical by design and the same latent gap
    # already exists in the pre-existing plans-dir predicate — claude-scratchpad-base.js
    # records it as an accepted pre-existing residual, out of scope for #2108.
    # L3 gap: a real filesystem where the redirect actually lands on the far side.
}
