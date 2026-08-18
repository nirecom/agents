#!/usr/bin/env bash
# lang-check: ignore -- rows intentionally accept English/Japanese for the same regex needle (see below).
# tests/fix-1689-run-tests-contract.sh
# Tests: skills/run-tests/SKILL.md, rules/test.md
# Tags: run-tests, prompt-contract, merge-base, ssot, recovery, static, scope:issue-specific, pwsh-not-required, TL2

# Pins RNT-1's merge-base delegation (#1638), RNT-9's non-coercive recovery (#1689), and RNT-3's
# Tier 2 degraded-range contract (#1779) in skills/run-tests/SKILL.md -- prompt-only logic with no
# other test, so rows assert load-bearing tokens (script names, flags, sentinels, exit codes)
# rather than wording, and accept English/Japanese equally.

# TL3 gap: whether a model actually follows/reaches the instruction, or whether the named commands
# work in a real repo, is not checked here -- see WORKFLOW_USER_VERIFIED preflight
# (bin/check-verification-gate.sh category: skill-orchestration).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$AGENTS_DIR/skills/run-tests/SKILL.md"
TEST_RULES="$AGENTS_DIR/rules/test.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  echo "FAIL: precondition — $SKILL does not exist"
  echo ""
  echo "Total: 0 passed, 1 failed"
  exit 1
fi

