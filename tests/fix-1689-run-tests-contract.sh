#!/usr/bin/env bash
# tests/fix-1689-run-tests-contract.sh
# Tests: skills/run-tests/SKILL.md, rules/test.md
# Tags: run-tests, prompt-contract, merge-base, ssot, recovery, static, scope:issue-specific, pwsh-not-required, TL2
#
# Issues #1638 / #1689 — the two halves of skills/run-tests/SKILL.md that are PROMPT rather than
# code, and therefore have no other test.
#
# WHY A PROMPT NEEDS A TEST AT ALL. Everything this skill does at runtime is done by an LLM
# reading these instructions. There is no function to call and no exit code to assert, so a
# sentence that goes missing in a later edit fails silently and permanently: the model simply
# does the old thing, or invents something. The two sentences at stake here are the ones whose
# absence caused the issues in the first place.
#
#   #1638 — RNT-1 CARRIED ITS OWN merge-base CHAIN. Five lines of prose reimplementing
#   `origin/main` → `main` → `HEAD~1`. That is a second implementation of a fact that now has an
#   owner (bin/resolve-merge-base.sh), and it is the copy that produced the 280k-line range: it
#   had no anomaly check, no recorded baseline and no way to stop. The rows below pin the
#   REPLACEMENT — one reference to the resolver — and, just as importantly, pin the REMOVAL: as
#   long as the old chain is still written here, a model reading the file can follow either one,
#   and CPR-SSOT is violated whatever the resolver does.
#
#   #1689 — RNT-9 HAD NO NON-COERCIVE RECOVERY. When the suite fails for a reason the diff did
#   not cause (a pre-existing failure on main), the only documented outcomes were `pending`
#   forever or reaching for a session-wide OFF sentinel — which suspends every guard in the
#   workflow to get past one step. So the rows pin the surgical alternative AND its price:
#   evidence, in the same turn, that the failure is unrelated. A recovery mechanism documented
#   without its evidence requirement is just permission to mark a failing suite complete.
#
# S10-S10t additionally cover #1779: RNT-3's Tier 2 range on a branch that has not committed yet,
# and the three things reading unreviewed files costs — the prompt-injection framing (S10i/S10j),
# the credential-leak guard on content nobody vetted (S10o-S10q), and argument-safe enumeration of
# filenames the model hands back to git (S10r-S10t).
#
# WHAT THESE ROWS DELIBERATELY DO NOT DO. They do not check wording. Every assertion is on a
# token that is load-bearing for the reader — a script name, a flag, a sentinel literal, an exit
# code — because those are what a model must reproduce exactly, and they survive rewording and
# translation. Prose-level regexes accept both English and Japanese for the same reason: the
# repository's prompts are English today, and a row that fails on a faithful translation would
# be testing the author's language rather than the contract.
#
# TL3 gap (what this test does NOT catch):
# - whether a model actually FOLLOWS the instruction. Every row here matches text in a file; RNT-3
#   and RNT-9 are executed by an LLM, and a contract that is present, correctly worded and
#   consistently ignored passes this suite completely.
# - whether the instruction is reachable in context. The rows read the whole section from disk; a
#   model reads it after the file has been truncated, summarised or compacted, and a token that is
#   present at line 40 of SKILL.md is not necessarily a token the model saw.
# - whether the commands the prose names produce the intended result in a real repository. `git
#   diff HEAD --name-only`, `git ls-files --others --exclude-standard` and `git diff --no-index`
#   are asserted as literals here; nothing runs them, so a form that is correct English and wrong
#   git passes.
# - the Tier 1 / Tier 2 agreement itself. This file pins Tier 2's half of the range contract and
#   tests/feature-689-select-tests.sh pins Tier 1's; that the two ranges are the SAME range on a
#   live zero-commit branch is only observable with a model in the loop.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

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

# One RNT step's text: from its own `RNT-<n>.` line up to the next `RNT-` step or the next `##`
# heading. Scoping every assertion to a step is what makes the rows specific — a token found
# anywhere in a 60-line file proves nothing about where a model will read it.
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

# The sections have to be non-empty before anything is asserted about them: an awk range that
# matched nothing would make every expect_no_match row below pass for free.
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

