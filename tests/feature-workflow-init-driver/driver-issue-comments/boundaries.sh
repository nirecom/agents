#!/bin/bash
# tests/feature-workflow-init-driver/driver-issue-comments/boundaries.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, issue-comments, fetch-issues, write-context, sentinel-strip, prompt-injection, scope:issue-specific

# C12-C14 (#2063, boundaries): idempotent rewrite, a 200-comment array through the whole pipeline, and the live `gh issue view --json comments` pagination edge.
# Injection seams: ../HARNESS-CONTRACT.md

# TL3 gap: no real `claude -p` ask_user round-trip (answers are replayed through
# --resume/--answer) and no live gh, so the `comments` payload is the mock's shape.
# Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- C12 (idempotency): re-running over the same state overwrites, never appends -
# context.md is rewritten whenever WI-9 runs again — every --resume of a gated session
# reaches write-context. An appending writer would duplicate the section and the reader
# would see the same discussion twice, with no signal which copy is current.
setup_case wid-c2063-c12
mock_issue 928 CLOSED "type:task"
mock_issue_comments 928 '[{"author":{"login":"alice"},"body":"the only remark","createdAt":"2026-07-02T00:00:00Z"}]'
set_wip 928 same
run_driver '#928'
assert_kv "C12: a closed issue raises the reopen gate" ASK_ID closed_reopen_928
C12_CKPT="$(get_kv CHECKPOINT)" || true
# Snapshot the gate checkpoint BEFORE resuming it: the resume advances the file in place,
# so a second pass over the same state needs its own untouched copy of that state.
cp "$C12_CKPT" "$PLANS/c12-replay.json" 2>/dev/null || true
run_driver --resume "$C12_CKPT" --answer reopen
assert_kv "C12: the reopened session completes" ACTION done
C12_FIRST="$CASE_DIR/context-after-first.md"
cp "$(ctx_file)" "$C12_FIRST" 2>/dev/null || true
assert_ctx_count "C12(i): '## Issue comments' appears exactly once" '^## Issue comments$' 1
assert_ctx_count "C12(i): the single comment has exactly one entry" '^### Comment 1 — ' 1
# The same state, written a second time into the same session's context.md.
# A writer that appended — to the file, or to an already-rendered section — shows here.
run_driver --resume "$PLANS/c12-replay.json" --answer reopen
assert_kv "C12(ii): the replayed pass also completes" ACTION done
assert_no_uncaught "C12(ii): the repeat pass is handled, not thrown"
assert_ctx_count "C12(ii): '## Issue comments' still appears exactly once after a repeat pass" '^## Issue comments$' 1
assert_ctx_count "C12(ii): the comment entry is not duplicated by the repeat pass" '^### Comment 1 — ' 1
# `timestamp:` is per-run by design, so it is normalized away; everything else must
# match. Comparing whole files would fail on that one line and hide real drift behind it.
C12_DIFF="$(node -e '
const fs = require("fs");
const norm = (p) => fs.readFileSync(p, "utf8").split("\n")
    .map((l) => l.replace(/^timestamp: .*/, "timestamp: <normalized>"));
const [a, b] = [norm(process.argv[1]), norm(process.argv[2])];
const out = [];
for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) out.push("L" + (i + 1) + ": [" + (a[i] ?? "<eof>") + "] vs [" + (b[i] ?? "<eof>") + "]");
}
process.stdout.write(out.slice(0, 6).join(" ; "));
' "$C12_FIRST" "$(ctx_file)" 2>/dev/null)"
if [ ! -s "$C12_FIRST" ]; then
    fail "C12(iii): the first pass wrote no context.md, so the comparison is unfalsifiable"
elif [ -z "$C12_DIFF" ]; then
    pass "C12(iii): the repeat pass reproduced context.md line for line (timestamp aside)"
else
    fail "C12(iii): context.md drifted between passes: $C12_DIFF"
fi
teardown_case

