# shellcheck shell=bash
# tests/feature-1733-state-event-stream/common.sh
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js
# Tags: workflow-state, event-stream, state-io, harness, scope:issue-specific, pwsh-not-required, TL2
#
# Shared harness for the #1733 append-only event-stream suite. SOURCED, never run
# standalone (it has no cases of its own).
#
# ISOLATION CONTRACT (identical across every case file):
#   CLAUDE_WORKFLOW_DIR -> per-file temp dir, so no real session state is touched.
#   AGENTS_CONFIG_DIR   -> fixture config dir whose .env carries no workflow toggles,
#                          so env-dependent branches resolve from a known file rather
#                          than the developer's real .env (test-design.md
#                          "Config-dependent branches").
#   HOME / USERPROFILE  -> temp dir, so getWorkflowDir()'s homedir fallback and
#                          zombie cleanup cannot reach the real ~/.claude.
#   WORKFLOW_PLANS_DIR  -> empty temp dir, so the plan-artifact predicates
#                          (hasPlanArtifact) answer from a known-empty directory
#                          instead of the developer's real ~/.workflow-plans.
#
# PRE-IMPLEMENTATION CONTRACT — THERE IS NO SKIP PATH.
# This suite is written test-first, so before the #1733 implementation lands every case
# FAILS (module-not-found / missing export / wrong shape) and every file exits non-zero.
# That is the intended signal: a suite that reported SKIP instead would go green while
# nothing was implemented, which is indistinguishable from a passing implementation.
#   * run_case is unconditional — it exists only to name the case being run.
#   * report_totals turns any SKIP into a FAIL: this suite must never report one.
#   * finish() exits 1 on any failure and NEVER exits 77 (the dispatcher reads 77 as
#     "node is absent", so a file with exactly 77 failures must not collide with it).
# The only 77 in this harness is the `command -v node` gate below, which is an
# environment fact, not a feature probe.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
SKIPPED=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