# The removal, item by item. Each of these is one line of the old chain, and any one of them
# left behind is a second source of truth a model may follow instead.
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
# The recovery is only real if the approved base is PERSISTED: re-running without recording it
# hits exit 4 again forever, which is the dead end the first draft had.
expect_match "S6" "the approved base is recorded through the approval CLI" \
  'record-merge-base-baseline' "$RNT1"
expect_match "S7" "and RNT-1 is re-run afterwards rather than skipped past" \
  're-?run|re-?execute|再実行|やり直' "$RNT1"
# Abort is a documented outcome too. Without it the only way out of a base the user does not
# trust is to approve one anyway.
expect_match "S8" "aborting is an option, and it leaves the step pending" \
  'pending' "$RNT1"

# RNT-2 must consume the same one-liner, with no variable left over from the deleted chain.
expect_match "S9" "RNT-2 calls select-tests.sh --auto" \
  'select-tests\.sh[[:space:]]+--auto' "$RNT2"
expect_no_match "S9b" "and no longer passes the deleted \$merge_base variable" \
  'select-tests\.sh[[:space:]]+"?\$\{?merge_base' "$RNT2"

# Tier 1 and Tier 2 must look at the SAME range. They are resolved by different commands, so
# without this line Tier 2 can re-resolve to a different base and silently review a different
# set of files than Tier 1 selected tests for.
#
# #1779 moves this from `--format base` to `--format kv`. A bare base is exactly enough
# information to reproduce the bug: on a branch with no commits the base IS HEAD, `<base>...HEAD`
# is empty, and Tier 2 reviews nothing while reporting success. Tier 2 is an LLM reading prose,
# so unlike Tier 1 it cannot be fixed in code — the instruction has to carry the field, the
# untracked half, and the fallback for a resolver too old to answer.
expect_match "S10" "RNT-3 asks the resolver for the kv block, not just a base" \
  '--format[[:space:]]+kv' "$RNT3"
expect_match "S10b" "and reads base_is_head, so a zero-commit branch is detectable at all" \
  'base_is_head' "$RNT3"
# `git diff HEAD` cannot see an untracked file. On a branch this young a brand-new file is the
# likeliest thing there is, so the tracked half alone silently drops it.
expect_match "S10c" "the degraded change set includes untracked files" \
  'ls-files[[:space:]]+--others' "$RNT3"
# The field is new: an older resolver omits it entirely, and an absent field must not be read
# as false — that is the answer that reproduces the bug.
expect_match "S10d" "and when the field is absent RNT-3 settles it locally" \
  'rev-parse' "$RNT3"
expect_match "S10d2" "naming absence as the condition rather than a false value" \
  'absent' "$RNT3"
# The exclusivity half of S10, in the same shape as S3a-S3d: as long as the old `--format base`
# instruction is still written here, a model can follow either one and CPR-SSOT is violated
# whatever the resolver does.
expect_no_match "S10e" "RNT-3 no longer carries the bare --format base form" \
  '--format[[:space:]]+base' "$RNT3"
# Reading an untracked file's content needs `git diff --no-index`; plain `git diff` has nothing
# to compare it against, so without this the diff BODY half of Tier 2 sees only tracked files.
expect_match "S10f" "and reads untracked content through the no-index form" \
  'no-index' "$RNT3"

# S10c/S10f are the UNTRACKED half of the degraded range. The tracked half needs pinning
# separately and in both of its parts, because Tier 2 does two different things with it and a
# `git diff HEAD` written for only one of them is a real and silent failure mode:
#
#   file names   without `git diff HEAD --name-only` the `# Tests:` overlap check has no tracked
#                paths to overlap against, and a bare `git diff` (index vs working tree) reports
#                NOTHING on the fully-staged branch #1779 was reported from.
#   diff body    without the body, `# Tags:` subsystem matching — the entire reason Tier 2 exists
#                on top of Tier 1's stem match — has nothing to read.
expect_match "S10g" "RNT-3 takes the tracked file names from git diff HEAD, not a bare git diff" \
  'diff[[:space:]]+HEAD[[:space:]]+--name-only|diff[[:space:]]+--name-only[[:space:]]+HEAD' "$RNT3"
expect_match "S10h" "and the tracked diff BODY from git diff HEAD as well, not just the names" \
  'diff[[:space:]]+body.*git[[:space:]]+diff[[:space:]]+HEAD' "$RNT3"

