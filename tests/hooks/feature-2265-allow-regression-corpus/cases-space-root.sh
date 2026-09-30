#!/usr/bin/env bash
# Tests: hooks/bash-guard/allow.js, hooks/bash-guard/judge.js, hooks/lib/allow-command-list.js
# Tags: hook, bash-guard, self-script-allow, worktree, spaces, scope:issue-specific, pwsh-not-required, TL2
# Sourced by tests/hooks/feature-2265-allow-regression-corpus.sh (fx_layout/fx_commit defined).
# A checkout whose path contains spaces: quoted absolute and `bash -c 'cd "<root>" && ...'`
# spellings must resolve it (main and linked worktree), while a same-prefix lookalike, a plain
# spaced directory, and an unquoted (word-split) spelling must keep the prompt.

SP_DIR="$FX_BASE/space fixture"
SP_MAIN="$SP_DIR/agents main"
SP_WT="$SP_DIR/agents wt"
SP_EVIL="$SP_DIR/agents main-evil"
SP_PLAIN="$SP_DIR/plain dir"
harness_git_init "$SP_MAIN"
fx_layout "$SP_MAIN"
fx_commit "$SP_MAIN"
# Explicit branch: the default one derived from "agents wt" contains a space and is rejected.
git -C "$SP_MAIN" worktree add -q -b sp-wt "$SP_WT" 2>/dev/null
fx_layout "$SP_EVIL"
fx_layout "$SP_PLAIN"

SP_TABLE="$FX_TMP/space-table.txt"
cat > "$SP_TABLE" <<'ROWS'
sp-abs-q-node       ~ node "@MAIN@/bin/workflow/next-step" --list                         ~ -     ~ allow|BG-ALLOW-SELF-SCRIPT
sp-abs-q-bash       ~ bash "@MAIN@/bin/confirm-off" X on                                   ~ -     ~ allow|BG-ALLOW-SELF-SCRIPT
sp-rel-cwd          ~ node bin/workflow/next-step --list                                   ~ MAIN  ~ allow|BG-ALLOW-SELF-SCRIPT
sp-bashc-cd-rel     ~ bash -c 'cd "@MAIN@" && node bin/workflow/next-step --list'          ~ -     ~ allow|BG-ALLOW-SELF-SCRIPT
sp-bashc-cd-abs     ~ bash -c 'cd "@MAIN@" && bash "@MAIN@/bin/confirm-off" X on'           ~ -     ~ allow|BG-ALLOW-SELF-SCRIPT
sp-wt-abs-q         ~ node "@WT@/bin/workflow/next-step" --list                           ~ -     ~ allow|BG-ALLOW-SELF-SCRIPT
sp-wt-bashc-cd      ~ bash -c 'cd "@WT@" && node bin/workflow/next-step --list'            ~ -     ~ allow|BG-ALLOW-SELF-SCRIPT
neg-sp-unquoted     ~ node @MAIN@/bin/workflow/next-step --list                           ~ -     ~ passThrough|BG-NO-HIT
neg-sp-lookalike    ~ node "@FOREIGN@/bin/workflow/next-step" --list                      ~ -     ~ passThrough|BG-NO-HIT
neg-sp-lookalike-cd ~ bash -c 'cd "@FOREIGN@" && node bin/workflow/next-step --list'       ~ -     ~ passThrough|BG-NO-HIT
neg-sp-plain-abs    ~ node "@PLAIN@/bin/workflow/next-step" --list                        ~ -     ~ passThrough|BG-NO-HIT
neg-sp-plain-cd     ~ bash -c 'cd "@PLAIN@" && node bin/workflow/next-step --list'         ~ -     ~ passThrough|BG-NO-HIT
neg-sp-plain-rel    ~ node bin/workflow/next-step --list                                   ~ PLAIN ~ passThrough|BG-NO-HIT
ROWS
SP_ROWS="sp-abs-q-node sp-abs-q-bash sp-rel-cwd sp-bashc-cd-rel sp-bashc-cd-abs sp-wt-abs-q sp-wt-bashc-cd"
SP_NEG_ROWS="neg-sp-unquoted neg-sp-lookalike neg-sp-lookalike-cd neg-sp-plain-abs neg-sp-plain-cd neg-sp-plain-rel"

# @FOREIGN@ is the same-prefix lookalike here; the judge's root is the spaced main checkout.
SP_OUT="$(run_with_timeout 300 node "$(np "$PART_DIR/run-corpus.js")" --table "$(np "$SP_TABLE")" \
  --main "$(np "$SP_MAIN")" --wt "$(np "$SP_WT")" --foreign "$(np "$SP_EVIL")" \
  --plain "$(np "$SP_PLAIN")" --session "$FX_SESSION")"

sp_rows() {
  local id got
  for id in "$@"; do
    got="$(fx_row "$SP_OUT" "$id")"
    fx_check "space-root[$id] — $got" "PASS" "${got%% *}"
  done
}

case_begin "space-root-table-complete" "hooks/bash-guard/judge.js"
fx_check "space-root: every table row ran" "13" "$(grep -c '^ROW ' <<< "$SP_OUT")"
fx_check "space-root: no row skipped" "0" "$(fx_field "$SP_OUT" "RESULT " skip)"
case_end

case_begin "space-root-quoted-spellings-allow" "hooks/bash-guard/allow.js"
sp_rows $SP_ROWS
case_end

case_begin "space-root-lookalikes-keep-prompt" "hooks/bash-guard/allow.js"
sp_rows $SP_NEG_ROWS
case_end
