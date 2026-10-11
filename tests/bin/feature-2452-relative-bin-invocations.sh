#!/usr/bin/env bash
# tests/bin/feature-2452-relative-bin-invocations.sh
# Tests: CLAUDE.md, rules/shell-commands.md, rules/test/macos-timeout.md, skills/run-tests/SKILL.md, skills/clarify-intent/SKILL.md, skills/commit-push/SKILL.md, skills/session-close/SKILL.md, skills/worktree-end/SKILL.md
# Tags: TL2, bin, skills, rules, agents, prompt, command-form, relative-path, scope:issue-specific, pwsh-not-required
# #2452: prompt assets show commands the model copies verbatim. A relative `bin/...` invocation
# exits 127 whenever the cwd is not the agents checkout (a Codex verdict was silently voided this
# way), and the `bash -c 'cd "$AGENTS_MAIN_ROOT" && ...'` confirm-off probe falls to a permission
# ask. Both must be written in the standalone absolute form.

# TL3 gap (what this test does NOT catch): whether the model actually issues the absolute form;
# only the prompt text is scanned. Forbidden literals in general are left to the #2266 classifier.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
unset CLAUDE_CODE_SESSION_ID

ck() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

# rb_scan <root> -> "file:line: <code>" per relative bin/ invocation in skills/ rules/ agents/ **/*.md
# and CLAUDE.md; bin/ may be spelled ./bin/. Inline span: first token bin/x with >=1 argument, or
# node|bash bin/x. Fence line: node|bash bin/x anywhere, a line starting bin/x <arg>, or ./bin/x <arg>
# after a separator. Absolute ($VAR/bin/...) and argument-less name-only references never match.
cat > "$TMPROOT/rb-scan.js" <<'EOF'
const fs = require("fs"), path = require("path");
const root = process.argv[2];
const files = [];
const walk = (rel) => {
  const abs = path.join(root, rel);
  if (!fs.existsSync(abs)) return;
  for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
    const r = rel + "/" + e.name;
    if (e.isDirectory()) walk(r); else if (e.name.endsWith(".md")) files.push(r);
  }
};
["skills", "rules", "agents"].forEach(walk);
if (fs.existsSync(path.join(root, "CLAUDE.md"))) files.push("CLAUDE.md");
const SPAN = /^(?:(?:node|bash)\s+(?:\.\/)?bin\/\S+.*|(?:\.\/)?bin\/\S+\s+\S.*)$/;
const FENCE = /(?:^|[\s;&|(])(?:node|bash)\s+(?:\.\/)?bin\/|^\s*(?:\.\/)?bin\/\S+\s+\S|(?:^|[\s;&|(])\.\/bin\/\S+\s+\S/;
const out = [];
for (const f of files.sort()) {
  let inFence = false;
  fs.readFileSync(path.join(root, f), "utf8").split(/\r?\n/).forEach((line, i) => {
    if (/^\s*(```|~~~)/.test(line)) { inFence = !inFence; return; }
    if (inFence) { if (FENCE.test(line)) out.push(f + ":" + (i + 1) + ": " + line.trim()); return; }
    for (const m of line.matchAll(/`([^`]+)`/g)) {
      if (SPAN.test(m[1].trim())) out.push(f + ":" + (i + 1) + ": " + m[1].trim());
    }
  });
}
process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
EOF
rb_scan() { node "$(np "$TMPROOT/rb-scan.js")" "$(np "$1")"; }

# rb_cd_probe <root> -> "file:line" per `bash -c 'cd "$AGENTS_MAIN_ROOT" && ...` command form in skills/
rb_cd_probe() { (cd "$1" && grep -rnF --include='*.md' -- "bash -c 'cd \"\$AGENTS_MAIN_ROOT\" &&" skills 2>/dev/null) | cut -d: -f1,2; }

echo "=== negative controls: the scanner separates relative from absolute and name-only ==="
case_begin "NC-scanner" "rules/shell-commands.md"
# Row: <hit|miss>|<skills|rules|agents|tests|CLAUDE>|<span|fence>|<markdown line>. Each row gets its
# own fixture file; a fence row is wrapped in a ```bash block, so its line is 2, a span row's is 1.
NC_ROWS=(
  'hit|skills|span|Run `bin/workflow/next-step --list`.'
  'hit|skills|span|Then `node bin/print-forbidden-literals --markdown-table`.'
  'hit|skills|span|Or `bash bin/select-tests.sh`.'
  'hit|skills|span|Run `./bin/workflow/next-step --list`.'
  'hit|skills|span|Then `node ./bin/print-forbidden-literals --markdown-table`.'
  'hit|skills|span|Or `bash ./bin/select-tests.sh --all`.'
  'hit|rules|fence|bin/run-with-timeout.sh 180 bash t.sh'
  'hit|rules|fence|node bin/workflow/next-step --session S'
  'hit|rules|fence|./bin/run-with-timeout.sh 180 bash t.sh'
  'hit|rules|fence|cd x && ./bin/audit-tests.sh --dup-groups'
  'hit|agents|fence|bash ./bin/select-tests.sh --all'
  'hit|CLAUDE|span|After each skill: `node bin/workflow/next-step --session $CLAUDE_CODE_SESSION_ID`.'
  'miss|agents|span|Run `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --list`.'
  'miss|agents|span|Gate: `"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off`.'
  'miss|agents|span|Run `"$AGENTS_MAIN_ROOT/bin/run-with-timeout.sh" 180 bash t.sh`.'
  'miss|agents|span|`bin/resolve-merge-base.sh` resolves the base.'
  'miss|agents|span|See `bin/workflow/`.'
  'miss|agents|span|See `./bin/workflow/next-step`.'
  'miss|agents|span|Run `tests/bin/feature-2452-relative-bin-invocations.sh --verbose`.'
  'miss|rules|fence|node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --list'
  'miss|rules|fence|"$AGENTS_MAIN_ROOT/bin/run-with-timeout.sh" 180 bash t.sh'
  'miss|rules|fence|bash tests/bin/feature-2452-relative-bin-invocations.sh'
  'miss|rules|fence|echo x'
  'miss|tests|span|Run `bin/workflow/next-step --list`.'
  'miss|tests|fence|./bin/run-with-timeout.sh 180 bash t.sh'
)
FX="$TMPROOT/fx"
NC_REL=()
NC_LN=()
NC_HITS=0
for idx in "${!NC_ROWS[@]}"; do
  IFS='|' read -r want dir kind text <<< "${NC_ROWS[$idx]}"
  case "$dir" in
    CLAUDE) rel="CLAUDE.md" ;;
    skills) rel="skills/r$idx/SKILL.md" ;;
    *) rel="$dir/r$idx.md" ;;
  esac
  mkdir -p "$(dirname "$FX/$rel")"
  if [ "$kind" = "fence" ]; then printf '%s\n' '```bash' "$text" '```' > "$FX/$rel"; NC_LN+=(2)
  else printf '%s\n' "$text" > "$FX/$rel"; NC_LN+=(1); fi
  NC_REL+=("$rel")
  [ "$want" = "hit" ] && NC_HITS=$((NC_HITS + 1))
done
RB_FX="$(rb_scan "$FX")"
for idx in "${!NC_ROWS[@]}"; do
  IFS='|' read -r want dir kind text <<< "${NC_ROWS[$idx]}"
  case $'\n'"$RB_FX" in
    *$'\n'"${NC_REL[$idx]}:${NC_LN[$idx]}:"*) got="hit" ;;
    *) got="miss" ;;
  esac
  ck "NC[$idx] $kind in $dir: $text" "$want" "$got"
