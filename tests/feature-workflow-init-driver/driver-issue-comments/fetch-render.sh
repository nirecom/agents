#!/bin/bash
# tests/feature-workflow-init-driver/driver-issue-comments/fetch-render.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, issue-comments, fetch-issues, write-context, sentinel-strip, prompt-injection, scope:issue-specific

# C1-C3, C6, C6b (#2063): the single fetch point asks for `comments`, what comes back renders into context.md — including the zero-comment `(none)` floor — and one issue costs exactly one fetch, across an interruption and resume too.
# Injection seams: ../HARNESS-CONTRACT.md

# TL3 gap: no real `claude -p` ask_user round-trip (answers are replayed through
# --resume/--answer) and no live gh, so the `comments` payload is the mock's shape.
# Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- C1: the single fetch point requests the `comments` field ------------------
# Everything downstream is unfalsifiable if the field never leaves the wire, so
# this is asserted on the call log itself rather than inferred from context.md.
setup_case wid-c2063-c1
mock_issue 900 OPEN "type:task"
set_wip 900 same
run_driver '#900'
# The field list is parsed, not pattern-matched: `--json …,commentsCount,…` satisfies a
# substring regex while requesting a different field entirely. Only an exact token in
# the comma-separated list means gh will return the `comments` array.
C1_FIELDS="$(node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
const line = lines.find((l) => /^issue view /.test(l)) || "";
const m = line.match(/--json\s+(\S+)/);
if (!m) { process.stdout.write("<<NO---JSON-FLAG>>"); process.exit(0); }
const fields = m[1].split(",").map((s) => s.trim());
process.stdout.write(fields.includes("comments") ? "EXACT" : "MISSING:" + m[1]);
' "$GH_LOG")"
assert_count "C1: the --json list carries an exact 'comments' token" EXACT "$C1_FIELDS"
teardown_case

# --- C2: comments render into context.md with header + blockquoted body --------
setup_case wid-c2063-c2
mock_issue 901 OPEN "type:task"
mock_issue_comments 901 '[{"author":{"login":"alice"},"body":"first remark","createdAt":"2026-07-02T00:00:00Z"},{"author":{"login":"bob"},"body":"second remark","createdAt":"2026-07-03T00:00:00Z"}]'
set_wip 901 same
run_driver '#901'
assert_kv "C2: two-comment issue completes the pipeline" ACTION done
assert_ctx_has "C2: context.md carries the '## Issue comments' section" '## Issue comments'
assert_ctx_has "C2: comment 1 header names author and createdAt" '### Comment 1 — alice (2026-07-02T00:00:00Z)'
assert_ctx_has "C2: comment 1 body is blockquoted" '> first remark'
assert_ctx_has "C2: comment 2 header names author and createdAt" '### Comment 2 — bob (2026-07-03T00:00:00Z)'
assert_ctx_has "C2: comment 2 body is blockquoted" '> second remark'
teardown_case

# --- C3: an issue with zero comments renders `(none)` --------------------------
# The empty collection is a normal state, not a defect: it must never surface the
# malformed-cache wording, which would make "no discussion yet" read as breakage.
setup_case wid-c2063-c3
mock_issue 902 OPEN "type:task"
set_wip 902 same
run_driver '#902'
assert_kv "C3: zero-comment issue completes the pipeline" ACTION done
assert_ctx_has "C3: '## Issue comments' section present for a zero-comment issue" '## Issue comments'
# Asserted as the WHOLE section, not as "(none) appears under the heading": a section
# reading `(none)` followed by a fabricated `### Comment 1 — …` entry satisfies any
# presence check while telling the planner about discussion that never happened. The
# entry-count assertion below is kept independent so it survives a wording change.
C3_SECTION='## Issue comments
(none)'
assert_section_eq "C3: the whole section is exactly the heading and (none)" "$C3_SECTION"
assert_section_lacks "C3: no comment entry is fabricated beside (none)" '### Comment'
assert_ctx_lacks "C3: an empty comment list is not reported as a malformed cache" 'comments unavailable'
teardown_case

