# Part of tests/feature-review-code-codex/path-priority.sh (sourced, not standalone).
# Tests: bin/review-code-codex, bin/lib/codex-core.sh
# Tags: codex, review, disclosure, excluded, error-handling, failure-injection, secret-leakage, logging, scope:issue-specific, pwsh-not-required, TL2
# F1: disclosure on a mixed repo (committed range under review, plus staged/unstaged/untracked changes the range can't cover) — those files are what the author most likely believes was reviewed. F2: the rewrite's new failure modes (multiple `git diff` shell-outs vs the old in-memory `head -n`) can silently return fewer files than actually changed — PERFORMED with a quietly shorter list, not a crash. F3: withheld content must not leak via JSONL log, stderr, or temp files.
# Wording note: assertions target `## Codex Review Scope: EXCLUDED` (the approved single-source line for "changed, not reviewed"), not the older `Not in the review target` phrasing — the contract tested is unchanged.
# TL3 gap: F2's git failures are PATH-shim injected, not real corruption/permission errors; F3 redirects HOME at a fixture, so an absolute-path logger could leak elsewhere unseen. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

# ---------------------------------------------------------------------------
# F1 — one repo holding all four kinds of change at once.
# ---------------------------------------------------------------------------
F_MIX="$(pp_new_base_repo pp-f-mix)"
pp_gen "$F_MIX/unstaged.txt" 10 "pp-f-unstaged-base"
git -C "$F_MIX" add unstaged.txt
git -C "$F_MIX" commit -q -m "seed the file the branch will modify without staging"
git -C "$F_MIX" checkout -q -b feature-pp-f-mix

pp_gen "$F_MIX/committed.txt" 20 "pp-f-committed-marker"
git -C "$F_MIX" add committed.txt
git -C "$F_MIX" commit -q -m "the change actually under review"

pp_gen "$F_MIX/staged.txt" 10 "pp-f-staged-marker"
git -C "$F_MIX" add staged.txt
echo "pp-f-unstaged-marker" >> "$F_MIX/unstaged.txt"
pp_gen "$F_MIX/untracked.txt" 10 "pp-f-untracked-marker"

PP_ENV=()
PP_OUT="$(pp_run "$F_MIX" --base main --base-state RECORDED --no-log)"

f_excl="$(printf '%s\n' "$PP_OUT" | grep -E "^## Codex Review Scope: EXCLUDED" -A 20 || true)"
if [ -z "$f_excl" ]; then
    fail "F1: three kinds of session change sit outside the reviewed range and no EXCLUDED disclosure was printed. Output: $PP_OUT"
else
    f_named=1
    for f_p in staged.txt unstaged.txt untracked.txt; do
        if ! pp_has_fixed "$f_excl" "$f_p"; then
            f_named=0
            fail "F1-disclose: $f_p is changed but outside the reviewed range, and the EXCLUDED disclosure does not name it"
        fi
    done
    [ "$f_named" = "1" ] && pass "F1-disclose: the EXCLUDED disclosure names the staged, unstaged and untracked paths"
fi

if [ -f "$PP_CAPTURE" ] && pp_diff_body "$PP_CAPTURE" | grep -q "pp-f-committed-marker"; then
    pass "F1-target: the committed change under review did reach the model"
else
    fail "F1-target: the committed change never reached the prompt, so F1's exclusions prove nothing. Output: $PP_OUT"
fi

f_leaked=""
for f_m in pp-f-staged-marker pp-f-unstaged-marker pp-f-untracked-marker; do
    if [ -f "$PP_CAPTURE" ] && grep -q "$f_m" "$PP_CAPTURE"; then f_leaked="$f_leaked $f_m"; fi
done
if [ -z "$f_leaked" ]; then
    pass "F1-content: none of the excluded paths' content was sent — they are disclosed by name only, as the report says"
else
    fail "F1-content: content of excluded path(s) reached the prompt anyway:$f_leaked"
fi

# ---------------------------------------------------------------------------
# F2 — injected failures in each new subprocess the pipeline depends on. The bar is the same
#      every time: the run may fail, and it may fall back, but it may not report a completed
#      review over a file list that silently lost members.
# ---------------------------------------------------------------------------
F_SHIM="$TMPDIR_BASE/pp-f-shim"
F_REAL_GIT="$(command -v git)"
rm -rf "$F_SHIM"
mkdir -p "$F_SHIM"

