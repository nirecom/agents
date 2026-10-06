# Mode cases (full / --staged / usage) for feat-2512-isolation-guard.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

# cls_repo <dir> — throwaway git repo carrying a copy of the classifier.
cls_repo() {
  local d="$1"
  mkdir -p "$d/bin" "$d/tests/hooks"
  harness_git_init "$d"
  git -C "$d" config core.autocrlf false
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  cp "$CLS" "$d/bin/"
  if [[ -d "$AGENTS_DIR/bin/check-plans-dir-isolation" ]]; then
    cp -r "$AGENTS_DIR/bin/check-plans-dir-isolation" "$d/bin/"
  fi
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm fixture
}

c_i9_residual_token() {
  local d
  d="$T/i9-hit"
  cls_repo "$d"
  fx "$d/hooks/old.js" "const d = process.env.$OLD_TOKEN;"
  commit_all "$d"
  run_cls_in "$d" "$d/bin/check-plans-dir-isolation.sh"
  expect "I9 rc=1 for a committed residual token" rc_is 1
  expect "I9 RESIDUAL-TOKEN names hooks/old.js:1" label_hits RESIDUAL-TOKEN "hooks/old.js:1"

  d="$T/i9-lower"
  cls_repo "$d"
  fx "$d/bin/tool.sh" '#!/usr/bin/env bash' "echo \"\${${OLD_TOKEN,,}:-}\""
  commit_all "$d"
  run_cls_in "$d" "$d/bin/check-plans-dir-isolation.sh"
  expect "I9 the token match is case-insensitive" label_hits RESIDUAL-TOKEN "bin/tool.sh:2"

  d="$T/i9-history"
  cls_repo "$d"
  fx "$d/docs/history/2026.md" "- renamed $OLD_TOKEN"
  fx "$d/CHANGELOG.md" "- renamed $OLD_TOKEN"
  commit_all "$d"
  run_cls_in "$d" "$d/bin/check-plans-dir-isolation.sh"
  expect "I9 docs/history/ and CHANGELOG.md are exempt (rc=0)" rc_is 0
  expect "I9 no RESIDUAL-TOKEN line for the exempt files" no_violation_for "docs/history"

  d="$T/i9-staged"
  cls_repo "$d"
  commit_all "$d"
  fx "$d/hooks/new.js" "const d = process.env.$OLD_TOKEN;"
  git -C "$d" add hooks/new.js
  run_cls_in "$d" "$d/bin/check-plans-dir-isolation.sh" --staged
  expect "I9 --staged rc=1 for a staged residual token" rc_is 1
  expect "I9 --staged RESIDUAL-TOKEN names hooks/new.js" label_hits RESIDUAL-TOKEN "hooks/new.js"
}

c_i10_staged_skips_scan() {
  local d
  d="$T/i10"
  cls_repo "$d"
  fx "$d/tests/hooks/bad.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  fx "$d/README.md" "readme"
  commit_all "$d"
  fx "$d/README.md" "readme v2"
  git -C "$d" add README.md
  run_cls_in "$d" "$d/bin/check-plans-dir-isolation.sh" --staged
  expect "I10 --staged without a tests .sh skips the isolation scan (rc=0)" rc_is 0
  expect "I10 the unstaged violation is not reported" no_violation_for "bad.sh"

  git -C "$d" reset -q
  printf '%s\n' '# touched' >> "$d/tests/hooks/bad.sh"
  git -C "$d" add tests/hooks/bad.sh
  run_cls_in "$d" "$d/bin/check-plans-dir-isolation.sh" --staged
  expect "I10 --staged with a tests .sh runs the scan (rc=1)" rc_is 1
  expect "I10 STATE-UNPINNED names tests/hooks/bad.sh" label_hits STATE-UNPINNED "hooks/bad.sh"
}

c_i11_usage_errors() {
  run_cls --bogus-flag
  expect "I11 an unknown flag exits 2" rc_is 2
  run_cls --root
  expect "I11 --root without a value exits 2" rc_is 2
}

c_i12_repo_clean() {
  CLS_RC=0
  CLS_OUT="$(cd "$AGENTS_DIR" && run_with_timeout 300 bash "$CLS" 2>&1)" || CLS_RC=$?
  expect "I12 the whole repo (no args) exits 0" rc_is 0
  expect "I12 the whole repo prints no violation line" no_violation_for ""
}

# Codex C2: --staged is the pre-commit gate, so its isolation verdict must follow the
# index (what is committed), not the working tree. Index and worktree diverge both ways.
c_staged_reads_index() {
  local d
  d="$T/staged-index"
  cls_repo "$d"
  fx "$d/tests/hooks/gate.sh" '#!/usr/bin/env bash' "$PIN_BOTH" "$EXEC_RO"
  commit_all "$d"

  fx "$d/tests/hooks/gate.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  git -C "$d" add tests/hooks/gate.sh
  fx "$d/tests/hooks/gate.sh" '#!/usr/bin/env bash' "$PIN_BOTH" "$EXEC_RO"
  run_cls_in "$d" "$d/bin/check-plans-dir-isolation.sh" --staged
  expect "staged index: a staged unpinned blob fails although the worktree is pinned (rc=1)" rc_is 1
  expect "staged index: STATE-UNPINNED names the staged tests/hooks/gate.sh" label_hits STATE-UNPINNED "hooks/gate.sh"

  git -C "$d" reset -q
  fx "$d/tests/hooks/gate.sh" '#!/usr/bin/env bash' "$PIN_BOTH" "$EXEC_RO" '# touched'
  git -C "$d" add tests/hooks/gate.sh
  fx "$d/tests/hooks/gate.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  fx "$d/tests/hooks/untracked.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  run_cls_in "$d" "$d/bin/check-plans-dir-isolation.sh" --staged
  expect "staged index: a pinned staged blob passes although the worktree copy is unpinned (rc=0)" rc_is 0
  expect "staged index: the unstaged worktree edit is not reported" no_violation_for "hooks/gate.sh"
  expect "staged index: an untracked tests .sh is not reported" no_violation_for "hooks/untracked.sh"
}

case_begin "staged-reads-index" "bin/check-plans-dir-isolation.sh"
c_staged_reads_index
case_end
