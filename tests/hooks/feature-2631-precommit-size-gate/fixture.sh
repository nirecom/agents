#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate/fixture.sh — fixture of
# tests/hooks/feature-2631-precommit-size-gate{,-cli}.sh (the former through lane.sh).
# Sourced after harness.sh is loaded and the isolation is pinned (ROOT, TMP_ROOT set).
# Every run uses one agents install that is also the repo under commit (the feature-1894 pattern),
# with a non-GitHub origin, so a gate placed after the hook's early `exit 0`s never runs (= FAIL).

NON_GITHUB="https://git.example.com/acme/widgets.git"
GATE="$ROOT/hooks/pre-commit.d/checks/size-gate.js"

# make_lines <n> [tag] — exactly n newline-terminated lines.
make_lines() { local i; for ((i = 1; i <= $1; i++)); do printf '%s line %d\n' "${2:-v1}" "$i"; done; }

# init_repo <dir> — hooks disabled, example.com identity, HEAD on main.
init_repo() {
  mkdir -p "$1"
  harness_git_init "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name Test
  git -C "$1" config core.autocrlf false
  git -C "$1" symbolic-ref HEAD refs/heads/main
}

# CFG_TEMPLATE — the install, with src/old.js already over the code HARD (600 > 500) at HEAD.
# The .env (read by the hook from its own root only) switches the comment-block gate off: it is
# not under test here and costs a node spawn per run.
CFG_TEMPLATE="$TMP_ROOT/cfg-template"
init_repo "$CFG_TEMPLATE"
cp -r "$ROOT/hooks" "$ROOT/bin" "$ROOT/rules" "$CFG_TEMPLATE/"
# The other agents-repo gates are not under test and need the whole repo (skills/, tests/ data
# files). hooks/pre-commit.d/checks/agents-repo-gates.js requires each registry gate's module in
# process, so the module itself (listed by the registry, not by hand) is stubbed clean here.
FIXTURE_GATE_MODULES="$(node -e 'for (const g of require(process.argv[1]).AGENTS_REPO_GATES) console.log(g.module)' "$ROOT/hooks/pre-commit.d/registry.js")"
[ -n "$FIXTURE_GATE_MODULES" ] || { echo "fixture: the registry lists no agents-repo gate module" >&2; exit 1; }
while IFS= read -r g; do
  [ -n "$g" ] || continue
  mkdir -p "$(dirname "$CFG_TEMPLATE/$g")"
  printf '#!/usr/bin/env node\n"use strict";\nmodule.exports = { run: async () => 0 };\nif (require.main === module) process.exit(0);\n' > "$CFG_TEMPLATE/$g"
done <<<"$FIXTURE_GATE_MODULES"
mkdir -p "$CFG_TEMPLATE/src"
make_lines 600 v1 > "$CFG_TEMPLATE/src/old.js"
echo init > "$CFG_TEMPLATE/README.md"
git -C "$CFG_TEMPLATE" add README.md hooks bin rules src
git -C "$CFG_TEMPLATE" commit -q -m init
git -C "$CFG_TEMPLATE" remote add origin "$NON_GITHUB"
printf 'COMMENT_BLOCK_ENFORCE=off\n' > "$CFG_TEMPLATE/.env"

# new_cfg [stub-rc] — the install reset to HEAD with an empty index (a copy per case costs more
# than the whole run on Windows); with stub-rc, bin/size-check is replaced by `exit stub-rc`
# until the next new_cfg. The real size-check (once it exists) is kept aside and restored.
SIZE_CHECK_BAK="$TMP_ROOT/size-check.real"
new_cfg() {
  [ -f "$SIZE_CHECK_BAK" ] && cp "$SIZE_CHECK_BAK" "$CFG_TEMPLATE/bin/size-check"
  git -C "$CFG_TEMPLATE" reset -q --hard HEAD
  if [ -n "${1:-}" ]; then
    [ -f "$CFG_TEMPLATE/bin/size-check" ] && [ ! -f "$SIZE_CHECK_BAK" ] && cp "$CFG_TEMPLATE/bin/size-check" "$SIZE_CHECK_BAK"
    printf '#!/usr/bin/env node\nprocess.exit(%s);\n' "$1" > "$CFG_TEMPLATE/bin/size-check"
    chmod +x "$CFG_TEMPLATE/bin/size-check"
  fi
  printf '%s' "$CFG_TEMPLATE"
}

# new_nohead_cfg — a second install that is a fresh repo with no commit yet (no HEAD): the install's
# files sit untracked in its worktree, so a case's first commit holds only what the case stages.
NOHEAD_CFG="$TMP_ROOT/cfg-nohead"
new_nohead_cfg() {
  new_cfg > /dev/null
  rm -rf "$NOHEAD_CFG"
  init_repo "$NOHEAD_CFG"
  cp -r "$CFG_TEMPLATE/hooks" "$CFG_TEMPLATE/bin" "$CFG_TEMPLATE/rules" "$CFG_TEMPLATE/.env" "$NOHEAD_CFG/"
  git -C "$NOHEAD_CFG" remote add origin "$NON_GITHUB"
  printf '%s' "$NOHEAD_CFG"
}

# stage <repo> <path> <n> [tag] — write <path> with n lines and stage it.
stage() {
  mkdir -p "$(dirname "$1/$2")"
  make_lines "$3" "${4:-v2}" > "$1/$2"
  git -C "$1" add -- "$2"
}

# stage_blob <repo> <path> <n> — stage n lines under <path> through the index alone, for a name
# no Windows file system can hold (a newline); protectNTFS would refuse it there.
stage_blob() {
  local sha
  sha="$(make_lines "$3" v2 | git -C "$1" hash-object -w --stdin)" || return 1
  git -C "$1" -c core.protectNTFS=false update-index --add --cacheinfo "100644,$sha,$2"
}
# unstage_blob <repo> <path> — drop it again: new_cfg's reset cannot remove such a name on Windows.
unstage_blob() { git -C "$1" -c core.protectNTFS=false update-index --force-remove -- "$2"; }

RC=0
OUT=""
ERR=""
# run_pc <repo> <cfg> [VAR=VAL ...] — runs <cfg>/hooks/pre-commit from <repo>; sets RC / OUT / ERR.
run_pc() {
  local repo="$1" cfg="$2"
  shift 2
  RC=0
  OUT="$(cd "$repo" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID AGENTS_MAIN_ROOT="$cfg" ENFORCE_WORKTREE=off "$@" bash "$cfg/hooks/pre-commit" 2>"$TMP_ROOT/pc.err")" || RC=$?
  ERR="$(cat "$TMP_ROOT/pc.err" 2>/dev/null || true)"
}

# expect_block <name> <path> — rc 1 and the size verdict names the file (not some other gate).
expect_block() {
  if [ "$RC" = 1 ] && printf '%s\n%s\n' "$OUT" "$ERR" | grep -F "$2" | grep -q HARD; then pass "$1"
  else fail "$1" "rc=$RC out=$(printf '%s' "$OUT" | head -c 300) err=$(printf '%s' "$ERR" | head -c 300)"; fi
}
# expect_pass <name> — the commit goes through.
expect_pass() {
  if [ "$RC" = 0 ]; then pass "$1"
  else fail "$1" "rc=$RC out=$(printf '%s' "$OUT" | head -c 300) err=$(printf '%s' "$ERR" | head -c 300)"; fi
}
