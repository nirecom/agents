# shellcheck shell=bash
# Tests: hooks/lib/instructions-loaded-receipt.js, hooks/instructions-loaded-audit.js
# Tags: rules-injection, instructions-loaded, rules-key, root-anchoring, table-driven, path-traversal, security, TL2, scope:common
#
# WHY (CPR-WPH): a rules file reaches the loader from five different roots, and only one
# of them yields a repo-relative path that begins with `rules/`. The earlier
# implementation recovered identity by TAIL MATCHING — "does a `rules/` segment appear
# anywhere in this path". That is not identity. It turns /home/v/.ssh/rules/id_rsa.md
# into the key `rules/id_rsa.md`, which (a) defeats the deliberate `out-of-root:<digest>`
# redaction that keeps unrelated absolute paths out of the receipt, and (b) hands an
# unrelated file to the policy comparison, which then reports a bogus error-severity
# S-MISSING about a file nobody registered.
#
# toRulesKey() is now ROOT-ANCHORED: it resolves the path and derives a key only when
# the result sits under one of the KNOWN rules roots, with segment-aware containment and
# win32 case folding. This group is the table-driven pin on that predicate
# (skills/_shared/test-design/parser-regex-tests.md), plus the end-to-end integration
# cases that prove the predicate is what the hook actually consumes.
#
# Assumes BASE, WFDIR, REPO, HOOK, RECEIPT_LIB, node_path(), fire(), read_field(),
# pass(), fail() from the dispatcher and helpers.sh.

echo ""
echo "=== rules-key root anchoring (table-driven) ==="

RR="$BASE/rr"
RR_P="$(node_path "$RR/proj")"        # CLAUDE_PROJECT_DIR
RR_A="$(node_path "$RR/agentscfg")"   # AGENTS_CONFIG_DIR
RR_C="$(node_path "$RR/cfg")"         # CLAUDE_CONFIG_DIR
RR_H="$(node_path "$RR/home")"        # HOME
mkdir -p "$RR/proj/rules" "$RR/proj/.claude/rules" "$RR/agentscfg/rules" \
         "$RR/cfg/rules" "$RR/home/.claude/rules"

RR_HELPER="$BASE/rr-key.js"
cat > "$RR_HELPER" <<'RR_HELPER_EOF'
"use strict";
// argv: <receipt-lib> <file-path> <env-json>. Prints the key, or EMPTY for "".
// The env object is passed EXPLICITLY (toRulesKey's second parameter) so the case
// table controls exactly which roots exist — an ambient var must never decide a row.
const { toRulesKey } = require(process.argv[2]);
let env;
try { env = JSON.parse(process.argv[4]); } catch (_) { env = {}; }
const key = toRulesKey(process.argv[3], env);
process.stdout.write(key === "" ? "EMPTY" : String(key));
RR_HELPER_EOF
RR_HELPER_NODE="$(node_path "$RR_HELPER")"
RR_LIB_NODE="$(node_path "$RECEIPT_LIB")"

# The three env shapes the table selects between. `json_env` builds them through node so
# Windows drive-letter paths survive JSON quoting untouched.
rr_env_json() { node -e 'const o={};for(let i=1;i<process.argv.length;i+=2){if(process.argv[i+1]!=="")o[process.argv[i]]=process.argv[i+1];}console.log(JSON.stringify(o));' "$@"; }
RR_ENV_ALL="$(rr_env_json CLAUDE_PROJECT_DIR "$RR_P" AGENTS_CONFIG_DIR "$RR_A" CLAUDE_CONFIG_DIR "$RR_C" HOME "$RR_H")"
RR_ENV_NOAGENTS="$(rr_env_json CLAUDE_PROJECT_DIR "$RR_P" CLAUDE_CONFIG_DIR "$RR_C" HOME "$RR_H")"
RR_ENV_NOPROJ="$(rr_env_json AGENTS_CONFIG_DIR "$RR_A" CLAUDE_CONFIG_DIR "$RR_C" HOME "$RR_H")"

# rr_key <env-token> <input-with-placeholders> -> the key, or EMPTY
rr_key() {
    local envtok="$1" p="$2" envjson
    case "$envtok" in
        all)       envjson="$RR_ENV_ALL" ;;
        no-agents) envjson="$RR_ENV_NOAGENTS" ;;
        no-proj)   envjson="$RR_ENV_NOPROJ" ;;
        *) printf 'BAD_ENV_TOKEN'; return ;;
    esac
    p="${p//@P@/$RR_P}"
    p="${p//@A@/$RR_A}"
    p="${p//@C@/$RR_C}"
    p="${p//@H@/$RR_H}"
    case "$p" in
        win:*) p="${p#win:}"; p="${p//\//\\}" ;;
    esac
    node "$RR_HELPER_NODE" "$RR_LIB_NODE" "$p" "$envjson" 2>&1
}

