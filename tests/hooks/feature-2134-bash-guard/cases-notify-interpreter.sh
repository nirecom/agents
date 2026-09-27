# tests/feature-2134-bash-guard/cases-notify-interpreter.sh
# Tests: hooks/bash-guard/detect.js, hooks/bash-guard/judge.js, hooks/lib/allow-command-list.js, install/settings-allow-commands.txt
# Tags: hook, bash-guard, notify, calling-convention, cwd, scope:issue-specific, pwsh-not-required, TL2
# L1-L2: the L3 notify class -- a script executed by path with no interpreter. Sourced by the dispatcher.

# WHY (#2262 / #2264). The calling convention is `bash <path>` / `node <path>`: the argument
# position is what the self-script allow matches, so an exec-position script is never allowed
# and prompts every time. A path-shaped cmd0 with a script extension, or one that resolves to
# an allow-list entry, gets a one-line notify pointing at the argument-position form.

l1_interpreter_rows() {
    local name cmd want got
    while IFS='~' read -r name cmd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(verdict_code_of "$cmd")"
        assert_eq "L1/$name: verdict|code" "$want" "$got"
    done <<'TABLE'
# --- positives: a separator in cmd0 AND (a script extension OR an allow-list entry) ---
agents-config-exec ~ "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
braced-config-exec ~ "${AGENTS_CONFIG_DIR}/bin/confirm-off" RUN_TL4 on  ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
dot-slash-sh       ~ ./x.sh                                            ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
win-abs-js         ~ C:/tmp/bin/foo.js --flag                          ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
posix-abs-mjs      ~ /opt/tools/run.mjs                                ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
backslash-cjs      ~ .\\tools\\run.cjs                                 ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
# --- negatives ---
bash-arg-position  ~ bash ./x.sh                                       ~ passThrough|BG-NO-HIT
node-arg-position  ~ node bin/x.js                                     ~ passThrough|BG-NO-HIT
bare-name          ~ mytool --x                                        ~ passThrough|BG-NO-HIT
bare-with-ext      ~ x.sh                                              ~ passThrough|BG-NO-HIT
no-ext-user-script ~ ./gradlew build                                   ~ passThrough|BG-NO-HIT
rel-noext-no-cwd   ~ bin/workflow/next-step --list                     ~ passThrough|BG-NO-HIT
TABLE
}

# rel-noext-no-cwd: an extension-less relative path matches an allow-list entry only through
# a verified cwd; with none in the payload bash-guard must not guess from process.cwd().
case_begin "notify-interpreter-shapes" "hooks/bash-guard/detect.js"
l1_interpreter_rows
case_end

# L2: the same relative form WITH a cwd. It resolves to an entry only when the cwd is the
# agents root -- another repo's `bin/workflow/next-step` is not ours to comment on.
BG_AGENTS_CWD_JSON="\"$(node_path "$AGENTS_DIR")\""
BG_OTHER_CWD_JSON="\"$(node_path "$TMPROOT")\""
case_begin "notify-interpreter-cwd" "hooks/lib/allow-command-list.js"
ROWS=$((ROWS + 1))
assert_eq "L2a: rel no-ext form with tool_input.cwd = agents root is an L3 notify" \
    "notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER" \
    "$(BG_PROBE_TOOL_CWD_JSON="$BG_AGENTS_CWD_JSON" verdict_code_of 'bin/workflow/next-step --list')"
ROWS=$((ROWS + 1))
assert_eq "L2b: rel no-ext form with a cwd outside the agents root passes through" \
    "passThrough|BG-NO-HIT" \
    "$(BG_PROBE_TOOL_CWD_JSON="$BG_OTHER_CWD_JSON" verdict_code_of 'bin/workflow/next-step --list')"
ROWS=$((ROWS + 1))
assert_eq "L2c: rel no-ext form that is NOT an allow-list entry passes through even at the root" \
    "passThrough|BG-NO-HIT" \
    "$(BG_PROBE_TOOL_CWD_JSON="$BG_AGENTS_CWD_JSON" verdict_code_of 'bin/not-a-listed-entry --x')"
case_end
