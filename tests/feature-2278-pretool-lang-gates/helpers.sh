#!/bin/bash
# tests/feature-2278-pretool-lang-gates/helpers.sh
# Tests: hooks/gate-plan-lang.js, hooks/gate-worktree-notes-lang.js, hooks/lib/pretool-lang-gate.js
# Tags: lang, hook, pretooluse, plans, worktree-notes, TL2, scope:issue-specific
# Sourced by ../feature-2278-pretool-lang-gates.sh — shared fixtures and
# assertion helpers for the SHL-/PLG-/WNG-/SET- case files.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for language-policy tests

# Same fixture identities as tests/unit-check-plan-lang.sh (TIMESTAMP + UUID forms).
FAKE_UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
FAKE_TS="20260625-120000"

# English prose long enough for lintPlanLang's ENGLISH_RUN_RE (4+ words).
EN_PROSE='This paragraph is written entirely in English prose for the gate.'
JA_PROSE='この段落は日本語で書かれています。'
# Synthetic token planted on a NON-violating line of a violating fixture (C3):
# a block reason may echo the violating line, never the rest of the payload.
SYNTHETIC_SECRET='SYNTHETIC_SECRET_2278_a9f3k2'

# make_env <plan_lang> <docs_public> <docs_private>
# Creates a fresh AGENTS_CONFIG_DIR whose .env carries exactly the given keys
# (an empty argument omits that key). Prints the Node-form path.
make_env() {
    local plan_lang="$1" docs_public="$2" docs_private="$3"
    local d
    d="$(mktemp -d "$TEST_ROOT/cfg-XXXXXX")"
    : > "$d/.env"
    [ -n "$plan_lang" ] && echo "PLAN_LANG=$plan_lang" >> "$d/.env"
    [ -n "$docs_public" ] && echo "DOCS_LANG_PUBLIC=$docs_public" >> "$d/.env"
    [ -n "$docs_private" ] && echo "DOCS_LANG_PRIVATE=$docs_private" >> "$d/.env"
    cygpath -m "$d" 2>/dev/null || echo "$d"
}

# run_gate <hook.js> <payload_json> <agents_config_dir> [cwd]
# Runs the PreToolUse hook with the payload on stdin from a neutral cwd (or the
# given fixture repo), with every shell-inherited policy key and session id
# removed so the fixture .env is the sole policy source.
# Sets GATE_STDOUT, GATE_RC, GATE_STDERR.
run_gate() {
    local hook="$1" payload="$2" cfg="$3" cwd="${4:-$NEUTRAL_CWD}"
    local errf="$TEST_ROOT/gate-stderr.txt"
    GATE_STDERR_FILE="$errf"
    GATE_STDOUT="$(
        cd "$cwd" || exit 97
        unset PLAN_LANG DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE
        unset DOCS_LANG_HISTORY_PUBLIC DOCS_LANG_HISTORY_PRIVATE
        unset DOCS_LANG_CHANGELOG_PUBLIC DOCS_LANG_CHANGELOG_PRIVATE
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export AGENTS_CONFIG_DIR="$cfg"
        printf '%s' "$payload" | run_with_timeout 20 node "$hook" 2>"$errf"
    )"
    GATE_RC=$?
    # One diagnostic line is enough to attribute a failure (e.g. Cannot find module).
    GATE_STDERR="$(grep -m1 -E 'Error|Cannot find' "$errf" 2>/dev/null || tail -n 1 "$errf" 2>/dev/null || true)"
}

# gate_reason — prints the block reason from GATE_STDOUT ("" when not a block).
gate_reason() {
    run_with_timeout 10 node -e '
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.decision === "block" && typeof o.reason === "string" ? o.reason : "");
} catch (e) { process.stdout.write(""); }
' "$GATE_STDOUT" 2>/dev/null
}

# assert_approve <label>
# stdout must be exactly {"decision":"approve"} (hence no additionalContext) and rc 0.
assert_approve() {
    local label="$1"
    if [ "$GATE_RC" -eq 0 ] && [ "$GATE_STDOUT" = '{"decision":"approve"}' ]; then
        pass "$label"
    else
        fail "$label — expected rc=0 stdout={\"decision\":\"approve\"}, got rc=$GATE_RC stdout='$GATE_STDOUT' stderr='$GATE_STDERR'"
    fi
}

# assert_block_prefix <label> <prefix>
# stdout must parse as a block whose reason starts with <prefix>; rc 0 (gate
# blocks via JSON decision, not via exit code).
assert_block_prefix() {
    local label="$1" prefix="$2" reason
    reason="$(gate_reason)"
    if [ "$GATE_RC" -eq 0 ] && [ -n "$reason" ] && [ "${reason#"$prefix"}" != "$reason" ]; then
        pass "$label"
    else
        fail "$label — expected block reason starting with '$prefix', got rc=$GATE_RC stdout='$GATE_STDOUT' stderr='$GATE_STDERR'"
    fi
}

# assert_reason_has <label> <substring>     — block reason contains substring
# assert_reason_lacks <label> <substring>   — block reason does not contain it
assert_reason_has() {
    local label="$1" needle="$2" reason
    reason="$(gate_reason)"
    if [ -n "$reason" ] && [ "${reason#*"$needle"}" != "$reason" ]; then
        pass "$label"
    else
        fail "$label — reason lacks '$needle': '$reason'"
    fi
}
assert_reason_lacks() {
    local label="$1" needle="$2" reason
    reason="$(gate_reason)"
    if [ -n "$reason" ] && [ "${reason#*"$needle"}" = "$reason" ]; then
        pass "$label"
    else
        fail "$label — reason unexpectedly contains '$needle' (or is not a block): '$reason'"
    fi
}

