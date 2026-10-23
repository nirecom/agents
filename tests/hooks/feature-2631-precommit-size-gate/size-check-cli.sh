#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate/size-check-cli.sh — the bin/size-check CLI bodies
# of tests/hooks/feature-2631-precommit-size-gate-cli.sh (the case markers stay in the entry file).
# Sourced after fixture.sh (init_repo, make_lines, ROOT, TMP_ROOT set).
# #2631 L9: `bin/size-check --kind <code|prompt|docs> --pre <none|rev:REF> --post <index|worktree>`
# reads NUL-separated paths on stdin and prints `TARGETS\t<n>` plus one record per target:
# `<OK|WARN|SHRINK|HARD>\t<value>\t<pre>\t<warn>\t<hard>\t<unit>\t<path>`.
# rc: 0 no HARD, 1 HARD, 2 usage error, 3 infrastructure error. Records are looked up by path.

SIZE_CHECK="$ROOT/bin/size-check"
SC_RC=0
SC_OUT=""
SC_ERR=""
SC_SEQ=0

# sc_repo — a fresh fixture repo (hooks disabled); a counter is safe: callers never use $(...).
sc_repo() {
  SC_SEQ=$((SC_SEQ + 1))
  SC_DIR="$TMP_ROOT/sc-repo-$SC_SEQ"
  init_repo "$SC_DIR"
}

# sc_put <repo> <path> <n> [tag] [open] — n lines; with open, the last line has no newline.
sc_put() {
  mkdir -p "$(dirname "$1/$2")"
  if [ "${5:-}" = open ]; then
    { make_lines $(($3 - 1)) "${4:-v1}"; printf '%s line %d' "${4:-v1}" "$3"; } > "$1/$2"
  else
    make_lines "$3" "${4:-v1}" > "$1/$2"
  fi
}

# sc_commit <repo> — commit everything in the fixture repo.
sc_commit() {
  git -C "$1" add -A
  git -C "$1" commit -q -m fixture
}

# sc_run <repo> "<paths>" <args...> — paths (space-separated) go to stdin NUL-separated.
# Sets SC_RC / SC_OUT (CR stripped) / SC_ERR. SC_EXTRA_ENV (VAR=VAL), when set, joins the env.
sc_run() {
  local repo="$1" paths="$2" p
  shift 2
  SC_RC=0
  SC_OUT="$(cd "$repo" && for p in $paths; do printf '%s\0' "$p"; done | run_with_timeout 60 env CODE_FILE_EXTENSIONS='js;sh;py' ${SC_EXTRA_ENV:+"$SC_EXTRA_ENV"} node "$SIZE_CHECK" "$@" 2>"$TMP_ROOT/sc.err")" || SC_RC=$?
  SC_OUT="$(printf '%s' "$SC_OUT" | tr -d '\r')"
  SC_ERR="$(cat "$TMP_ROOT/sc.err" 2>/dev/null || true)"
}

# sc_targets — the n of the TARGETS line (empty when there is none).
sc_targets() { printf '%s\n' "$SC_OUT" | awk -F'\t' '$1 == "TARGETS" { print $2; exit }'; }
# sc_rec <path> — the first six fields of the record for <path> (empty when there is none).
sc_rec() {
  printf '%s\n' "$SC_OUT" | awk -F'\t' -v p="$1" 'NF == 7 && $1 ~ /^(OK|WARN|SHRINK|HARD)$/ && $7 == p { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6; exit }'
}
# sc_tsv <field...> — the fields joined by tabs.
sc_tsv() { local IFS=$'\t'; printf '%s' "$*"; }
sc_show() { printf 'rc=%s out=%s err=%s' "$SC_RC" "$(printf '%s' "$SC_OUT" | head -c 300)" "$(printf '%s' "$SC_ERR" | head -c 200)"; }