# --- C6: one issue = exactly one `gh issue view` -------------------------------
# The accepted tradeoff is a single fetch feeding BOTH Path A and Path B. A second
# consumer fetching for itself would still satisfy every rendering assertion, so
# the call count is the only observable that can fail.
setup_case wid-c2063-c6
mock_issue 905 OPEN "type:task"
mock_issue_comments 905 '[{"author":{"login":"alice"},"body":"only comment","createdAt":"2026-07-02T00:00:00Z"}]'
set_wip 905 same
run_driver '#905'
assert_kv "C6: pipeline runs to completion" ACTION done
assert_count "C6: exactly one 'gh issue view' for #905" 1 "$(count_issue_view 905)"
teardown_case

# --- C6b: an interruption AFTER the fetch costs no second fetch ------------------
# C6 covers the uninterrupted run and reopen-cache.sh's C7/C9 the reopen refetch, which
# leaves the ordinary shape untested: comments are cached, an UNRELATED gate stops the
# session, the user resumes. Nothing in that resume asks for fresh data, so the cached
# comments must reach context.md with the counter still reading 1. A driver that refetches
# "just in case" whenever it resumes satisfies C6 and C7 and fails only here.
setup_case wid-c2063-c6b
mock_issue 916 OPEN "type:task"
mock_issue_comments 916 '[{"author":{"login":"alice"},"body":"CACHED-BEFORE-THE-INTERRUPTION-916","createdAt":"2026-07-02T00:00:00Z"}]'
set_wip 916 other
run_driver '#916'
assert_kv "C6b: an issue owned elsewhere interrupts at wip_conflict" ASK_ID wip_conflict
assert_count "C6b: the pre-interruption run fetched #916 exactly once" 1 "$(count_issue_view 916)"
C6B_CKPT="$(get_kv CHECKPOINT)" || true
C6B_SEED="$(ckpt_get "$C6B_CKPT" state.issue_json_cache.916.comments)"
case "$C6B_SEED" in
    *CACHED-BEFORE-THE-INTERRUPTION-916*)
        pass "C6b: the comments were cached before the interruption (the survival probe is live)" ;;
    *)
        fail "C6b: the interrupted checkpoint holds no comments — the survival assertion cannot fail: '$C6B_SEED'" ;;
esac
# The mock is mutated so an unwanted refetch is visible in the ARTIFACT and not only in
# the counter: if the resume goes back to gh, this replacement text is what lands.
mock_issue_comments 916 '[{"author":{"login":"mallory"},"body":"REFETCHED-DURING-THE-RESUME-916","createdAt":"2026-07-09T00:00:00Z"}]'
run_driver --resume "$C6B_CKPT" --answer continue
assert_kv "C6b: the resumed session runs to completion" ACTION done
assert_count "C6b: still exactly one 'gh issue view' for #916 across the whole session" 1 "$(count_issue_view 916)"
C6B_CKPT2="$(get_kv CHECKPOINT)" || true
C6B_FINAL="$(ckpt_get "$C6B_CKPT2" state.issue_json_cache.916.comments)"
case "$C6B_FINAL" in
    *CACHED-BEFORE-THE-INTERRUPTION-916*) pass "C6b: the cached comments survive the resume unchanged" ;;
    *) fail "C6b: the cached comments did not survive the resume: '$(printf '%s' "$C6B_FINAL" | head -c 200)'" ;;
esac
case "$C6B_FINAL" in
    *REFETCHED-DURING-THE-RESUME-916*) fail "C6b: the resume refetched — post-interruption mock text reached the cache" ;;
    *) pass "C6b: no post-interruption text entered the cache" ;;
esac
assert_ctx_has "C6b: the cached comment reaches the context.md written after the resume" 'CACHED-BEFORE-THE-INTERRUPTION-916'
assert_ctx_lacks "C6b: no refetched text reaches context.md" 'REFETCHED-DURING-THE-RESUME-916'
teardown_case