assert_key() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name (key=$got)"
    else
        fail "$name — want=$want got=$got"
    fi
}

# --- the table. name | env | input | want -------------------------------------------
# Accept rows cover all five recognized roots, nested subpaths, and the relative-path
# form. Reject rows cover every way a non-rules path could sneak a `rules/` segment past
# a tail match, plus the wrong-extension and unset-root cases.
while IFS='|' read -r rr_name rr_env rr_in rr_want; do
    rr_name="${rr_name//[[:space:]]/}"
    [ -z "$rr_name" ] && continue
    case "$rr_name" in \#*) continue ;; esac
    rr_env="${rr_env//[[:space:]]/}"
    rr_in="${rr_in//[[:space:]]/}"
    rr_want="${rr_want//[[:space:]]/}"
    assert_key "R-$rr_name" "$rr_want" "$(rr_key "$rr_env" "$rr_in")"
done <<'RR_TABLE'
# --- accept: the five recognized roots ---
root-project        | all | @P@/rules/test.md                        | rules/test.md
root-project-claude | all | @P@/.claude/rules/test.md                 | rules/test.md
root-agents-config  | all | @A@/rules/test.md                        | rules/test.md
root-claude-config  | all | @C@/rules/test.md                        | rules/test.md
root-home-claude    | all | @H@/.claude/rules/test.md                 | rules/test.md
# --- accept: nested subpaths keep their full tail ---
nested-test-sub     | all | @P@/rules/test/fixture-isolation.md       | rules/test/fixture-isolation.md
nested-coding-sub   | all | @A@/rules/coding/python.md                | rules/coding/python.md
nested-deep         | all | @H@/.claude/rules/a/b/c.md                | rules/a/b/c.md
# --- accept: a relative path resolves against CLAUDE_PROJECT_DIR ---
relative-under-proj | all | rules/docs.md                             | rules/docs.md
relative-nested     | all | rules/test/fixture-isolation.md           | rules/test/fixture-isolation.md
# --- reject: a `rules/` segment somewhere else is not identity (the M4 finding) ---
ssh-tail-match      | all | /home/v/.ssh/rules/id_rsa.md              | EMPTY
traversal-escape    | all | ../../secrets/rules/prod.md               | EMPTY
abs-outside-root    | all | /var/tmp/rules/anything.md                | EMPTY
# --- reject: adjacent-name root; the prefix test must be segment-aware ---
adjacent-rulesfoo   | all | @P@/rulesfoo/x.md                         | EMPTY
adjacent-rules-dash | all | @P@/rules-extra/x.md                      | EMPTY
adjacent-suffix-cfg | all | @A@/rulesbackup/x.md                      | EMPTY
# --- reject: wrong extension ---
wrong-ext-txt       | all | @P@/rules/notmd.txt                       | EMPTY
wrong-ext-none      | all | @P@/rules/notmd                           | EMPTY
wrong-ext-nested    | all | @A@/rules/coding/python.py                | EMPTY
# --- reject: the root itself is not a file ---
root-itself         | all | @P@/rules                                 | EMPTY
# --- reject: a root whose env var is UNSET drops out of the candidate list entirely
# rather than collapsing into a base that matches everything ---
unset-agents-root   | no-agents | @A@/rules/test.md                    | EMPTY
unset-proj-root     | no-proj   | @P@/rules/test.md                    | EMPTY
unset-proj-relative | no-proj   | rules/test.md                        | EMPTY
# --- reject: a `rules/` directory that is not AT a known root ---
rules-not-at-root   | all | @P@/docs/rules/x.md                       | EMPTY
nested-claude-rules | all | @P@/sub/.claude/rules/x.md                | EMPTY
RR_TABLE

# --- the empty-string input cannot travel through the table (the field would be blank),
# so it is asserted directly. ---
assert_key "R-empty-string" "EMPTY" "$(node "$RR_HELPER_NODE" "$RR_LIB_NODE" "" "$RR_ENV_ALL" 2>&1)"

# --- Windows separator forms of the same inputs. This repo runs on win32, where the
# loader can hand over either separator, so normalization must hold both ways. On a
# POSIX host a backslash is a legal filename character rather than a separator, so the
# rows are skipped rather than asserted wrongly (CPR-UNV: name the exception). ---
RR_PLATFORM="$(node -e 'process.stdout.write(process.platform)')"
if [ "$RR_PLATFORM" = "win32" ]; then
    while IFS='|' read -r rr_name rr_env rr_in rr_want; do
        rr_name="${rr_name//[[:space:]]/}"
        [ -z "$rr_name" ] && continue
        case "$rr_name" in \#*) continue ;; esac
        rr_env="${rr_env//[[:space:]]/}"
        rr_in="${rr_in//[[:space:]]/}"
        rr_want="${rr_want//[[:space:]]/}"
        assert_key "W-$rr_name" "$rr_want" "$(rr_key "$rr_env" "$rr_in")"
    done <<'RR_WIN_TABLE'