# Tier 2 is an LLM, and the degraded range hands it the contents of files that were never
# reviewed or committed — including brand-new untracked ones read through `git diff --no-index`.
# That is untrusted input arriving inside the same context as the instructions, which is OWASP
# LLM01 (see skills/_shared/test-design.md "Prompt injection"). The instruction block therefore
# has to say what the content IS (data to classify) and what it is NOT (something to obey);
# either half alone leaves the reading ambiguous, so they are two rows.
expect_match "S10i" "RNT-3 frames file content read during selection as data" \
  'inert|as data|data only|データとして' "$RNT3"
expect_match "S10j" "and never as instructions to act on" \
  '(never|not|must not|do not|no)[^.]*instruction|指示として' "$RNT3"

# S10b-S10h assert that the TOKENS are present somewhere in RNT-3. Presence is not the contract:
# a section that names `base_is_head`, the committed range and the working-tree range in three
# unrelated sentences satisfies every row above while telling the model nothing about WHICH range
# goes with WHICH verdict — and a model that guesses wrong reproduces #1779 (true → committed
# range) or breaks every ordinary branch (false → working tree). The three rows below pin the
# mapping itself.
#
# They match over the section with newlines collapsed to spaces, inside an 80-character window.
# The window is what makes it a mapping assertion rather than another presence assertion: the
# verdict and its range have to sit in the same clause. Both orders are accepted because
# "if base_is_head is true, use X" and "use X when base_is_head is true" are the same instruction.
RNT3_FLAT="$(printf '%s' "$RNT3" | tr '\n' ' ')"

expect_match "S10k" "RNT-3 binds the true verdict to the working-tree range" \
  '(true.{0,80}(diff[[:space:]]+HEAD|ls-files)|(diff[[:space:]]+HEAD|ls-files).{0,80}true)' "$RNT3_FLAT"
# The symmetric half, and the one whose absence is invisible: `false` is what every ordinary
# branch carries, so a mapping that only documents the true case leaves the common path to
# inference. `...HEAD` is the committed range's own literal — the range Tier 1 selected from.
expect_match "S10l" "and the false verdict to the committed <base>...HEAD range" \
  '(false.{0,80}(\.\.\.[[:space:]]*HEAD|merge_base)|(\.\.\.[[:space:]]*HEAD|merge_base).{0,80}false)' "$RNT3_FLAT"
# Absence is a third verdict, not a synonym for false (S10d/S10d2 pin the tokens; this pins that
# they belong together — the local observation is what an absent field is answered with).
expect_match "S10m" "and an absent field to the model deriving the answer itself" \
  '(absent.{0,80}rev-parse|rev-parse.{0,80}absent)' "$RNT3_FLAT"

# `--exclude-standard` is one flag, it is easy to drop as noise, and without it `ls-files --others`
# reports every gitignored path in the tree: node_modules, build output, local scratch. Tier 2
# would then semantically match subsystems nobody changed and, worse, READ those files' contents
# into the model's context as part of the degraded diff body. Tier 1's equivalent is asserted
# behaviourally in tests/feature-689-select-tests/zero-commit-boundaries.sh (S22/S23); Tier 2 has
# no behaviour to assert, so the flag is pinned as a literal.
expect_match "S10n" "the untracked enumeration excludes gitignored paths by flag, not by hope" \
  'ls-files[[:space:]]+--others[[:space:]]+--exclude-standard|ls-files[[:space:]]+--exclude-standard[[:space:]]+--others' "$RNT3"

# ---- the degraded range reads files nobody vetted: secrets ------------------
#
# S10i/S10j settle how the content is TREATED once it is in context (data, never instructions).
# They say nothing about WHICH files get there, and on a zero-commit branch the untracked set is
# the least-vetted set in the repository: `.env` written five minutes ago, a downloaded service
# -account key, a scratch file with a bearer token pasted into it. `--exclude-standard` (S10n) is
# not the guard — it drops what .gitignore names, and a secret nobody has gitignored yet is
# exactly the one that is still untracked. `git diff --no-index` then reads the whole body into
# the model's context, from where it reaches the transcript, the tool log and any summary the run
# produces. That is OWASP ASVS V8 secret leakage (skills/_shared/test-design.md), and it is a one
# -way door: a credential that reached a log is a credential to rotate.
#
# Three rows, because the contract has three parts and each fails differently on its own:
#   S10o  the class is named at all — a guard that never says what it is guarding against is
#         read as generic caution and skipped.
#   S10p  the class is BOUND to an action (exclude or redact). Naming secrets while telling the
#         model nothing to do about them is worse than silence: it reads as an acknowledgement.
#   S10q  the guard is SCOPED. "Do not read untracked content" would satisfy S10o and S10p and
#         destroy the fix — untracked content is the whole reason RNT-3 changed (S10f), and on a
#         branch this young most files are untracked. The guard has to cost the secret files
#         only.
expect_match "S10o" "RNT-3 names credential-shaped content as a hazard of the degraded range" \
  'secret|credential|api[_ -]?key|private key|\.env|認証情報|機密' "$RNT3"

