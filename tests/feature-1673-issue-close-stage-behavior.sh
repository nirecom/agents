#!/usr/bin/env bash
# tests/feature-1673-issue-close-stage-behavior.sh
# Tests: bin/worker-dispatch/workers/issue-close-stage.js, skills/issue-close-stage/scripts/run-stage-chain.sh, bin/worker-dispatch.js
# Tags: worker-dispatch, issue-close-stage, kv-parsing, no-eval, stub-seam, table-driven, TL2, scope:issue-specific
#
# Issue #1673 — agents/issue-close-stage-worker.md told an LLM to run
# `eval "$(bash run-stage-chain.sh ...)"`. That eval is the whole risk surface of
# the old design: SUMMARY carries issue-derived text, and one unbalanced quote or
# one `$(...)` in an issue title turns a status report into command execution.
# The plain worker must parse the KEY=VALUE stdout WITHOUT eval and must survive
# any byte sequence in SUMMARY.
#
# Group A drives the REAL run-stage-chain.sh against a fixture AGENTS_CONFIG_DIR
# and a PATH `gh` stub, so the KV shape the worker parses is measured, not
# assumed. Groups B/C drive the real dispatcher with the child-process seam
# canned (tests/feature-1643-worker-dispatch-lib/spawn-stub.js) so every KV
# corruption case can be produced on demand.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - The real `gh` binary's comment-URL shape, which Step D scrapes for the
#     comment id, and a real linked-worktree dispatch. Both are fenced by
#     tests/TL3-issue-close-stage-dispatch.sh (RUN_TL3-gated).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_ICS1673_BEH_INNER:-}" ]; then
    _ICS1673_BEH_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
CHAIN_SH="$AGENTS_DIR/skills/issue-close-stage/scripts/run-stage-chain.sh"
WORKER_JS="$AGENTS_DIR/bin/worker-dispatch/workers/issue-close-stage.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "needle=$(printf '%q' "$needle") in=$(printf '%q' "$hay")" ;;
    esac
}
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        # The needle is never echoed back on failure: this assertion exists for
        # credentials, and the failure message is itself a log.
        *"$needle"*) fail "$name" "forbidden substring present" ;;
        *) pass "$name" ;;
    esac
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ics1673-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# ===========================================================================
# Group A — the real run-stage-chain.sh KV contract (green today)
# ===========================================================================
bash "$AGENTS_DIR/tests/feature-1673-issue-close-stage-lib/make-chain-fixture.sh" "$TMPD"
FAKE_ACD="$TMPD/fakeacd"

# chain_out [VAR=value ...] — extra assignments steer the fixture scripts.
chain_out() {
    env PATH="$TMPD/ghbin:$PATH" AGENTS_CONFIG_DIR="$FAKE_ACD" "$@" \
        bash "$CHAIN_SH" 12 example-owner/example-repo 2>/dev/null
}
kv_of() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }

group_chain_kv() {
    if [ ! -f "$CHAIN_SH" ]; then
        fail "chainkv/script-present" "missing $CHAIN_SH"
        return
    fi
    local out
    out="$(chain_out)"
    assert_eq "chainkv/proceed/status" "phase1_done" "$(kv_of STATUS "$out")"
    assert_eq "chainkv/proceed/comment-id" "987654" "$(kv_of COMMENT_ID "$out")"
    assert_contains "chainkv/proceed/summary" "Phase 1 complete for #12" "$(kv_of SUMMARY "$out")"

    out="$(chain_out STUB_GATE_RC=1)"
    assert_eq "chainkv/blocked/status" "blocked_sub_issue" "$(kv_of STATUS "$out")"
    assert_contains "chainkv/blocked/summary" "sub-issue gate blocked" "$(kv_of SUMMARY "$out")"

    out="$(chain_out STUB_GH_API_RC=1 STUB_STEPS=F)"
    assert_eq "chainkv/patch-failure/status" "error" "$(kv_of STATUS "$out")"

    out="$(chain_out STUB_ACTION=phase1_done)"
    assert_eq "chainkv/already-done/status" "phase1_done" "$(kv_of STATUS "$out")"
}

# ===========================================================================
# Group B — the dispatcher, with run-stage-chain.sh canned
# ===========================================================================
MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/ics-probe "$LINKED_RAW" >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"

