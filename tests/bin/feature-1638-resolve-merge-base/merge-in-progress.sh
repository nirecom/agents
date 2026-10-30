# Part of tests/bin/feature-1638-resolve-merge-base.sh (sourced, not standalone).
# Tests: bin/resolve-merge-base.sh
# Tags: merge-base, baseline, merge-in-progress, scope:issue-specific, pwsh-not-required, TL2
# M — #2631: layer 1 while an uncommitted `git merge` is in progress. The recorded base may be an
# ancestor of HEAD OR of a valid MERGE_HEAD entry; branch_head stays a HEAD-only check.

# work and other both edit shared.txt from c0, so `git merge other` on work stops on a conflict
# and leaves MERGE_HEAD = other's tip. Prints "<repo> <c0> <other-mid> <other-tip> <third-tip>".
merge_conflict_repo() {
  local r c0 mid tip third
  r="$(new_repo main)"
  commit_file "$r" shared.txt 1 base
  c0="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" switch -q -c other >/dev/null 2>&1
  commit_file "$r" shared.txt 2 "other side"
  mid="$(git -C "$r" rev-parse HEAD)"
  commit_file "$r" other-only.txt 1 "other tip"
  tip="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" switch -q -c third "$c0" >/dev/null 2>&1
  commit_file "$r" third.txt 1 third
  third="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" switch -q -c work "$c0" >/dev/null 2>&1
  commit_file "$r" shared.txt 3 "work side"
  git -C "$r" merge --no-edit other >/dev/null 2>&1 || true
  printf '%s %s %s %s %s' "$r" "$c0" "$mid" "$tip" "$third"
}

merge_baseline_json() { # <base> <branch_head> <repo>
  printf '{"base":"%s","branch":"work","branch_head":"%s","repo_root":"%s","source":"user-approved","post_session_head":false,"alt_base":null}' "$1" "$2" "$3"
}

m1_merge_head_base_is_adopted_during_merge() {
  local repo c0 mid tip third head sid="sid-m1"
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  if [ ! -f "$repo/.git/MERGE_HEAD" ]; then
    fail "M1-fixture: the conflicting merge did not leave MERGE_HEAD"
    return
  fi
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" "$(merge_baseline_json "$tip" "$head" "$repo")"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "M1-state: a recorded base = MERGE_HEAD is adopted while the merge is in progress" "RECORDED" "$(kv state)"
  check "M1-base: and the base is the MERGE_HEAD sha" "$tip" "$(kv base)"
}

m2_merge_head_base_survives_the_merge_commit() {
  local repo c0 mid tip third head sid="sid-m2"
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" "$(merge_baseline_json "$tip" "$head" "$repo")"
  printf 'resolved\n' > "$repo/shared.txt"
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" commit -q --no-edit >/dev/null 2>&1
  if [ -f "$repo/.git/MERGE_HEAD" ]; then
    fail "M2-fixture: the merge commit was not made (MERGE_HEAD still present)"
    return
  fi
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "M2-state: the same record stays adopted after the merge commit" "RECORDED" "$(kv state)"
  check "M2-base: with the former MERGE_HEAD as the base" "$tip" "$(kv base)"
}

m3_unrelated_base_is_demoted_during_merge() {
  local repo c0 mid tip third head sid="sid-m3"
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" "$(merge_baseline_json "$third" "$head" "$repo")"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  if [ "$(kv state)" != "RECORDED" ]; then
    pass "M3-state: a base on neither side of the merge is demoted"
  else
    fail "M3-state: a base on neither side of the merge was adopted"
  fi
  check_match "M3-detail: and the reason names the failed ancestry check" "base is not a verified ancestor" "$(kv detail)"
}

m4_branch_head_stays_head_only_during_merge() {
  local repo c0 mid tip third sid="sid-m4"
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  put_baseline "$sid" "$repo" "$(merge_baseline_json "$c0" "$mid" "$repo")"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  if [ "$(kv state)" != "RECORDED" ]; then
    pass "M4-state: a branch_head reachable only from MERGE_HEAD is still demoted"
  else
    fail "M4-state: a branch_head reachable only from MERGE_HEAD was adopted"
  fi
  check_match "M4-detail: and the reason names the branch_head check" "branch_head is not a verified ancestor" "$(kv detail)"
}