# sc_eq <name> <actual> <want> — pass on an exact match; an empty want never passes.
sc_eq() {
  if [ -n "$3" ] && [ "$2" = "$3" ]; then pass "$1"
  else fail "$1" "want [$3] got [$2]; $(sc_show)"; fi
}
# sc_rc <name> <want-rc> — rc check; a verdict rc (0 / 1) also needs the TARGETS line, so a
# crash that happens to exit 1 is never read as a HARD verdict.
sc_rc() {
  if [ "$SC_RC" = "$2" ] && { [ "$2" -ge 2 ] || [ -n "$(sc_targets)" ]; }; then pass "$1"
  else fail "$1" "want rc=$2; $(sc_show)"; fi
}

WT=(--kind code --pre none --post worktree)

sc_case_kind_worktree_records() {
  if [ -f "$SIZE_CHECK" ]; then pass "bin/size-check exists"; else fail "bin/size-check exists" "missing"; fi
  sc_repo
  sc_put "$SC_DIR" a.js 301
  sc_put "$SC_DIR" b.js 10
  sc_put "$SC_DIR" c.js 501
  sc_put "$SC_DIR" notes.txt 1
  sc_run "$SC_DIR" "a.js b.js c.js notes.txt" "${WT[@]}"
  sc_rc "rc 1 when one target is HARD" 1
  sc_eq "TARGETS counts only code paths (3)" "$(sc_targets)" 3
  sc_eq "WARN record for 301 lines" "$(sc_rec a.js)" "$(sc_tsv WARN 301 0 300 500 lines)"
  sc_eq "OK record for 10 lines" "$(sc_rec b.js)" "$(sc_tsv OK 10 0 300 500 lines)"
  sc_eq "HARD record for 501 lines" "$(sc_rec c.js)" "$(sc_tsv HARD 501 0 300 500 lines)"
  if [ -n "$(sc_targets)" ] && [ -z "$(sc_rec notes.txt)" ]; then pass "a non-code path has no record"
  else fail "a non-code path has no record" "$(sc_show)"; fi
  sc_run "$SC_DIR" "a.js notes.txt" "${WT[@]}"
  sc_rc "rc 0 without a HARD record" 0
  sc_eq "rc 0 run: TARGETS 1" "$(sc_targets)" 1
  sc_repo
  sc_put "$SC_DIR" d.js 501 v1 open
  sc_run "$SC_DIR" "d.js" "${WT[@]}"
  sc_rc "a last line without a newline counts (501 -> rc 1)" 1
  sc_eq "a last line without a newline counts (501 -> HARD)" "$(sc_rec d.js)" "$(sc_tsv HARD 501 0 300 500 lines)"
}

sc_case_pre_rev_and_new_blob() {
  local rev=(--kind code --pre rev:HEAD --post worktree)
  sc_repo
  sc_put "$SC_DIR" big.js 510
  sc_commit "$SC_DIR"
  sc_put "$SC_DIR" big.js 505
  sc_put "$SC_DIR" new.js 501
  sc_run "$SC_DIR" "big.js new.js" "${rev[@]}"
  sc_eq "shrinking an over-HARD file is SHRINK with its pre" "$(sc_rec big.js)" "$(sc_tsv SHRINK 505 510 300 500 lines)"
  sc_eq "a path missing at rev has pre 0 and is HARD" "$(sc_rec new.js)" "$(sc_tsv HARD 501 0 300 500 lines)"
  sc_rc "rc 1 (new.js is HARD)" 1
  sc_eq "TARGETS 2" "$(sc_targets)" 2
  sc_put "$SC_DIR" big.js 510 v2
  sc_run "$SC_DIR" "big.js" "${rev[@]}"
  sc_eq "same count over HARD, edited, is HARD" "$(sc_rec big.js)" "$(sc_tsv HARD 510 510 300 500 lines)"
  sc_rc "same count over HARD -> rc 1" 1
  sc_put "$SC_DIR" big.js 505
  sc_run "$SC_DIR" "big.js" "${rev[@]}"
  sc_eq "only a SHRINK record: the record is SHRINK" "$(sc_rec big.js)" "$(sc_tsv SHRINK 505 510 300 500 lines)"
  sc_rc "only a SHRINK record -> rc 0" 0
}