# Scope (approved plan, detail.md Files-to-modify items 4 and 6): the block reason echoes the
# VIOLATING line by design (`line N: <line>` / `[section:n] (expected policy) <line>`), so a secret
# inside a violating line WILL appear; this helper proves only compliant lines / the rest stay out.
# assert_not_leaked <label> <secret>
# Requires a block (non-empty reason — an absent/silent gate must not pass this);
# the secret must appear in neither stdout, the full stderr capture, nor the parsed
# block reason (the gate reports violating lines only, never the whole payload).
assert_not_leaked() {
    local label="$1" secret="$2" where="" reason
    reason="$(gate_reason)"
    if [ -z "$reason" ]; then
        fail "$label — no block reason to inspect (rc=$GATE_RC stdout='$GATE_STDOUT' stderr='$GATE_STDERR')"
        return
    fi
    printf '%s' "$GATE_STDOUT" | grep -qF -- "$secret" && where="$where stdout"
    grep -qF -- "$secret" "$GATE_STDERR_FILE" 2>/dev/null && where="$where stderr"
    printf '%s' "$reason" | grep -qF -- "$secret" && where="$where reason"
    if [ -z "$where" ]; then
        pass "$label"
    else
        fail "$label — secret '$secret' leaked into:$where"
    fi
}

# reason_count <substring> — number of occurrences of substring in the block reason.
reason_count() {
    run_with_timeout 10 node -e '
const reason = process.argv[1], needle = process.argv[2];
process.stdout.write(String(reason.split(needle).length - 1));
' "$(gate_reason)" "$1" 2>/dev/null
}

# mk_payload <tool_name> <file_path|-> <field|-> <content>
# tool_input = {file_path, <field>: content}; "-" omits that part.
mk_payload() {
    run_with_timeout 10 node -e '
const [tool, fp, field, content] = process.argv.slice(1);
const ti = {};
if (fp !== "-") ti.file_path = fp;
if (field !== "-") ti[field] = content;
process.stdout.write(JSON.stringify({ tool_name: tool, tool_input: ti }));
' "$1" "$2" "$3" "$4"
}

# mk_payload_pathkey <tool_name> <path_key> <path_value> <field> <content>
# Like mk_payload but the path key is chosen by the caller (`path` for editFiles).
mk_payload_pathkey() {
    run_with_timeout 10 node -e '
const [tool, key, val, field, content] = process.argv.slice(1);
const ti = {}; ti[key] = val; ti[field] = content;
process.stdout.write(JSON.stringify({ tool_name: tool, tool_input: ti }));
' "$1" "$2" "$3" "$4" "$5"
}

# mk_payload_big <tool_name> <file_path> <unit> <repeat>
# Write payload whose content is <unit> repeated <repeat> times, built inside node
# so a multi-hundred-KB fragment never travels through argv (Windows 32K limit).
mk_payload_big() {
    run_with_timeout 10 node -e '
const [tool, fp, unit, n] = process.argv.slice(1);
process.stdout.write(JSON.stringify({ tool_name: tool, tool_input: { file_path: fp, content: unit.repeat(Number(n)) } }));
' "$1" "$2" "$3" "$4"
}

# mk_payload_raw <tool_name> <tool_input JSON literal>
# {tool_name, tool_input: <literal>} — for malformed shapes (null, wrong types).
mk_payload_raw() {
    run_with_timeout 10 node -e '
const [tool, raw] = process.argv.slice(1);
process.stdout.write(JSON.stringify({ tool_name: tool, tool_input: JSON.parse(raw) }));
' "$1" "$2"
}

# mk_edit <tool_name> <file_path> <old_string> <new_string>
mk_edit() {
    run_with_timeout 10 node -e '
const [tool, fp, oldS, newS] = process.argv.slice(1);
process.stdout.write(JSON.stringify({ tool_name: tool, tool_input: { file_path: fp, old_string: oldS, new_string: newS } }));
' "$1" "$2" "$3" "$4"
}

# mk_edit_elem <path_key|-> <path_value> <old_string> <new_string|->
# One edits[] element. path_key "-" omits the path (inherits the top-level
# path); new_string "-" omits new_string (element must be dropped).
mk_edit_elem() {
    run_with_timeout 10 node -e '
const [key, val, oldS, newS] = process.argv.slice(1);
const e = {};
if (key !== "-") e[key] = val;
e.old_string = oldS;
if (newS !== "-") e.new_string = newS;
process.stdout.write(JSON.stringify(e));
' "$1" "$2" "$3" "$4"
}

# mk_multiedit <tool_name> <top_path|-> <edit_elem_json>...
# Assembles {tool_name, tool_input:{file_path: top, edits:[...]}} keeping the
# top-level path and the per-element paths separate.
mk_multiedit() {
    local tool="$1" top="$2"; shift 2
    run_with_timeout 10 node -e '
const [tool, top, ...elems] = process.argv.slice(1);
const ti = { edits: elems.map((s) => JSON.parse(s)) };
if (top !== "-") ti.file_path = top;
process.stdout.write(JSON.stringify({ tool_name: tool, tool_input: ti }));
' "$tool" "$top" "$@"
}

# make_fixture_repo <remote|"">
# git init fixture with hooks disabled; optional origin remote. Prints Node-form path.
make_fixture_repo() {
    local remote="$1" d
    d="$(mktemp -d "$TEST_ROOT/repo-XXXXXX")"
    git -C "$d" init -q
    git -C "$d" config core.hooksPath "$TEST_ROOT/no-such-hooks-dir"
    [ -n "$remote" ] && git -C "$d" remote add origin "$remote"
    cygpath -m "$d" 2>/dev/null || echo "$d"
}