m5_merge_head_side_ancestor_is_adopted() {
  local repo c0 mid tip third head sid="sid-m5"
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  if git -C "$repo" merge-base --is-ancestor "$mid" HEAD; then
    fail "M5-fixture: other-mid is an ancestor of HEAD (the row would not isolate MERGE_HEAD)"
    return
  fi
  head="$(git -C "$repo" rev-parse HEAD)"
  put_baseline "$sid" "$repo" "$(merge_baseline_json "$mid" "$head" "$repo")"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "M5-state: a base that is an ancestor of MERGE_HEAD only is adopted during the merge" "RECORDED" "$(kv state)"
  check "M5-base: and the base is that ancestor" "$mid" "$(kv base)"
}

# The same conflicting merge, redone inside a linked worktree of work, so MERGE_HEAD lives in
# .git/worktrees/<name>/ rather than in the main checkout's .git. Prints "<wt> <mid>".
linked_merge_worktree() {
  local repo c0 mid tip third wt
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  git -C "$repo" merge --abort >/dev/null 2>&1
  git -C "$repo" switch -q main >/dev/null 2>&1
  wt="$(mktemp -d "$TMPROOT/wt.XXXXXX")"
  git -C "$repo" worktree add -q "$wt" work >/dev/null 2>&1
  git -C "$wt" merge --no-edit other >/dev/null 2>&1 || true
  printf '%s %s' "$wt" "$mid"
}

m6_linked_worktree_merge_head_side_base_is_adopted() {
  local wt mid gitdir head sid="sid-m6"
  read -r wt mid <<< "$(linked_merge_worktree)"
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -z "$gitdir" ] || [ ! -f "$gitdir/MERGE_HEAD" ] || [ -f "$wt/.git/MERGE_HEAD" ]; then
    fail "M6-fixture: MERGE_HEAD is not in the linked worktree's own gitdir [$gitdir]"
    return
  fi
  head="$(git -C "$wt" rev-parse HEAD)"
  put_baseline "$sid" "$wt" "$(merge_baseline_json "$mid" "$head" "$wt")"
  HELPER_ENV=()
  run_helper "$wt" "$sid"
  check "M6-state: in a linked worktree, a MERGE_HEAD-side base is adopted during the merge" "RECORDED" "$(kv state)"
  check "M6-base: and the base is that ancestor" "$mid" "$(kv base)"
}

# MERGE_HEAD line selection, the same rows as approver A10. Tokens: TIP/THIRD/HEAD name a commit,
# CR appends a carriage return, BLANK is an empty line, JUNK is not a sha, HEADxN/JUNKxN repeat it.
# The base is other-mid, an ancestor of other-tip only.
m7_merge_head_line_selection_table() {
  local repo c0 mid tip third head name entries want tok line n i
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  head="$(git -C "$repo" rev-parse HEAD)"
  while IFS='|' read -r name entries want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    : > "$repo/.git/MERGE_HEAD"
    for tok in $entries; do
      n=1
      [[ "$tok" =~ ^(HEAD|JUNK)x([0-9]+)$ ]] && { n="${BASH_REMATCH[2]}"; tok="${BASH_REMATCH[1]}"; }
      case "$tok" in
        TIP) line="$tip" ;; TIPCR) line="$tip"$'\r' ;; THIRD) line="$third" ;;
        HEAD) line="$head" ;; BLANK) line="" ;; *) line="not-a-sha" ;;
      esac
      for ((i = 0; i < n; i++)); do printf '%s\n' "$line" >> "$repo/.git/MERGE_HEAD"; done
    done
    put_baseline "sid-m7-$name" "$repo" "$(merge_baseline_json "$mid" "$head" "$repo")"
    HELPER_ENV=()
    run_helper "$repo" "sid-m7-$name"
    check "M7-$name: layer-1 state" "$want" "$( [ "$(kv state)" = "RECORDED" ] && echo RECORDED || echo DEMOTED )"
  done <<'TABLE'
blank-lines-skipped            | BLANK BLANK TIP BLANK | RECORDED
crlf-stripped                  | TIPCR                 | RECORDED
invalid-line-before-valid      | JUNK TIP              | RECORDED
ancestor-of-second-valid-entry | THIRD TIP             | RECORDED
cap-valid-entry-8-counts       | HEADx7 TIP            | RECORDED
cap-valid-entry-9-ignored      | HEADx8 TIP            | DEMOTED
invalid-lines-not-counted-toward-cap | JUNKx8 TIP      | RECORDED
TABLE
}

