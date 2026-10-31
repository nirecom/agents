#!/usr/bin/env bash
# Tests: hooks/pre-commit, bin/check-plans-artifacts
# Tags: scope:issue-specific, TL2, plans-dir-lint, feature-2434, plans-dir, pwsh-not-required
# Part file of tests/bin/feature-2434-plans-dir-lint.sh (sourced; uses its T, TABLE_REL,
# edit_table, check, np and RWT). #2638: a real `git commit` in linked worktree B, with
# core.hooksPath on main worktree A's hooks dir. A supplies the hook and every checker;
# B's own staged data files decide the verdict. A is a copy of this checkout's tracked files.
# TL3 gap: the fixture has no origin remote, so the hook's private-repo probe (gh) never runs,
# and the outbound scan reads an empty fixture blocklist instead of the installed one.

GATE_A="$T/gate-a"
GATE_B="$T/gate-b"
GATE_PROBE="bin/gate-probe.sh"
GATE_KIND_FILE="gate-probe-kind.txt"
GATE_SSOT_TABLE="bin/check-session-id-ssot/path-tables.txt"
GATE_SSOT_PROBE="hooks/lib/gate-probe.js"
GATE_RETIRED="CLAUDE_""SESSION_ID"
GATE_BASE=""
GATE_READY=0

gate_build() {
  mkdir -p "$GATE_A" || return 1
  git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -z > "$T/gate-files.z" || return 1
  tar -C "$SCRIPT_CHECKOUT_ROOT" --null -T "$T/gate-files.z" -cf "$T/gate-files.tar" 2>/dev/null
  tar -C "$GATE_A" -xf "$T/gate-files.tar" || return 1
  rm -f "$T/gate-files.tar"
  [ -f "$GATE_A/hooks/pre-commit" ] || return 1
  git -C "$GATE_A" init -q || return 1
  git -C "$GATE_A" config core.hooksPath /dev/null
  git -C "$GATE_A" config core.autocrlf false
  git -C "$GATE_A" config user.email "test@example.com"
  git -C "$GATE_A" config user.name "Test"
  git -C "$GATE_A" add -A || return 1
  git -C "$GATE_A" commit -q -m "base" || return 1
  git -C "$GATE_A" worktree add -q -b feature/gate-probe "$GATE_B" || return 1
  # The scanner reads this list from the main worktree only; without one it blocks every commit.
  printf '%s\n' "# fixture: no patterns" > "$GATE_A/.private-info-blocklist"
  GATE_HOOKS="$(np "$GATE_A/hooks")"
  GATE_BASE="$(git -C "$GATE_B" rev-parse HEAD)"
}

gate_reset() {
  git -C "$GATE_B" reset -q --hard "$GATE_BASE"
  git -C "$GATE_B" clean -fdq
}

# gate_commit — commit B's index through A's hooks; rc in G_RC, both streams in G_OUT.
gate_commit() {
  G_RC=0
  G_OUT="$(cd "$GATE_B" && env -u CODE_LANG ENFORCE_WORKTREE=on AGENTS_MAIN_ROOT="$(np "$GATE_A")" \
    bash "$RWT" 180 git -c core.hooksPath="$GATE_HOOKS" commit -q -m "gate probe" 2>&1 </dev/null)" || G_RC=$?
}

# gate_neuter <checker> — stage a copy of B's own checker that always answers "clean".
gate_neuter() {
  printf '%s\n' "$2" "$3" > "$GATE_B/$1"
  git -C "$GATE_B" add --chmod=+x "$1"
}

gate_has() { if [[ "$1" == *"$2"* ]]; then printf yes; else printf no; fi; }
gate_landed() { if [ "$(git -C "$GATE_B" rev-parse HEAD)" != "$GATE_BASE" ]; then printf yes; else printf no; fi; }
gate_committed() { git -C "$GATE_B" show --name-only --format= HEAD | tr -d '\r' | sort | tr '\n' ' '; }
gate_add_exempt() { awk -v p="$2" '{print; l=$0; sub(/\r$/,"",l); if (l=="[TOMBSTONE_EXEMPT]") print p}' "$1" > "$T/gate-table.txt" && cp "$T/gate-table.txt" "$1"; }

gate_build && GATE_READY=1
gate_ready() {
  [ "$GATE_READY" = 1 ] && return 0
  fail "$1" "fixture: main worktree A plus linked worktree B could not be built"
  return 1
}