done
ck "NC: the scanner reports exactly the $NC_HITS hit rows and nothing else" "$NC_HITS" \
  "$(printf '%s\n' "$RB_FX" | grep -c .)"
FX_CD="$TMPROOT/fx-cd"
mkdir -p "$FX_CD/skills/a"
printf '%s\n' 'x' "Probe: \`bash -c 'cd \"\$AGENTS_MAIN_ROOT\" && bash \"\$AGENTS_MAIN_ROOT/bin/confirm-off\" KEY on'\`" \
  'Probe: `bash "$AGENTS_MAIN_ROOT/bin/confirm-off" KEY on`' > "$FX_CD/skills/a/SKILL.md"
ck "NC: the cd-prefixed confirm-off probe is found, the standalone form is not" "skills/a/SKILL.md:2" \
  "$(rb_cd_probe "$FX_CD" | tr '\n' ' ' | sed 's/ $//')"
case_end

echo "=== real tree ==="
case_begin "PC-absolute-get-config-var" "rules/test/claude-e2e.md"
if grep -qF -- '"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var"' "$SCRIPT_CHECKOUT_ROOT/rules/test/claude-e2e.md"; then
  pass "PC: rules/test/claude-e2e.md carries the absolute get-config-var form (positive control input present)"
else fail "PC: rules/test/claude-e2e.md carries the absolute get-config-var form" "fixture line gone; pick a new control"; fi
ck "PC: the scanner does not report rules/test/claude-e2e.md" "" \
  "$(rb_scan "$SCRIPT_CHECKOUT_ROOT" | grep -F 'rules/test/claude-e2e.md:')"
case_end

case_begin "RB-no-relative-bin" "skills/run-tests/SKILL.md"
RB_REAL="$(rb_scan "$SCRIPT_CHECKOUT_ROOT")"
if [ -z "$RB_REAL" ]; then pass "RB: no relative bin/ invocation in skills/ rules/ agents/ CLAUDE.md"
else fail "RB: no relative bin/ invocation in skills/ rules/ agents/ CLAUDE.md" \
  "$(printf '%s\n' "$RB_REAL" | grep -c .) found:"$'\n'"$RB_REAL"; fi
case_end

case_begin "RB-no-cd-confirm-off-probe" "skills/clarify-intent/SKILL.md"
ck "RB: no skill wraps the confirm-off probe in bash -c 'cd \"\$AGENTS_MAIN_ROOT\" && ...'" "" \
  "$(rb_cd_probe "$SCRIPT_CHECKOUT_ROOT" | tr '\n' ' ')"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
