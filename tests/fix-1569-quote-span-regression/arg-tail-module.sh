# tests/fix-1569-quote-span-regression/arg-tail-module.sh
# Tests: hooks/enforce-worktree/arg-tail-guard.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree/main-worktree-allows/standard.js
# Tags: worktree, enforce, hook, quote-spans, arg-tail, security, classifier, scope:issue-specific
#
# STATUS: 15 rows RED until C3 lands (6x ARG-accept rule-5, ARG-reject bare
# subshell, 6x RISK10-*-rule5, 2x RISK10-*-rule2); every other row GREEN today
# and must stay green. See the STATUS block in the parent dispatcher
# tests/fix-1569-quote-span-regression.sh.
#
# Direct-module assertions, split out of the parent per rules/coding/file-split.md.
# Sourced by tests/fix-1569-quote-span-regression.sh — uses its pass/fail,
# run_with_timeout, ACD/ACD_RAW, DISPATCH, EVIL, MAIN_WT and _AGENTS_DIR_NODE.

run_arg_tail_module_cases() {

# ============================================================================
# Arg-tail acceptance, asserted directly on isAllowedWorkerScriptInvocation.
#
# Why a direct-module section inside a full-hook file: at the hook boundary the
# rule-5 relaxation is not observable. A sanctioned invocation whose arg tail
# carries a quoted metacharacter and no repo write is allowed today anyway (the
# standard classifier sees no write), and one whose write targets a linked
# worktree is allowed by the standard classifier too. The ONLY place the
# relaxation changes an answer is the predicate itself — so it is pinned here.
#
# STATUS: the ARG-accept-* rows are RED until C3 lands (today the flat
# /\|\|&&|;|\$\(|`|<\(|>\(|\n/ scan in worker-script.js rejects them).
# The ARG-reject-* rows are GREEN today and must stay green.
# ============================================================================

arg_tail_probe() {
    run_with_timeout 30 env "AGENTS_CONFIG_DIR=$ACD" node -e '
      const path = require("path");
      const mod = path.join(process.argv[1], "hooks", "enforce-worktree",
                            "main-worktree-allows", "worker-script.js");
      let f;
      try { f = require(mod).isAllowedWorkerScriptInvocation; }
      catch (e) { console.log("ERROR: " + e.message); process.exit(0); }
      if (typeof f !== "function") { console.log("ERROR: isAllowedWorkerScriptInvocation not exported"); process.exit(0); }
      try { console.log(String(f(process.argv[2], process.argv[3]))); }
      catch (e) { console.log("ERROR: threw " + e.message); }
    ' "$_AGENTS_DIR_NODE" "$1" "$MAIN_WT" 2>&1
}

assert_arg_tail() {
    local label="$1" cmd="$2" want="$3" got
    got="$(arg_tail_probe "$cmd")"
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label (want=$want got=$got)"; fi
}

# Accepted: SET-A metacharacters that live inside a dq/sq span (rule 5).
assert_arg_tail "ARG-accept dq pipe"          "bash \"$DISPATCH\" --title \"a|b\""        true
assert_arg_tail "ARG-accept sq pipe"          "bash \"$DISPATCH\" --title 'a|b'"          true
assert_arg_tail "ARG-accept dq semicolon"     "bash \"$DISPATCH\" --title \"a;b\""        true
assert_arg_tail "ARG-accept dq ampersand"     "bash \"$DISPATCH\" --title \"a&b\""        true
assert_arg_tail "ARG-accept dq parens"        "bash \"$DISPATCH\" --title \"a (b) c\""    true
assert_arg_tail "ARG-accept dq unbalanced ("  "bash \"$DISPATCH\" --title \"a (b\""       true
assert_arg_tail "ARG-accept mixed foo\"|\"bar" "bash \"$DISPATCH\" --title foo\"|\"bar"   true
assert_arg_tail "ARG-accept escaped \\\$( in dq" "bash \"$DISPATCH\" --title \"a\\\$(b)\"" true
assert_arg_tail "ARG-accept plain tail"       "bash \"$DISPATCH\" --title ab"             true

# Rejected: the same characters unquoted (rule 3), substitution (rule 4),
# ANSI-C (rule 2), and unparseable tails (rule 1).
assert_arg_tail "ARG-reject bare pipe"        "bash \"$DISPATCH\" --title a|b"            false
assert_arg_tail "ARG-reject bare semicolon"   "bash \"$DISPATCH\" --title a;b"            false
assert_arg_tail "ARG-reject bare &&"          "bash \"$DISPATCH\" --title a&&b"           false
assert_arg_tail "ARG-reject bare ampersand"   "bash \"$DISPATCH\" --title a&b"            false
assert_arg_tail "ARG-reject bare subshell"    "bash \"$DISPATCH\" (b)"                    false
assert_arg_tail "ARG-reject dq cmdsubst"      "bash \"$DISPATCH\" --title \"\$(id)\""     false
assert_arg_tail "ARG-reject dq backtick"      "bash \"$DISPATCH\" --title \"\`id\`\""     false
assert_arg_tail "ARG-reject bare cmdsubst"    "bash \"$DISPATCH\" --title \$(id)"         false
assert_arg_tail "ARG-reject ansic piece"      "bash \"$DISPATCH\" --title \$'a|b'"        false
assert_arg_tail "ARG-reject unclosed dq"      "bash \"$DISPATCH\" --title \"unclosed"     false
assert_arg_tail "ARG-reject unclosed sq"      "bash \"$DISPATCH\" --title a|b'"           false
assert_arg_tail "ARG-reject non-sanctioned"   "bash \"$EVIL/issue-create-dispatch.sh\""   false
# #1191 module half of FP6b: the fast path must keep rejecting the bare pipe even
# though the tee target is a registered linked worktree (the hook still ALLOWs
# the command via the standard write-scope path — see FP6b above).
assert_arg_tail "ARG-reject #1191 tee into a linked worktree" \
    "ISSUE_CREATE_SKILL=1 bash \"$DISPATCH\" 2>&1 | tee \"$MAIN_WT/.wt/x/build.log\"" false

# ── the `&>` redirect exception, isolated on the worker-script profile ───────
# The profile table gives `worker-script` (and `overlay`) an `&>` exception and
# a SET-A reject set that does NOT contain a bare `>` — only `<(` / `>(`. The
# `sanctioned-bin` profile has allowRedirectAmpersand:false and rejects plain
# `>` / `<` outright. These four rows are the ONLY place that difference is
# observable; their `sanctioned-bin` counterparts are the RISK10-*-redirect
# rows below, and the two blocks must disagree. If a C3 refactor collapses the
# profiles into one table, one of the two blocks flips.
# The redirect target must sit in a registered linked worktree, otherwise the
# (c)/(d) write-scope tail rejects the command for an unrelated reason and the
# row stops being about the arg-tail guard at all.
assert_arg_tail "ARG-accept '&>' redirect (worker-script exception)" \
    "bash \"$DISPATCH\" --title ab &> \"$MAIN_WT/.wt/x/out.txt\""   true
assert_arg_tail "ARG-accept '&>>' redirect (worker-script exception)" \
    "bash \"$DISPATCH\" --title ab &>> \"$MAIN_WT/.wt/x/out.txt\""  true
assert_arg_tail "ARG-accept plain '>' redirect"         \
    "bash \"$DISPATCH\" --title ab > \"$MAIN_WT/.wt/x/out.txt\""    true
assert_arg_tail "ARG-reject '2>&1' (its & is not followed by >)" \
    "bash \"$DISPATCH\" --title ab 2>&1"                false
assert_arg_tail "ARG-reject trailing bare '&' (background)" \
    "bash \"$DISPATCH\" --title ab &"                   false
assert_arg_tail "ARG-reject process substitution '>('" \
    "bash \"$DISPATCH\" --title ab >(cat)"              false
assert_arg_tail "ARG-reject process substitution '<('" \
    "bash \"$DISPATCH\" --title ab <(cat)"              false

# ============================================================================
# Risk 10 — the `sanctioned-bin` profile micro-difference must survive C3.
#
# standard.js:341 (isAllowedComposeDocAppend) and standard.js:399-401
# (isAllowedClarifyGuardLoop) are two hand-written scans of the SAME shape,
# except that :399-401 rejects `&` a second time unconditionally. The plan
# folds both into rejectsUnsafeArgTail(argTail, "sanctioned-bin") and keeps the
# difference as the profile flag allowRedirectAmpersand:false — explicitly NOT
# collapsed. These rows pin the observable verdict of BOTH predicates so the
# merge cannot silently loosen one or tighten the other. All are GREEN today.
#
# Rule 5 (SET-A inside a dq/sq piece is ALLOWed) is a property of
# rejectsUnsafeToken, not of the profile table — the profile table only selects
# the SET-A reject set, the `&>` exception and the newline policy. So the
# relaxation reaches `sanctioned-bin` too, and the quoted/unquoted PAIRS below
# pin it in both directions for both predicates. `allowRedirectAmpersand:false`
# keeps `&>` rejected here while the worker-script rows above accept it.
# ============================================================================

mkdir -p "$ACD_RAW/bin"
touch "$ACD_RAW/bin/compose-doc-append-entry" \
      "$ACD_RAW/bin/github-issues/clarify-guard-loop.sh"
COMPOSE="$ACD/bin/compose-doc-append-entry"
CLARIFY="$ACD/bin/github-issues/clarify-guard-loop.sh"

# sanctioned_bin_probe <predicate-name> <command> -> "true" | "false" | "ERROR: ..."
sanctioned_bin_probe() {
    run_with_timeout 30 env "AGENTS_CONFIG_DIR=$ACD" node -e '
      const path = require("path");
      const mod = path.join(process.argv[1], "hooks", "enforce-worktree",
                            "main-worktree-allows", "standard.js");
      let f;
      try { f = require(mod)[process.argv[2]]; }
      catch (e) { console.log("ERROR: " + e.message); process.exit(0); }
      if (typeof f !== "function") { console.log("ERROR: " + process.argv[2] + " not exported"); process.exit(0); }
      try { console.log(String(f(process.argv[3], process.argv[4]))); }
      catch (e) { console.log("ERROR: threw " + e.message); }
    ' "$_AGENTS_DIR_NODE" "$1" "$2" "$MAIN_WT" 2>&1
}

assert_sanctioned_bin() {
    local label="$1" fn="$2" cmd="$3" want="$4" got
    got="$(sanctioned_bin_probe "$fn" "$cmd")"
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label (want=$want got=$got)"; fi
}

# :341 — compose-doc-append-entry
assert_sanctioned_bin "RISK10-341 compose plain arg tail" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --file CHANGELOG.md" true
assert_sanctioned_bin "RISK10-341 compose bare ampersand rejected" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --file CHANGELOG.md &" false
assert_sanctioned_bin "RISK10-341 compose '&>' redirect rejected" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --file CHANGELOG.md &> out.txt" false
assert_sanctioned_bin "RISK10-341 compose bare pipe rejected" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --file CHANGELOG.md | tee out.txt" false
assert_sanctioned_bin "RISK10-341 compose wrong script path rejected" \
    isAllowedComposeDocAppend "bash \"$EVIL/compose-doc-append-entry\" --file CHANGELOG.md" false
# allowRedirectAmpersand:false — `&>` stays rejected here (contrast: the
# ARG-accept '&>' row above, same characters, worker-script profile).
assert_sanctioned_bin "RISK10-341-redirect compose plain '>' rejected" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --file CHANGELOG.md > out.txt" false
assert_sanctioned_bin "RISK10-341-redirect compose '2>&1' rejected" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --file CHANGELOG.md 2>&1" false
# Rule 5 pairs: quoted SET-A ALLOW / same characters unquoted BLOCK.
assert_sanctioned_bin "RISK10-341-rule5 compose dq pipe accepted" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title \"a|b\"" true
assert_sanctioned_bin "RISK10-341-rule5 compose bare pipe rejected (pair)" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title a|b" false
assert_sanctioned_bin "RISK10-341-rule5 compose sq semicolon accepted" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title 'a;b'" true
assert_sanctioned_bin "RISK10-341-rule5 compose bare semicolon rejected (pair)" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title a;b" false
assert_sanctioned_bin "RISK10-341-rule5 compose dq ampersand accepted" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title \"a&b\"" true
assert_sanctioned_bin "RISK10-341-rule5 compose bare ampersand rejected (pair)" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title a&b" false
# Rule 4 is NOT relaxed by rule 5: SET-B inside dq is still rejected.
assert_sanctioned_bin "RISK10-341-rule4 compose dq cmdsubst still rejected" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title \"\$(id)\"" false
assert_sanctioned_bin "RISK10-341-rule4 compose dq backtick still rejected" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title \"\`id\`\"" false
# Rule 2: an ANSI-C piece is rejected regardless of what it contains.
assert_sanctioned_bin "RISK10-341-rule2 compose ansic rejected" \
    isAllowedComposeDocAppend "bash \"$COMPOSE\" --title \$'ab'" false

# :399-401 — clarify-guard-loop.sh (the extra unconditional `&` rejection)
assert_sanctioned_bin "RISK10-399 clarify plain arg tail" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" 1234" true
assert_sanctioned_bin "RISK10-399 clarify bare ampersand rejected" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" 1234 &" false
assert_sanctioned_bin "RISK10-399 clarify '&>' redirect rejected" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" 1234 &> out.txt" false
assert_sanctioned_bin "RISK10-399 clarify bare pipe rejected" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" 1234 | tee out.txt" false
assert_sanctioned_bin "RISK10-399 clarify wrong script path rejected" \
    isAllowedClarifyGuardLoop "bash \"$EVIL/clarify-guard-loop.sh\" 1234" false
# Symmetric with the :341 block above (CPR-ORTH): the two predicates share the
# `sanctioned-bin` profile, so every row here must answer identically to its
# RISK10-341-* twin. A divergence means the merge tightened or loosened one site.
assert_sanctioned_bin "RISK10-399-redirect clarify plain '>' rejected" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" 1234 > out.txt" false
assert_sanctioned_bin "RISK10-399-redirect clarify '2>&1' rejected" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" 1234 2>&1" false
assert_sanctioned_bin "RISK10-399-rule5 clarify dq pipe accepted" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" \"a|b\"" true
assert_sanctioned_bin "RISK10-399-rule5 clarify bare pipe rejected (pair)" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" a|b" false
assert_sanctioned_bin "RISK10-399-rule5 clarify sq semicolon accepted" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" 'a;b'" true
assert_sanctioned_bin "RISK10-399-rule5 clarify bare semicolon rejected (pair)" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" a;b" false
assert_sanctioned_bin "RISK10-399-rule5 clarify dq ampersand accepted" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" \"a&b\"" true
assert_sanctioned_bin "RISK10-399-rule5 clarify bare ampersand rejected (pair)" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" a&b" false
assert_sanctioned_bin "RISK10-399-rule4 clarify dq cmdsubst still rejected" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" \"\$(id)\"" false
assert_sanctioned_bin "RISK10-399-rule4 clarify dq backtick still rejected" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" \"\`id\`\"" false
assert_sanctioned_bin "RISK10-399-rule2 clarify ansic rejected" \
    isAllowedClarifyGuardLoop "bash \"$CLARIFY\" \$'ab'" false

# ============================================================================
# Integration pin: worker-script.js must consume the SELECTOR form.
#
# The behavioural rows above cannot see which fold is used — a worker-script
# that kept its private foldDqNewlines would answer identically on every input
# in this file. The kinds argument is a contract though: foldNewlinesInSpans is
# specified to REQUIRE it, and the plan names ["dq"] as the complete
# replacement for the deleted local helper. So the call shape is pinned on the
# source text itself. STATUS: RED until C3 lands (today line 137 reads
# `const scanTail = foldDqNewlines(argTail);` and the helper is defined at
# line 17 of the same file).
# ============================================================================

WORKER_SRC="$AGENTS_DIR/hooks/enforce-worktree/main-worktree-allows/worker-script.js"

assert_worker_src() {
    local label="$1" pattern="$2" want="$3" got=false
    if grep -Eq "$pattern" "$WORKER_SRC" 2>/dev/null; then got=true; fi
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label (want=$want got=$got for /$pattern/)"; fi
}

assert_worker_src "FOLDPIN worker-script calls foldNewlinesInSpans with a kinds selector" \
    'foldNewlinesInSpans\([^)]*\[[^]]*"dq"[^]]*\]' true
assert_worker_src "FOLDPIN the kinds selector is DQ-only (no sq/ansic widening)" \
    'foldNewlinesInSpans\([^)]*\[[^]]*"(sq|ansic)"' false
assert_worker_src "FOLDPIN local foldDqNewlines helper is gone (complete replacement)" \
    '^\s*function foldDqNewlines' false
assert_worker_src "FOLDPIN worker-script sources the fold from the quote-spans module" \
    'require\(.*quote-spans' true

}