case_begin "worktree-commit-plans-kind-and-use-together" "hooks/pre-commit"
if gate_ready "wt-plans-pass: fixture"; then
  gate_reset
  printf '%s\n' '#!/usr/bin/env bash' "cat \"\$PLANS_DIR/\$SID-$GATE_KIND_FILE\"" > "$GATE_B/$GATE_PROBE"
  git -C "$GATE_B" add --chmod=+x "$GATE_PROBE"
  edit_table "$GATE_B" add-kind artifactKinds gate-probe 'gate-probe-kind\.txt' non-plan
  git -C "$GATE_B" add "$TABLE_REL"
  gate_commit
  check "wt-plans-pass: a new kind and its use staged together commit (exit 0)" "0" "$G_RC"
  check "wt-plans-pass: the commit holds exactly the use and the table" "$GATE_PROBE $TABLE_REL " "$(gate_committed)"
  check "wt-plans-pass: the main worktree's table never knew the kind" "no" "$(gate_has "$(cat "$GATE_A/$TABLE_REL")" "gate-probe")"
  [ "$G_RC" = 0 ] || printf '%s\n' "$G_OUT" | head -8
fi
case_end

case_begin "worktree-commit-plans-use-without-kind-blocked" "hooks/pre-commit"
if gate_ready "wt-plans-block: fixture"; then
  gate_reset
  printf '%s\n' '#!/usr/bin/env bash' "cat \"\$PLANS_DIR/\$SID-$GATE_KIND_FILE\"" > "$GATE_B/$GATE_PROBE"
  git -C "$GATE_B" add --chmod=+x "$GATE_PROBE"
  gate_neuter bin/check-plans-artifacts '#!/usr/bin/env node' 'process.exit(0);'
  gate_commit
  check "wt-plans-block: the use without its table entry is refused (exit 1)" "1" "$G_RC"
  check "wt-plans-block: nothing was committed" "no" "$(gate_landed)"
  check "wt-plans-block: the plans gate is the one that refused" "yes" "$(gate_has "$G_OUT" "Commit blocked: plans-dir names that are not registered artifacts")"
  check "wt-plans-block: the diagnostic names the file (B's neutered checker did not answer)" "yes" "$(gate_has "$G_OUT" "$GATE_PROBE:")"
fi
case_end

case_begin "worktree-commit-session-id-path-and-file-together" "hooks/pre-commit"
if gate_ready "wt-ssot-pass: fixture"; then
  gate_reset
  printf '%s\n' "// strips $GATE_RETIRED from the child environment" "module.exports = {};" > "$GATE_B/$GATE_SSOT_PROBE"
  gate_add_exempt "$GATE_B/$GATE_SSOT_TABLE" "$GATE_SSOT_PROBE"
  git -C "$GATE_B" add "$GATE_SSOT_PROBE" "$GATE_SSOT_TABLE"
  gate_commit
  check "wt-ssot-pass: a new exempt path and its file staged together commit (exit 0)" "0" "$G_RC"
  check "wt-ssot-pass: the commit holds exactly the path table and the file" "$GATE_SSOT_TABLE $GATE_SSOT_PROBE " "$(gate_committed)"
  check "wt-ssot-pass: the main worktree's path table never listed the file" "no" "$(gate_has "$(cat "$GATE_A/$GATE_SSOT_TABLE")" "$GATE_SSOT_PROBE")"
  [ "$G_RC" = 0 ] || printf '%s\n' "$G_OUT" | head -8
fi
case_end

case_begin "worktree-commit-session-id-file-without-path-blocked" "hooks/pre-commit"
if gate_ready "wt-ssot-block: fixture"; then
  gate_reset
  printf '%s\n' "// strips $GATE_RETIRED from the child environment" "module.exports = {};" > "$GATE_B/$GATE_SSOT_PROBE"
  git -C "$GATE_B" add "$GATE_SSOT_PROBE"
  gate_neuter bin/check-session-id-ssot.sh '#!/usr/bin/env bash' 'exit 0'
  gate_commit
  check "wt-ssot-block: the file without its table line is refused (exit 1)" "1" "$G_RC"
  check "wt-ssot-block: nothing was committed" "no" "$(gate_landed)"
  check "wt-ssot-block: the session-id gate is the one that refused" "yes" "$(gate_has "$G_OUT" "Commit blocked: session-id env reads bypassing the SSOT resolver")"
  check "wt-ssot-block: the diagnostic names the file (B's neutered checker did not answer)" "yes" "$(gate_has "$G_OUT" "$GATE_SSOT_PROBE:")"
fi
case_end
true
