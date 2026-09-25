# Part of tests/feature-833-check-verification-gate.sh (sourced, not standalone).
# Tests: bin/check-verification-gate.sh
# Tags: verification-gate, risk-category, merge-base, degradation, scope:issue-specific, pwsh-required, TL2
#
# W (#1638) — THE REST OF THE STATE TABLE, and the two ways the resolver answers badly.
#
# V2/V3/V4/V6 cover one trustworthy state (RESOLVED), one untrustworthy state (SUSPECT), a
# resolver that gave up (exit 3) and a resolver that is not installed. The table has five
# states and the resolver has two other failure modes, and the ones left out are not
# interchangeable with the ones covered:
#
#   RECORDED is the state the #1638 fix makes NORMAL. Once a baseline is recorded at branching
#   time, nearly every real invocation of this classifier arrives here. If RECORDED is not on
#   the trusted side of the branch, the everyday path narrows to uncommitted changes and asks
#   the user about a subset of what the session did — at the last gate before commit, where
#   there is no later opportunity to notice. V2 cannot catch that: RESOLVED and RECORDED come
#   from different layers of the resolver and an implementation can trust one and not the other.
#
#   FALLBACK is HEAD~1 — a base chosen because nothing better was found. It is untrustworthy for
#   a completely different reason than SUSPECT (SUSPECT resolved something implausible; FALLBACK
#   never resolved anything), and the two are separate tokens in the resolver precisely so
#   consumers can treat them differently. This classifier must treat them the SAME, and that is
#   an assertion, not an assumption.
#
#   EXIT 2 is a usage error: this classifier passed arguments the resolver rejected. Distinct
#   from exit 3 (the resolver ran and had no answer) because the cause is on the CALLER's side —
#   a flag renamed, an argument order changed. The tempting reading is "the resolver is broken,
#   so ignore it and carry on with the full committed range", which is the silent wrong-scope
#   bug with extra steps.
#
#   MALFORMED OUTPUT is exit 0 with something unparseable on stdout — a resolver that printed a
#   warning, a partially written kv block, a shell error captured into stdout. An implementation
#   that greps for `base=` and uses whatever it finds ends up with an empty or garbage base and
#   hands it to `git diff`, which then either errors or silently produces nothing. Empty is the
#   dangerous outcome: no files, no categories, no questions, and a clean exit.
#
# EVERY ROW ASSERTS FOUR THINGS, because they fail independently: which range was classified
# (via the disjoint category sets setup_v_repo builds), whether the narrowing was declared as a
# category, whether it was announced on stderr, and that the exit code is still 0 — a resolver
# problem is a caveat for the user, never a failure of the classifier.

# The parent file provides pass/fail only, so the equality form used below is defined here.
w_check() { # <desc> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi
}

# Both sides of the trust boundary assert the same shape, so it is written once.
w_expect_committed_scope() { # <row-id>
  local row="$1" problems=""
  echo "$V_TOKENS" | grep -q "skill-orchestration" || problems="$problems [missing:skill-orchestration]"
  echo "$V_TOKENS" | grep -q "installer" && problems="$problems [unexpected:installer]"
  echo "$V_TOKENS" | grep -q "merge-base-suspect" && problems="$problems [unexpected:merge-base-suspect]"
  if [ -z "$problems" ]; then
    pass "$row: a trustworthy base classifies the COMMITTED range and declares no caveat"
  else
    fail "$row: problems$problems tokens=[$V_TOKENS] rc=$V_RC stderr=[$(head -2 <<< "$V_ERR")]"
  fi
  if grep -q "narrowed to uncommitted changes" <<< "$V_ERR"; then
    fail "$row-stderr: a narrowing notice was printed although nothing was narrowed -- [$V_ERR]"
  else
    pass "$row-stderr: and prints no narrowing notice"
  fi
  w_check "$row-rc: with the ordinary verdict exit code" "0" "$V_RC"
}