# --- C13 (collection boundary): a large comment array survives the WHOLE pipeline -
# A hand-built CLI checkpoint proves only that the renderer can walk 200 entries. This
# feeds them through gh → fetch-issues → the checkpoint cache → write-context, which is
# where a truncation would actually live: a `.slice(0, 30)` at fetch time, a paginated
# read that stops at the first page, or a cache write that drops the tail. The last
# element is the one that disappears in every one of those, so it is asserted by name.
setup_case wid-c2063-c13
node -e '
const fs = require("fs");
const comments = [];
for (let i = 1; i <= 200; i++) {
    comments.push({
        author: { login: "u" + i },
        body: "remark " + i,
        createdAt: "2026-07-01T00:00:" + String(i % 60).padStart(2, "0") + "Z"
    });
}
fs.writeFileSync(process.argv[1], JSON.stringify({
    number: 930, title: "Two hundred comments", body: "large collection fixture",
    labels: [{ name: "type:task" }], state: "OPEN", createdAt: "2026-07-01T00:00:00Z",
    comments
}) + "\n");
' "$RESP/issue-view-930.json"
set_wip 930 same
run_driver '#930'
assert_kv "C13: a 200-comment issue completes the pipeline" ACTION done
C13_CKPT="$(get_kv CHECKPOINT)" || true
# Read the array out of the checkpoint itself: context.md could render 200 entries from
# a cache holding only 30 if the renderer refetched, and the cache is the SSOT here.
C13_CACHED="$(node -e '
const fs = require("fs");
try {
    const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const a = c.state.issue_json_cache["930"].comments;
    if (!Array.isArray(a)) { process.stdout.write("<<NOT-ARRAY>>"); process.exit(0); }
    const ordered = a.every((e, i) => e && e.body === "remark " + (i + 1));
    process.stdout.write(a.length + (ordered ? "" : " <<OUT-OF-ORDER>>"));
} catch (e) { process.stdout.write("<<UNREADABLE>>"); }
' "$C13_CKPT")"
assert_count "C13(i): the checkpoint cache holds all 200 comments, in fetch order" 200 "$C13_CACHED"
assert_ctx_count "C13(ii): context.md renders exactly 200 comment headers" '^### Comment [0-9]+ — ' 200
assert_ctx_has "C13(iii): the FIRST comment is rendered" '### Comment 1 — u1 (2026-07-01T00:00:01Z)'
assert_ctx_has "C13(iii): the LAST comment is rendered — nothing was truncated" '### Comment 200 — u200 (2026-07-01T00:00:20Z)'
assert_ctx_has "C13(iii): the last comment's body is rendered too" '> remark 200'
# Order is asserted over every pair, not spot-checked: a stable-looking first and last
# can still bracket a shuffled middle.
C13_ORDER="$(node -e '
const fs = require("fs");
const p = process.argv[1];
if (!fs.existsSync(p)) { process.stdout.write("<<NO-FILE>>"); process.exit(0); }
const lines = fs.readFileSync(p, "utf8").split("\n");
const seen = [];
for (const l of lines) {
    const m = l.match(/^### Comment (\d+) — u(\d+) /);
    if (m) seen.push(m[1] === m[2] ? Number(m[1]) : -1);
}
const ok = seen.length === 200 && seen.every((v, i) => v === i + 1);
process.stdout.write(ok ? "ORDERED" : "BROKEN:" + seen.slice(0, 8).join(",") + "…len=" + seen.length);
' "$(ctx_file)")"
assert_count "C13(iv): every header from 1 to 200 appears once, in ascending order" ORDERED "$C13_ORDER"
teardown_case
# C13 is a mock-side boundary only: it proves the pipeline CARRIES whatever gh returns.
# Whether gh returns everything is a live-API fact — see C14.

# --- C14 (live boundary): the real `gh issue view` pagination edge ---------------
# C13 feeds a complete array into the mock, so a truncation living INSIDE gh — `issue
# view --json comments` returning only the first page of a paginated thread — is defined
# away rather than tested. Ground truth is `gh api …/comments --paginate`; the claim is
# that the single `--json comments` read agrees with it on count, order and last element.
# Gated on RUN_TL3, a usable gh, and WI_COMMENTS_LIVE_ISSUE (`owner/repo#N`, >1 page).
# Missing any of those, the case SKIPs with its reason: a synthetic stand-in would only
# restate C13 while reading as live coverage.
C14_SKIP=""
if [ ! -x "$AGENTS_DIR/bin/get-config-var" ]; then
    C14_SKIP="bin/get-config-var is unavailable, so the RUN_TL3 gate cannot be read"
elif "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then
    C14_SKIP="RUN_TL3 is off — this case needs live access to api.github.com"
elif ! command -v gh >/dev/null 2>&1; then
    C14_SKIP="the gh CLI is not on PATH"
elif [ -z "${WI_COMMENTS_LIVE_ISSUE:-}" ]; then
    C14_SKIP="WI_COMMENTS_LIVE_ISSUE is unset — no live fixture issue (owner/repo#N with >1 page of comments) is available in this environment"
fi

if [ -n "$C14_SKIP" ]; then
    echo "SKIP: C14/live-pagination: Skipped-Because: $C14_SKIP"
else
    C14_REPO="${WI_COMMENTS_LIVE_ISSUE%#*}"
    C14_NUM="${WI_COMMENTS_LIVE_ISSUE##*#}"
    C14_TMP="$ROOT_TMP/c14"
    mkdir -p "$C14_TMP"
    # Both reads happen BEFORE setup_case: inside a case the PATH-prepended mock would
    # answer them, which is the layer this case exists to bypass. `@base64` keeps one
    # comment per line whatever a body contains.
    gh api "repos/$C14_REPO/issues/$C14_NUM/comments" --paginate --jq '.[] | @base64' \
        > "$C14_TMP/api-b64.txt" 2> "$C14_TMP/api.err" || true
    gh issue view "$C14_NUM" --repo "$C14_REPO" \
        --json number,title,body,labels,state,createdAt,comments \
        > "$C14_TMP/view.json" 2> "$C14_TMP/view.err" || true
    C14_CMP="$(node -e '
const fs = require("fs");
const [b64Path, viewPath] = process.argv.slice(1, 3);
const out = (s) => { process.stdout.write(s); process.exit(0); };
let api, view;
try {
    api = fs.readFileSync(b64Path, "utf8").split("\n").filter(Boolean)
        .map((l) => JSON.parse(Buffer.from(l, "base64").toString("utf8")));
} catch (e) { out("<<API-UNREADABLE>>"); }
try { view = JSON.parse(fs.readFileSync(viewPath, "utf8")); } catch (e) { out("<<VIEW-UNREADABLE>>"); }
if (!Array.isArray(api) || api.length === 0) out("<<API-EMPTY>>");
if (api.length <= 30) out("<<SINGLE-PAGE:" + api.length + ">>");
const vc = view && view.comments;
if (!Array.isArray(vc)) out("<<VIEW-NO-COMMENTS>>");
if (vc.length !== api.length) out("<<COUNT:" + vc.length + "/" + api.length + ">>");
for (let i = 0; i < api.length; i++) {
    if ((vc[i] || {}).body !== api[i].body) out("<<ORDER-OR-BODY-AT:" + (i + 1) + ">>");
}
out("MATCH:" + api.length);
' "$C14_TMP/api-b64.txt" "$C14_TMP/view.json")"
    case "$C14_CMP" in
        '<<SINGLE-PAGE:'*)
            echo "SKIP: C14/live-pagination: Skipped-Because: $WI_COMMENTS_LIVE_ISSUE has one page of comments ($C14_CMP) — it cannot exercise the pagination boundary" ;;
        '<<API-UNREADABLE>>'|'<<API-EMPTY>>'|'<<VIEW-UNREADABLE>>')
            fail "C14(i): the live reads failed: $C14_CMP; api.err=$(head -c 200 "$C14_TMP/api.err"); view.err=$(head -c 200 "$C14_TMP/view.err")" ;;
        'MATCH:'*)
            pass "C14(i): gh issue view --json comments matches the paginated API on count, order and last element ($C14_CMP)"
            C14_TOTAL="${C14_CMP#MATCH:}"
            # Second leg: the same live payload must survive the driver pipeline intact.
            setup_case wid-c2063-c14
            node -e '