RNT3_FLAT2="$(printf '%s' "$RNT3" | tr '\n' ' ')"
expect_match "S10p" "and binds it to excluding or redacting before the content is read out" \
  '((secret|credential|api[_ -]?key|private key|\.env).{0,80}(exclud|redact|skip|omit|除外|伏せ)|(exclud|redact|skip|omit|除外|伏せ)[^.]{0,80}(secret|credential|api[_ -]?key|private key|\.env))' "$RNT3_FLAT2"

# The scoping half, as a negative: a blanket ban on untracked content passes every positive row
# above while reinstating #1779 for every new file. S10c/S10f stay green alongside this row —
# together they are the statement "read untracked content, except the credential-shaped ones".
expect_no_match "S10q" "and the guard does not become a blanket ban on untracked content" \
  '(never|do not|don.t|must not)[[:space:]]+(read|open|include)[^.]{0,40}untracked|skip[[:space:]]+all[[:space:]]+untracked' "$RNT3"

# ---- the degraded range enumerates filenames: argument injection ------------
#
# Tier 1 gets this checked behaviourally — tests/feature-689-select-tests/zero-commit-hostile-
# paths.sh (S27) puts a leading-dash, a newline and a space into real filenames and runs the real
# selector over them. Tier 2 has no code to run, so the same three hazards have to be pinned as
# instructions, and they are not cosmetic here: RNT-3 is the only step that takes an enumerated
# path and hands it back to git as an ARGUMENT (`git diff --no-index -- /dev/null <path>`).
#
#   S10r  newline-delimited enumeration splits `a\nb.sh` into two paths that do not exist. The
#         fix is one flag, and it is the flag a reader drops as noise.
#   S10s  a file named `-o` or `--output=x` is read by git as an option unless the invocation is
#         option-terminated. This is CWE-88 argument injection, and it is the same class the
#         selector's own positional form already validates against (bin/select-tests.sh:105) and
#         that the resolver format-validates the recorded baseline for.
#   S10t  the hazard has to be named, not just defended against by a flag the model may
#         reformat away. A model that understands WHY the terminator is there keeps it when it
#         rewrites the command; one that copied a literal drops it.
expect_match "S10r" "RNT-3 enumerates untracked paths NUL-delimited, so a newline in a name cannot split it" \
  'ls-files.*(-z|--null)|NUL[- ]?(delimit|separat|terminat|byte)|zero[- ]?byte' "$RNT3"
# `--no-index` itself contains a `--`, so the pattern requires a STANDALONE `--` token after it:
# that is the option terminator, and nothing else in the form looks like it.
expect_match "S10s" "and terminates options before the path reaches git" \
  'no-index[[:space:]]+--[[:space:]]' "$RNT3"
expect_match "S10t" "naming the filenames that make the terminator necessary" \
  'leading[- ](dash|hyphen)|option[- ]?(terminat|injection)|metachar|word[- ]split|newline|改行' "$RNT3"

# The Rules section is where a model looks for the prohibition rather than the procedure.
expect_match "S11" "the Rules section names the resolver as the single source of truth" \
  'resolve-merge-base\.sh' "$RULES"

# ---- #1689: the surgical recovery, and its price ---------------------------

