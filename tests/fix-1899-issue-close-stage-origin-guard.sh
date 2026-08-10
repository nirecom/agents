#!/usr/bin/env bash
# tests/fix-1899-issue-close-stage-origin-guard.sh
# Tests: bin/worker-dispatch/workers/issue-close-stage.js, hooks/lib/parse-remote-url.js, bin/worker-dispatch.js
# Tags: worker-dispatch, issue-close-stage, origin-resolution, fail-closed, secret-redaction, security, table-driven, stub-seam, TL2, scope:issue-specific
#
# Issue #1899 — the issue-close-stage worker decides WHICH repository Phase 1
# mutates. It used to ask `gh repo view --json nameWithOwner`, which on a fork
# carrying both `origin` and `upstream` can answer with the upstream repository,
# so Steps D/F/G land on the wrong repo while the caller reads `phase1_done` for
# the one it meant. The fix replaces that probe with a local
# `git remote get-url origin` read, parsed by hooks/lib/parse-remote-url.js.
#
# tests/feature-1673-issue-close-stage-behavior.sh cans the probe to AGREE with
# the payload (happy path + redaction only) and never drives the guard itself.
# The guard's value is negative: when the probe can't produce a trustworthy
# owner/repo, the chain must NOT run — reporting `error` while still spawning it
# would pass every status assertion. So every BLOCK case here asserts the
# CHILD-PROCESS COUNT (1 = only the probe ran), not just the status token.
#
# Group D is the secret half: an HTTPS origin can carry an access token in its
# userinfo. On probe FAILURE the credential can reach an error message
# (`parsed.message`, or git's stderr) rendered into both the dispatcher's
# `summary` and the on-disk artifact — both surfaces are asserted absent-of-token.
# Credentials are FAKE placeholders (`ghp_EXAMPLEEXAMPLE`, under
# bin/scan-outbound.sh's token-pattern length), same as
# tests/fix-1899-parse-remote-url/redaction.sh.
#
# TL2: real dispatcher, payload/capability walls, worker, and parse-remote-url.js
# run; only the child-process seam is canned
# (tests/feature-1643-worker-dispatch-lib/spawn-stub.js).
# TL3 gap (what this does NOT catch): no real fork checkout with two remotes and
# no real `git` binary produce the probe output here, so a real git whose
# `remote get-url origin` output shape differs (extra whitespace, insteadOf
# rewriting, a URL rewritten by a credential helper) is out of reach, and no real
# `gh` round-trip proves the resolved owner/repo is the repository GitHub itself
# resolves. Fenced by tests/TL3-issue-close-stage-dispatch.sh (RUN_TL3-gated).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_FIX1899_ICS_INNER:-}" ]; then
    _FIX1899_ICS_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
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
# The needle is never echoed back on failure: this assertion exists for
# credentials, and the failure message is itself a log.
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) fail "$name" "forbidden substring present (${#hay} bytes inspected)" ;;
        *) pass "$name" ;;
    esac
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/fix1899ics-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a real main repo + a real linked worktree. The dispatcher's anchor and
# payload walls are real, so worktree_path must genuinely be a member of the
# main-root family or the run is rejected before the worker is ever entered.
# ---------------------------------------------------------------------------
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
git -C "$MAIN_RAW" worktree add -q -b feature/origin-guard "$LINKED_RAW" >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"

CHAIN_OK="$(printf 'STATUS=phase1_done\nSUMMARY=Phase 1 complete for #12 (comment 987654)\nCOMMENT_ID=987654\n')"