const fs = require("fs");
const v = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
// State and labels are normalised so the run takes the ordinary path; the comments
// array, the only thing under test here, is copied through untouched.
v.state = "OPEN";
v.labels = [{ name: "type:task" }];
fs.writeFileSync(process.argv[2], JSON.stringify(v) + "\n");
' "$C14_TMP/view.json" "$RESP/issue-view-$C14_NUM.json"
            set_wip "$C14_NUM" same
            run_driver "#$C14_NUM"
            assert_kv "C14(ii): the live-comment issue completes the pipeline" ACTION done
            assert_ctx_count "C14(iii): context.md renders every live comment" \
                '^### Comment [0-9]+ — ' "$C14_TOTAL"
            assert_ctx_has "C14(iv): the LAST live comment is rendered — nothing truncated in the pipeline" \
                "### Comment $C14_TOTAL — "
            teardown_case ;;
        *)
            fail "C14(i): gh issue view --json comments disagrees with the paginated API: $C14_CMP" ;;
    esac
fi

# --- C18 (write path): write-context.js cannot write its own artifact -------------
# The permission coverage so far is entirely on the READ side (an unreadable checkpoint,
# feature-2063-render-issue-comments/error-tokens.sh P25). Its symmetric half is the
# write: #2063 makes write-context.js emit a section built from third-party text, and a
# writer that fails halfway through is how a context.md ends up holding a truncated
# comment — or how a session reports `done` over a file that was never written. Neither
# the token nor the wording is pinned here: the plan gives write-context.js no failure
# vocabulary of its own, so only the fail-closed observables every driver failure shares
# are asserted (CPR-SC — the contract that exists, not one invented by the test).
assert_write_failure() {  # <id> <what>
    assert_no_uncaught "C18$1: $2 is handled, not thrown"
    assert_single_action_line "C18$1: $2 still emits exactly one directive line"
    if [ "$(get_kv ACTION)" = "done" ]; then
        fail "C18$1: the session reported done though context.md was never written"
    else
        pass "C18$1: no success is claimed for a run that could not write context.md"
    fi
}

