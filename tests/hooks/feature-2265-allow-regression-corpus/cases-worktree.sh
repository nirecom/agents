#!/usr/bin/env bash
# Tests: hooks/bash-guard/allow.js, hooks/bash-guard/detect.js, hooks/lib/allow-command-list.js
# Tags: hook, bash-guard, self-script-allow, worktree, scope:issue-specific, pwsh-not-required, TL2
# Sourced by tests/hooks/feature-2265-allow-regression-corpus.sh (fixture already built).
# The corpus's MAIN and WT hold identical files, so it cannot tell "resolved the worktree" from
# "silently read MAIN". Here fx-wt-only exists only in the WT list, and fx-diverge is bash in
# MAIN but node in WT: every WT row's expected verdict differs from the MAIN-based answer.
# MAIN rows run first in the same process, so a cache keyed on the main root also shows up.

WT_TABLE="$FX_TMP/worktree-table.txt"
cat > "$WT_TABLE" <<'ROWS'
main-wt-only-rel      ~ bash bin/fx-wt-only                                ~ MAIN ~ passThrough|BG-NO-HIT
main-diverge-bash     ~ bash "@MAIN@/bin/fx-diverge"                       ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
main-diverge-node     ~ node "@MAIN@/bin/fx-diverge"                       ~ -    ~ passThrough|BG-NO-HIT
wt-only-rel           ~ bash bin/fx-wt-only                                ~ WT   ~ allow|BG-ALLOW-SELF-SCRIPT
wt-only-abs           ~ bash "@WT@/bin/fx-wt-only"                         ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
wt-only-bashc-cd      ~ bash -c 'cd "@WT@" && bash bin/fx-wt-only'         ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
wt-diverge-node-rel   ~ node bin/fx-diverge                                ~ WT   ~ allow|BG-ALLOW-SELF-SCRIPT
wt-diverge-node-abs   ~ node "@WT@/bin/fx-diverge"                         ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
wt-diverge-bash-rel   ~ bash bin/fx-diverge                                ~ WT   ~ passThrough|BG-NO-HIT
wt-diverge-bash-abs   ~ bash "@WT@/bin/fx-diverge"                         ~ -    ~ passThrough|BG-NO-HIT
wt-diverge-bashc-cd   ~ bash -c 'cd "@WT@" && node bin/fx-diverge'         ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
neg-wt-subdir-rel     ~ bash ../bin/fx-wt-only                             ~ @WT@/install ~ passThrough|BG-NO-HIT
neg-foreign-rel       ~ bash bin/fx-wt-only                                ~ FOREIGN ~ passThrough|BG-NO-HIT
neg-foreign-abs       ~ bash "@FOREIGN@/bin/fx-wt-only"                    ~ -    ~ passThrough|BG-NO-HIT
neg-foreign-abs-ssot  ~ node "@FOREIGN@/bin/workflow/next-step"            ~ -    ~ passThrough|BG-NO-HIT
neg-plain-abs         ~ node "@PLAIN@/bin/workflow/next-step"              ~ -    ~ passThrough|BG-NO-HIT
neg-plain-rel         ~ node bin/workflow/next-step                        ~ PLAIN ~ passThrough|BG-NO-HIT
neg-fakewt-abs        ~ bash "@FAKEWT@/bin/fx-wt-only"                     ~ -    ~ passThrough|BG-NO-HIT
neg-fakewt-rel        ~ node bin/workflow/next-step                        ~ FAKEWT ~ passThrough|BG-NO-HIT
neg-env-form-wt-cwd   ~ bash "$AGENTS_CONFIG_DIR/bin/fx-wt-only"           ~ WT   ~ passThrough|BG-NO-HIT
notify-wt-abs-exec    ~ "@WT@/bin/workflow/next-step"                      ~ -    ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
notify-wt-rel-exec    ~ bin/workflow/next-step                             ~ WT   ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
notify-wt-only-exec   ~ "@WT@/bin/fx-wt-only"                              ~ -    ~ notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER
notify-foreign-exec   ~ "@FOREIGN@/bin/fx-wt-only"                         ~ -    ~ passThrough|BG-NO-HIT
ROWS
WT_TABLE_ROWS=24
WT_OUT="$(fx_run --table "$WT_TABLE")"
printf '%s\n' "$WT_OUT"

# wt_rows <id...>: each named table row ran and matched.
wt_rows() {
  local id r
  for id in "$@"; do
    r="$(fx_row "$WT_OUT" "$id")"
    if [[ "${r%% *}" == "PASS" ]]; then pass "worktree[$id]"; else fail "worktree[$id]" "$r"; fi
  done
}

case_begin "worktree-table-complete" "hooks/bash-guard/judge.js"
fx_check "worktree: every table row ran" "$WT_TABLE_ROWS" "$(fx_field "$WT_OUT" "RESULT " rows)"
fx_check "worktree: no row skipped" "0" "$(fx_field "$WT_OUT" "RESULT " skip)"
case_end

case_begin "worktree-main-controls" "hooks/lib/allow-command-list.js"
wt_rows main-wt-only-rel main-diverge-bash main-diverge-node
case_end

case_begin "worktree-list-and-shebang-follow-the-checkout" "hooks/lib/allow-command-list.js"
# The SSOT match and the shebang read both use the resolved worktree, not the main root.
wt_rows wt-only-rel wt-only-abs wt-diverge-node-rel wt-diverge-node-abs wt-diverge-bash-rel wt-diverge-bash-abs
case_end

case_begin "worktree-bash-c-cd-into-worktree" "hooks/bash-guard/allow.js"
wt_rows wt-only-bashc-cd wt-diverge-bashc-cd
case_end

case_begin "worktree-resolution-negatives" "hooks/lib/allow-command-list.js"
# A worktree subdirectory cwd, a foreign repo, a plain copy, a worktree of a foreign repo, and
# the $AGENTS_CONFIG_DIR form (always the main root, whatever the cwd) all stay passThrough.
wt_rows neg-wt-subdir-rel neg-foreign-rel neg-foreign-abs neg-foreign-abs-ssot neg-plain-abs \
  neg-plain-rel neg-fakewt-abs neg-fakewt-rel neg-env-form-wt-cwd
case_end

case_begin "worktree-exec-position-notify" "hooks/bash-guard/detect.js"
# L3 notify shares the resolver, so an exec-position worktree script is notified too.
wt_rows notify-wt-abs-exec notify-wt-rel-exec notify-wt-only-exec notify-foreign-exec
case_end
