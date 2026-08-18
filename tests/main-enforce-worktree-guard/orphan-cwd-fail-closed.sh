# Tests: hooks/enforce-worktree.js
# Tags: TL2, enforce-worktree, orphan-cwd, bash-c, fail-closed, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/fix-525-orphan-cwd-bash-c-bypass.sh (all cases).
# Cases: T1.1-T1.7.
# The axis is what the guard defaults to when repository resolution FAILS
# (repoRoot null: non-git CWD or parse failure) on a Bash call — it must fail
# closed. Command-body classification is a different axis: interpreter-readonly.sh.
# These cases use run_bash_guard_clean (env -i), not run_bash_guard: an inherited
# ENFORCE_WORKTREE_* or session variable would change the very default under test.

oc_setup_orphan_dir() {
  local dir="$TMPDIR_BASE/$1"
  mkdir -p "$dir"
  echo "$dir"
}

echo "=== fix-525: orphan-cwd bash-c bypass ==="
echo ""

# T1.1: repoRoot resolves from the cd-arg to main while CWD is orphan, so the
# mainCheckout guard is what blocks — not Change ④.
oc_main="$(setup_main_checkout "t1-1-main")"
oc_orphan="$(oc_setup_orphan_dir "t1-1-orphan")"
oc_out="$(run_bash_guard_clean "bash -c \"cd $oc_main && git push origin main\"" "$oc_orphan" ENFORCE_WORKTREE=on)"
if guard_blocks "$oc_out"; then
  pass "T1.1: orphan + bash-c cd <main> && git push → BLOCK"
else
  fail "T1.1: orphan + bash-c cd <main> && git push should BLOCK (got: $oc_out)"
fi

# T1.2
oc_main="$(setup_main_checkout "t1-2-main")"
oc_orphan="$(oc_setup_orphan_dir "t1-2-orphan")"
oc_out="$(run_bash_guard_clean "bash -c \"cd $oc_main && echo x >> README.md\"" "$oc_orphan" ENFORCE_WORKTREE=on)"
if guard_blocks "$oc_out"; then
  pass "T1.2: orphan + bash-c cd <main> && echo >> README.md → BLOCK"
else
  fail "T1.2: orphan + bash-c cd <main> && echo >> README.md should BLOCK (got: $oc_out)"
fi

# T1.3: no cd at all → startDir = orphan (non-git) → repoRoot null → Change ④.
oc_orphan="$(oc_setup_orphan_dir "t1-3-orphan")"
oc_tmpout="$TMPDIR_BASE/fix525-test-t13.txt"
oc_out="$(run_bash_guard_clean "bash -c \"echo x > $oc_tmpout\"" "$oc_orphan" ENFORCE_WORKTREE=on)"
if guard_blocks "$oc_out"; then
  pass "T1.3: orphan + bash-c echo > /tmp/... (no cd) → BLOCK (fail-closed, no repo root)"
else
  fail "T1.3: orphan + bash-c echo > /tmp/... should BLOCK via Change ④ (got: $oc_out)"
fi

# T1.4: the read-only body classifies as "read" and returns before Change ④ is
# reached — this pins that the fail-closed default does not swallow reads.
oc_orphan="$(oc_setup_orphan_dir "t1-4-orphan")"
oc_out="$(run_bash_guard_clean 'bash -c "ls /tmp"' "$oc_orphan" ENFORCE_WORKTREE=on)"
if guard_allows "$oc_out"; then
  pass "T1.4: orphan + bash-c ls /tmp → ALLOW (isReadOnlyInterpreterC early-return)"
else
  fail "T1.4: orphan + bash-c ls /tmp should ALLOW (got: $oc_out)"
fi

# T1.5: CWD is the main repo, cd target is orphan.
oc_main="$(setup_main_checkout "t1-5-main")"
oc_orphan="$(oc_setup_orphan_dir "t1-5-orphan")"
oc_out="$(run_bash_guard_clean "bash -c \"cd $oc_orphan && git push\"" "$oc_main" ENFORCE_WORKTREE=on)"
if guard_blocks "$oc_out"; then
  pass "T1.5: main CWD + bash-c cd <orphan> && git push → BLOCK"
else
  fail "T1.5: main CWD + bash-c cd <orphan> && git push should BLOCK (got: $oc_out)"
fi

# T1.6: the FIRST absolute cd wins — /tmp is non-git, so repoRoot is null.
oc_main="$(setup_main_checkout "t1-6-main")"
oc_orphan="$(oc_setup_orphan_dir "t1-6-orphan")"
oc_out="$(run_bash_guard_clean "bash -c \"cd /tmp; cd $oc_main; git push\"" "$oc_orphan" ENFORCE_WORKTREE=on)"
if guard_blocks "$oc_out"; then
  pass "T1.6: orphan + bash-c cd /tmp; cd <main>; git push → BLOCK (first cd=/tmp → null repoRoot)"
else
  fail "T1.6: orphan + bash-c cd /tmp; cd <main>; git push should BLOCK (got: $oc_out)"
fi

# T1.7: same rule, opposite outcome path — first cd is main, so mainCheckout blocks.
oc_main="$(setup_main_checkout "t1-7-main")"
oc_orphan="$(oc_setup_orphan_dir "t1-7-orphan")"
oc_out="$(run_bash_guard_clean "bash -c \"cd $oc_main && cd $oc_orphan && git push\"" "$oc_orphan" ENFORCE_WORKTREE=on)"
if guard_blocks "$oc_out"; then
  pass "T1.7: orphan + bash-c cd <main> && cd <orphan> && git push → BLOCK (first cd=main → mainCheckout)"
else
  fail "T1.7: orphan + bash-c cd <main> && cd <orphan> && git push should BLOCK (got: $oc_out)"
fi

# Completion marker (dispatcher FRAG2) — must remain the last line.
frag_done "orphan-cwd-fail-closed.sh"
