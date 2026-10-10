#!/usr/bin/env bash
# tests/hooks/feature-2265-allow-regression-corpus.sh
# Tests: hooks/bash-guard/judge.js, hooks/bash-guard/allow.js, hooks/bash-guard/detect.js, hooks/lib/allow-command-list.js, install/settings-allow-commands.txt, settings.json
# Tags: hook, bash-guard, self-script-allow, classifier, worktree, regression-corpus, scope:issue-specific, pwsh-not-required, TL2

set -uo pipefail

# #2265: the classifier must cover every spelling the retired #2421 generator and the #2451
# static rules allowed (bash -c wrappers, linked worktrees), so the static rules can go.

# TL3 gap (what this test does NOT catch):
# - Whether Claude Code honours the allow envelope (skips the prompt) --
#   probed by tests/hooks/TL3-hook-bash-guard-envelope.sh.
# - Drive-letter and MSYS cwd folding (win32-only branches) -- feature-2134 W1 win/msys rows.
# - Entries added to the SSOT after this snapshot; the corpus is frozen data.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

# Pinned before the harness: an inherited SCRIPT_CHECKOUT_ROOT would point at another checkout.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
PART_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2265-allow-regression-corpus"

# fx_build <tmp> builds, under <tmp>:
#   main    git checkout: the real SSOT pair + every entry file, plus bin/fx-diverge (bash shebang)
#   fx-wt   linked worktree of main; its working tree ALONE lists bin/fx-wt-only and turns
#           bin/fx-diverge into a node script, so a MAIN-based answer differs from a WT-based one
#   foreign an unrelated git repo with the same layout; fx-fakewt a worktree of foreign
#   plain   the same layout with no .git; main/vendor/nested a foreign repo nested inside main
# and exports FX_MAIN FX_WT FX_FOREIGN FX_PLAIN FX_FAKEWT FX_NESTED (node-form paths) and
# FX_SESSION, a settled workflow session so the early-write-gate interlock stays quiet.

FX_STEPS="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate"

fx_settled_state() {
  local sid="$1" step steps=""
  for step in $FX_STEPS; do
    steps="$steps,\"$step\":{\"status\":\"complete\",\"updated_at\":null}"
  done
  printf '{"version":1,"session_id":"%s","created_at":"2026-01-01T00:00:00.000Z","is_bugfix":false,"git_branch":"feature/2265-fixture","steps":{%s},"workflow_type":"wf-code"}' \
    "$sid" "${steps#,}" > "$WORKFLOW_STATE_DIR/$sid.json"
}

# fx_layout <dst>: the real SSOT pair and every entry it lists, copied from the checkout under test.
fx_layout() {
  local dst="$1" entry
  mkdir -p "$dst/install"
  cp "$SCRIPT_CHECKOUT_ROOT/install/settings-allow-commands.txt" "$SCRIPT_CHECKOUT_ROOT/install/path-exposed-commands.txt" "$dst/install/"
  while IFS= read -r entry; do
    entry="${entry%%$'\r'}"
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    mkdir -p "$dst/$(dirname "$entry")"
    cp "$SCRIPT_CHECKOUT_ROOT/$entry" "$dst/$entry"
  done < "$SCRIPT_CHECKOUT_ROOT/install/settings-allow-commands.txt"
  # The corpus also covers bin/workflow/handoff-append, the entry #2265 adds to the SSOT; its
  # file is copied even while the list does not name it, so only the list decides the verdict.
  mkdir -p "$dst/bin/workflow"
  cp "$SCRIPT_CHECKOUT_ROOT/bin/workflow/handoff-append" "$dst/bin/workflow/handoff-append"
  printf '#!/usr/bin/env bash\necho diverge\n' > "$dst/bin/fx-diverge"
  printf 'bin/fx-diverge\n' >> "$dst/install/settings-allow-commands.txt"
}

fx_commit() {
  git -C "$1" config core.autocrlf false
  git -C "$1" add -A
  git -C "$1" -c user.email=fixture@example.com -c user.name=fixture commit -qm fixture
}