# set_chain <stdout> [exit-status] — written via node so no escaping is needed.
#
# The chain spawn is the SECOND child: the worker first resolves the repo the
# validated worktree belongs to and refuses if payload `owner_repo` differs.
# #1899: that probe is now `git remote get-url origin` (a local read) instead
# of `gh repo view --json nameWithOwner` (which can answer `upstream` on a
# fork), so the canned rule returns an origin URL, not an owner/repo pair. The
# probe here reports the same repo the payload claims, exercising the chain
# path; the mismatch path is covered in feature-1673-issue-close-stage-schema.sh.
#
# write_canned <origin-url> <chain-stdout> [chain-exit-status] — origin URL is a
# parameter because the probe's OUTPUT is itself a test input (see the
# credential group below); set_chain pins it to the credential-free form.
write_canned() {
    node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify([
  { match: "remote get-url origin", stdout: process.argv[2] + "\n", status: 0 },
  { match: "stageChain", stdout: process.argv[3], status: Number(process.argv[4] || 0) },
  { stdout: "", status: 0 },
]));' "$(nodepath "$CANNED")" "$1" "$2" "${3:-0}"
}

set_chain() {
    write_canned "https://github.com/example-owner/example-repo.git" "$1" "${2:-0}"
}

DOUT=""; DRC=0
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }
field_of() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }
line_count() { printf '%s\n' "$DOUT" | grep -c '' | tr -d ' '; }

dispatch_stage() {
    DRC=0
    : > "$CALLLOG"
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" \
        issue-close-stage "$MAIN" "$1" 2>/dev/null)" || DRC=$?
}
# call_field <field> [row-index] — row 0 is the `git remote get-url origin` repo
# probe (#1899; formerly `gh repo view`), row 1 the chain spawn. The index is explicit so an added or reordered child process
# shows up as a want!=got instead of silently re-pointing an assertion.
call_field() {
    node -e '
const fs = require("fs");
const raw = fs.readFileSync(process.argv[1], "utf8").trim();
if (!raw) { process.stdout.write("(no-calls)"); process.exit(0); }
const rows = raw.split("\n").filter(Boolean).map(JSON.parse);
const f = process.argv[2];
if (f === "count") { process.stdout.write(String(rows.length)); process.exit(0); }
const idx = Number(process.argv[3] || 0);
const r = rows[idx];
if (!r) { process.stdout.write("(no-row-" + idx + ")"); process.exit(0); }
if (f === "args") { process.stdout.write(r.args.join(" ")); process.exit(0); }
if (f === "script_base") {
  process.stdout.write(String(r.script || "").split(/[\\/]/).pop());
  process.exit(0);
}
process.stdout.write(String(r[f] === null || r[f] === undefined ? "(null)" : r[f]));
' "$(nodepath "$CALLLOG")" "$1" "${2:-0}"
}
# artifact_text <path> — read the on-disk worker log. Read through node, not
# `cat`: artifact_path comes back as a native absolute path, which on Windows is
# a drive-letter form the shell would not open the same way node does.
artifact_text() {
    node -e '
const fs = require("fs");
try { process.stdout.write(fs.readFileSync(process.argv[1], "utf8")); }
catch (e) { process.stdout.write("(unreadable: " + (e && e.code ? e.code : "unknown") + ")"); }
' "$1"
}
# The renderer is status-triple-quoted, so the artifact_path slot arrives wrapped
# in double quotes.
unquote() { local v="$1"; v="${v#\"}"; v="${v%\"}"; printf '%s' "$v"; }

PAYLOAD_JSON="{\"issue_number\":12,\"worktree_path\":\"$LINKED\",\"owner_repo\":\"example-owner/example-repo\",\"artifact_dir\":\"$PLANS\"}"

impl_ready() {
    if [ -f "$WORKER_JS" ] && [ -f "$DISPATCH_JS" ] && [ -f "$PRELOAD" ]; then return 0; fi
    fail "$1" "implementation missing: bin/worker-dispatch/workers/issue-close-stage.js"
    return 1
}