# can_probe <stdout> <stderr> <status> <timedOut:true|false> <spawnError|__NULL__>
#   Writes the canned rule set: rule 0 answers the `git remote get-url origin`
#   probe with exactly the failure/success shape under test, rule 1 answers the
#   stage chain with a SUCCESSFUL Phase 1. Rule 1 is deliberately a success: if
#   the guard leaked, the chain would report `phase1_done` and the run would look
#   completely healthy — which is precisely the #1899 failure mode, and why the
#   child count rather than the status is the load-bearing assertion.
#   Written through node so no shell escaping of the URL is needed.
can_probe() {
    node -e '
const fs = require("fs");
const rule = { match: "remote get-url origin", stdout: process.argv[2], stderr: process.argv[3], status: Number(process.argv[4]) };
if (process.argv[5] === "true") rule.timedOut = true;
if (process.argv[6] !== "__NULL__") rule.spawnError = process.argv[6];
fs.writeFileSync(process.argv[1], JSON.stringify([
  rule,
  { match: "stageChain", stdout: process.argv[7], status: 0 },
  { stdout: "", status: 0 },
]));' "$(nodepath "$CANNED")" "$1" "$2" "$3" "$4" "$5" "$CHAIN_OK"
}
# can_origin <url> — the ordinary shape: probe succeeds and prints <url>.
can_origin() { can_probe "$1
" "" 0 false __NULL__; }

DOUT=""; DRC=0
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }
field_of() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }
unquote() { local v="$1"; v="${v#\"}"; v="${v%\"}"; printf '%s' "$v"; }

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
# call_count -> number of intercepted child spawns for the last dispatch.
call_count() {
    node -e '
const fs = require("fs");
let raw = "";
try { raw = fs.readFileSync(process.argv[1], "utf8").trim(); } catch (e) { process.stdout.write("(unreadable)"); process.exit(0); }
process.stdout.write(String(raw ? raw.split("\n").filter(Boolean).length : 0));
' "$(nodepath "$CALLLOG")"
}
# call_line <index> -> "<command> <args...>" of the nth intercepted spawn.
call_line() {
    node -e '
const fs = require("fs");
let raw = "";
try { raw = fs.readFileSync(process.argv[1], "utf8").trim(); } catch (e) { process.stdout.write("(unreadable)"); process.exit(0); }
const rows = raw ? raw.split("\n").filter(Boolean).map(JSON.parse) : [];
const r = rows[Number(process.argv[2])];
if (!r) { process.stdout.write("(no-row)"); process.exit(0); }
process.stdout.write([r.command].concat(r.args || []).join(" "));
' "$(nodepath "$CALLLOG")" "$1"
}
artifact_text() {
    node -e '
const fs = require("fs");
try { process.stdout.write(fs.readFileSync(process.argv[1], "utf8")); }
catch (e) { process.stdout.write("(unreadable: " + (e && e.code ? e.code : "unknown") + ")"); }
' "$1"
}

# payload_json <owner_repo> [issue_repo]
payload_json() {
    local extra=""
    if [ -n "${2:-}" ]; then extra=",\"issue_repo\":\"$2\""; fi
    printf '{"issue_number":12,"worktree_path":"%s","owner_repo":"%s","artifact_dir":"%s"%s}' \
        "$LINKED" "$1" "$PLANS" "$extra"
}

impl_ready() {
    if [ -f "$WORKER_JS" ] && [ -f "$DISPATCH_JS" ] && [ -f "$PRELOAD" ]; then return 0; fi
    fail "$1" "implementation missing: bin/worker-dispatch/workers/issue-close-stage.js"
    return 1
}

# ===========================================================================
# Group A — ALLOW: the probe agrees with the payload, so the chain runs.
#
#   These are the positive controls the BLOCK group depends on. Without them a
#   worker that refused EVERYTHING would satisfy every child-count assertion
#   below and look perfectly guarded.
# ===========================================================================
group_allow() {
    local name owner_repo issue_repo url p
    while IFS='|' read -r name owner_repo issue_repo url; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; owner_repo="$(echo "$owner_repo" | xargs)"
        issue_repo="$(echo "$issue_repo" | xargs)"; url="$(echo "$url" | xargs)"
        [ "$issue_repo" = "__NONE__" ] && issue_repo=""
        impl_ready "allow/$name" || continue

        can_origin "$url"
        p="$(write_payload "allow-$name" "$(payload_json "$owner_repo" "$issue_repo")")"
        dispatch_stage "$p"
        assert_eq "allow/$name/status" "phase1_done" "$(field_of status)"
        assert_eq "allow/$name/chain-ran" "2" "$(call_count)"
        # The chain's argv must carry the RESOLVED repo, not the payload's claim —
        # they are equal here by construction, which is what makes the BLOCK
        # group's refusals meaningful rather than incidental.
        assert_eq "allow/$name/chain-argv" "bash 12 example-owner/example-repo" "$(call_line 1)"
    done <<'TABLE'
# name                | owner_repo                 | issue_repo                 | origin url
no-issue-repo         | example-owner/example-repo | __NONE__                   | https://github.com/example-owner/example-repo.git
issue-repo-full       | example-owner/example-repo | example-owner/example-repo | https://github.com/example-owner/example-repo.git
issue-repo-bare       | example-owner/example-repo | example-repo               | https://github.com/example-owner/example-repo.git
# GitHub is case-insensitive about owner and repo names, so a differently-cased
# payload names the SAME repository and must not be refused.
owner-repo-case-fold  | Example-Owner/Example-Repo | __NONE__                   | https://github.com/example-owner/example-repo.git
issue-repo-case-fold  | example-owner/example-repo | EXAMPLE-REPO               | https://github.com/example-owner/example-repo.git
# The probe's URL FORM must not change the verdict: an SCP remote and a
# token-bearing HTTPS remote name the same repository as the plain HTTPS one.
scp-origin-form       | example-owner/example-repo | __NONE__                   | git@github.com:example-owner/example-repo.git
origin-trailing-slash | example-owner/example-repo | __NONE__                   | https://github.com/example-owner/example-repo.git/
TABLE
}