sc_case_post_index_reads_the_staged_blob() {
  sc_repo
  sc_put "$SC_DIR" s.js 502
  git -C "$SC_DIR" add s.js
  sc_put "$SC_DIR" s.js 10
  sc_run "$SC_DIR" "s.js" --kind code --pre none --post index
  sc_eq "the index value (502) wins over the worktree (10)" "$(sc_rec s.js)" "$(sc_tsv HARD 502 0 300 500 lines)"
  sc_rc "staged 502 lines -> rc 1" 1
}

# sc_stage_then_put <path> <staged-n> <worktree-n> <tag> — stage one size, then leave another in the worktree.
sc_stage_then_put() {
  sc_put "$SC_DIR" "$1" "$2" "$4-idx"
  git -C "$SC_DIR" add -- "$1"
  sc_put "$SC_DIR" "$1" "$3" "$4-wt"
}

# big.js is 510 (over HARD) at HEAD; the index and the worktree always disagree on the verdict.
sc_case_pre_rev_with_post_index_ignores_the_worktree() {
  local idx=(--kind code --pre rev:HEAD --post index) wt=(--kind code --pre rev:HEAD --post worktree)
  sc_repo
  sc_put "$SC_DIR" big.js 510
  sc_commit "$SC_DIR"
  sc_put "$SC_DIR" big.js 505 shrunk
  git -C "$SC_DIR" add big.js
  sc_put "$SC_DIR" big.js 510
  sc_run "$SC_DIR" "big.js" "${idx[@]}"
  sc_eq "index shrunk to 505, worktree restored to HEAD: SHRINK by the index" "$(sc_rec big.js)" "$(sc_tsv SHRINK 505 510 300 500 lines)"
  sc_rc "index shrunk, worktree restored -> rc 0" 0
  sc_stage_then_put big.js 505 520 a
  sc_run "$SC_DIR" "big.js" "${idx[@]}"
  sc_eq "index shrunk to 505, worktree grown to 520: SHRINK by the index" "$(sc_rec big.js)" "$(sc_tsv SHRINK 505 510 300 500 lines)"
  sc_rc "index shrunk, worktree grown -> rc 0" 0
  sc_run "$SC_DIR" "big.js" "${wt[@]}"
  sc_eq "control: the same tree read --post worktree is HARD 520" "$(sc_rec big.js)" "$(sc_tsv HARD 520 510 300 500 lines)"
  sc_rc "control: --post worktree -> rc 1" 1
  sc_stage_then_put big.js 515 505 b
  sc_run "$SC_DIR" "big.js" "${idx[@]}"
  sc_eq "index grown to 515, worktree shrunk to 505: HARD by the index" "$(sc_rec big.js)" "$(sc_tsv HARD 515 510 300 500 lines)"
  sc_rc "index grown, worktree shrunk -> rc 1" 1
  sc_run "$SC_DIR" "big.js" "${wt[@]}"
  sc_eq "control: the same tree read --post worktree is SHRINK 505" "$(sc_rec big.js)" "$(sc_tsv SHRINK 505 510 300 500 lines)"
  sc_rc "control: --post worktree -> rc 0" 0
}

# sc_count <path> — how many records name <path>; sc_total — how many records there are.
sc_count() { printf '%s\n' "$SC_OUT" | awk -F'\t' -v p="$1" 'NF == 7 && $1 ~ /^(OK|WARN|SHRINK|HARD)$/ && $7 == p { n++ } END { print n + 0 }'; }
sc_total() { printf '%s\n' "$SC_OUT" | awk -F'\t' 'NF == 7 && $1 ~ /^(OK|WARN|SHRINK|HARD)$/ { n++ } END { print n + 0 }'; }