f_write_git_shim() { # <match-word>
    cat > "$F_SHIM/git" <<SHIM_EOF
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = "$1" ]; then
        echo "git shim: forced failure on $1" >&2
        exit 128
    fi
done
exec "$F_REAL_GIT" "\$@"
SHIM_EOF
    chmod +x "$F_SHIM/git"
}

F_FAIL="$(pp_new_repo pp-f-fail)"
pp_gen "$F_FAIL/one.txt" 20 "pp-f-one-marker"
pp_gen "$F_FAIL/two.txt" 20 "pp-f-two-marker"
git -C "$F_FAIL" add one.txt two.txt
git -C "$F_FAIL" commit -q -m "two files"

# (a) the name list itself fails — the pipeline does not know WHICH files changed. The bar is
#     an EXACT FAILED verdict — "some Codex Review line was printed" is not enough, because
#     that would also accept a PERFORMED verdict wearing an unrelated caveat while the file
#     list, and any path it silently dropped, stay unknown to the reader.
f_write_git_shim "--name-only"
PP_ENV=(PATH="$F_SHIM:$MOCK_BIN:$PATH")
rm -f "$PP_CAPTURE"
pp_exec "$F_FAIL" --base main --no-log
if pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
    pass "F2a: a failing 'git diff --name-only' produces an exact FAILED verdict rather than a shortened review"
else
    fail "F2a: a failing 'git diff --name-only' did not produce an exact FAILED verdict (rc=$PP_RC). Output: $PP_OUT_TEXT stderr: $PP_ERR_TEXT"
fi
if [ -s "$PP_CAPTURE" ]; then
    fail "F2a-no-invoke: codex was invoked (a prompt was captured) even though the file list could not be built — a review ran over an unknown/incomplete file set"
else
    pass "F2a-no-invoke: codex was never invoked when the change list itself could not be determined"
fi

# (b) per-path chunk extraction fails — the pipeline knows the files and cannot read them.
#     review-code-codex's own collect step (`## Collect — treat git failure as FAILED (not
#     SKIPPED) to avoid silent coverage gaps`) always emits FAILED here, never SKIPPED — SKIPPED
#     is reserved for the empty-diff case. Accepting SKIPPED here would let a regression back
#     into the silent-coverage-gap behavior that comment exists to prevent, so the bar is an
#     exact FAILED verdict, not "some Codex Review line".
f_write_git_shim "--"
rm -f "$PP_CAPTURE"
pp_exec "$F_FAIL" --base main --no-log
if pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
    pass "F2b: failing per-path chunk extraction ends in an exact FAILED verdict rather than a partial review presented as whole"
else
    fail "F2b: failing per-path chunk extraction did not produce an exact FAILED verdict (rc=$PP_RC). Output: $PP_OUT_TEXT stderr: $PP_ERR_TEXT"