m8_head_side_base_is_adopted_during_conflicted_merge() {
  local repo c0 mid tip third head sid="sid-m8"
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  head="$(git -C "$repo" rev-parse HEAD)"
  if [[ ! -f "$repo/.git/MERGE_HEAD" || -z "$(git -C "$repo" ls-files -u)" ]]; then
    fail "M8-fixture: the merge is not in progress with unmerged entries in the index"
    return
  fi
  if git -C "$repo" merge-base --is-ancestor "$head" "$tip"; then
    fail "M8-fixture: work-tip is an ancestor of MERGE_HEAD (the row would not isolate HEAD)"
    return
  fi
  put_baseline "$sid" "$repo" "$(merge_baseline_json "$head" "$head" "$repo")"
  HELPER_ENV=()
  run_helper "$repo" "$sid"
  check "M8-state: a base on the HEAD side only is adopted during a conflicted merge" "RECORDED" "$(kv state)"
  check "M8-base: and the base is the recorded HEAD-side commit" "$head" "$(kv base)"
}

# MERGE_HEAD line format, the same rows as approver A13: a line counts only when the line itself
# is a 40- or 64-hex object name. Tokens: TIP is other-tip's sha; SYM..UPPER are ref names,
# revision expressions or non-canonical hex that all resolve to other-tip; WORKx8 repeats `work`.
m9_merge_head_line_format_table() {
  local repo c0 mid tip third head name entries want tok line n i
  read -r repo c0 mid tip third <<< "$(merge_conflict_repo)"
  head="$(git -C "$repo" rev-parse HEAD)"
  while IFS='|' read -r name entries want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    : > "$repo/.git/MERGE_HEAD"
    for tok in $entries; do
      n=1
      [[ "$tok" =~ ^(WORK)x([0-9]+)$ ]] && { n="${BASH_REMATCH[2]}"; tok="${BASH_REMATCH[1]}"; }
      case "$tok" in
        TIP) line="$tip" ;; SYM) line="other" ;; FULLREF) line="refs/heads/other" ;;
        SUFFIX) line="other~0" ;; REFLOG) line="other@{0}" ;; MSG) line=":/other tip" ;;
        ABBREV) line="${tip:0:12}" ;; UPPER) line="$(printf '%s' "$tip" | tr '[:lower:]' '[:upper:]')" ;; WORK) line="work" ;;
        HEXTILDE) line="${tip}~0" ;; HEXPEEL) line="${tip}^{commit}" ;; HEXLSP) line=" ${tip}" ;;
        HEXTSP) line="${tip} " ;; HEXTAB) line="${tip}"$'\t' ;; HEX39) line="${tip:0:39}" ;; HEX41) line="${tip}a" ;;
        *) line="not-a-sha" ;;
      esac
      for ((i = 0; i < n; i++)); do printf '%s\n' "$line" >> "$repo/.git/MERGE_HEAD"; done
    done
    put_baseline "sid-m9-$name" "$repo" "$(merge_baseline_json "$mid" "$head" "$repo")"
    HELPER_ENV=()
    run_helper "$repo" "sid-m9-$name"
    check "M9-$name: layer-1 state" "$want" "$( [[ "$(kv state)" == "RECORDED" ]] && echo RECORDED || echo DEMOTED )"
    if [[ "$want" == "RECORDED" ]]; then
      check "M9-$name: base is the recorded sha" "$mid" "$(kv base)"
    fi
  done <<'TABLE'
hex-40-adopted                        | TIP         | RECORDED
branch-name-demoted                   | SYM         | DEMOTED
full-ref-demoted                      | FULLREF     | DEMOTED
suffix-expression-demoted             | SUFFIX      | DEMOTED
reflog-expression-demoted             | REFLOG      | DEMOTED
message-search-demoted                | MSG         | DEMOTED
abbreviated-hex-demoted               | ABBREV      | DEMOTED
uppercase-hex-demoted                 | UPPER       | DEMOTED
symbolic-then-hex-adopted             | SYM TIP     | RECORDED
symbolic-lines-not-counted-toward-cap | WORKx8 TIP  | RECORDED
# Lines that embed the full 40-hex tip: only a whole-line anchored match may adopt them.
hex-tilde-zero-demoted                | HEXTILDE    | DEMOTED
hex-peel-commit-demoted               | HEXPEEL     | DEMOTED
hex-leading-space-demoted             | HEXLSP      | DEMOTED
hex-trailing-space-demoted            | HEXTSP      | DEMOTED
hex-trailing-tab-demoted              | HEXTAB      | DEMOTED
hex-39-prefix-demoted                 | HEX39       | DEMOTED
hex-41-demoted                        | HEX41       | DEMOTED
TABLE
}