# ===========================================================================
# Group B — BLOCK: every way the probe can fail to name the payload's repo.
#
#   Two assertions per row, and the second is the one that matters:
#     status == error      the caller is told
#     child count == 1     the chain NEVER SPAWNED
#   The canned chain would have reported `phase1_done`, so a guard that reports
#   `error` after letting the chain run would fail the count assertion while
#   passing the status one — which is the exact shape of the #1899 defect.
# ===========================================================================
group_block_mismatch() {
    local name owner_repo issue_repo url p
    while IFS='|' read -r name owner_repo issue_repo url; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; owner_repo="$(echo "$owner_repo" | xargs)"
        issue_repo="$(echo "$issue_repo" | xargs)"; url="$(echo "$url" | xargs)"
        [ "$issue_repo" = "__NONE__" ] && issue_repo=""
        impl_ready "block/$name" || continue

        can_origin "$url"
        p="$(write_payload "block-$name" "$(payload_json "$owner_repo" "$issue_repo")")"
        dispatch_stage "$p"
        assert_eq "block/$name/status" "error" "$(field_of status)"
        assert_eq "block/$name/chain-never-spawned" "1" "$(call_count)"
        assert_eq "block/$name/only-child-is-probe" "git remote get-url origin" "$(call_line 0)"
    done <<'TABLE'
# name                 | owner_repo                 | issue_repo   | origin url
# The upstream-vs-origin case itself: the payload claims the upstream repo, the
# checkout's origin says otherwise.
payload-claims-upstream| upstream-owner/upstream-repo | __NONE__   | https://github.com/example-owner/example-repo.git
# Same repo NAME under a different owner — the near-miss a substring or
# bare-name comparison would wave through.
same-name-other-owner  | other-owner/example-repo   | __NONE__     | https://github.com/example-owner/example-repo.git
same-owner-other-name  | example-owner/other-repo   | __NONE__     | https://github.com/example-owner/example-repo.git
# Cross-repo Phase 1 via issue_repo: owner_repo agrees, issue_repo does not.
issue-repo-other-full  | example-owner/example-repo | other-owner/other-repo | https://github.com/example-owner/example-repo.git
issue-repo-other-bare  | example-owner/example-repo | other-repo   | https://github.com/example-owner/example-repo.git
# The bare form must be matched against the REPO half only. `example-owner` is
# the OWNER of the current repo, never a legal bare repo-ref for it.
issue-repo-bare-is-owner | example-owner/example-repo | example-owner | https://github.com/example-owner/example-repo.git
TABLE
}

group_block_unresolvable() {
    local name url p
    while IFS='|' read -r name url; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; url="$(echo "$url" | xargs)"
        [ "$url" = "__EMPTY__" ] && url=""
        impl_ready "unresolvable/$name" || continue

        can_origin "$url"
        p="$(write_payload "unres-$name" "$(payload_json example-owner/example-repo)")"
        dispatch_stage "$p"
        assert_eq "unresolvable/$name/status" "error" "$(field_of status)"
        assert_eq "unresolvable/$name/chain-never-spawned" "1" "$(call_count)"
    done <<'TABLE'
# name              | origin url
empty-origin        | __EMPTY__
non-github-origin   | https://gitlab.com/example-owner/example-repo.git
lookalike-host      | https://github.com.evil.example/example-owner/example-repo.git
owner-only-path     | https://github.com/example-owner
path-too-deep       | https://github.com/example-owner/team/example-repo
dot-segment-owner   | https://github.com/../example-repo
at-in-path-rebase   | https://github.com/example-owner/example-repo@example.com/attacker/repo
not-a-url-at-all    | fatal-not-a-git-repository
TABLE
}