fi
if [ "$(pp_count_matching "$PP_OUT_TEXT" "^## Codex Review: ")" = "1" ]; then
    pass "F2b-single-verdict: exactly one Codex Review verdict line was emitted, not a FAILED line appended to a review that ran anyway"
else
    fail "F2b-single-verdict: expected exactly one verdict line, got: $PP_OUT_TEXT"
fi
if [ -s "$PP_CAPTURE" ]; then
    fail "F2b-no-invoke: codex was invoked even though no path's chunk could be extracted"
else
    pass "F2b-no-invoke: codex was never invoked when chunk extraction failed for every path"
fi
rm -f "$F_SHIM/git"

# (d) untracked-file discovery fails — parallel to (a), but on the enumeration `git ls-files
#     --others` runs instead of `git diff --name-only`. A silent PERFORMED here means an
#     untracked file (here holding a would-be-disclosed secret) dropped out of the EXCLUDED
#     disclosure without anyone being told discovery itself failed. Same FAILED-only bar as F2b:
#     collect-step git failures never legitimately produce SKIPPED (see the comment above F2b).
f_write_git_shim "--others"
F_UNTRACKED="$(pp_new_repo pp-f-untracked-fail)"
pp_gen "$F_UNTRACKED/tracked.txt" 20 "pp-f-untracked-fail-marker"
git -C "$F_UNTRACKED" add tracked.txt
git -C "$F_UNTRACKED" commit -q -m "one tracked file"
pp_gen "$F_UNTRACKED/secret-untracked.txt" 10 "pp-f-untracked-fail-secret"
PP_ENV=(PATH="$F_SHIM:$MOCK_BIN:$PATH")
rm -f "$PP_CAPTURE"
pp_exec "$F_UNTRACKED" --base main --no-log
if pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
    pass "F2d: a failing 'git ls-files --others' produces an exact FAILED verdict rather than silently dropping the untracked file from disclosure"
else
    fail "F2d: a failing 'git ls-files --others' did not produce an exact FAILED verdict (rc=$PP_RC). Output: $PP_OUT_TEXT stderr: $PP_ERR_TEXT"
fi
if [ "$(pp_count_matching "$PP_OUT_TEXT" "^## Codex Review: ")" = "1" ]; then
    pass "F2d-single-verdict: exactly one Codex Review verdict line was emitted, not a FAILED line appended to a review that ran anyway"
else
    fail "F2d-single-verdict: expected exactly one verdict line, got: $PP_OUT_TEXT"
fi
if pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
    fail "F2d-no-silent-drop: the run reported PERFORMED even though untracked-file discovery failed — the untracked file was silently omitted from the EXCLUDED disclosure. Output: $PP_OUT_TEXT"
else
    pass "F2d-no-silent-drop: the run did not paper over a failed untracked-file enumeration with a clean PERFORMED verdict"
fi
if [ -s "$PP_CAPTURE" ]; then
    fail "F2d-no-invoke: codex was invoked (a prompt was captured) even though untracked-file discovery failed"
else
    pass "F2d-no-invoke: codex was never invoked when untracked-file discovery failed"
fi
rm -f "$F_SHIM/git"

# (c) config lookup fails. This one must NOT fail the review: an unreadable setting is a
#     reason to use the default, not a reason to skip reviewing the code.
F_BADCFG="$TMPDIR_BASE/pp-f-badcfg"
rm -rf "$F_BADCFG"
mkdir -p "$F_BADCFG/bin"
printf '#!/usr/bin/env bash\necho "get-config-var: exploded" >&2\nexit 1\n' > "$F_BADCFG/bin/get-config-var"
chmod +x "$F_BADCFG/bin/get-config-var"
PP_ENV=(AGENTS_CONFIG_DIR="$F_BADCFG")
pp_exec "$F_FAIL" --base main --no-log
if ! pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
    fail "F2c: a failing config lookup cost the whole review. Output: $PP_OUT_TEXT stderr: $PP_ERR_TEXT"
elif [ "$(pp_diff_body_lines "$PP_CAPTURE")" -eq 0 ]; then
    fail "F2c: the review ran with an empty diff body after the config lookup failed"
else
    pass "F2c: a failing config lookup falls back to the default budget and the review still runs"
fi
PP_ENV=()

# (c-bis) the same config-lookup failure, but proven on a fixture PAST the default cap, and
#         against get-config-var being ABSENT from AGENTS_CONFIG_DIR/bin entirely as well as
#         exiting non-zero. F_FAIL above is only 40 lines — too small to tell "capped at 5000"
#         from "the fallback silently means no cap at all", which is exactly the bug this row
#         exists to catch.
F_BIGCFG="$(pp_new_repo pp-f-bigcfg)"
pp_gen "$F_BIGCFG/big.txt" 6000 "pp-f-bigcfg-marker"
git -C "$F_BIGCFG" add big.txt
git -C "$F_BIGCFG" commit -q -m "6000-line file, past the default 5000-line cap"

for f_cfgmode in absent failing; do
    F_BADCFG2="$TMPDIR_BASE/pp-f-badcfg-$f_cfgmode"
    rm -rf "$F_BADCFG2"
    mkdir -p "$F_BADCFG2/bin"
    if [ "$f_cfgmode" = "failing" ]; then
        printf '#!/usr/bin/env bash\necho "get-config-var: exploded" >&2\nexit 1\n' > "$F_BADCFG2/bin/get-config-var"
        chmod +x "$F_BADCFG2/bin/get-config-var"
    fi
    # "absent": bin/ exists but get-config-var itself is deliberately never placed in it.
    PP_ENV=(AGENTS_CONFIG_DIR="$F_BADCFG2")
    pp_exec "$F_BIGCFG" --base main --no-log
    f2c_n="$(pp_diff_body_lines "$PP_CAPTURE")"
    if ! pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
        fail "F2c-$f_cfgmode: get-config-var $f_cfgmode cost the whole review on a fixture past the default cap. Output: $PP_OUT_TEXT stderr: $PP_ERR_TEXT"
    elif ! printf '%s\n' "$PP_OUT_TEXT" | grep -E "^## Codex Review Scope: TRUNCATED" | grep -q "5000"; then
        fail "F2c-$f_cfgmode: get-config-var $f_cfgmode did not announce a fallback cap of exactly 5000 on a 6000-line fixture — either uncapped or a different silent default. Output: $PP_OUT_TEXT"
    elif [ "${f2c_n:-0}" -gt 0 ] && [ "$f2c_n" -le 5000 ]; then
        pass "F2c-$f_cfgmode: get-config-var $f_cfgmode falls back to an exact 5000-line cap, proven on a 6000-line fixture ($f2c_n lines actually sent)"
    else
        fail "F2c-$f_cfgmode: the fallback announced 5000 but sent $f2c_n lines of diff body"
    fi
done
PP_ENV=()

# ---------------------------------------------------------------------------
# F3 — the same degraded-state suppression as P6, but with logging ON and the CLI failing, so
#      every channel that only exists on those two paths is checked: the log file the run
#      writes, the stderr the failure prints, and the temp files it leaves behind.
# ---------------------------------------------------------------------------
F_LEAK="$(pp_new_repo pp-f-leak)"
echo "pp-f-leak-tracked-edit" >> "$F_LEAK/README.md"
pp_gen "$F_LEAK/secret.txt" 10 "PP-F-SECRET-MARKER"

F_LOG_DIR="$TMPDIR_BASE/.claude/projects/codex-review"
rm -rf "$F_LOG_DIR"
f_tmp_before="$(ls /tmp/codex-* 2>/dev/null | sort || true)"

pp_install_failing_mock
PP_ENV=()
pp_exec "$F_LEAK" --base main --base-state SUSPECT
pp_install_capturing_mock

f_channels=""
pp_has_fixed "$PP_OUT_TEXT" "PP-F-SECRET-MARKER" && f_channels="$f_channels stdout"
pp_has_fixed "$PP_ERR_TEXT" "PP-F-SECRET-MARKER" && f_channels="$f_channels stderr"
if [ -d "$F_LOG_DIR" ] && grep -rqF "PP-F-SECRET-MARKER" "$F_LOG_DIR" 2>/dev/null; then
    f_channels="$f_channels jsonl-log"
fi
for f_t in $(ls /tmp/codex-* 2>/dev/null || true); do
    case "$f_tmp_before" in *"$f_t"*) continue ;; esac
    if grep -qF "PP-F-SECRET-MARKER" "$f_t" 2>/dev/null; then f_channels="$f_channels leftover:$f_t"; fi
done

if [ -z "$f_channels" ]; then
    pass "F3: under a degraded base state with logging on and the CLI failing, the withheld content appears in no channel — stdout, stderr, JSONL log or leftover temp file"
else
    fail "F3: content withheld from the model leaked into:$f_channels"
fi

# The row above is only meaningful if the run actually reached the logging and failure paths.
if [ ! -d "$F_LOG_DIR" ] || [ -z "$(ls -A "$F_LOG_DIR" 2>/dev/null)" ]; then
    fail "F3-guard: no log file was written, so F3's clean JSONL result proves nothing about the logger"
elif [ "$PP_RC" -eq 0 ] && ! pp_has "$PP_OUT_TEXT" "^## Codex Review: FAILED"; then
    fail "F3-guard: the CLI was made to exit 2 and the run reported neither a non-zero status nor FAILED (rc=$PP_RC). Output: $PP_OUT_TEXT"
else
    pass "F3-guard: the run really did write a log and really did take the failure path, so F3's silence is meaningful"
fi

# ---------------------------------------------------------------------------
# F4 — a .gitignore-excluded file holding a secret must never reach any channel, on a trusted
#      (RECORDED) base state that ALSO holds an ordinary untracked file, so the row can tell
#      "the secret was specifically withheld" from "the whole untracked class was suppressed"
#      (which P6 already covers for degraded states, and would make this row's silence prove
#      nothing about .gitignore handling specifically).
# ---------------------------------------------------------------------------
F_GI="$(pp_new_repo pp-f-gitignore)"
printf 'ignored-secret.txt\n' > "$F_GI/.gitignore"
git -C "$F_GI" add .gitignore
git -C "$F_GI" commit -q -m "gitignore rule excluding the secret file"
pp_gen "$F_GI/ordinary-untracked.txt" 10 "PP-F-ORDINARY-MARKER"
pp_gen "$F_GI/ignored-secret.txt" 10 "PP-F-GITIGNORE-SECRET"

F4_LOG_DIR="$TMPDIR_BASE/.claude/projects/codex-review"
rm -rf "$F4_LOG_DIR"
f4_tmp_before="$(ls /tmp/codex-* 2>/dev/null | sort || true)"

pp_install_capturing_mock
PP_ENV=()
pp_exec "$F_GI" --base main --base-state RECORDED

f4_channels=""
pp_has_fixed "$PP_OUT_TEXT" "PP-F-GITIGNORE-SECRET" && f4_channels="$f4_channels stdout"
pp_has_fixed "$PP_ERR_TEXT" "PP-F-GITIGNORE-SECRET" && f4_channels="$f4_channels stderr"
if [ -f "$PP_CAPTURE" ] && grep -qF "PP-F-GITIGNORE-SECRET" "$PP_CAPTURE"; then
    f4_channels="$f4_channels prompt"
fi
if [ -d "$F4_LOG_DIR" ] && grep -rqF "PP-F-GITIGNORE-SECRET" "$F4_LOG_DIR" 2>/dev/null; then
    f4_channels="$f4_channels jsonl-log"
fi
for f4_t in $(ls /tmp/codex-* 2>/dev/null || true); do
    case "$f4_tmp_before" in *"$f4_t"*) continue ;; esac
    if grep -qF "PP-F-GITIGNORE-SECRET" "$f4_t" 2>/dev/null; then f4_channels="$f4_channels leftover:$f4_t"; fi