assert_eq() { # <name> <want> <got>
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

assert_ne() { # <name> <unwanted> <got>
    local name="$1" bad="$2" got="$3"
    if [ "$bad" != "$got" ]; then pass "$name"
    else fail "$name" "got the forbidden value $(printf '%q' "$got")"; fi
}

report_totals() { # <file-label>
    # A skipped case is a FAILURE in this suite: see the pre-implementation contract
    # above. Nothing calls skip(), and this guard keeps it that way.
    if [ "$SKIPPED" -ne 0 ]; then
        echo "FAIL: $1 reported $SKIPPED skipped case(s) — this suite has no skip path"
        FAIL=$((FAIL + 1))
    fi
    echo ""
    echo "Total[$1]: PASS=$PASS FAIL=$FAIL SKIP=$SKIPPED"
}

# finish <file-label> — the single exit point of every case file. Exit status is 0 or 1
# only: never the raw FAIL count (which could be 77, the dispatcher's node-absent code,
# or >255).
finish() { # <file-label>
    report_totals "$1"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
}

native_path() { (cd "$1" 2>/dev/null && (pwd -W 2>/dev/null || pwd)) || printf '%s' "$1"; }

WF="$TMPROOT/wf";       mkdir -p "$WF"
CFG="$TMPROOT/cfg";     mkdir -p "$CFG"
ISO_HOME="$TMPROOT/h";  mkdir -p "$ISO_HOME"
PLANS="$TMPROOT/plans"; mkdir -p "$PLANS"
printf '# fixture config for tests/feature-1733-state-event-stream/*\nAGENT_FIXTURE=1\n' > "$CFG/.env"

WF_NATIVE="$(native_path "$WF")"
CFG_NATIVE="$(native_path "$CFG")"
ISO_HOME_NATIVE="$(native_path "$ISO_HOME")"
PLANS_NATIVE="$(native_path "$PLANS")"

# node_env — the isolation env prefix shared by every node invocation below.
node_env() {
    printf '%s' "CLAUDE_WORKFLOW_DIR=$WF_NATIVE AGENTS_CONFIG_DIR=$CFG_NATIVE WORKFLOW_PLANS_DIR=$PLANS_NATIVE"
}

# mk_git_repo <dir> <branch> — a REAL git repository with one commit, checked out on
# <branch>. Worktree-context resolution runs `git -C <path> rev-parse`, so a plain
# mkdir'd directory can only ever exercise the FAILURE branch: any case that means to
# assert path_source=tool_input must hand the recorder a genuine repository.
mk_git_repo() { # <dir> <branch>
    local dir="$1" branch="$2"
    mkdir -p "$dir" || return 1
    git -C "$dir" init -q >/dev/null 2>&1 || return 1
    git -C "$dir" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
    git -C "$dir" config user.email "fixture@example.com" >/dev/null 2>&1
    git -C "$dir" config user.name "1733 fixture" >/dev/null 2>&1
    git -C "$dir" config commit.gpgsign false >/dev/null 2>&1
    git -C "$dir" config core.hooksPath "$dir/.git/no-hooks" >/dev/null 2>&1
    printf 'fixture\n' > "$dir/README.md"
    git -C "$dir" add README.md >/dev/null 2>&1 || return 1
    git -C "$dir" commit -q --no-verify -m "fixture" >/dev/null 2>&1 || return 1
    if [ "$branch" != "main" ]; then
        git -C "$dir" checkout -q -B "$branch" >/dev/null 2>&1 || return 1
    fi
    return 0
}

# json_path <dir> — a JSON-string-safe absolute path for the host (backslashes escaped).
json_path() { native_path "$1" | sed 's/\\/\\\\/g'; }

# fs_snapshot <root> <exclude-dir> — "path checksum" for every file under <root> except
# those under <exclude-dir>. Two snapshots compared as strings answer the only question
# a containment assertion can ask from outside the process: did anything appear, vanish
# or change outside the directory the code was allowed to write to. cksum is POSIX, so
# this works on macOS and on git-bash alike.
fs_snapshot() { # <root> <exclude-dir>
    local root="$1" excl="$2" f
    find "$root" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        case "$f" in
            "$excl"/*|"$excl") continue ;;
        esac
        printf '%s %s\n' "$f" "$(cksum < "$f" 2>/dev/null | tr -s ' ' '-')"
    done
}

SID_N=0
# Assigns a fresh session id into $SID. NOT a command substitution — `SID=$(next_sid)`
# would bump the counter inside a subshell and hand every case the same state file.
next_sid() { SID_N=$((SID_N + 1)); printf -v SID "sid1733-%s-%02d" "${CASE_TAG:-x}" "$SID_N"; }

# nodejs <sid> <js> — runs one node process in the repo root with the isolation env.
# Sets NODE_OUT (stdout+stderr) and NODE_RC.
nodejs() {
    local sid="$1" js="$2"
    NODE_RC=0
    NODE_OUT="$(cd "$AGENTS_DIR" && env \
        CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$sid" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node -e "$js" 2>&1)" || NODE_RC=$?
}

# nodejs_env <extra-env-assignments> <sid> <js> — as nodejs, plus extra env vars.
nodejs_env() {
    local extra="$1" sid="$2" js="$3"
    NODE_RC=0
    # shellcheck disable=SC2086
    NODE_OUT="$(cd "$AGENTS_DIR" && env \
        CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$sid" $extra \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node -e "$js" 2>&1)" || NODE_RC=$?
}

# nodejs_bg <sid> <js> <stdout-file> — same, detached. Used by concurrency.sh.
nodejs_bg() {
    local sid="$1" js="$2" outfile="$3"
    (cd "$AGENTS_DIR" && env \
        CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$sid" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 60 node -e "$js" >"$outfile" 2>&1) &
}

# ── case entry ───────────────────────────────────────────────────────────────

# run_case <label> — names the case about to run and ALWAYS returns 0.
#
# It replaced a capability probe (`need_feature`) that skipped the case body whenever
# the #1733 modules were absent. That inverted the meaning of the suite: with nothing
# implemented every case skipped, every file exited 0, and the dispatcher went green —
# the exact state the suite exists to detect. A missing module must surface as a FAILING
# assertion (require throws, NODE_OUT carries the error, assert_eq fails), never as a
# skip. The label is echoed so a failure in a multi-assert case is attributable.
run_case() { # <label>
    CURRENT_CASE="$1"
    return 0
}

# ── capability probes (diagnostics only — they must never gate a case) ───────

mod_exists() { [ -f "$AGENTS_DIR/$1" ]; }

# exports_have <require-path-relative-to-repo-root> <export-name>
exports_have() {
    local out
    out="$(cd "$AGENTS_DIR" && env \
        CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node -e \
        "try{const m=require('$1');console.log(m['$2']===undefined?'NO':'YES');}catch(e){console.log('NO');}" \
        2>/dev/null)" || out="NO"
    [ "$out" = "YES" ]
}

# feature_banner — DIAGNOSTIC ONLY. Prints one line saying whether the #1733 modules
# are present, so a wall of failures is immediately attributable to "not implemented
# yet" rather than to a broken harness. It gates nothing: the cases run either way.
feature_banner() {
    if mod_exists "hooks/workflow-state/state-io/events.js" \
        && mod_exists "hooks/workflow-state/state-io/projection.js" \
        && exports_have "./hooks/workflow-state/state-io" "appendEvents"; then
        echo "# feature-probe: #1733 event-stream modules present"
    else
        echo "# feature-probe: #1733 event-stream modules ABSENT — every case below is expected to FAIL (test-first)"
    fi
}

# ── shared JS preambles ──────────────────────────────────────────────────────

PRE='const S = require("./hooks/workflow-state/state-io");
const fs = require("fs"), path = require("path");
const sid = process.env.SID;
const sp = () => path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json");
const raw = () => fs.readFileSync(sp(), "utf8");
const rd = () => JSON.parse(raw());
const wraw = (o) => fs.writeFileSync(sp(), JSON.stringify(o, null, 2));
const sleep = (ms) => { const t = Date.now(); while (Date.now() - t < ms) {} };
const evs = (kind) => rd().events.filter((e) => !kind || e.kind === kind);
const cur = () => rd().current;
'

# genuine(sid) — observes the genuine-recorded-complete predicate through a REAL public
# entry point, `effective-state.evaluateInheritance(state)`.
#
# hasGenuineRecordedComplete is module-private and stays that way; asserting on a direct
# export would invent API surface that no consumer uses, and passing it a hand-built
# `{ session_id }` stub would test the stub, not the state file. evaluateInheritance is
# the one live consumer: its S3 rule fires exactly when clarify_intent is genuinely
# recorded complete AND its plan artifact is gone —
#
#     genuine && !hasPlanArtifact  ->  { eligible: false, scan: "stop" }
#     otherwise                    ->  { eligible: true,  scan: null }
#
# The harness pins the second conjunct: WORKFLOW_PLANS_DIR is an empty temp dir, so the
# artifact never exists unless a case creates it deliberately (see plan_artifact below).
# Under that pin, scan === "stop" IS the predicate's verdict. Every case therefore drives
# the real reader, reads a real state file, and would still fail if evaluateInheritance
# stopped consulting provenance at all.
#
# `subject` is always clarify_intent — the only step S3 examines. Cases that need a
# different step assert on the projected events directly instead.
#
# CONFOUNDER (do not break): evaluateInheritance also stops on S1 (user_verification
# complete) and S2 (review_security complete). No case below may complete either step,
# or scan === "stop" would no longer be attributable to the predicate.
GENUINE_JS='const ES = require("./hooks/workflow-state/effective-state");
const GENUINE_SUBJECT = "clarify_intent";
const inheritance = (s) => {
  const st = S.readState(s);
  try { return ES.evaluateInheritance(st); } catch (e) { return { threw: e && e.name }; }
};
const genuine = (s) => {
  const v = inheritance(s);
  if (v && v.threw) return "THREW:" + v.threw;
  return !!(v && v.scan === "stop" && v.eligible === false);
};
// Creates/removes the clarify_intent plan artifact that S3 requires to be ABSENT.
const plan_artifact = (s, present) => {
  const p = path.join(process.env.WORKFLOW_PLANS_DIR, s + "-intent.md");
  if (present) fs.writeFileSync(p, "# fixture intent\n");
  else if (fs.existsSync(p)) fs.unlinkSync(p);
};
'

# Seeds the plan_approvals audit records that #1133 requires before outline/detail
# may be persisted `complete`. Changes no step status and no timestamp, so it never
# weakens an assertion in the case that uses it.
APPROVE_GATED_JS='const CA = require("./hooks/workflow-state/completion-approval");
for (const s of CA.APPROVAL_GATED_STEPS) {
  CA.recordPlanApproval(sid, s, { source: "reset-sentinel", reason: "1733 fixture" });
}
'

# One diagnostic line per case file (gates nothing — see the contract at the top).
feature_banner