sc_case_input_edges() {
  sc_repo
  sc_put "$SC_DIR" empty.js 0
  sc_put "$SC_DIR" a.js 501
  sc_run "$SC_DIR" "" "${WT[@]}"
  sc_rc "empty stdin -> rc 0" 0
  sc_eq "empty stdin -> TARGETS 0" "$(sc_targets)" 0
  sc_run "$SC_DIR" "empty.js" "${WT[@]}"
  sc_eq "an empty file is OK at 0 lines" "$(sc_rec empty.js)" "$(sc_tsv OK 0 0 300 500 lines)"
  sc_rc "an empty file -> rc 0" 0
  sc_run "$SC_DIR" "a.js a.js" "${WT[@]}"
  sc_rc "a duplicated over-HARD path -> rc 1" 1
  sc_eq "a duplicated path: its record is HARD 501" "$(sc_rec a.js)" "$(sc_tsv HARD 501 0 300 500 lines)"
  sc_eq "a duplicated path: TARGETS equals the record count" "$(sc_targets)" "$(sc_total)"
  sc_eq "a duplicated path is counted once: TARGETS 1" "$(sc_targets)" 1
  sc_eq "a duplicated path is counted once: exactly one record" "$(sc_count a.js)" 1
  # The plan is silent on a missing path; fail-closed infrastructure error (rc 3, path named on
  # stderr) is chosen, and the pre-commit gate blocks on rc 3 without reading it as a verdict.
  sc_run "$SC_DIR" "ghost.js" "${WT[@]}"
  sc_rc "a nonexistent path -> rc 3 (infrastructure error)" 3
  if printf '%s' "$SC_ERR" | grep -qF ghost.js; then pass "a nonexistent path: stderr names ghost.js"
  else fail "a nonexistent path: stderr names ghost.js" "$(sc_show)"; fi
  if [ -z "$(printf '%s\n' "$SC_OUT" | awk -F'\t' '$1 == "HARD" && $7 == "ghost.js"')" ]; then pass "a nonexistent path has no HARD record"
  else fail "a nonexistent path has no HARD record" "$(sc_show)"; fi
}

sc_case_kind_prompt_and_docs_filters() {
  local paths="rules/x.md docs/a.md docs/history.md"
  sc_repo
  sc_put "$SC_DIR" rules/x.md 201
  sc_put "$SC_DIR" docs/a.md 301
  sc_put "$SC_DIR" docs/history.md 900
  sc_run "$SC_DIR" "$paths" --kind prompt --pre none --post worktree
  sc_eq "prompt: only rules/x.md is a target" "$(sc_targets)" 1
  sc_eq "prompt: rules/x.md is HARD at 201 over 200" "$(sc_rec rules/x.md)" "$(sc_tsv HARD 201 0 100 200 lines)"
  sc_rc "prompt: rc 1" 1
  sc_run "$SC_DIR" "$paths" --kind docs --pre none --post worktree
  sc_eq "docs: every non-exempt .md is a target (2)" "$(sc_targets)" 2
  if [ -n "$(sc_targets)" ] && [ -z "$(sc_rec docs/history.md)" ]; then pass "docs: history.md is exempt (no record)"
  else fail "docs: history.md is exempt (no record)" "$(sc_show)"; fi
  sc_eq "docs: docs/a.md is WARN at 301" "$(sc_rec docs/a.md)" "$(sc_tsv WARN 301 0 300 500 lines)"
  sc_rc "docs: rc 0" 0
}

sc_case_usage_and_infrastructure_errors() {
  local name args nogit
  sc_repo
  sc_put "$SC_DIR" a.js 3
  # usage name | args (sc_run feeds node its own stdin, so the table is not consumed)
  while IFS='|' read -r name args; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    # shellcheck disable=SC2086 # args is a word list on purpose
    sc_run "$SC_DIR" "a.js" $args
    sc_rc "usage error ($name) -> rc 2" 2
  done <<'EOF'
no --kind|--pre none --post worktree
unknown kind|--kind bogus --pre none --post worktree
unknown --pre form|--kind code --pre HEAD --post worktree
unknown --post|--kind code --pre none --post disk
unknown flag|--kind code --pre none --post worktree --frobnicate
EOF
  nogit="$TMP_ROOT/sc-not-a-repo/work"
  mkdir -p "$nogit"
  sc_put "$nogit" a.js 3
  SC_EXTRA_ENV="GIT_CEILING_DIRECTORIES=$TMP_ROOT/sc-not-a-repo"
  sc_run "$nogit" "a.js" --kind code --pre none --post index
  SC_EXTRA_ENV=""
  sc_rc "git failure (--post index outside a repo) -> rc 3" 3
  sc_run "$SC_DIR" "a.js" --kind code --pre rev:no-such-ref --post worktree
  sc_rc "unresolvable --pre rev -> rc 3" 3
}