# The probe process itself misbehaving. FAIL CLOSED means "no target at all",
# never a fallback to the payload's claim — and the payload's claim is CORRECT in
# every row here, so a fallback would produce a green `phase1_done` and a spawned
# chain. That is what makes these rows discriminating rather than decorative.
group_block_probe_failure() {
    local name stdout stderr status timedout spawnerr p
    while IFS='|' read -r name stdout stderr status timedout spawnerr; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; stdout="$(echo "$stdout" | xargs)"
        stderr="$(echo "$stderr" | xargs)"; status="$(echo "$status" | xargs)"
        timedout="$(echo "$timedout" | xargs)"; spawnerr="$(echo "$spawnerr" | xargs)"
        [ "$stdout" = "__EMPTY__" ] && stdout=""
        [ "$stderr" = "__EMPTY__" ] && stderr=""
        impl_ready "probefail/$name" || continue

        can_probe "$stdout" "$stderr" "$status" "$timedout" "$spawnerr"
        p="$(write_payload "pf-$name" "$(payload_json example-owner/example-repo)")"
        dispatch_stage "$p"
        assert_eq "probefail/$name/status" "error" "$(field_of status)"
        assert_eq "probefail/$name/chain-never-spawned" "1" "$(call_count)"
        # The dispatcher itself must still exit 0: a refusal is a reported
        # outcome, not a crash the caller has to interpret from an exit code.
        assert_eq "probefail/$name/dispatcher-exit0" "0" "$DRC"
    done <<'TABLE'
# name        | probe stdout                                       | probe stderr                            | status | timedOut | spawnError
git-timeout   | __EMPTY__                                          | __EMPTY__                               | 0      | true     | __NULL__
git-spawnfail | __EMPTY__                                          | __EMPTY__                               | 0      | false    | ENOENT
git-exit128   | __EMPTY__                                          | fatal: not a git repository             | 128    | false    | __NULL__
git-exit1-noremote | __EMPTY__                                     | error: No such remote origin            | 1      | false    | __NULL__
# Non-zero exit WITH a plausible URL on stdout: the value must be discarded
# because the command failed, not used because it happens to look right.
git-exit1-with-stdout | https://github.com/example-owner/example-repo.git | fatal: broken            | 1      | false    | __NULL__
TABLE
}

# ===========================================================================
# Group C — the ALLOW group is not vacuous: prove the canned chain really does
#   report success, so "chain never spawned" is a statement about the guard and
#   not about a chain rule that never fires.
# ===========================================================================
group_positive_control() {
    impl_ready "control/setup" || return
    can_origin "https://github.com/example-owner/example-repo.git"
    local p
    p="$(write_payload control-chain "$(payload_json example-owner/example-repo)")"
    dispatch_stage "$p"
    assert_eq "control/chain-rule-fires" "2" "$(call_count)"
    assert_contains "control/chain-summary-reaches-caller" "Phase 1 complete for #12" "$(field_of summary)"
}

