#!/usr/bin/env bash
# tests/bin/feature-2631-review-size-bins/all-scan.sh — the --all bodies of
# tests/bin/feature-2631-review-size-bins.sh (case markers stay in the entry file). Sourced after the
# entry defines TREE, TMP_ROOT, run_bin, put and make_lines. --all is advisory: always rc 0.

# as_has <name> <fixed-string> — OUT carries the string.
as_has() {
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then pass "$1"
  else fail "$1" "missing '$2' in: $(printf '%s' "$OUT" | head -c 400)"; fi
}

# as_line <name> <verdict> <path> — one OUT line carries both the verdict word and the path.
as_line() {
  if printf '%s\n' "$OUT" | grep -F -- "$3" | grep -q "$2:"; then pass "$1"
  else fail "$1" "no '$2:' line naming $3 in: $(printf '%s' "$OUT" | head -c 400)"; fi
}

# as_rc0 <name> — the advisory contract: --all exits 0 whatever it finds.
as_rc0() {
  if [ "$RC" = 0 ]; then pass "$1"; else fail "$1" "rc=$RC out=$(printf '%s' "$OUT" | head -c 400)"; fi
}

# bin | empty-tree header | file kind | WARN path:n | HARD path:n | OK path:n
AS_TABLE=(
  "review-code-size|SKIPPED — no code files found|code|bin/w.js:301|bin/h.js:501|bin/ok.js:10"
  "review-prompt-size|SKIPPED — no prompt files found|prompt|rules/w.md:101|rules/h.md:201|rules/ok.md:10"
  "review-doc-size|PERFORMED (all-scan mode)|docs|docs/w.md:301|docs/h.md:501|docs/ok.md:10"
)

as_case_empty_tree() {
  local row bin empty rest dir
  for row in "${AS_TABLE[@]}"; do
    IFS='|' read -r bin empty rest <<<"$row"
    dir="$(mktemp -d "$TMP_ROOT/empty.XXXXXX")"
    run_bin "$TREE" "$dir" "$bin" --all
    as_rc0 "$bin --all on an empty tree exits 0"
    as_has "$bin --all on an empty tree reports '$empty'" "$empty"
    if printf '%s\n' "$OUT" | grep -qE '(HARD|WARN):'; then fail "$bin --all on an empty tree names no finding" "$OUT"
    else pass "$bin --all on an empty tree names no finding"; fi
  done
}

as_case_mixed_tree() {
  local row bin empty kind warn hard ok dir spec
  for row in "${AS_TABLE[@]}"; do
    IFS='|' read -r bin empty kind warn hard ok <<<"$row"
    dir="$(mktemp -d "$TMP_ROOT/mixed.XXXXXX")"
    for spec in "$warn" "$hard" "$ok"; do put "$dir" "${spec%:*}" make_lines "${spec##*:}"; done
    run_bin "$TREE" "$dir" "$bin" --all
    as_rc0 "$bin --all with a $kind HARD file still exits 0 (advisory)"
    as_has "$bin --all on a mixed tree is PERFORMED (all-scan mode)" "PERFORMED (all-scan mode)"
    as_line "$bin --all names ${hard%:*} as HARD" HARD "${hard%:*}"
    as_line "$bin --all names ${warn%:*} as WARN" WARN "${warn%:*}"
    as_has "$bin --all says its findings are advisory" "advisory"
    if printf '%s\n' "$OUT" | grep -F -- "${ok%:*}" | grep -qE '(HARD|WARN):'; then fail "$bin --all gives ${ok%:*} no finding" "$OUT"
    else pass "$bin --all gives ${ok%:*} no finding"; fi
  done
}

# as_case_newline_name — an over-HARD code file whose name holds a newline. Known gap (#2631):
# review_size_worktree_nul reads find's output one line at a time, so the name splits in two and
# neither half exists; the correct report is pinned with xfail_contains until the bin uses -print0.
as_case_newline_name() {
  local dir nl=$'\n' name hard_lines
  dir="$(mktemp -d "$TMP_ROOT/newline.XXXXXX")"
  name="bin/nl${nl}x.js"
  if ! { mkdir -p "$dir/bin" && make_lines 501 > "$dir/$name"; } 2>/dev/null \
    || ! node -e 'process.exit(require("fs").existsSync(process.argv[1]) ? 0 : 1)' "$(np "$dir")/$name"; then
    skip "--all reports a newline-named over-HARD file — this filesystem cannot hold a file name with a newline (Windows maps it to another character)"
    return 0
  fi
  put "$dir" bin/plain.js make_lines 501
  run_bin "$TREE" "$dir" review-code-size --all
  as_rc0 "review-code-size --all with a newline-named HARD file still exits 0 (advisory)"
  as_line "control: review-code-size --all names the plain bin/plain.js as HARD" HARD bin/plain.js
  hard_lines="$(printf '%s\n' "$OUT" | grep -F 'HARD:' || true)"
  xfail_contains "review-code-size --all names the newline-named bin/nl...x.js as HARD" "bin/nl" "$hard_lines"
}
