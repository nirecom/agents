# shellcheck shell=bash
# Tests: hooks/lib/staged-doc-changes.js
# Tags: TL2, docs, review-docs, staged, git, scope:issue-specific, pwsh-not-required
#
# GROUP D: hasStagedDocChanges(repoDir). True iff `git diff --cached --name-only
# -- '*.md'` is non-empty for repoDir — i.e. at least one .md is in the index.
# Unstaged .md, a clean index, and staged non-.md all return false.

# has_staged <repoDir> — run hasStagedDocChanges(repoDir), print "true"/"false".
has_staged() {
  local repo_n; repo_n="$(nrm "$1")"
  D_REPO="$repo_n" run_node -e '
const { hasStagedDocChanges } = require(process.env.MOD_N);
process.stdout.write(String(hasStagedDocChanges(process.env.D_REPO)));
' 2>&1
}

run_group_d() {
  require_module "D" "hooks/lib/staged-doc-changes.js" || return 0
  export MOD_N="$AGENTS_DIR_N/hooks/lib/staged-doc-changes.js"
  local repo out

  # D1: a staged .md → true.
  repo="$(new_doc_repo)"
  gen_md "$repo/doc.md" 10
  git -C "$repo" add doc.md >/dev/null 2>&1
  out="$(has_staged "$repo")"
  assert_eq "D1: staged .md → hasStagedDocChanges true" "true" "$out"

  # D2: an .md changed on disk but NOT staged → false (index blob semantics).
  repo="$(new_doc_repo)"
  gen_md "$repo/tracked.md" 10
  git -C "$repo" add tracked.md >/dev/null 2>&1
  git -C "$repo" commit -q -m "add tracked.md"
  gen_md "$repo/tracked.md" 40          # working tree only; no git add
  out="$(has_staged "$repo")"
  assert_eq "D2: unstaged .md edit → hasStagedDocChanges false" "false" "$out"

  # D3: a clean index (nothing staged) → false.
  repo="$(new_doc_repo)"
  out="$(has_staged "$repo")"
  assert_eq "D3: clean index → hasStagedDocChanges false" "false" "$out"

  # D4: staged .js only, no .md → false.
  repo="$(new_doc_repo)"
  printf '// code\n' > "$repo/thing.js"
  git -C "$repo" add thing.js >/dev/null 2>&1
  out="$(has_staged "$repo")"
  assert_eq "D4: staged .js only → hasStagedDocChanges false" "false" "$out"

  # --- D-NEW: path-class coverage (#2340 gap C4). Matches *.md (root) and
  # docs/**/*.md (any depth); a non-.md path never matches, even under docs/. ---

  # D-NEW-1: root-level README.md staged → true.
  repo="$(new_doc_repo)"
  gen_md "$repo/README.md" 10
  git -C "$repo" add README.md >/dev/null 2>&1
  out="$(has_staged "$repo")"
  assert_eq "D-NEW-1: root README.md staged → hasStagedDocChanges true" "true" "$out"

  # D-NEW-2: a nested docs/foo/bar.md staged → true (docs/**/*.md, any depth).
  repo="$(new_doc_repo)"
  gen_md "$repo/docs/foo/bar.md" 10
  git -C "$repo" add docs/foo/bar.md >/dev/null 2>&1
  out="$(has_staged "$repo")"
  assert_eq "D-NEW-2: nested docs/foo/bar.md staged → hasStagedDocChanges true" "true" "$out"

  # D-NEW-3: a non-.md source file (src/index.js) only → false.
  repo="$(new_doc_repo)"
  mkdir -p "$repo/src"
  printf '// code\n' > "$repo/src/index.js"
  git -C "$repo" add src/index.js >/dev/null 2>&1
  out="$(has_staged "$repo")"
  assert_eq "D-NEW-3: staged src/index.js only → hasStagedDocChanges false" "false" "$out"

  # D-NEW-4: a file under docs/ that is NOT .md (docs/foo/bar.ts) → false.
  repo="$(new_doc_repo)"
  mkdir -p "$repo/docs/foo"
  printf 'export const x = 1;\n' > "$repo/docs/foo/bar.ts"
  git -C "$repo" add docs/foo/bar.ts >/dev/null 2>&1
  out="$(has_staged "$repo")"
  assert_eq "D-NEW-4: staged docs/foo/bar.ts (not .md) → hasStagedDocChanges false" "false" "$out"
}