# (a) The portable arm: a DIRECTORY occupies the exact context.md path, so the write
# fails with EISDIR while the plans dir itself stays writable — which keeps the failure
# scoped to write-context.js instead of taking the checkpoint writer down with it. No
# chmod is involved, so this arm runs on every host including Windows.
setup_case wid-c2063-c18a
mock_issue 950 OPEN "type:task"
mock_issue_comments 950 '[{"author":{"login":"alice"},"body":"a remark that must never be half-written","createdAt":"2026-07-02T00:00:00Z"}]'
set_wip 950 same
C18A_PATH="$(ctx_file)"
mkdir -p "$C18A_PATH"
run_driver '#950'
assert_write_failure a "an unwritable context.md path"
if [ -d "$C18A_PATH" ]; then
    pass "C18a: the blocking directory is still a directory — nothing replaced it"
else
    fail "C18a: the context.md path is no longer the directory the case staged"
fi
C18A_INSIDE="$(ls -A "$C18A_PATH" 2>/dev/null | tr '\n' ' ')"
if [ -z "$C18A_INSIDE" ]; then
    pass "C18a: no partial artifact was written inside the blocked path"
else
    fail "C18a: the failed write left content at the context.md path: $C18A_INSIDE"
fi
# A writer that fell back to a temp name, or to a neighbouring path, leaves the same
# third-party text on disk under a different name — the leak this arm exists to catch.
C18A_STRAY="$(grep -rlF -- 'a remark that must never be half-written' "$PLANS" 2>/dev/null | tr '\n' ' ')"
if [ -z "$C18A_STRAY" ]; then
    pass "C18a: no fallback or temp file carries the comment text"
else
    fail "C18a: comment text was written to a fallback artifact: $C18A_STRAY"
fi
teardown_case

# (b) The genuine EACCES arm. Same discipline as P25: the fixture is verified to be
# really unwritable before the case is claimed, and a host that ignores POSIX modes
# (root, or a filesystem that does not enforce them) SKIPs with its reason rather than
# reporting a pass that proves nothing.
setup_case wid-c2063-c18b
mock_issue 951 OPEN "type:task"
set_wip 951 same
chmod 555 "$PLANS" 2>/dev/null || true
C18B_WRITABLE="$(node -e '
const fs = require("fs");
const p = require("path").join(process.argv[1], "c18b-probe.tmp");
try { fs.writeFileSync(p, "x"); fs.unlinkSync(p); process.stdout.write("WRITABLE"); }
catch (e) { process.stdout.write("DENIED:" + (e.code || "?")); }
' "$PLANS" 2>/dev/null || printf 'WRITABLE:probe-failed')"
case "$C18B_WRITABLE" in
    DENIED:*)
        run_driver '#951'
        assert_write_failure b "an unwritable plans directory"
        if [ -f "$(ctx_file)" ]; then
            fail "C18b: a context.md exists though the directory rejects writes: $(ctx_file)"
        else
            pass "C18b: no partial context.md artifact survives the denied write"
        fi ;;
    *)
        echo "SKIP: C18b/plans-dir-unwritable: Skipped-Because: this host still writes into a mode-555 directory ($C18B_WRITABLE) — the process runs as root/Administrator or the filesystem ignores POSIX modes, so a genuine EACCES cannot be staged here; the EISDIR arm C18a covers the same write-failure contract on such a host" ;;
esac
chmod 755 "$PLANS" 2>/dev/null || true
teardown_case

finish