# --- C17 (Path C): a session with NO issue renders the no-issue floor -------------
# Path C reaches write-context with `issues` empty, so the comments section has no
# issue to describe. Two failures are equally bad and pull in opposite directions: the
# section could report a DEFECT ("comments unavailable — malformed cache entry") for a
# session that is behaving perfectly, or it could be omitted so a reader cannot tell the
# renderer ran at all. The floor is the same wording write-context already uses for the
# body — `(none — no issue)` — and it is asserted as the WHOLE section so a fabricated
# entry beside it cannot pass. Three arrivals at Path C, each with its own way in.
check_path_c() {  # <id> <label> — asserts the shared Path C floor on the current case
    local id="$1" what="$2"
    C17_SECTION='## Issue comments
(none — no issue)'
    assert_kv "C17$id: $what completes the pipeline" ACTION done
    assert_no_uncaught "C17$id: $what is handled, not thrown"
    assert_kv "C17$id: $what routes to Path C" PATH_DECISION C
    # assert_section_eq fails outright when no section was rendered, so the negatives
    # below cannot be satisfied by a context.md that never wrote the heading.
    assert_section_eq "C17$id: the whole section is the heading and (none — no issue)" "$C17_SECTION"
    assert_ctx_lacks "C17$id: an absent issue is never reported as a malformed cache" 'comments unavailable'
    assert_ctx_lacks "C17$id: no multi-issue announcement is emitted for a no-issue session" 'comments shown for #'
    assert_ctx_count "C17$id: no comment entry is fabricated" '^### Comment ' 0
}

# (a) zero issue tokens on the command line — the ordinary Path C entry.
setup_case wid-c2063-c17a
run_driver
check_path_c a "a session with zero issue tokens"
teardown_case

# (b) NON_GITHUB=1 — the WI-2 gate short-circuits to done BEFORE any phase runs, so
# write-context is reached with a state no fetch ever touched. That is a different code
# path to (a) and the one where a renderer reading `issue_json_cache[issues[0]]` without
# a length guard dereferences `undefined`.
setup_case wid-c2063-c17b
export NON_GITHUB=1
run_driver
check_path_c b "the NON_GITHUB=1 gate"
assert_count "C17b: the non-GitHub gate consults gh for nothing" 0 "$(count_gh_calls '^issue view')"
teardown_case

# (c) a PARTIAL multi-issue fetch answered with `continue`. The dangerous one: #942 was
# fetched successfully and its comments are in the cache when `continue` empties
# `state.issues`, so the cache is non-empty while the issue list is not. A renderer that
# walks the CACHE instead of `issues[0]` prints a discussion belonging to an issue this
# session just abandoned — and the reader has no way to know it is not their own.
setup_case wid-c2063-c17c
mock_issue 942 OPEN "type:task"
mock_issue_comments 942 '[{"author":{"login":"alice"},"body":"ABANDONED-ISSUE-REMARK-942","createdAt":"2026-07-02T00:00:00Z"}]'
mock_issue 943 OPEN "type:task"
mock_issue_rc 943 1
set_wip 942 same
set_wip 943 same
run_driver '#942' '#943'
assert_kv "C17c: the half-failed fetch raises fetch_failed_path_c" ASK_ID fetch_failed_path_c
C17C_CKPT="$(get_kv CHECKPOINT)" || true
# The leak probe: #942's comments must genuinely BE in the cache at the moment the user
# answers, or "they were not rendered" is a claim about data that never existed.
C17C_SEED="$(ckpt_get "$C17C_CKPT" state.issue_json_cache.942.comments)"
case "$C17C_SEED" in
    *ABANDONED-ISSUE-REMARK-942*)
        pass "C17c: the successfully fetched issue's comments are cached before the answer (the probe is live)" ;;
    *)
        fail "C17c: nothing was cached for #942 — the no-leak assertion cannot fail: '$(printf '%s' "$C17C_SEED" | head -c 200)'" ;;
esac
run_driver --resume "$C17C_CKPT" --answer continue
check_path_c c "a partial fetch answered with continue"
assert_ctx_lacks "C17c: the abandoned issue's comment is not rendered from the surviving cache" 'ABANDONED-ISSUE-REMARK-942'
teardown_case

finish
