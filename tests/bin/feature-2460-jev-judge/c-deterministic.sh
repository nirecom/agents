#!/usr/bin/env bash
# Tests: hooks/workflow-state/complexity-routing/deterministic-signals.js
# Tags: TL1, bin, jev, two-stage, deterministic-signals, path-normalization, windows-paths, repo-escape, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# the write-code list (WCD-2) is the only input of S1b and S4. Paths normalize to repo-relative
# '/' form, duplicates count once, and any path outside the repo makes the list invalid.

echo "=== deterministic-signals: write-code list parsing and S1b/S4 ==="
need_mod hooks/workflow-state/complexity-routing/deterministic-signals.js || return 0

DR="$TMPROOT/det-repo"
mkdir -p "$DR/install" "$DR/src"
DRN="$(np "$DR")"
IS_WIN=0
command -v cygpath >/dev/null 2>&1 && IS_WIN=1
DLIST="$TMPROOT/det-list.txt"
# dlist <line...>: write the list file, one line per argument.
dlist() { printf '%s\n' "$@" > "$DLIST"; }
dparse() { pb det-parse "$(np "$DLIST")" "$DRN"; }
dcompute() { pb det-compute "$(np "$DLIST")" "$DRN"; }

case_begin "det-constants" "hooks/workflow-state/complexity-routing/deterministic-signals.js"
check "S1B_FILE_THRESHOLD 8, list file name, S4_PATH_RULES exported" \
  '{"threshold":8,"name":"write-code-files.txt","rules":true}' "$(pb det-consts)"
case_end

case_begin "det-normalize-path" "hooks/workflow-state/complexity-routing/deterministic-signals.js"
check "relative path kept" "install/x.sh" "$(pb det-norm 'install/x.sh' "$DRN")"
check "absolute path under the repo becomes repo-relative" "install/x.sh" "$(pb det-norm "$DRN/install/x.sh" "$DRN")"
check "backslash separators become /" "install/x.sh" "$(pb det-norm 'install\x.sh' "$DRN")"
check "surrounding whitespace trimmed" "install/x.sh" "$(pb det-norm '   install/x.sh  ' "$DRN")"
check "repo-relative ../ escape is null" "null" "$(pb det-norm '../x.sh' "$DRN")"
check "absolute path climbing out of the repo is null" "null" "$(pb det-norm "$DRN/../other/x.sh" "$DRN")"
if [ "$IS_WIN" -eq 1 ]; then
  check "win32: backslash absolute path under the repo" "install/x.sh" \
    "$(pb det-norm "$(cygpath -w "$DR")\\install\\x.sh" "$DRN")"
  check "win32: Git Bash /c/... absolute path under the repo" "install/x.sh" \
    "$(pb det-norm "$(cygpath -u "$DR")/install/x.sh" "$DRN")"
  check "win32: an absolute path on another drive is null" "null" "$(pb det-norm 'Q:/elsewhere/x.sh' "$DRN")"
else
  skip "win32-only path forms (backslash absolute, /c/..., other drive)"
fi
case_end

case_begin "det-parse-status" "hooks/workflow-state/complexity-routing/deterministic-signals.js"
dlist "install/x.sh" "src/a.js"
check "ok list: paths normalized" '{"status":"ok","paths":["install/x.sh","src/a.js"]}' "$(dparse)"
check "no source bytes: missing" '{"status":"missing","paths":[]}' "$(pb det-parse - "$DRN")"
printf '\n  \n' > "$DLIST"
check "only blank lines: missing" "missing" "$(dparse | sed -n 's/.*"status":"\([a-z-]*\)".*/\1/p')"
dlist "install/x.sh" "../x.sh"
check "one line outside the repo: invalid" "invalid" "$(dparse | sed -n 's/.*"status":"\([a-z-]*\)".*/\1/p')"
dlist "install/x.sh" "$DRN/../other/x.sh"
check "absolute escape: invalid" "invalid" "$(dparse | sed -n 's/.*"status":"\([a-z-]*\)".*/\1/p')"
printf 'install/x.sh\nsrc/\001bad.js\n' > "$DLIST"
check "a control character in a line: invalid" "invalid" "$(dparse | sed -n 's/.*"status":"\([a-z-]*\)".*/\1/p')"
case_end

case_begin "det-compute-s4" "hooks/workflow-state/complexity-routing/deterministic-signals.js"
dlist "install/x.sh"
check "install/ first segment: S4 true, S1b false" '{"S1b-wide-change":false,"S4-installer":true}' "$(dcompute)"
dlist "src/dotfiles/zshrc"
check "a dotfiles segment: S4 true" '{"S1b-wide-change":false,"S4-installer":true}' "$(dcompute)"
dlist "settings.json" "src/installer-notes.md"
check "settings.json and an install-prefixed name are not S4" '{"S1b-wide-change":false,"S4-installer":false}' "$(dcompute)"
case_end

case_begin "det-compute-s1b" "hooks/workflow-state/complexity-routing/deterministic-signals.js"
dlist src/1.js src/2.js src/3.js src/4.js src/5.js src/6.js src/7.js
check "7 distinct files: S1b false" '{"S1b-wide-change":false,"S4-installer":false}' "$(dcompute)"
dlist src/1.js src/2.js src/3.js src/4.js src/5.js src/6.js src/7.js src/8.js
check "8 distinct files: S1b true" '{"S1b-wide-change":true,"S4-installer":false}' "$(dcompute)"
dlist "src/a.js" "$DRN/src/a.js" 'src\a.js' "./src/a.js" "src/./a.js" "src/a.js " " src/a.js" "src//a.js"
check "one file written 8 ways counts once: S1b false" '{"S1b-wide-change":false,"S4-installer":false}' "$(dcompute)"
check "one file written 8 ways: a single deduplicated path" '{"status":"ok","paths":["src/a.js"]}' "$(dparse)"
case_end