group_status_mapping() {
    local name kv want p
    while IFS='|' read -r name kv want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; want="$(echo "$want" | xargs)"
        kv="${kv#"${kv%%[![:space:]]*}"}"; kv="${kv%"${kv##*[![:space:]]}"}"
        impl_ready "status/$name" || continue
        set_chain "$(printf '%b' "$kv")"
        p="$(write_payload "stage-$name" "$PAYLOAD_JSON")"
        dispatch_stage "$p"
        assert_eq "status/$name/status" "$want" "$(field_of status)"
        assert_eq "status/$name/exit0" "0" "$DRC"
        assert_eq "status/$name/three-lines" "3" "$(line_count)"
    done <<'TABLE'
phase1-done  | STATUS=phase1_done\nSUMMARY=Phase 1 complete for #12 (comment 987654)\nCOMMENT_ID=987654\n | phase1_done
blocked      | STATUS=blocked_sub_issue\nSUMMARY=sub-issue gate blocked #12\n                          | blocked_sub_issue
chain-error  | STATUS=error\nSUMMARY=Step D: failed to extract comment ID\n                            | error
crlf         | STATUS=phase1_done\r\nSUMMARY=done\r\nCOMMENT_ID=1\r\n                                   | phase1_done
TABLE
}

# A status token the chain never emits, an empty stdout, and a non-zero exit all
# have to fail CLOSED — never be echoed through as a status the caller's branch
# table does not cover.
group_fail_closed() {
    local name kv rc p got
    while IFS='|' read -r name kv rc; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; rc="$(echo "$rc" | xargs)"
        kv="${kv#"${kv%%[![:space:]]*}"}"; kv="${kv%"${kv##*[![:space:]]}"}"
        impl_ready "failclosed/$name" || continue
        set_chain "$(printf '%b' "$kv")" "$rc"
        p="$(write_payload "fc-$name" "$PAYLOAD_JSON")"
        dispatch_stage "$p"
        got="$(field_of status)"
        case "$got" in
            error|failed) pass "failclosed/$name" ;;
            *) fail "failclosed/$name" "status='$got'" ;;
        esac
        assert_eq "failclosed/$name/exit0" "0" "$DRC"
    done <<'TABLE'
unknown-status | STATUS=totally_new_token\nSUMMARY=x\n | 0
no-status-key  | SUMMARY=x\nCOMMENT_ID=3\n            | 0
empty-stdout   |                                      | 0
nonzero-exit   | STATUS=phase1_done\nSUMMARY=x\n      | 4
TABLE
}

# The corruption cases the old `eval` could not survive.
group_quoting_resilience() {
    impl_ready "quoting/setup" || return
    local p sum
    set_chain "$(printf 'STATUS=error\nSUMMARY=Step F: PATCH failed a="b" c=$(id) `id` && rm -rf / |x| %s\n' "'unbalanced")"
    p="$(write_payload stage-quoting "$PAYLOAD_JSON")"
    dispatch_stage "$p"
    assert_eq "quoting/status" "error" "$(field_of status)"
    assert_eq "quoting/three-lines" "3" "$(line_count)"
    sum="$(field_of summary)"
    # Value keeps everything after the FIRST '=' — a naive split on every '='
    # would truncate at `a=`.
    assert_contains "quoting/keeps-later-equals" 'a=' "$sum"
    # No shell ever saw the text: the command substitution survives literally.
    assert_contains "quoting/no-command-substitution" '$(id)' "$sum"
    if [ -e "$LINKED_RAW/README.md" ]; then
        pass "quoting/rm-rf-not-executed"
    else
        fail "quoting/rm-rf-not-executed" "worktree content disappeared"
    fi
    # emit.js normalizes `"` to `'` inside the quoted slot; the triple stays parseable.
    case "$sum" in
        '"'*'"') pass "quoting/summary-slot-well-formed" ;;
        *) fail "quoting/summary-slot-well-formed" "summary=$sum" ;;
    esac
}