# Scopes each assertion to one RNT-<n> step's text, so a token found anywhere in the file proves
# nothing about where a model will actually read it.
rnt_section() { # <n> ; prints the section text
  awk -v n="$1" '
    $0 ~ "^RNT-" n "\\." { inside = 1; print; next }
    inside && ($0 ~ /^RNT-[0-9]+\./ || $0 ~ /^## /) { inside = 0 }
    inside { print }
  ' "$SKILL"
}

rules_section() { # prints the `## Rules` block
  awk '/^## Rules/ { inside = 1; next } inside && /^## / { inside = 0 } inside { print }' "$SKILL"
}

# `--` before the pattern: several patterns below start with a flag literal (`--explain`,
# `--format base`), which grep would otherwise parse as its own option.
expect_match() { # <row> <desc> <ere> <text>
  if printf '%s' "$4" | grep -qiE -- "$3"; then pass "$1: $2"; else fail "$1: $2 -- nothing matches /$3/"; fi
}

expect_no_match() { # <row> <desc> <ere> <text>
  if printf '%s' "$4" | grep -qiE -- "$3"; then fail "$1: $2 -- /$3/ is still present"; else pass "$1: $2"; fi
}

RNT1="$(rnt_section 1)"
RNT2="$(rnt_section 2)"
RNT3="$(rnt_section 3)"
RNT9="$(rnt_section 9)"
RULES="$(rules_section)"

# Non-empty check first: an awk range that matched nothing would make every expect_no_match row
# below pass for free.
for _pair in "RNT-1:$RNT1" "RNT-2:$RNT2" "RNT-3:$RNT3" "RNT-9:$RNT9" "Rules:$RULES"; do
  _name="${_pair%%:*}"
  _body="${_pair#*:}"
  if [ -n "$(printf '%s' "$_body" | tr -d '[:space:]')" ]; then
    pass "S0[$_name]: the section was located and is non-empty"
  else
    fail "S0[$_name]: the section is empty or missing, so no assertion about it means anything"
  fi
done

# ---- #1638: RNT-1 delegates, and no longer carries its own chain ------------

expect_match "S1" "RNT-1 delegates merge-base resolution to select-tests.sh --auto" \
  'select-tests\.sh[[:space:]]+--auto' "$RNT1"
expect_match "S2" "and names the resolver that owns the chain" \
  'resolve-merge-base\.sh' "$RNT1"

# Each row below is one line of the old reimplemented chain; any one left behind is a second
# source of truth a model may follow instead (CPR-SSOT).
expect_no_match "S3a" "RNT-1 no longer reimplements the origin/main attempt" \
  'merge-base[[:space:]]+origin/main' "$RNT1"
expect_no_match "S3b" "nor the local main attempt" \
  'merge_base=\$\(git merge-base main HEAD\)' "$RNT1"
expect_no_match "S3c" "nor the HEAD~1 fallback" \
  'merge_base=HEAD~1' "$RNT1"
expect_no_match "S3d" "nor its own git fetch" \
  'git fetch origin main' "$RNT1"

# ---- #1638: exit 4 has a way out, and it survives the re-run ---------------

expect_match "S4" "RNT-1 documents the exit code that stops the run" \
  'exit[[:space:]]*4' "$RNT1"
expect_match "S5" "and presents the resolver's own explanation to the user" \
  '--explain' "$RNT1"
# Recovery is only real if the approved base is persisted; otherwise re-running hits exit 4 again.
expect_match "S6" "the approved base is recorded through the approval CLI" \
  'record-merge-base-baseline' "$RNT1"
expect_match "S7" "and RNT-1 is re-run afterwards rather than skipped past" \
  're-?run|re-?execute|再実行|やり直' "$RNT1"
expect_match "S8" "aborting is an option, and it leaves the step pending" \
  'pending' "$RNT1"

# RNT-2 must consume the same one-liner, with no variable left over from the deleted chain.
expect_match "S9" "RNT-2 calls select-tests.sh --auto" \
  'select-tests\.sh[[:space:]]+--auto' "$RNT2"
expect_no_match "S9b" "and no longer passes the deleted \$merge_base variable" \
  'select-tests\.sh[[:space:]]+"?\$\{?merge_base' "$RNT2"

# #1779: Tier 1/Tier 2 must resolve the SAME range, via --format kv (not the old bare --format
# base, which reads as HEAD on a zero-commit branch and silently reviews nothing).
expect_match "S10" "RNT-3 asks the resolver for the kv block, not just a base" \
  '--format[[:space:]]+kv' "$RNT3"
expect_match "S10b" "and reads base_is_head, so a zero-commit branch is detectable at all" \
  'base_is_head' "$RNT3"
expect_match "S10c" "the degraded change set includes untracked files" \
  'ls-files[[:space:]]+--others' "$RNT3"
expect_match "S10d" "and when the field is absent RNT-3 settles it locally" \
  'rev-parse' "$RNT3"
expect_match "S10d2" "naming absence as the condition rather than a false value" \
  'absent' "$RNT3"
expect_no_match "S10e" "RNT-3 no longer carries the bare --format base form" \
  '--format[[:space:]]+base' "$RNT3"
expect_match "S10f" "and reads untracked content through the no-index form" \
  'no-index' "$RNT3"

# Tracked half of the degraded range, pinned in both halves Tier 2 needs: file names (for the
# `# Tests:` overlap check) and diff body (for `# Tags:` subsystem matching).
expect_match "S10g" "RNT-3 takes the tracked file names from git diff HEAD, not a bare git diff" \
  'diff[[:space:]]+HEAD[[:space:]]+--name-only|diff[[:space:]]+--name-only[[:space:]]+HEAD' "$RNT3"
expect_match "S10h" "and the tracked diff BODY from git diff HEAD as well, not just the names" \
  'diff[[:space:]]+body.*git[[:space:]]+diff[[:space:]]+HEAD' "$RNT3"

# OWASP LLM01: file content read during degraded-range selection is untrusted input arriving in
# the model's context, so RNT-3 has to say both what it IS (data) and what it is NOT (instructions).
expect_match "S10i" "RNT-3 frames file content read during selection as data" \
  'inert|as data|data only|データとして' "$RNT3"
expect_match "S10j" "and never as instructions to act on" \
  '(never|not|must not|do not|no)[^.]*instruction|指示として' "$RNT3"

# S10b-S10h assert token presence; the rows below assert the MAPPING (verdict bound to its range
# in the same clause), since presence alone lets a model guess wrong and reproduce #1779.
RNT3_FLAT="$(printf '%s' "$RNT3" | tr '\n' ' ')"

expect_match "S10k" "RNT-3 binds the true verdict to the working-tree range" \
  '(true.{0,80}(diff[[:space:]]+HEAD|ls-files)|(diff[[:space:]]+HEAD|ls-files).{0,80}true)' "$RNT3_FLAT"
expect_match "S10l" "and the false verdict to the committed <base>...HEAD range" \
  '(false.{0,80}(\.\.\.[[:space:]]*HEAD|merge_base)|(\.\.\.[[:space:]]*HEAD|merge_base).{0,80}false)' "$RNT3_FLAT"
expect_match "S10m" "and an absent field to the model deriving the answer itself" \
  '(absent.{0,80}rev-parse|rev-parse.{0,80}absent)' "$RNT3_FLAT"

# `--exclude-standard` is easy to drop as noise; without it `ls-files --others` reports every
# gitignored path (node_modules, build output) and Tier 2 reads their contents into context.
expect_match "S10n" "the untracked enumeration excludes gitignored paths by flag, not by hope" \
  'ls-files[[:space:]]+--others[[:space:]]+--exclude-standard|ls-files[[:space:]]+--exclude-standard[[:space:]]+--others' "$RNT3"

# ---- the degraded range reads files nobody vetted: secrets ------------------

# OWASP ASVS V8: the untracked set on a zero-commit branch is the least-vetted set in the repo
# (fresh .env, pasted tokens), and --exclude-standard does not guard it. Three rows because the
# contract has three parts: S10o names the hazard, S10p binds it to an action, S10q scopes the
# guard so it doesn't become a blanket ban on untracked content (which would reinstate #1779).
expect_match "S10o" "RNT-3 names credential-shaped content as a hazard of the degraded range" \
  'secret|credential|api[_ -]?key|private key|\.env|認証情報|機密' "$RNT3"

RNT3_FLAT2="$(printf '%s' "$RNT3" | tr '\n' ' ')"
expect_match "S10p" "and binds it to excluding or redacting before the content is read out" \
  '((secret|credential|api[_ -]?key|private key|\.env).{0,80}(exclud|redact|skip|omit|除外|伏せ)|(exclud|redact|skip|omit|除外|伏せ)[^.]{0,80}(secret|credential|api[_ -]?key|private key|\.env))' "$RNT3_FLAT2"

expect_no_match "S10q" "and the guard does not become a blanket ban on untracked content" \
  '(never|do not|don.t|must not)[[:space:]]+(read|open|include)[^.]{0,40}untracked|skip[[:space:]]+all[[:space:]]+untracked' "$RNT3"

# ---- the degraded range enumerates filenames: argument injection ------------

# Tier 1's equivalent is checked behaviourally (zero-commit-hostile-paths.sh); Tier 2 is prose, so
# the same CWE-88 hazards are pinned as literals: S10r NUL-delimits enumeration (a newline in a
# filename must not split it), S10s terminates options before a path reaches git (a `-o`-named
# file must not be read as a flag), S10t names the hazard so a model preserves the terminator.
expect_match "S10r" "RNT-3 enumerates untracked paths NUL-delimited, so a newline in a name cannot split it" \
  'ls-files.*(-z|--null)|NUL[- ]?(delimit|separat|terminat|byte)|zero[- ]?byte' "$RNT3"
expect_match "S10s" "and terminates options before the path reaches git" \
  'no-index[[:space:]]+--[[:space:]]' "$RNT3"
expect_match "S10t" "naming the filenames that make the terminator necessary" \
  'leading[- ](dash|hyphen)|option[- ]?(terminat|injection)|metachar|word[- ]split|newline|改行' "$RNT3"

expect_match "S11" "the Rules section names the resolver as the single source of truth" \
  'resolve-merge-base\.sh' "$RULES"

# ---- #1689: the surgical recovery, and its price ---------------------------

# The retired MARK_STEP sentinel is replaced by the advance CLI (`--advance --step run_tests
# --complete`), which reports `ADVANCED=run_tests status=complete` / `ADVANCE_SCOPE=` on stdout --
# see tests/feature-1644-run-tests-docs-only.sh D5b and
# tests/feature-1644-advance-transaction/basic.sh A1a for the same shape asserted elsewhere.
expect_match "S12" "RNT-9 settles a pass through the advance CLI (--step run_tests --complete), not the retired MARK_STEP sentinel" \
  '--advance[[:space:]]+--step[[:space:]]+run_tests[[:space:]]+--complete' "$RNT9"
expect_match "S13" "and the pending sentinel on failure" \
  '<<WORKFLOW_MARK_STEP_run_tests_pending>>' "$RNT9"

expect_match "S14" "RNT-9 documents a recovery for failures unrelated to the diff" \
  'unrelated|pre-?existing|無関係|既存' "$RNT9"

# Evidence, item by item: which test failed, what it touches, that the diff range excludes those
# paths, and that main reproduces the same failure -- each rules out a different wrong conclusion.
expect_match "S15a" "the evidence includes which tests failed" \
  'failing[_ -]?tests?|test name|失敗テスト' "$RNT9"
expect_match "S15b" "the paths the failure touches" \
  'path|パス' "$RNT9"
expect_match "S15c" "that those paths are outside the resolved diff range" \
  'resolve-merge-base\.sh|--format[[:space:]]+base|diff' "$RNT9"
expect_match "S15d" "and that the same failure reproduces on main" \
  'main' "$RNT9"
expect_match "S16" "the evidence is required in the same turn as the sentinel" \
  'same turn|同一ターン|同じターン' "$RNT9"
expect_match "S17" "and without the evidence the step stays pending for the user to judge" \
  'pending' "$RNT9"

# The prohibition separating this surgical recovery from a workflow-wide escape hatch.
expect_match "S18" "RNT-9 forbids the session-wide OFF sentinel for this purpose" \
  'WORKFLOW_ENFORCE_WORKFLOW_OFF|EMERGENCY[_ ]OFF' "$RNT9"
if printf '%s' "$RULES" | grep -qE 'WORKFLOW_ENFORCE_WORKFLOW_OFF|OFF sentinel|EMERGENCY[_ ]OFF'; then
  pass "S19: the Rules section repeats the prohibition where a model looks for rules"
else
  fail "S19: the Rules section does not name the OFF sentinel it is prohibiting"
fi
expect_match "S20" "and scopes the recovery to the run_tests step alone" \
  'run_tests' "$RULES"

# ---- shape: the file stays a prompt --------------------------------------

# rules/coding/file-split.md Pattern B: prompts WARN at 100 lines, HARD at 200.
SKILL_LINES="$(grep -c '' "$SKILL" || true)"
if [ "$SKILL_LINES" -le 200 ]; then
  pass "S21: SKILL.md is within the hard prompt-size limit ($SKILL_LINES lines, limit 200)"
else
  fail "S21: SKILL.md is $SKILL_LINES lines, past the 200-line hard split limit for prompts"
fi

# rules/prompt.md forbids fenced code blocks of 3+ lines in a prompt.
FENCES="$(grep -c '^```' "$SKILL" || true)"
if [ "$FENCES" = "0" ]; then
  pass "S22: and carries no fenced code block — the sentinels stay inline literals"
else
  fail "S22: SKILL.md contains $FENCES fence line(s); the additions must be prose with inline literals"
fi

# ---- the risk-category SSOT description ------------------------------------

if [ ! -f "$TEST_RULES" ]; then
  fail "S23: rules/test.md does not exist"
elif grep -qF "merge-base-suspect" "$TEST_RULES"; then
  pass "S23: rules/test.md lists the new merge-base-suspect risk category"
else
  fail "S23: rules/test.md does not mention merge-base-suspect, so its category listing is stale"
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
