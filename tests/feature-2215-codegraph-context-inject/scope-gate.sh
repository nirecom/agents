# shellcheck shell=bash
# Tests: hooks/codegraph-context-inject.js, hooks/lib/codegraph-boundary.js
# Tags: hook-injection, codegraph, prompt-hook, scope-gate, TL2, scope:issue-specific
# M27-M31 — promptHookScopeAllows(): which cwd may reach the CLI at all.

# ===========================================================================
# M27 / M27b: scope-gate negative cases -- home and filesystem root are
# denied outright, stub never invoked, regardless of what a down-scan would
# have found (round-5 codex C2 / round-7 codex C2)
# ===========================================================================
RESET_LOGS
run_hook "{\"prompt\":\"hi\",\"cwd\":\"$FAKE_HOME_N\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$FAKE_HOME" >/dev/null
raw27="$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$FAKE_HOME_N\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$FAKE_HOME")"
calls27="$(call_count)"
if [ "$raw27" = "{}" ] && [ "$calls27" -eq 0 ]; then
    pass "M27: cwd=\$FAKE_HOME (package.json + indexed child) -> {} , stub never called"
else
    fail "M27: raw='$raw27' calls=$calls27"
fi

FS_ROOT=$(node -e "process.stdout.write(require('path').parse(process.cwd()).root)")
RESET_LOGS
raw27b="$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$FS_ROOT\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$ORD_PLAIN")"
calls27b="$(call_count)"
if [ "$raw27b" = "{}" ] && [ "$calls27b" -eq 0 ]; then
    pass "M27b: cwd=filesystem root ($FS_ROOT) -> {} , stub never called"
else
    fail "M27b: raw='$raw27b' calls=$calls27b"
fi

# ===========================================================================
# M27c: cwd is a SUBDIRECTORY of $HOME (not $HOME itself) -> ALLOW, stub IS
# called. Round-7 design decision: the gate denies only when cwd IS EXACTLY
# home (or the filesystem root), never merely "under" home. An implementation
# that used cwd.startsWith(homedir) instead of exact equality would wrongly
# silence the hook for every directory under the user's home, and no other
# case in this file would catch that regression -- every existing ALLOW
# fixture lives entirely outside $FAKE_HOME.
# ===========================================================================
mkdir -p "$FAKE_HOME/projects/foo"
RESET_LOGS
raw27c="$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$(to_node_path "$FAKE_HOME/projects/foo")\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$FAKE_HOME/projects/foo" CG_STUB_OUT="ctx27c")"
calls27c="$(call_count)"
argv27c="$(last_call_argv)"
if [ "$calls27c" -eq 1 ] && [ "$argv27c" = "prompt-hook" ]; then
    pass "M27c: cwd=\$HOME/projects/foo (subdirectory of home, not home itself) -> stub called (exact-equality gate, not startsWith)"
else
    fail "M27c: calls=$calls27c argv='$argv27c' raw='$raw27c'"
fi
rm -rf "$FAKE_HOME/projects"

# ===========================================================================
# M28 / M29: scope-gate positive cases -- an indexed root, and a directory
# 3 levels below it (up-walk)
# ===========================================================================
RESET_LOGS
raw28="$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$INDEXED_ROOT\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$TMPDIR_BASE/roots/indexed" CG_STUB_OUT="ctx28")"
calls28="$(call_count)"
ctx28=$(json_field "$raw28" "hookSpecificOutput.additionalContext")
argv28="$(last_call_argv)"
if [ "$calls28" -eq 1 ] && [ "$ctx28" = "ctx28" ] && [ "$argv28" = "prompt-hook" ]; then
    pass "M28: cwd=indexed project root -> stub called once with argv 'prompt-hook', output forwarded"
else
    fail "M28: calls=$calls28 ctx='$ctx28' argv='$argv28' raw='$raw28'"
fi

RESET_LOGS
raw29="$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$DEEP_SUB\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$TMPDIR_BASE/roots/indexed/a/b/c" CG_STUB_OUT="ctx29")"
calls29="$(call_count)"
argv29="$(last_call_argv)"
if [ "$calls29" -eq 1 ] && [ "$argv29" = "prompt-hook" ]; then
    pass "M29: cwd=3 levels below an indexed root -> stub called with argv 'prompt-hook' (up-walk)"
else
    fail "M29: calls=$calls29 argv='$argv29' raw='$raw29'"
fi

# ===========================================================================
# M30: ordinary directories (neither home nor root, no indexed ancestor) --
# the stub IS called in both cases (down-scan path is upstream's to run;
# round-7 codex C2 regression -- a too-narrow gate would silence these)
# ===========================================================================
RESET_LOGS
raw30a="$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$ORD_MANIFEST\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$TMPDIR_BASE/roots/ord-manifest" CG_STUB_OUT="ctx30a")"
calls30a="$(call_count)"
argv30a="$(last_call_argv)"
if [ "$calls30a" -eq 1 ] && [ "$argv30a" = "prompt-hook" ]; then
    pass "M30 (with manifest): stub called with argv 'prompt-hook' -- down-scan path not silenced"
else
    fail "M30 (with manifest): calls=$calls30a argv='$argv30a' raw='$raw30a'"
fi

RESET_LOGS
raw30b="$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$ORD_PLAIN\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$ORD_PLAIN" CG_STUB_OUT="ctx30b")"
calls30b="$(call_count)"
argv30b="$(last_call_argv)"
if [ "$calls30b" -eq 1 ] && [ "$argv30b" = "prompt-hook" ]; then
    pass "M30 (no manifest): stub called with argv 'prompt-hook' -- gate does not require a manifest"
else
    fail "M30 (no manifest): calls=$calls30b argv='$argv30b' raw='$raw30b'"
fi

# ===========================================================================
# M31: payload has no cwd key -- gate falls back to process.cwd()
# ===========================================================================
RESET_LOGS
raw31a="$(run_hook '{"prompt":"hi","session_id":"s1","hook_event_name":"UserPromptSubmit"}' "$TMPDIR_BASE/roots/indexed" CG_STUB_OUT="ctx31a")"
calls31a="$(call_count)"
argv31a="$(last_call_argv)"
if [ "$calls31a" -eq 1 ] && [ "$argv31a" = "prompt-hook" ]; then
    pass "M31 (indexed process.cwd()): cwd absent, launched from an indexed dir -> stub called with argv 'prompt-hook'"
else
    fail "M31 (indexed process.cwd()): calls=$calls31a argv='$argv31a' raw='$raw31a'"
fi

RESET_LOGS
raw31b="$(run_hook '{"prompt":"hi","session_id":"s1","hook_event_name":"UserPromptSubmit"}' "$FAKE_HOME")"
calls31b="$(call_count)"
if [ "$raw31b" = "{}" ] && [ "$calls31b" -eq 0 ]; then
    pass "M31 (\$FAKE_HOME process.cwd()): cwd absent, launched from home -> {} , stub not called"
else
    fail "M31 (\$FAKE_HOME process.cwd()): raw='$raw31b' calls=$calls31b"
fi