# ===========================================================================
# Group D — a credential must not survive a FAILING probe.
#
#   Three distinct leak surfaces, and the behaviour suite covers none of them
#   because it only cans a probe that SUCCEEDS:
#     1. an unparsable URL that still carries userinfo — resolveCurrentRepo puts
#        `parsed.message` into the refusal summary, and that message is built
#        from the URL
#     2. git's STDERR on a failed invocation, which commonly echoes the remote
#        URL back and is pushed into the same on-disk log
#     3. a well-formed but MISMATCHED origin, where the refusal summary names the
#        resolved repository — the resolved value must be the owner/repo, never
#        the raw URL it came from
#   Each row asserts the credential is absent from BOTH the dispatcher's stdout
#   (which the calling skill reads and may quote into a comment) and the artifact
#   file on disk. Each also asserts a positive marker, so a run that produced no
#   text at all cannot satisfy the absence assertion vacuously.
# ===========================================================================
group_credential_on_failure() {
    impl_ready "cred/setup" || return
    local fake='ghp_EXAMPLEEXAMPLE'
    local p art body

    # (1) unparsable URL carrying userinfo: the host is a lookalike, so parsing
    # fails AFTER the userinfo has been seen.
    can_origin "https://x-access-token:${fake}@github.com.evil.example/example-owner/example-repo.git"
    p="$(write_payload cred-unparsable "$(payload_json example-owner/example-repo)")"
    dispatch_stage "$p"
    assert_eq "cred/unparsable/status" "error" "$(field_of status)"
    assert_eq "cred/unparsable/chain-never-spawned" "1" "$(call_count)"
    assert_contains "cred/unparsable/summary-explains" "origin remote" "$(field_of summary)"
    assert_not_contains "cred/unparsable/no-token-in-stdout" "$fake" "$DOUT"
    art="$(unquote "$(field_of artifact_path)")"
    if [ -n "$art" ] && [ "$art" != "(none)" ]; then
        pass "cred/unparsable/artifact-written"
        body="$(artifact_text "$art")"
        # Positive marker: the probe line IS in the file, redacted.
        assert_contains "cred/unparsable/log-records-redacted-url" "***@github.com.evil.example" "$body"
        assert_not_contains "cred/unparsable/no-token-on-disk" "$fake" "$body"
    else
        fail "cred/unparsable/artifact-written" "artifact_path=$art"
    fi

    # (2) the probe FAILS and git echoes the remote URL back on stderr.
    can_probe "" "fatal: could not read Username for 'https://x-access-token:${fake}@github.com': terminal prompts disabled" \
        128 false __NULL__
    p="$(write_payload cred-stderr "$(payload_json example-owner/example-repo)")"
    dispatch_stage "$p"
    assert_eq "cred/stderr/status" "error" "$(field_of status)"
    assert_eq "cred/stderr/chain-never-spawned" "1" "$(call_count)"
    assert_not_contains "cred/stderr/no-token-in-stdout" "$fake" "$DOUT"
    art="$(unquote "$(field_of artifact_path)")"
    if [ -n "$art" ] && [ "$art" != "(none)" ]; then
        pass "cred/stderr/artifact-written"
        body="$(artifact_text "$art")"
        assert_contains "cred/stderr/log-records-redacted-stderr" "***@github.com" "$body"
        assert_not_contains "cred/stderr/no-token-on-disk" "$fake" "$body"
    else
        fail "cred/stderr/artifact-written" "artifact_path=$art"
    fi

    # (3) a parsable, token-bearing, MISMATCHED origin: the refusal summary names
    # the resolved repository, and must name only that.
    can_origin "https://x-access-token:${fake}@github.com/other-owner/other-repo.git"
    p="$(write_payload cred-mismatch "$(payload_json example-owner/example-repo)")"
    dispatch_stage "$p"
    assert_eq "cred/mismatch/status" "error" "$(field_of status)"
    assert_eq "cred/mismatch/chain-never-spawned" "1" "$(call_count)"
    assert_contains "cred/mismatch/summary-names-resolved-repo" "other-owner/other-repo" "$(field_of summary)"
    assert_not_contains "cred/mismatch/no-token-in-stdout" "$fake" "$DOUT"
    art="$(unquote "$(field_of artifact_path)")"
    if [ -n "$art" ] && [ "$art" != "(none)" ]; then
        pass "cred/mismatch/artifact-written"
        body="$(artifact_text "$art")"
        assert_not_contains "cred/mismatch/no-token-on-disk" "$fake" "$body"
    else
        fail "cred/mismatch/artifact-written" "artifact_path=$art"
    fi

    # Anti-vacuous control for all six absence assertions above: the placeholder
    # IS detectable by assert_not_contains when it is genuinely present.
    assert_not_contains "cred/detector-works-on-clean-text" "$fake" "no secret here"
    case "$(printf 'prefix-%s-suffix' "$fake")" in
        *"$fake"*) pass "cred/detector-would-catch-a-leak" ;;
        *) fail "cred/detector-would-catch-a-leak" "the substring matcher itself is broken" ;;
    esac
}

group_allow
group_block_mismatch
group_block_unresolvable
group_block_probe_failure
group_positive_control
group_credential_on_failure

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