done

if [ -z "$f4_channels" ]; then
    pass "F4: a .gitignore-excluded file's secret content appears in no channel — stdout, stderr, the model prompt, the JSONL log, or a leftover temp file"
else
    fail "F4: .gitignore-excluded secret content leaked into:$f4_channels"
fi

# The row above is only meaningful if the run took the intentional, disclosed committed-diff
# exclusion path (E24, #1702), not some other failure/suppression that hides everything without
# naming it. This fixture's .gitignore commit makes BASE...HEAD non-empty, so per E24 the
# ordinary untracked file is excluded from the prompt but still named on the EXCLUDED line; the
# secret is absent from that line too but for a different reason — `git ls-files --others
# --exclude-standard` never surfaces a .gitignore'd path, so it never enters unc[]/unt[].
# First confirm the review actually ran (PERFORMED/rc=0/prompt captured) — a silent failure
# before the review body was assembled would also print no EXCLUDED line, and this guard would
# otherwise mistake "never ran" for "ran and correctly excluded".
if ! pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
    fail "F4-guard: review was not PERFORMED (rc=$PP_RC), so F4's clean result proves nothing. Output: $PP_OUT_TEXT"
elif [ "$PP_RC" -ne 0 ]; then
    fail "F4-guard: review reported PERFORMED but the run exited non-zero (rc=$PP_RC)"