# `RECORDED=`/`<<WORKFLOW_MARK_STEP_run_tests_complete>>` is retired: the advance CLI now
# settles a pass through `next-step --advance --step run_tests --status complete`, which
# reports its own result as `ADVANCED=run_tests status=complete` (plus `ADVANCE_SCOPE=`) on
# stdout at runtime -- see tests/feature-1644-run-tests-docs-only.sh D5b and
# tests/feature-1644-advance-transaction/basic.sh A1a for the same shape asserted elsewhere.
# This row pins the SKILL.md prose that drives that call.
expect_match "S12" "RNT-9 settles a pass through the advance CLI (--step run_tests --status complete), not the retired MARK_STEP sentinel" \
  '--advance[[:space:]]+--step[[:space:]]+run_tests[[:space:]]+--status[[:space:]]+complete' "$RNT9"
expect_match "S13" "and the pending sentinel on failure" \
  '<<WORKFLOW_MARK_STEP_run_tests_pending>>' "$RNT9"

# The recovery itself: a failure the diff did not cause.
expect_match "S14" "RNT-9 documents a recovery for failures unrelated to the diff" \
  'unrelated|pre-?existing|無関係|既存' "$RNT9"

# The evidence, item by item, because each one rules out a different wrong conclusion: the test
# name says WHAT failed, the paths say what it touches, the diff range says the change did not
# touch them, and main says the failure was already there.
expect_match "S15a" "the evidence includes which tests failed" \
  'failing[_ -]?tests?|test name|失敗テスト' "$RNT9"
expect_match "S15b" "the paths the failure touches" \
  'path|パス' "$RNT9"
expect_match "S15c" "that those paths are outside the resolved diff range" \
  'resolve-merge-base\.sh|--format[[:space:]]+base|diff' "$RNT9"
expect_match "S15d" "and that the same failure reproduces on main" \
  'main' "$RNT9"
# Evidence is worthless if it can be produced later, after the sentinel is already accepted.
expect_match "S16" "the evidence is required in the same turn as the sentinel" \
  'same turn|同一ターン|同じターン' "$RNT9"
# And the default when the evidence cannot be produced has to be spelled out, or the recovery
# reads as the ordinary way to get past a red suite.
expect_match "S17" "and without the evidence the step stays pending for the user to judge" \
  'pending' "$RNT9"

# The prohibition. This is the row that separates a surgical recovery from a workflow-wide
# escape hatch: WORKFLOW_ENFORCE_WORKFLOW_OFF suspends every guard for the whole session,
# including the outbound-content scan's neighbours, to get past one step.
expect_match "S18" "RNT-9 forbids the session-wide OFF sentinel for this purpose" \
  'WORKFLOW_ENFORCE_WORKFLOW_OFF|EMERGENCY[_ ]OFF' "$RNT9"
# Case-sensitive and specific: a bare case-insensitive `off` would be satisfied by any word
# containing it, so this row would start passing on an unrelated edit.
if printf '%s' "$RULES" | grep -qE 'WORKFLOW_ENFORCE_WORKFLOW_OFF|OFF sentinel|EMERGENCY[_ ]OFF'; then
  pass "S19: the Rules section repeats the prohibition where a model looks for rules"
else
  fail "S19: the Rules section does not name the OFF sentinel it is prohibiting"
fi
expect_match "S20" "and scopes the recovery to the run_tests step alone" \
  'run_tests' "$RULES"

# ---- shape: the file stays a prompt --------------------------------------

# rules/coding/file-split.md Pattern B: prompts WARN at 100 lines, HARD at 200. The additions
# above are prose, and a prompt that has to be split is a prompt a model reads less of.
SKILL_LINES="$(grep -c '' "$SKILL" || true)"
if [ "$SKILL_LINES" -le 200 ]; then
  pass "S21: SKILL.md is within the hard prompt-size limit ($SKILL_LINES lines, limit 200)"
else
  fail "S21: SKILL.md is $SKILL_LINES lines, past the 200-line hard split limit for prompts"
fi

# rules/prompt.md forbids code blocks of three or more lines in a prompt: a fenced block invites
# a model to execute it verbatim instead of reading the instruction around it.
FENCES="$(grep -c '^```' "$SKILL" || true)"
if [ "$FENCES" = "0" ]; then
  pass "S22: and carries no fenced code block — the sentinels stay inline literals"
else
  fail "S22: SKILL.md contains $FENCES fence line(s); the additions must be prose with inline literals"
fi

# ---- the risk-category SSOT description ------------------------------------

# rules/test.md names the current risk categories in prose while pointing at the classifier as
# the SSOT. A category added to the classifier and not reflected here leaves the prose listing
# stale, which is what a reader consults before the code.
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