# sc_run_bare <repo> <args...> — sc_run with CODE_FILE_EXTENSIONS removed and an empty stdin.
sc_run_bare() {
  local repo="$1"
  shift
  SC_RC=0
  SC_OUT="$(cd "$repo" && run_with_timeout 60 env -u CODE_FILE_EXTENSIONS node "$SIZE_CHECK" "$@" </dev/null 2>"$TMP_ROOT/sc.err")" || SC_RC=$?
  SC_OUT="$(printf '%s' "$SC_OUT" | tr -d '\r')"
  SC_ERR="$(cat "$TMP_ROOT/sc.err" 2>/dev/null || true)"
}

# The commit gate is the last line of defence: an inherited CODE_FILE_EXTENSIONS that drops .js
# narrows --kind (the premise) but must not narrow --staged-auto.
sc_case_staged_auto_ignores_env_extensions() {
  sc_repo
  sc_put "$SC_DIR" seed.txt 1
  sc_commit "$SC_DIR"
  sc_put "$SC_DIR" big.js 501
  git -C "$SC_DIR" add big.js
  SC_EXTRA_ENV="CODE_FILE_EXTENSIONS=txt"
  sc_run "$SC_DIR" "big.js" --kind code --pre rev:HEAD --post index
  sc_eq "premise: --kind code honours CODE_FILE_EXTENSIONS=txt (big.js is no target)" "$(sc_targets)" 0
  sc_run "$SC_DIR" "" --staged-auto
  SC_EXTRA_ENV=""
  sc_rc "--staged-auto with CODE_FILE_EXTENSIONS=txt: an over-HARD .js -> rc 1" 1
  sc_eq "--staged-auto with CODE_FILE_EXTENSIONS=txt: big.js is HARD 501" "$(sc_rec big.js)" "$(sc_tsv HARD 501 0 300 500 lines)"
  sc_run_bare "$SC_DIR" --staged-auto
  sc_rc "control: --staged-auto without CODE_FILE_EXTENSIONS -> rc 1" 1
  sc_eq "control: --staged-auto without CODE_FILE_EXTENSIONS: big.js is HARD 501" "$(sc_rec big.js)" "$(sc_tsv HARD 501 0 300 500 lines)"
}

# --staged-auto reads CODE_FILE_EXTENSIONS from the config .env (AGENTS_MAIN_ROOT/.env), like the
# edit-time hook and workflow-gate: an extension added there is checked, while process.env is ignored.
sc_case_staged_auto_follows_dotenv_extensions() {
  local root="$TMP_ROOT/sc-dotenv-root"
  mkdir -p "$root"
  printf 'CODE_FILE_EXTENSIONS=js;sh;py;ts\n' > "$root/.env"
  sc_repo
  sc_put "$SC_DIR" seed.txt 1
  sc_commit "$SC_DIR"
  sc_put "$SC_DIR" big.ts 501
  git -C "$SC_DIR" add big.ts
  SC_EXTRA_ENV="AGENTS_MAIN_ROOT=$root"
  sc_run "$SC_DIR" "" --staged-auto
  SC_EXTRA_ENV=""
  sc_rc ".env CODE_FILE_EXTENSIONS adds ts: an over-HARD .ts -> rc 1" 1
  sc_eq ".env CODE_FILE_EXTENSIONS adds ts: big.ts is HARD 501" "$(sc_rec big.ts)" "$(sc_tsv HARD 501 0 300 500 lines)"
  printf 'CODE_FILE_EXTENSIONS=js;sh;py\n' > "$root/.env"
  SC_EXTRA_ENV="AGENTS_MAIN_ROOT=$root"
  sc_run "$SC_DIR" "" --staged-auto
  SC_EXTRA_ENV=""
  sc_rc "control: .env without ts leaves an over-HARD .ts unchecked -> rc 0" 0
}