group_spawn_seam() {
    impl_ready "seam/setup" || return
    local p
    set_chain "$(printf 'STATUS=phase1_done\nSUMMARY=ok\nCOMMENT_ID=1\n')"
    p="$(write_payload stage-seam "$PAYLOAD_JSON")"
    dispatch_stage "$p"
    # Exactly two children: the repo probe, then the chain. Nothing else.
    assert_eq "seam/two-child-processes" "2" "$(call_field count)"
    # Row 0 — the repo probe. #1899: it must be a read-only, LOCAL git read of the
    # ORIGIN remote (not `gh repo view`, which consults the API and can answer
    # with `upstream` on a fork), and it must run in the worktree whose
    # repository is being resolved. Naming `origin` explicitly in the argv is the
    # load-bearing part: `git remote get-url` without it, or with a different
    # remote, would reintroduce the ambiguity.
    assert_eq "seam/probe-command-is-git" "git" "$(call_field command 0)"
    assert_eq "seam/probe-argv-is-origin-url" \
        "remote get-url origin" "$(call_field args 0)"
    assert_eq "seam/probe-cwd-is-linked-worktree" "$LINKED" "$(nodepath "$(call_field cwd 0)")"
    # Row 1 — the chain itself.
    assert_eq "seam/command-is-bash" "bash" "$(call_field command 1)"
    assert_eq "seam/script-is-stage-chain" "stageChain" "$(call_field script_base 1)"
    assert_eq "seam/argv-is-issue-and-repo" "12 example-owner/example-repo" "$(call_field args 1)"
    assert_eq "seam/cwd-is-linked-worktree" "$LINKED" "$(nodepath "$(call_field cwd 1)")"
}

# ===========================================================================
# Group B2 — a token-bearing origin URL must not land in the on-disk log
#
# #1899 made the repo probe `git remote get-url origin`, whose output can carry
# an access token in HTTPS userinfo (https://x-access-token:<token>@github.com/
# owner/repo.git). That output is persisted to a log file the calling skill
# reads back, so resolveCurrentRepo routes stdout/stderr through
# redactUserinfo first. Assertion is on the FILE, not dispatcher stdout (which
# carries only the status triple and would hide an unredacted entry).
#
# The credential below is a FAKE placeholder — 16 chars after `ghp_`, under the
# 36 bin/scan-outbound.sh's github-token pattern needs. Same placeholder as
# tests/fix-1899-parse-remote-url/redaction.sh.
# ===========================================================================
group_origin_credential_redaction() {
    impl_ready "redact/setup" || return
    local fake='ghp_EXAMPLEEXAMPLE'
    local p art body
    write_canned "https://x-access-token:${fake}@github.com/example-owner/example-repo.git" \
        "$(printf 'STATUS=phase1_done\nSUMMARY=ok\nCOMMENT_ID=1\n')"
    p="$(write_payload stage-redact "$PAYLOAD_JSON")"
    dispatch_stage "$p"
    # The credential is not a parse failure: the URL still names the payload's
    # repo, so the run reaches the chain rather than bailing before the log write.
    assert_eq "redact/status" "phase1_done" "$(field_of status)"

    art="$(unquote "$(field_of artifact_path)")"
    if [ -z "$art" ] || [ "$art" = "(none)" ]; then
        fail "redact/artifact-written" "artifact_path=$art — nothing on disk to inspect"
        return
    fi
    pass "redact/artifact-written"
    body="$(artifact_text "$art")"
    # The probe line must actually BE in the file. Without this, a log that never
    # recorded the URL at all would satisfy the secret assertion vacuously.
    assert_contains "redact/log-records-probe-output" \
        "***@github.com/example-owner/example-repo.git" "$body"
    assert_not_contains "redact/no-raw-token-on-disk" "$fake" "$body"
}

# ===========================================================================
# Group C — source inspection: the worker must never eval
# ===========================================================================
group_no_eval() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "noeval/worker-present" "missing bin/worker-dispatch/workers/issue-close-stage.js"
        return
    fi
    # Patterns are ERE. `eval(` must escape its paren: an unescaped one makes grep
    # exit 2 on a syntax error, which reads identically to "not found" and turns
    # the most important assertion of this group into a permanent false green.
    local pat label
    for pat in 'eval\(' 'new Function' 'shell: *true' 'execSync' 'child_process'; do
        label=${pat//\\/}
        if grep -qE "$pat" "$WORKER_JS"; then
            fail "noeval/absent-$label" "issue-close-stage.js references $label"
        else
            pass "noeval/absent-$label"
        fi
    done
    # run-stage-chain.sh exports ISSUE_CLOSE_SKILL itself — the worker must not
    # set it into the child environment.
    if grep -q 'ISSUE_CLOSE_SKILL' "$WORKER_JS"; then
        fail "noeval/no-issue-close-skill-env" "issue-close-stage.js sets ISSUE_CLOSE_SKILL"
    else
        pass "noeval/no-issue-close-skill-env"
    fi
}

group_chain_kv
group_status_mapping
group_fail_closed
group_quoting_resilience
group_spawn_seam
group_origin_credential_redaction
group_no_eval

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
