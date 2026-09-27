# tests/feature-2134-bash-guard/cases-allow-self-script.sh
# Tests: hooks/bash-guard/allow.js, hooks/bash-guard/judge.js, hooks/lib/allow-command-list.js, hooks/lib/path-normalize.js, install/settings-allow-commands.txt, install/path-exposed-commands.txt
# Tags: hook, bash-guard, allow, self-script, cwd, path-normalize, scope:issue-specific, pwsh-not-required, TL2
# W1-W2: the self-script allow path (#2265). Sourced by the dispatcher.

# WHY THIS REPLACES THE GENERATED SPELLINGS. settings.json used to carry ~30 generated
# `Bash(...)` spellings per list entry; bash-guard now reads the two SSOT lists and answers
# permissionDecision "allow" itself. allow skips the prompt, so every negative below is a
# prompt that must survive: wrong interpreter, `..`, a separator, a redirect, an unverified cwd.

# W1 runs matchSelfScript() against a FIXTURE agents root (BG_PROBE_AGENTS_ROOT), so the rows
# never depend on what the real lists happen to contain. W2 is the real-list smoke at judge level.
FX_ROOT="$TMPROOT/fixture-agents"
mkdir -p "$FX_ROOT/install" "$FX_ROOT/bin/tool"
printf '%s\n' '# fixture allow list' 'bin/fx-bash' 'bin/fx-node.js' 'bin/tool/fx-sub' 'bin/fx-bare' \
    > "$FX_ROOT/install/settings-allow-commands.txt"
printf '%s\n' '# fixture PATH list' 'fx-bare' 'fx-unlisted' > "$FX_ROOT/install/path-exposed-commands.txt"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FX_ROOT/bin/fx-bash"
printf '%s\n' '#!/usr/bin/env node' '0;' > "$FX_ROOT/bin/fx-node.js"
printf '%s\n' '#!/bin/bash' 'true' > "$FX_ROOT/bin/tool/fx-sub"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FX_ROOT/bin/fx-bare"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FX_ROOT/bin/fx-unlisted"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FX_ROOT/bin/fx-notlisted"