# The conflicting merge of merge_conflict_repo in a SHA-256 repository. Prints "<repo> <mid> <tip>",
# or nothing when this git cannot create a SHA-256 repository.
sha256_merge_conflict_repo() {
  local r c0 mid tip
  r="$(mktemp -d "$TMPROOT/repo256.XXXXXX")"
  git -C "$r" init -q -b main --object-format=sha256 >/dev/null 2>&1 || return 0
  git -C "$r" config core.hooksPath "$r/.git/no-such-hooks" >/dev/null 2>&1
  git -C "$r" config user.email test@example.com >/dev/null 2>&1
  git -C "$r" config user.name test >/dev/null 2>&1
  git -C "$r" config commit.gpgsign false >/dev/null 2>&1
  commit_file "$r" shared.txt 1 base
  c0="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" switch -q -c other >/dev/null 2>&1
  commit_file "$r" shared.txt 2 "other side"
  mid="$(git -C "$r" rev-parse HEAD)"
  commit_file "$r" other-only.txt 1 "other tip"
  tip="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" switch -q -c work "$c0" >/dev/null 2>&1
  commit_file "$r" shared.txt 3 "work side"
  git -C "$r" merge --no-edit other >/dev/null 2>&1 || true
  printf '%s %s %s' "$r" "$mid" "$tip"
}

sha256_fixture_ok() { # <case> <repo> <mid> <tip>
  if [[ ! "$4" =~ ^[0-9a-f]{64}$ || "$(tr -d '\r\n' < "$2/.git/MERGE_HEAD" 2>/dev/null)" != "$4" ]]; then
    fail "$1-fixture: MERGE_HEAD does not hold the 64-hex tip [$4]"
    return 1
  fi
  if git -C "$2" merge-base --is-ancestor "$3" HEAD; then
    fail "$1-fixture: other-mid is an ancestor of HEAD (the row would not isolate MERGE_HEAD)"
    return 1
  fi
}

# The 64-hex half of the line format, the same case as approver A15: a SHA-256 repository whose
# MERGE_HEAD holds a 64-hex tip; other-mid is reachable only from MERGE_HEAD. SKIP when this git
# cannot create a SHA-256 repository.
m10_sha256_merge_head_side_base_is_adopted() {
  local r mid tip head sid="sid-m10"
  read -r r mid tip <<< "$(sha256_merge_conflict_repo)"
  if [[ -z "$r" ]]; then
    skip_case "M10: git init --object-format=sha256 is unsupported by this git"
    return
  fi
  sha256_fixture_ok M10 "$r" "$mid" "$tip" || return
  head="$(git -C "$r" rev-parse HEAD)"
  put_baseline "$sid" "$r" "$(merge_baseline_json "$mid" "$head" "$r")"
  HELPER_ENV=()
  run_helper "$r" "$sid"
  check "M10-state: a 64-hex MERGE_HEAD-side base is adopted during the merge" "RECORDED" "$(kv state)"
  check "M10-base: and the base is the recorded 64-hex sha" "$mid" "$(kv base)"
}

# M10 end to end, the SHA-256 half of approver A11: the real approval CLI records the
# MERGE_HEAD-side base and the 64-hex branch_head, and the resolver adopts that record.
m11_sha256_cli_approval_is_adopted_by_resolver() {
  local r mid tip head base sid="sid-m11"
  read -r r mid tip <<< "$(sha256_merge_conflict_repo)"
  if [[ -z "$r" ]]; then
    skip_case "M11: git init --object-format=sha256 is unsupported by this git"
    return
  fi
  sha256_fixture_ok M11 "$r" "$mid" "$tip" || return
  head="$(git -C "$r" rev-parse HEAD)"
  run_record_cli --session "$sid" --base "$mid" --reason "user approved the 64-hex MERGE_HEAD side" --repo "$r"
  check "M11-approve: the approval CLI exits 0 [$A_ERR]" "0" "$A_RC"
  check "M11-stored-base: the CLI stored the 64-hex base" "$mid" "$(node_state field "$sid" base)"
  check "M11-stored-head: the CLI stored the 64-hex HEAD as branch_head" "$head" "$(node_state field "$sid" branch_head)"
  HELPER_ENV=()
  run_helper "$r" "$sid" --format kv
  base="$(kv base)"
  check "M11-state: the resolver adopts the CLI-written 64-hex record" "RECORDED" "$(kv state)"
  check "M11-base: and returns the approved 64-hex sha" "$mid" "$base"
  check "M11-base-length: a full 64-hex name, not a 40-hex truncation" "64" "${#base}"
}

m5_to_m7_merge_head_extended_rows() {
  m5_merge_head_side_ancestor_is_adopted
  m6_linked_worktree_merge_head_side_base_is_adopted
  m7_merge_head_line_selection_table
}