elif [ ! -s "$PP_CAPTURE" ]; then
    fail "F4-guard: no prompt was captured by the mock reviewer, so PERFORMED does not prove the review body was assembled. File exists: $([ -f "$PP_CAPTURE" ] && echo yes || echo no)"
elif echo "$PP_OUT_TEXT" | grep -E "^## Codex Review Scope: EXCLUDED" | grep -q "ordinary-untracked.txt"; then
    pass "F4-guard: the review really ran (PERFORMED, rc=0, prompt captured) and the ordinary untracked file is named on the EXCLUDED line, so F4's silence about the secret reflects the intentional E24 disclosure path"
else
    fail "F4-guard: the review ran but the EXCLUDED line does not name the ordinary untracked file, so F4's clean result does not prove the E24 exclusion path was taken. Output: $PP_OUT_TEXT"
fi

# ---------------------------------------------------------------------------
# F4b — F4 always has a committed diff (the .gitignore rule's own commit), so E24 blanket-
#      excludes the whole untracked set and F4 cannot tell "gitignore-specific exclusion" from
#      "everything untracked was excluded anyway". Here the .gitignore rule is folded into the
#      SAME commit the branch starts from, so BASE...HEAD is empty and E24 does not trigger —
#      an ordinary untracked canary must reach the prompt while the gitignored secret must not,
#      proving the exclusion is gitignore-specific.
# ---------------------------------------------------------------------------
F4B_GI="$(pp_new_base_repo pp-f4b-gitignore)"
printf 'ignored-secret.txt\n' > "$F4B_GI/.gitignore"
git -C "$F4B_GI" add .gitignore
git -C "$F4B_GI" commit -q -m "gitignore rule, folded into the branch point"
git -C "$F4B_GI" checkout -q -b feature-pp-f4b-gitignore  # no further commits: main...HEAD is empty
pp_gen "$F4B_GI/ordinary-untracked.txt" 10 "PP-F4B-ORDINARY-MARKER"
pp_gen "$F4B_GI/ignored-secret.txt" 10 "PP-F4B-GITIGNORE-SECRET"