# Root spellings: M = forward-slash native, MSYS = /c/..., WIN = backslash. MSYS and WIN exist
# only on a drive-letter host; elsewhere those rows are skipped but still counted.
bg_root_forms() {
    local m="$1" drive rest
    BG_M="$m"; BG_MSYS=""; BG_WIN=""
    case "$m" in
        [A-Za-z]:/*) drive="${m%%:*}"; rest="${m#*:}"
                     BG_MSYS="/$(printf '%s' "$drive" | tr 'A-Z' 'a-z')$rest"; BG_WIN="${m//\//\\}" ;;
    esac
}
bg_root_forms "$(node_path "$FX_ROOT")"
FX_M="$BG_M"; FX_MSYS="$BG_MSYS"; FX_WIN="$BG_WIN"
bg_root_forms "$(node_path "$AGENTS_DIR")"
RL_M="$BG_M"; RL_MSYS="$BG_MSYS"; RL_WIN="$BG_WIN"

# bg_subst <text> <M> <MSYS> <WIN> -> text with @ROOT@ / @MSYS@ / @WIN@ replaced.
bg_subst() {
    local s="$1"
    s="${s//@ROOT@/$2}"; s="${s//@MSYS@/$3}"; s="${s//@WIN@/$4}"
    printf '%s' "$s"
}

# bg_cwd_json <token> <M> <MSYS> -> the JSON value for a cwd column; "" means "leave unset".
bg_cwd_json() {
    case "$1" in
        -) printf '' ;;
        ROOT) printf '"%s"' "$2" ;;
        MSYS) printf '"%s"' "$3" ;;
        OTHER) printf '"%s"' "$(node_path "$TMPROOT")" ;;
        *) printf '%s' "$1" ;;
    esac
}

bg_needs_drive() { case "$1" in *@MSYS@*|*@WIN@*|MSYS) return 0 ;; esac; return 1; }

w1_fixture_rows() {
    local name cmd cwd want got cwd_json
    while IFS='~' read -r name cmd cwd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        cwd="${cwd//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))
        if { bg_needs_drive "$cmd" || bg_needs_drive "$cwd"; } && [ -z "$FX_MSYS" ]; then
            skip "W1/$name: drive-letter spelling not applicable on this host"; continue
        fi
        cmd="$(bg_subst "$cmd" "$FX_M" "$FX_MSYS" "$FX_WIN")"
        cwd_json="$(bg_cwd_json "$cwd" "$FX_M" "$FX_MSYS")"
        got="$(BG_PROBE_AGENTS_ROOT="$FX_M" BG_PROBE_CTX_CWD_JSON="$cwd_json" probe self-script "$cmd")"
        assert_eq "W1/$name: matchSelfScript" "$want" "$got"
    done <<'TABLE'
# --- positives ---
env-form        ~ bash "$AGENTS_CONFIG_DIR/bin/fx-bash" --x          ~ -     ~ BG-ALLOW-SELF-SCRIPT
env-braced      ~ bash "${AGENTS_CONFIG_DIR}/bin/fx-bash"            ~ -     ~ BG-ALLOW-SELF-SCRIPT
node-entry      ~ node "$AGENTS_CONFIG_DIR/bin/fx-node.js" a b       ~ -     ~ BG-ALLOW-SELF-SCRIPT
subdir-bin-bash ~ bash "$AGENTS_CONFIG_DIR/bin/tool/fx-sub"          ~ -     ~ BG-ALLOW-SELF-SCRIPT
bash-exe        ~ bash.exe "$AGENTS_CONFIG_DIR/bin/fx-bash"          ~ -     ~ BG-ALLOW-SELF-SCRIPT
abs-interp      ~ /usr/bin/bash "$AGENTS_CONFIG_DIR/bin/fx-bash"     ~ -     ~ BG-ALLOW-SELF-SCRIPT
abs-root        ~ bash "@ROOT@/bin/fx-bash"                          ~ -     ~ BG-ALLOW-SELF-SCRIPT
win-root        ~ bash "@WIN@\bin\fx-bash"                           ~ -     ~ BG-ALLOW-SELF-SCRIPT
msys-root       ~ bash "@MSYS@/bin/fx-bash"                          ~ -     ~ BG-ALLOW-SELF-SCRIPT
rel-at-root     ~ bash bin/fx-bash                                   ~ ROOT  ~ BG-ALLOW-SELF-SCRIPT
abs-bad-cwd     ~ bash "@ROOT@/bin/fx-bash"                          ~ OTHER ~ BG-ALLOW-SELF-SCRIPT
bare-exposed    ~ fx-bare --x                                        ~ -     ~ BG-ALLOW-SELF-BARE
# --- negatives: each one is a permission prompt that must survive ---
interp-mismatch ~ node "$AGENTS_CONFIG_DIR/bin/fx-bash"              ~ -     ~ null
interp-mismatch2 ~ bash "$AGENTS_CONFIG_DIR/bin/fx-node.js"          ~ -     ~ null
other-interp    ~ sh "$AGENTS_CONFIG_DIR/bin/fx-bash"                ~ -     ~ null
dotdot          ~ bash "$AGENTS_CONFIG_DIR/bin/../bin/fx-bash"       ~ -     ~ null
rel-other-cwd   ~ bash bin/fx-bash                                   ~ OTHER ~ null
rel-no-cwd      ~ bash bin/fx-bash                                   ~ -     ~ null
or-suffix       ~ bash "$AGENTS_CONFIG_DIR/bin/fx-bash" || true      ~ -     ~ null
bg-suffix       ~ bash "$AGENTS_CONFIG_DIR/bin/fx-bash" &            ~ -     ~ null
redirect-in     ~ bash "$AGENTS_CONFIG_DIR/bin/fx-bash" < in.txt     ~ -     ~ null
not-listed      ~ bash "$AGENTS_CONFIG_DIR/bin/fx-notlisted"         ~ -     ~ null
bare-unexposed  ~ fx-bash                                            ~ -     ~ null
bare-unlisted   ~ fx-unlisted                                        ~ -     ~ null
bash-c-wrapper  ~ bash -c 'bash "$AGENTS_CONFIG_DIR/bin/fx-bash"'    ~ -     ~ null
exec-position   ~ "$AGENTS_CONFIG_DIR/bin/fx-bash"                   ~ -     ~ null
root-lookalike  ~ bash "@ROOT@-evil/bin/fx-bash"                     ~ -     ~ null
TABLE
}

case_begin "self-script-fixture-root" "hooks/bash-guard/allow.js"
w1_fixture_rows
case_end

# root-lookalike: the root must be stripped on a path BOUNDARY, or `<root>-evil/bin/x` would
# normalize to an entry. abs-bad-cwd: an absolute or $AGENTS_CONFIG_DIR form never reads cwd.

w2_real_rows() {
    local name cmd tcwd icwd want got tj ij
    while IFS='~' read -r name cmd tcwd icwd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"; tcwd="$(mkcmd "$tcwd")"; icwd="$(mkcmd "$icwd")"
        ROWS=$((ROWS + 1))
        if { bg_needs_drive "$cmd" || bg_needs_drive "$tcwd" || bg_needs_drive "$icwd"; } && [ -z "$RL_MSYS" ]; then
            skip "W2/$name: drive-letter spelling not applicable on this host"; continue
        fi
        cmd="$(bg_subst "$cmd" "$RL_M" "$RL_MSYS" "$RL_WIN")"
        tj="$(bg_cwd_json "$tcwd" "$RL_M" "$RL_MSYS")"; ij="$(bg_cwd_json "$icwd" "$RL_M" "$RL_MSYS")"
        got="$(BG_PROBE_TOOL_CWD_JSON="$tj" BG_PROBE_INPUT_CWD_JSON="$ij" verdict_code_of "$cmd")"
        assert_eq "W2/$name: verdict|code" "$want" "$got"
    done <<'TABLE'
node-next-step     ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list ~ -       ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
bash-confirm-off   ~ bash "$AGENTS_CONFIG_DIR/bin/confirm-off" RUN_TL4 on    ~ -       ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
bare-path-exposed  ~ review-code-codex --help                                ~ -       ~ -    ~ allow|BG-ALLOW-SELF-BARE
real-mismatch      ~ bash "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list ~ -       ~ -    ~ passThrough|BG-NO-HIT
rel-tool-cwd       ~ node bin/workflow/next-step --list                      ~ ROOT    ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
rel-input-cwd      ~ node bin/workflow/next-step --list                      ~ -       ~ ROOT ~ allow|BG-ALLOW-SELF-SCRIPT
rel-msys-cwd       ~ node bin/workflow/next-step --list                      ~ MSYS    ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
rel-blank-tool-cwd ~ node bin/workflow/next-step --list                      ~ "   "   ~ ROOT ~ allow|BG-ALLOW-SELF-SCRIPT
rel-tool-cwd-wins  ~ node bin/workflow/next-step --list                      ~ OTHER   ~ ROOT ~ passThrough|BG-NO-HIT
rel-no-cwd         ~ node bin/workflow/next-step --list                      ~ -       ~ -    ~ passThrough|BG-NO-HIT
rel-numeric-cwd    ~ node bin/workflow/next-step --list                      ~ 42      ~ -    ~ passThrough|BG-NO-HIT
rel-object-cwd     ~ node bin/workflow/next-step --list                      ~ {"p":"x"} ~ -  ~ passThrough|BG-NO-HIT
rel-relative-cwd   ~ node bin/workflow/next-step --list                      ~ "bin"   ~ -    ~ passThrough|BG-NO-HIT
env-bad-cwd        ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list ~ 42      ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
abs-bad-cwd        ~ node "@ROOT@/bin/workflow/next-step" --list             ~ "bin"   ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
TABLE
}

# rel-blank-tool-cwd: a whitespace-only tool_input.cwd is skipped, so input.cwd is used.
# rel-tool-cwd-wins: tool_input.cwd is read first; a valid non-root value is not overridden.
# Non-string, relative or absent cwd never resolves a relative form (no process.cwd() guess).
case_begin "self-script-real-lists" "hooks/bash-guard/judge.js"
w2_real_rows
case_end