win-root-project    | all | win:@P@/rules/test.md                     | rules/test.md
win-root-dotclaude  | all | win:@P@/.claude/rules/test.md             | rules/test.md
win-root-agents     | all | win:@A@/rules/test.md                     | rules/test.md
win-root-home       | all | win:@H@/.claude/rules/test.md             | rules/test.md
win-nested          | all | win:@P@/rules/test/fixture-isolation.md   | rules/test/fixture-isolation.md
win-adjacent        | all | win:@P@/rulesfoo/x.md                     | EMPTY
win-wrong-ext       | all | win:@P@/rules/notmd.txt                   | EMPTY
win-unset-root      | no-agents | win:@A@/rules/test.md               | EMPTY
RR_WIN_TABLE
    # Case folding is a win32-only property of the comparison, asserted where it holds.
    assert_key "W-case-folded-root" "rules/test.md" "$(rr_key all "@P@/RULES/test.md")"
else
    echo "SKIP: W-*: Skipped-Because: backslash is a legal filename character on $RR_PLATFORM, so the Windows-separator rows assert nothing here"
fi

# --- C8: the predicate is what the HOOK consumes -----------------------------------
echo ""
echo "=== rules-key root anchoring: end-to-end through the hook ==="

# C8a (reject side): an out-of-root path that carries a `rules/` segment. The receipt
# must keep the out-of-root digest, and the file must never reach classify() — a
# readable `rules/id_rsa.md` key would have produced an error-severity verdict about a
# file that has nothing to do with this repo.
mkdir -p "$RR/outside/.ssh/rules"
RR_SSH="$RR/outside/.ssh/rules/id_rsa.md"
printf 'not a rule at all\n' > "$RR_SSH"
RR_SSH_NODE="$(node_path "$RR_SSH")"
RR_C8A_RC="$(fire c8aoutroot "$RR_SSH_NODE" OMIT)"
RR_C8A_FP="$(read_field c8aoutroot "$RR_SSH_NODE" file_path)"
RR_C8A_V="$(read_field c8aoutroot "$RR_SSH_NODE" verdict)"
if [ "${RR_C8A_RC%%|*}" != "0" ]; then
    fail "C8a: the hook must fail open on an out-of-root path, got rc=${RR_C8A_RC%%|*}"
elif [ "${RR_C8A_FP#out-of-root:}" = "$RR_C8A_FP" ]; then
    fail "C8a: an out-of-root path with a rules/ segment was recorded as '$RR_C8A_FP' — the tail match is back and the digest redaction is defeated"
elif printf '%s' "$RR_C8A_FP" | grep -qi 'id_rsa\|\.ssh'; then
    fail "C8a: the digest leaked the original path into the receipt — file_path='$RR_C8A_FP'"
elif [ "$RR_C8A_V" != "ok" ]; then
    fail "C8a: the out-of-root file reached classify() and produced verdict '$RR_C8A_V' — a bogus finding about a file this repo never registered"
else
    pass "C8a: an out-of-root path with a rules/ segment keeps the digest ($RR_C8A_FP) and is never classified"
fi

# C8b: the same shape one level up — `.ssh/rules/` nested under a directory whose name
# ends in `rules`, i.e. the adjacent-name reject exercised through the real hook.
mkdir -p "$RR/outside/rulesfoo"
RR_ADJ="$RR/outside/rulesfoo/x.md"
printf 'adjacent-name file\n' > "$RR_ADJ"
RR_ADJ_NODE="$(node_path "$RR_ADJ")"
fire c8badjacent "$RR_ADJ_NODE" OMIT >/dev/null
RR_C8B_FP="$(read_field c8badjacent "$RR_ADJ_NODE" file_path)"
RR_C8B_V="$(read_field c8badjacent "$RR_ADJ_NODE" verdict)"
if [ "${RR_C8B_FP#out-of-root:}" != "$RR_C8B_FP" ] && [ "$RR_C8B_V" = "ok" ]; then
    pass "C8b: an adjacent-name directory (rulesfoo/) is not a rules root through the hook either"
else
    fail "C8b: want an out-of-root digest with verdict ok, got file_path='$RR_C8B_FP' verdict='$RR_C8B_V'"
fi