w_expect_narrowed_scope() { # <row-id>
  local row="$1" problems=""
  echo "$V_TOKENS" | grep -q "installer" || problems="$problems [missing:installer]"
  echo "$V_TOKENS" | grep -q "merge-base-suspect" || problems="$problems [missing:merge-base-suspect]"
  echo "$V_TOKENS" | grep -q "skill-orchestration" && problems="$problems [unexpected:skill-orchestration]"
  if [ -z "$problems" ]; then
    pass "$row: narrows to uncommitted changes and declares merge-base-suspect"
  else
    fail "$row: problems$problems tokens=[$V_TOKENS] rc=$V_RC stderr=[$(head -2 <<< "$V_ERR")]"
  fi
  if grep -q "narrowed to uncommitted changes" <<< "$V_ERR"; then
    pass "$row-stderr: and the narrowing is announced on stderr for the skill's log"
  else
    fail "$row-stderr: no narrowing notice on stderr -- [$V_ERR]"
  fi
  # A narrowed scope is a smaller question set, not an error: exiting non-zero here would
  # abort the preflight instead of asking the user a narrower question.
  w_check "$row-rc: and the classifier still exits 0" "0" "$V_RC"
}

# --- W1: RECORDED — the state the fix makes ordinary — is on the trusted side.
setup_tmp
setup_v_bin
v_repo="$TMP/v-repo"
setup_v_repo "$v_repo"
run_v_gate "$v_repo" RECORDED 0
w_expect_committed_scope "W1-RECORDED"
teardown_tmp

# --- W2: FALLBACK — a base nobody chose — degrades exactly like SUSPECT.
setup_tmp
setup_v_bin
v_repo="$TMP/v-repo"
setup_v_repo "$v_repo"
run_v_gate "$v_repo" FALLBACK 0
w_expect_narrowed_scope "W2-FALLBACK"
teardown_tmp

# --- W3: resolver exit 2 (this classifier called it wrongly). The caller's bug must not
#         become the user's silently-wider question set.
setup_tmp
setup_v_bin
v_repo="$TMP/v-repo"
setup_v_repo "$v_repo"
run_v_gate "$v_repo" - 2
w_expect_narrowed_scope "W3-exit2"
teardown_tmp

# --- W4: exit 0 with output that is not the kv contract. The failure mode this guards is an
#         EMPTY base extracted from garbage: `git diff ...HEAD` against nothing yields no
#         files, no categories and a clean exit — a pass at the last gate before commit.
setup_tmp
setup_v_bin
v_repo="$TMP/v-repo"
setup_v_repo "$v_repo"
w4_kv="$TMP/v-kv-malformed"
{
  printf 'Warning: could not fetch origin\n'
  printf 'base=\n'
  printf 'state\n'
  printf 'random noise that is not a key=value pair at all\n'
} > "$w4_kv"
w4_out="$(mktemp)"; w4_err="$(mktemp)"
V_RC=0
(
  cd "$v_repo" || exit 1
  export MB_STUB_OUT="$w4_kv" MB_STUB_RC=0
  run_with_timeout 15 bash "$VBIN/check-verification-gate.sh" --settings-path "$SETTINGS_EMPTY"
) >"$w4_out" 2>"$w4_err" || V_RC=$?
V_OUT="$(cat "$w4_out")"
V_ERR="$(cat "$w4_err")"
V_TOKENS="$(printf '%s\n' "$V_OUT" | sed -n 's/^CATEGORY: \([^	]*\)	.*/\1/p' | tr '\n' ' ')"
rm -f "$w4_out" "$w4_err"
w_expect_narrowed_scope "W4-malformed"
# The specific catastrophe, asserted on its own: an empty question set. Named separately from
# the scope row because "asked about the wrong files" and "asked about nothing" are different
# failures and only the second one is invisible to the user.
if [ -z "$(printf '%s' "$V_TOKENS" | tr -d '[:space:]')" ]; then
  fail "W4-nonempty: unparseable resolver output produced NO categories -- the preflight would ask nothing and pass"
else
  pass "W4-nonempty: unparseable resolver output never produces an empty question set"
fi
teardown_tmp