F4B_LOG_DIR="$TMPDIR_BASE/.claude/projects/codex-review"
rm -rf "$F4B_LOG_DIR"
f4b_tmp_before="$(ls /tmp/codex-* 2>/dev/null | sort || true)"

pp_install_capturing_mock
PP_ENV=()
pp_exec "$F4B_GI" --base main --base-state RECORDED

if ! pp_has "$PP_OUT_TEXT" "^## Codex Review: PERFORMED"; then
    fail "F4b-guard: review was not PERFORMED (rc=$PP_RC), so F4b proves nothing. Output: $PP_OUT_TEXT"
elif echo "$PP_OUT_TEXT" | grep -qE "^## Codex Review Scope: EXCLUDED"; then
    fail "F4b-guard: an EXCLUDED line appeared even though main...HEAD is empty — the fixture failed to avoid E24's blanket exclusion, so F4b cannot isolate gitignore-specific behavior. Output: $PP_OUT_TEXT"
elif [ ! -s "$PP_CAPTURE" ]; then
    fail "F4b-guard: no prompt was captured by the mock reviewer, so PERFORMED does not prove the review body was assembled."
elif ! grep -qF "PP-F4B-ORDINARY-MARKER" "$PP_CAPTURE"; then
    fail "F4b: the ordinary untracked file's content is missing from the prompt, so this fixture does not prove blanket E24 exclusion is inactive here. Captured: $(cat "$PP_CAPTURE")"
elif grep -qF "PP-F4B-GITIGNORE-SECRET" "$PP_CAPTURE"; then
    fail "F4b: the .gitignore-excluded secret's content leaked into the prompt even though an ordinary untracked file (not blanket-excluded) reached it — gitignore-specific exclusion is broken"
else
    pass "F4b: with no committed diff (E24 inactive), the ordinary untracked file reaches the prompt while the gitignored secret does not — proving gitignore-specific exclusion, not blanket exclusion"
fi

# F4b's own leak-check above only inspects the captured prompt. Mirror F4's f4_channels sweep
# (stdout/stderr/JSONL-log/leftover-temp-file) so a leak into any OTHER channel is not missed —
# the ordinary canary above already proves the review executed, so silence here is meaningful.
f4b_channels=""
pp_has_fixed "$PP_OUT_TEXT" "PP-F4B-GITIGNORE-SECRET" && f4b_channels="$f4b_channels stdout"
pp_has_fixed "$PP_ERR_TEXT" "PP-F4B-GITIGNORE-SECRET" && f4b_channels="$f4b_channels stderr"
if [ -d "$F4B_LOG_DIR" ] && grep -rqF "PP-F4B-GITIGNORE-SECRET" "$F4B_LOG_DIR" 2>/dev/null; then
    f4b_channels="$f4b_channels jsonl-log"
fi
for f4b_t in $(ls /tmp/codex-* 2>/dev/null || true); do
    case "$f4b_tmp_before" in *"$f4b_t"*) continue ;; esac
    if grep -qF "PP-F4B-GITIGNORE-SECRET" "$f4b_t" 2>/dev/null; then f4b_channels="$f4b_channels leftover:$f4b_t"; fi
done
if [ -z "$f4b_channels" ]; then
    pass "F4b-channels: the gitignored secret appears in no other channel — stdout, stderr, the JSONL log, or a leftover temp file"
else
    fail "F4b-channels: .gitignore-excluded secret content leaked into:$f4b_channels"
fi