# C8c (accept side, #1652): a rule loaded from <project>/.claude/rules/ has no
# `rules/`-prefixed repo-relative form, yet it MUST still classify. This is the very
# behaviour the root-anchored carve-out exists for; without it the de-injection audit
# goes blind on the root most rules actually load from.
mkdir -p "$REPO/.claude/rules"
RR_DOT="$REPO/.claude/rules/dotclaude-missing.md"
printf '# no paths: frontmatter and not in EXPECTED_UNCONDITIONAL\n' > "$RR_DOT"
RR_DOT_NODE="$(node_path "$RR_DOT")"
fire c8cdotclaude "$RR_DOT_NODE" OMIT >/dev/null
RR_C8C_V="$(read_field c8cdotclaude "$RR_DOT_NODE" verdict)"
if [ "$RR_C8C_V" = "S-MISSING" ]; then
    pass "C8c: a rule under <project>/.claude/rules/ is recognized and classified (S-MISSING)"
else
    fail "C8c: want verdict S-MISSING for <project>/.claude/rules/, got '$RR_C8C_V' — the .claude/rules root stopped being recognized"
fi

# C8d (accept side, #1652): the ~/.claude/rules/ root. HOME is overridden for this one
# firing only. Here the repo-relative form IS the out-of-root digest, so the receipt is
# expected to record the normalized rules key instead — the one class of file whose path
# is the finding.
RR_HOME_RULE="$RR/home/.claude/rules/homerule-missing.md"
printf '# no paths: frontmatter and not in EXPECTED_UNCONDITIONAL\n' > "$RR_HOME_RULE"
RR_HOME_NODE="$(node_path "$RR_HOME_RULE")"
rr_fire_home() {
    local sid="$1" fp="$2" payload rc=0
    payload="$(node -e 'console.log(JSON.stringify({session_id:process.argv[1],file_path:process.argv[2],hook_event_name:"InstructionsLoaded"}))' "$sid" "$fp")"
    printf '%s' "$payload" \
        | (cd "$BASE" && HOME="$RR_H" node "$(node_path "$HOOK")" >/dev/null 2>/dev/null) || rc=$?
    echo "$rc"
}
RR_C8D_RC="$(rr_fire_home c8dhomerules "$RR_HOME_NODE")"
RR_C8D_V="$(read_field c8dhomerules "$RR_HOME_NODE" verdict)"
RR_C8D_FP="$(read_field c8dhomerules "$RR_HOME_NODE" file_path)"
if [ "$RR_C8D_RC" != "0" ]; then
    fail "C8d: the hook must exit 0, got rc=$RR_C8D_RC"
elif [ "$RR_C8D_V" != "S-MISSING" ]; then
    fail "C8d: want verdict S-MISSING for \$HOME/.claude/rules/, got '$RR_C8D_V' — the home rules root stopped being recognized"
elif [ "$RR_C8D_FP" != "rules/homerule-missing.md" ]; then
    fail "C8d: want the normalized key 'rules/homerule-missing.md' recorded in place of the digest, got '$RR_C8D_FP'"
else
    pass "C8d: a rule under \$HOME/.claude/rules/ classifies and records the normalized key (rules/homerule-missing.md)"
fi

# C8e: the reject side must not be an artefact of the file being unreadable. The
# out-of-root file in C8a exists and is readable, and a file that IS under a known root
# with the identical basename classifies — so C8a's `ok` came from the root check, not
# from an incidental read failure.
RR_TWIN="$REPO/.claude/rules/id_rsa.md"
printf '# same basename, but genuinely under a rules root\n' > "$RR_TWIN"
RR_TWIN_NODE="$(node_path "$RR_TWIN")"
fire c8etwin "$RR_TWIN_NODE" OMIT >/dev/null
RR_C8E_V="$(read_field c8etwin "$RR_TWIN_NODE" verdict)"
if [ -r "$RR_SSH" ] && [ "$RR_C8E_V" = "S-MISSING" ]; then
    pass "C8e: the same basename under a real rules root does classify (S-MISSING) — C8a's 'ok' is the root check, not an unreadable file"
else
    fail "C8e: want the in-root twin to classify S-MISSING (readable=$([ -r "$RR_SSH" ] && echo yes || echo no)), got '$RR_C8E_V'"
fi

# --- C9: the symlink / junction half of containment. In a sibling file because this one
# sits at the 300-line WARN (rules/coding/file-split.md Pattern A); sourced from here so
# $RR and the fixtures above stay in scope. ---
RR_SYMCASES="$(dirname "${BASH_SOURCE[0]}")/cases-rulesroot-symlink.sh"
if [ -f "$RR_SYMCASES" ]; then
    # shellcheck source=./cases-rulesroot-symlink.sh
    . "$RR_SYMCASES"
else
    fail "IMPLEMENTATION MISSING: $RR_SYMCASES (symlink / junction traversal cases)"
fi