# --- W5: an unknown state is untrustworthy. A state added to the resolver later, or a typo,
#         must fall to the SAFE side; an allowlist of bad states (rather than of good ones)
#         would treat every future state as trustworthy by default.
setup_tmp
setup_v_bin
v_repo="$TMP/v-repo"
setup_v_repo "$v_repo"
run_v_gate "$v_repo" SOMETHING-NEW 0
w_expect_narrowed_scope "W5-unknown-state"
teardown_tmp

# ============================================================================
# C2 (#1638 round-2 coverage) — safe-scope degradation with an UNTRACKED risky file.
#
# `git diff HEAD --name-only` -- the command every untrustworthy state (SUSPECT, FALLBACK,
# UNRESOLVED) narrows to -- diffs the INDEX and working tree against HEAD for paths git already
# tracks. A file that was never `git add`-ed has no index entry to diff at all, so it is
# invisible to that command the same way it is invisible to plain `git diff`. That makes the
# narrowed "safe" scope able to silently drop exactly the file most likely to be the actual
# change under review moments before a commit: a brand-new file nobody has staged yet. All
# three narrowing states share the same `git diff HEAD` call (the `*` case in
# check-verification-gate.sh), so each is asserted here rather than trusting that one implies
# the others.
# ============================================================================

setup_v_repo_untracked_only() { # <repo-dir>
  local repo="$1"
  mkdir -p "$repo/install"
  (
    cd "$repo" || exit 1
    git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
    git config user.email test@example.com
    git config user.name Test
    git config commit.gpgsign false
    git config core.hooksPath "$repo/.git/no-such-hooks"
    echo "initial" > README.md
    git add README.md
    git commit -q -m initial
    git switch -q -c feature/untracked-only
    # The risky file: created but never `git add`-ed. Matches BOTH the installer and
    # pwsh-required patterns, so a single missing category already proves the gap.
    printf 'Write-Host "new, never staged"\n' > install/newfile.ps1
  )
}

w_expect_untracked_risky_detected() { # <row-id>
  local row="$1" problems=""
  echo "$V_TOKENS" | grep -q "installer" || problems="$problems [missing:installer]"
  echo "$V_TOKENS" | grep -q "pwsh-required" || problems="$problems [missing:pwsh-required]"
  echo "$V_TOKENS" | grep -q "merge-base-suspect" || problems="$problems [missing:merge-base-suspect]"
  if [ -z "$problems" ]; then
    pass "$row: an untracked risky file is still classified after the scope narrows to uncommitted changes"
  else
    fail "$row: problems$problems tokens=[$V_TOKENS] rc=$V_RC stderr=[$(head -2 <<< "$V_ERR")]"
  fi
  w_check "$row-rc: and the classifier still exits 0" "0" "$V_RC"
}

# --- C2-1: SUSPECT narrowing must still see an untracked risky file.
setup_tmp
setup_v_bin
v_repo="$TMP/v-repo-untracked"
setup_v_repo_untracked_only "$v_repo"
run_v_gate "$v_repo" SUSPECT 0
w_expect_untracked_risky_detected "C2-SUSPECT-untracked"
teardown_tmp

# --- C2-2: FALLBACK narrowing must still see an untracked risky file.
setup_tmp
setup_v_bin
v_repo="$TMP/v-repo-untracked"
setup_v_repo_untracked_only "$v_repo"
run_v_gate "$v_repo" FALLBACK 0
w_expect_untracked_risky_detected "C2-FALLBACK-untracked"
teardown_tmp

# --- C2-3: UNRESOLVED (resolver exit 3, no kv output) narrowing must still see an untracked
#           risky file.
setup_tmp
setup_v_bin
v_repo="$TMP/v-repo-untracked"
setup_v_repo_untracked_only "$v_repo"
run_v_gate "$v_repo" - 3
w_expect_untracked_risky_detected "C2-UNRESOLVED-untracked"
teardown_tmp

# SKIPPED: the real resolver against a real repository with a real stale remote.
# Because: every row here stubs the resolver so the STATE is the input under test; the
#          resolver's own behaviour is pinned in tests/feature-1638-resolve-merge-base.sh.
# TL3 gap: the two scripts disagreeing about the kv key names — only a run with both real
#          files on one host can catch a renamed key.