fx_build() {
  local tmp="$1"
  harness_git_init "$tmp/main"
  fx_layout "$tmp/main"
  fx_commit "$tmp/main"
  git -C "$tmp/main" worktree add -q "$tmp/fx-wt" 2>/dev/null
  printf '#!/usr/bin/env node\nconsole.log("diverge");\n' > "$tmp/fx-wt/bin/fx-diverge"
  printf '#!/usr/bin/env bash\necho wt-only\n' > "$tmp/fx-wt/bin/fx-wt-only"
  printf 'bin/fx-wt-only\n' >> "$tmp/fx-wt/install/settings-allow-commands.txt"

  harness_git_init "$tmp/foreign"
  fx_layout "$tmp/foreign"
  printf 'bin/fx-wt-only\n' >> "$tmp/foreign/install/settings-allow-commands.txt"
  printf '#!/usr/bin/env bash\necho foreign\n' > "$tmp/foreign/bin/fx-wt-only"
  fx_commit "$tmp/foreign"
  git -C "$tmp/foreign" worktree add -q "$tmp/fx-fakewt" 2>/dev/null

  fx_layout "$tmp/plain"
  harness_git_init "$tmp/main/vendor/nested"
  fx_layout "$tmp/main/vendor/nested"

  FX_MAIN="$(np "$tmp/main")"
  FX_WT="$(np "$tmp/fx-wt")"
  FX_FOREIGN="$(np "$tmp/foreign")"
  FX_PLAIN="$(np "$tmp/plain")"
  FX_FAKEWT="$(np "$tmp/fx-fakewt")"
  FX_NESTED="$(np "$tmp/main/vendor/nested")"
  FX_SESSION="sid-2265-corpus"
  fx_settled_state "$FX_SESSION"
  export FX_MAIN FX_WT FX_FOREIGN FX_PLAIN FX_FAKEWT FX_NESTED FX_SESSION
}

# fx_check <name> <want> <got>: a named equality assert on top of the harness reporters.
fx_check() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi
}

# fx_field <output> <line-prefix> <key> -> the key=value on the first line starting with prefix
# (e.g. fx_field "$OUT" "FAMILY env " fail). Prints <absent> when the line or key is missing.
fx_field() {
  local out="$1" prefix="$2" key="$3" line
  while IFS= read -r line; do
    [[ "$line" == "$prefix"* ]] || continue
    if [[ " $line " =~ \ $key=([^ ]*)\  ]]; then printf '%s' "${BASH_REMATCH[1]}"; return; fi
  done <<< "$out"
  printf '<absent>'
}

# fx_row <output> <id> -> "PASS want=.. got=.." / "FAIL ..." for one table row, <absent> if it never ran.
fx_row() {
  local out="$1" id="$2" line
  while IFS= read -r line; do
    [[ "$line" == "ROW $id "* ]] && { printf '%s' "${line#ROW "$id" }"; return; }
  done <<< "$out"
  printf '<absent>'
}

# fx_run <mode-flag> <file> -> run-corpus.js output against the fixture.
fx_run() {
  run_with_timeout 300 node "$(np "$PART_DIR/run-corpus.js")" \
    "$1" "$(np "$2")" --main "$FX_MAIN" --wt "$FX_WT" --foreign "$FX_FOREIGN" --plain "$FX_PLAIN" \
    --fakewt "$FX_FAKEWT" --session "$FX_SESSION"
}

# The corpus carries UNQUOTED <R> spellings (abs, win-unq), which only name the root when it has
# no space; a spaced temp dir moves that fixture to a space-free one instead of aborting.
# Spaced roots are covered on purpose by cases-space-root.sh.
FX_BASE="$(make_tmp)"
FX_TMP="$FX_BASE"
case "$FX_TMP" in *" "*) FX_TMP="$(mktemp -d /tmp/fx-2265.XXXXXX)" ;; esac
trap 'rm -rf "$FX_BASE" "$FX_TMP"' EXIT
harness_isolate "$FX_BASE/state"
cd "$FX_TMP" || exit 1
fx_build "$FX_TMP"

. "$PART_DIR/cases-corpus.sh"
. "$PART_DIR/cases-worktree.sh"
. "$PART_DIR/cases-space-root.sh"

case_begin "settings-json-static-rules-removed" "settings.json"
# The corpus owns the exact 206 #2451 strings, so no hand-written rule is caught here.
LEFT="$(node -e '
const fs = require("fs");
const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
const stat = new Set(rows.filter((r) => (r.sources || []).includes("static-2451")).map((r) => r.rule));
const allow = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).permissions.allow;
process.stdout.write(String(allow.filter((r) => stat.has(r)).length));
' "$(np "$PART_DIR/corpus.jsonl")" "$(np "$SCRIPT_CHECKOUT_ROOT/settings.json")")"
fx_check "settings.json: none of the 206 #2451 static rules remain" "0" "$LEFT"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
