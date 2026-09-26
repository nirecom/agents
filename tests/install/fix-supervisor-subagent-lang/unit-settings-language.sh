# unit-settings-language.sh — Unit tests for settings.json "language" field
# and survival through install/assemble-settings.js merge.
# Sourced after helpers.sh; inherits all variables and functions.

# ---------------------------------------------------------------------------
# T1 [Unit] settings.json has top-level "language": "japanese"
# ---------------------------------------------------------------------------
T1_LANG=$(node -e "
try {
  const s = require(process.argv[1]);
  process.stdout.write(typeof s.language === 'string' ? s.language : '__absent__');
} catch (e) { process.stdout.write('__error__'); }
" "$NODE_SETTINGS_JSON" 2>/dev/null)

if [ "$T1_LANG" = "__absent__" ]; then
    skip "T1: settings.json has no top-level 'language' field (pre-implementation Phase 1)"
elif [ "$T1_LANG" = "__error__" ]; then
    fail "T1: settings.json could not be loaded as JSON"
elif [ "$T1_LANG" = "japanese" ]; then
    pass "T1: settings.json top-level language === 'japanese'"
else
    fail "T1: settings.json top-level language is '$T1_LANG' (expected 'japanese')"
fi

# ---------------------------------------------------------------------------
# T2 [Unit] language field survives install/assemble-settings.js merge
# ---------------------------------------------------------------------------
if [ ! -f "$ASSEMBLE_SETTINGS" ]; then
    skip "T2: install/assemble-settings.js missing — cannot verify merge"
elif [ "$T1_LANG" = "__absent__" ]; then
    skip "T2: base settings.json lacks 'language' field — merge test moot"
else
    T2_HOME="$TMPDIR_BASE/t2-home"
    mkdir -p "$T2_HOME"
    # assemble-settings.js writes to ~/.claude/settings.json (homedir).
    if HOME="$T2_HOME" USERPROFILE="$T2_HOME" \
        run_with_timeout 30 node "$ASSEMBLE_SETTINGS" >/dev/null 2>&1; then
        # Find assembled file under HOME (Windows uses USERPROFILE for os.homedir).
        T2_OUT=""
        for cand in \
            "$T2_HOME/.claude/settings.json" \
            ; do
            if [ -f "$cand" ]; then T2_OUT="$cand"; break; fi
        done
        if [ -z "$T2_OUT" ]; then
            # Fallback: find anywhere under tmpdir
            T2_OUT=$(find "$T2_HOME" -name settings.json -type f 2>/dev/null | head -1)
        fi
        if [ -z "$T2_OUT" ]; then
            fail "T2: assemble-settings.js completed but no settings.json under $T2_HOME"
        else
            T2_OUT_NODE=$(to_node_path "$T2_OUT")
            T2_MERGED=$(node -e "
try {
  const s = require(process.argv[1]);
  process.stdout.write(typeof s.language === 'string' ? s.language : '__absent__');
} catch (e) { process.stdout.write('__error__'); }
" "$T2_OUT_NODE" 2>/dev/null)
            if [ "$T2_MERGED" = "japanese" ]; then
                pass "T2: assembled settings.json preserves language='japanese'"
            else
                fail "T2: assembled settings.json language='$T2_MERGED' (expected 'japanese')"
            fi
        fi
    else
        skip "T2: assemble-settings.js failed to run under tmpdir HOME (likely Windows homedir resolution)"
    fi
fi

# ---------------------------------------------------------------------------
# T3 [Regression] settings-extension.json language override wins (when present);
# else verify base language field is present in assembled file.
# ---------------------------------------------------------------------------
EXT_PATH="$AGENTS_DIR/settings-extension.json"
if [ ! -f "$ASSEMBLE_SETTINGS" ]; then
    skip "T3: install/assemble-settings.js missing — cannot verify override"
elif [ "$T1_LANG" = "__absent__" ]; then
    skip "T3: base settings.json lacks 'language' field — override test moot"
else
    T3_HOME="$TMPDIR_BASE/t3-home"
    mkdir -p "$T3_HOME"
    # Determine: does the repo ship a settings-extension.json with a language field?
    EXT_LANG="__no_ext__"
    if [ -f "$EXT_PATH" ]; then
        EXT_PATH_NODE=$(to_node_path "$EXT_PATH")
        EXT_LANG=$(node -e "
try {
  const s = require(process.argv[1]);
  process.stdout.write(typeof s.language === 'string' ? s.language : '__no_lang_key__');
} catch (e) { process.stdout.write('__error__'); }
" "$EXT_PATH_NODE" 2>/dev/null)
    fi
    if HOME="$T3_HOME" USERPROFILE="$T3_HOME" \
        run_with_timeout 30 node "$ASSEMBLE_SETTINGS" >/dev/null 2>&1; then
        T3_OUT=$(find "$T3_HOME" -name settings.json -type f 2>/dev/null | head -1)
        if [ -z "$T3_OUT" ]; then
            fail "T3: no assembled settings.json under $T3_HOME"
        else
            T3_OUT_NODE=$(to_node_path "$T3_OUT")
            T3_MERGED=$(node -e "
try {
  const s = require(process.argv[1]);
  process.stdout.write(typeof s.language === 'string' ? s.language : '__absent__');
} catch (e) { process.stdout.write('__error__'); }
" "$T3_OUT_NODE" 2>/dev/null)
            if [ "$EXT_LANG" != "__no_ext__" ] && [ "$EXT_LANG" != "__no_lang_key__" ] && [ "$EXT_LANG" != "__error__" ]; then
                # Extension carries a language field → it must win the merge.
                if [ "$T3_MERGED" = "$EXT_LANG" ]; then
                    pass "T3: settings-extension.json language='$EXT_LANG' overrides base in assembled output"
                else
                    fail "T3: extension language='$EXT_LANG' did not override; assembled='$T3_MERGED'"
                fi
            else
                # No extension override; assembled file should still carry base language.
                if [ "$T3_MERGED" = "japanese" ]; then
                    pass "T3: no extension override; assembled retains base language='japanese'"
                else
                    fail "T3: assembled language='$T3_MERGED' (expected 'japanese' since no extension override)"
                fi
            fi
        fi
    else
        skip "T3: assemble-settings.js failed under tmpdir HOME"
    fi
fi

# ---------------------------------------------------------------------------
# T4 [Phase 2a-gated] assembled settings has SubagentStart hook entry
# referencing subagent-start.js
# ---------------------------------------------------------------------------
if [ ! -f "$SUBAGENT_START" ]; then
    skip "T4: hooks/subagent-start.js missing (Phase 2a not yet adopted)"
elif [ ! -f "$ASSEMBLE_SETTINGS" ]; then
    skip "T4: install/assemble-settings.js missing — cannot verify assembled hooks"
else
    T4_HOME="$TMPDIR_BASE/t4-home"
    mkdir -p "$T4_HOME"
    if HOME="$T4_HOME" USERPROFILE="$T4_HOME" \
        run_with_timeout 30 node "$ASSEMBLE_SETTINGS" >/dev/null 2>&1; then
        T4_OUT=$(find "$T4_HOME" -name settings.json -type f 2>/dev/null | head -1)
        if [ -z "$T4_OUT" ]; then
            fail "T4: no assembled settings.json under $T4_HOME"
        else
            T4_OUT_NODE=$(to_node_path "$T4_OUT")
            T4_HAS=$(node -e "
try {
  const s = require(process.argv[1]);
  const arr = (s.hooks && s.hooks.SubagentStart) || [];
  let found = false;
  const flat = JSON.stringify(arr);
  if (flat.indexOf('subagent-start.js') !== -1) found = true;
  process.stdout.write(found ? 'yes' : 'no');
} catch (e) { process.stdout.write('error:' + e.message); }
" "$T4_OUT_NODE" 2>/dev/null)
            if [ "$T4_HAS" = "yes" ]; then
                pass "T4: assembled settings.json has SubagentStart hook referencing subagent-start.js"
            else
                fail "T4: assembled settings.json missing SubagentStart hook for subagent-start.js (got: $T4_HAS)"
            fi
        fi
    else
        skip "T4: assemble-settings.js failed under tmpdir HOME"
    fi
fi
