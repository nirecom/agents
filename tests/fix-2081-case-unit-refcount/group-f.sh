# Group F: marker-less fallback + .ps1/.py extension guard (C10) (#2081,#1864)
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/case-parser.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/fix-2081-case-unit-refcount.sh
#
# A file with no case markers keeps the current file-level trp_survival_verdict
# behavior unchanged (TRP_HAS_MARKERS=0). C10: a .Tests.ps1 / test_*.py file is
# never marker-scanned (extension guard forces TRP_HAS_MARKERS=0) even if its
# text happens to contain a case_begin-looking token.

if ! require_fn trp_enumerate_cases "F0a"; then return 0; fi
if ! require_fn trp_case_refcount_verdict "F0b"; then return 0; fi

F_REPO="$(make_repo)"
add_src "$F_REPO" "bin/f-alive.sh"

# Marker-less alive file → file-unit, verdict must equal trp_survival_verdict.
add_test_file "$F_REPO" "f-nomarker-alive.sh" "bin/f-alive.sh" "TL2, scope:common"
# Marker-less dead file → file-unit, dead.
add_test_file "$F_REPO" "f-nomarker-dead.sh" "bin/f-missing.sh" "TL2, scope:common"
commit_repo "$F_REPO" "group-f marker-less fixtures"

run_enum "$F_REPO" "tests/f-nomarker-alive.sh"
assert_eq "F1 marker-less file has no markers" "0" "${TRP_HAS_MARKERS:-x}"

run_verdict "$F_REPO" "tests/f-nomarker-alive.sh"
assert_eq "F1b marker-less → file unit mode" "file" "${TRP_UNIT_MODE:-x}"
assert_eq "F1c marker-less alive verdict unchanged" "alive" "${TRP_VERDICT:-x}"

run_verdict "$F_REPO" "tests/f-nomarker-dead.sh"
assert_eq "F2 marker-less dead verdict unchanged (survival token 'orphan')" \
    "orphan" "${TRP_VERDICT:-x}"
assert_eq "F2b marker-less orphan refcount 0" "0" "${TRP_REFCOUNT:-x}"

# F3 — equivalence: the case path's fallback must produce the SAME verdict the
# legacy trp_survival_verdict returns directly on the identical marker-less file.
if require_fn trp_survival_verdict "F3-guard"; then
    ( cd "$F_REPO" && trp_survival_verdict "$F_REPO" "tests/f-nomarker-alive.sh" >/dev/null 2>&1 )
    _legacy_rc=$?
    run_verdict "$F_REPO" "tests/f-nomarker-alive.sh"
    assert_eq "F3 case-path fallback verdict == legacy survival verdict" \
        "alive" "${TRP_VERDICT:-x}"
    unset _legacy_rc
fi

# C10 — extension guard. A .Tests.ps1 and a test_*.py file each carry a literal
# `case_begin "x" "bin/f-missing.sh"` token but must NOT be marker-scanned: the
# extension guard forces TRP_HAS_MARKERS=0 and the file-level fallback applies.
add_raw "$F_REPO" "F-Extension.Tests.ps1" <<'EOF'
# Tests: bin/f-alive.sh
# Tags: TL2, scope:common
Describe 'x' {
  It 'contains a token that must be ignored' {
    $x = 'case_begin "x" "bin/f-missing.sh"'
    $x | Should -Not -BeNullOrEmpty
  }
}
EOF
add_raw "$F_REPO" "test_f_guard.py" <<'EOF'
# Tests: bin/f-alive.sh
# Tags: TL2, scope:common
def test_token_ignored():
    s = 'case_begin "x" "bin/f-missing.sh"'
    assert s
EOF
commit_repo "$F_REPO" "group-f C10 extension-guard fixtures"

run_enum "$F_REPO" "tests/F-Extension.Tests.ps1"
assert_eq "C10a .Tests.ps1 not marker-scanned (extension guard)" "0" "${TRP_HAS_MARKERS:-x}"
run_enum "$F_REPO" "tests/test_f_guard.py"
assert_eq "C10b test_*.py not marker-scanned (extension guard)" "0" "${TRP_HAS_MARKERS:-x}"

# C10c — those files still get a file-level verdict off their `# Tests:` header
# (alive here), never a spurious case orphan.
run_verdict "$F_REPO" "tests/F-Extension.Tests.ps1"
assert_eq "C10c .ps1 file-level verdict from header" "alive" "${TRP_VERDICT:-x}"
assert_eq "C10d .ps1 stays file unit mode" "file" "${TRP_UNIT_MODE:-x}"

# ── C1 — marker-less fallback equivalence across ALL legacy verdicts ─────────
# NOTE: passes after write-code step. On a marker-less file, trp_case_refcount_
# verdict must DELEGATE to trp_survival_verdict and return the identical verdict.
# The comparison is dynamic (against whatever legacy returns at runtime), so the
# claim under test is delegation equivalence itself, not any hardcoded token —
# this covers no-header, malformed, alive, orphan and renamed uniformly.
if require_fn trp_survival_verdict "C1-guard"; then
    # assert_equiv <label> <repo> <rel> — legacy survival verdict == case verdict,
    # and the marker-less file always resolves to file-unit mode.
    assert_equiv() {
        local label="$1" repo="$2" rel="$3" legacy
        legacy="$(trp_survival_verdict "$repo" "$rel" 2>/dev/null | tail -1)"
        run_verdict "$repo" "$rel"
        assert_eq "$label case verdict delegates to legacy ($legacy)" \
            "$legacy" "${TRP_VERDICT:-x}"
        assert_eq "$label stays file unit mode" "file" "${TRP_UNIT_MODE:-x}"
    }

    C1_REPO="$(make_repo)"
    add_src "$C1_REPO" "bin/c1-live.sh"
    # no-header: no `# Tests:` line at all.
    add_raw "$C1_REPO" "c1-noheader.sh" <<'EOF'
#!/usr/bin/env bash
echo body-only
EOF
    # malformed: a `# Tests:` token that is not a bare path (prose).
    add_raw "$C1_REPO" "c1-malformed.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: see the README for coverage details
# Tags: TL2, scope:common
echo x
EOF
    # alive: header target exists.
    add_test_file "$C1_REPO" "c1-alive.sh" "bin/c1-live.sh" "TL2, scope:common"
    # orphan: header target well-formed but missing (never existed).
    add_test_file "$C1_REPO" "c1-orphan.sh" "bin/c1-gone.sh" "TL2, scope:common"
    # renamed: target committed, then git-mv'd away; the header still names the
    # OLD path. Whether legacy calls this renamed or orphan, the case path agrees.
    add_src "$C1_REPO" "bin/c1-old.sh"
    add_test_file "$C1_REPO" "c1-renamed.sh" "bin/c1-old.sh" "TL2, scope:common"
    commit_repo "$C1_REPO" "group-f C1 fallback-equivalence fixtures"
    git -C "$C1_REPO" mv bin/c1-old.sh bin/c1-new.sh >/dev/null 2>&1
    commit_repo "$C1_REPO" "group-f C1 rename bin/c1-old.sh -> bin/c1-new.sh"

    assert_equiv "C1a no-header" "$C1_REPO" "tests/c1-noheader.sh"
    assert_equiv "C1b malformed" "$C1_REPO" "tests/c1-malformed.sh"
    assert_equiv "C1c alive" "$C1_REPO" "tests/c1-alive.sh"
    assert_equiv "C1d orphan" "$C1_REPO" "tests/c1-orphan.sh"
    assert_equiv "C1e renamed" "$C1_REPO" "tests/c1-renamed.sh"
fi
