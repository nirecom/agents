# axis-d.sh — Axis D: Encoding / cross-platform cases (B-26..B-28)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.

# ===========================================================================
# B-26: Windows path forms — CLAUDE_PROJECT_DIR encoding (Windows-only).
# Guard: command -v cygpath — skip with SKIPPED on non-Windows hosts.
# Table-driven: three path forms, all encode to the same canonical dir name.
# ===========================================================================
setup
if ! command -v cygpath >/dev/null 2>&1; then
    echo "SKIPPED B-26: cygpath unavailable (not a Windows/MSYS2 host)"
    # Because: node path.resolve() on Linux resolves 'C:/...' relative to CWD,
    # not as a Windows drive letter — encoding differs from Windows node behavior.
else
    TARGET_ENCODED="c--sid-b26-fixture-proj"
    mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$TARGET_ENCODED" "sid-b26-result"

    assert_eq() {
        local name="$1" want="$2" got="$3"
        if [ "$want" = "$got" ]; then
            pass "$name"
        else
            fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        fi
    }

    while IFS='|' read -r row_name proj_dir_val; do
        [[ -z "$row_name" || "$row_name" =~ ^[[:space:]]*# ]] && continue
        row_name="${row_name//[[:space:]]/}"
        proj_dir_val="${proj_dir_val# }"
        NONGIT_CWD="$TMP/b26-nongit-$row_name"
        mkdir -p "$NONGIT_CWD"
        GOT=$(bash -c "
            unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
            export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
            export CLAUDE_PROJECT_DIR='$proj_dir_val'
            export AGENTS_CONFIG_DIR='$AGENTS_DIR'
            cd '$NONGIT_CWD'
            bash '$BRIDGE' 2>/dev/null
        " 2>/dev/null)
        assert_eq "B-26/$row_name" "sid-b26-result" "$GOT"
    done <<'TABLE'
forward-slash  | C:/sid-b26-fixture/proj
backslash      | C:\sid-b26-fixture\proj
trailing-slash | C:/sid-b26-fixture/proj/
TABLE
fi
teardown

# ===========================================================================
# B-27: Cross-platform encoding — CLAUDE_PROJECT_DIR = real created temp dir.
# Expected encoded name computed independently via enc() (argv-based node
# path.resolve). argv-based is essential under Git Bash: MSYS converts both
# node argv and exported env-var paths with the same lexical mapping, so
# enc()'s expectation and the bridge's view of CLAUDE_PROJECT_DIR agree;
# script-embedded paths bypass conversion and diverge.
# ===========================================================================
setup
PROJ_DIR="$TMP/b27-proj"
mkdir -p "$PROJ_DIR"
EXPECTED_ENCODED=$(enc "$PROJ_DIR")
mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$EXPECTED_ENCODED" "sid-b27-result"

NONGIT_CWD="$TMP/b27-nongit"
mkdir -p "$NONGIT_CWD"
run_bridge "$NONGIT_CWD" "CLAUDE_PROJECT_DIR=$PROJ_DIR"
if [ "$BRIDGE_RC" -eq 0 ] && [ "$BRIDGE_OUT" = "sid-b27-result" ]; then
    pass "B-27: bridge finds JSONL for real temp dir via independent node encoding"
else
    fail "B-27: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='sid-b27-result' (encoded='$EXPECTED_ENCODED')"
fi
teardown

# ===========================================================================
# B-28: Cross-platform — CLAUDE_PROJECT_DIR = POSIX-form nonexistent path.
# Expected encoding computed via enc() (argv-based; platform-dependent by
# design: on native win32 node, '/sid-b28-fixture/repo' resolves under the
# current drive; under Git Bash, MSYS lexically maps it under the MSYS root —
# identically for enc()'s argv and the bridge's env, so they always agree).
# Adjacent Skipped-Because: Git-Bash /c/... drive-form normalization coverage
# (old B-10/B-13) intentionally dropped — the only producer of that form was
# the old bash R3 encoder (deleted); node process.cwd()/CLAUDE_PROJECT_DIR
# never emit /c/... form; R1 logic change is prohibited.
# ===========================================================================
setup
POSIX_PROJ='/sid-b28-fixture/repo'
EXPECTED_ENCODED=$(enc "$POSIX_PROJ")
mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$EXPECTED_ENCODED" "sid-b28-result"

NONGIT_CWD="$TMP/b28-nongit"
mkdir -p "$NONGIT_CWD"
run_bridge "$NONGIT_CWD" "CLAUDE_PROJECT_DIR=$POSIX_PROJ"
if [ "$BRIDGE_RC" -eq 0 ] && [ "$BRIDGE_OUT" = "sid-b28-result" ]; then
    pass "B-28: bridge finds JSONL for POSIX-form nonexistent CLAUDE_PROJECT_DIR (enc/argv encoding)"
else
    fail "B-28: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='sid-b28-result' (encoded='$EXPECTED_ENCODED')"
fi
teardown
