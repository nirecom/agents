#!/bin/bash
# tests/hooks/enforce-worktree-allow-single-invocation-redirects.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/command-shape.js, hooks/enforce-worktree/main-worktree-allows/supervisor-bin.js, hooks/lib/command-ir.js, hooks/enforce-worktree.js
# Tags: hook, worktree, enforce, security, allow-predicate, command-ir, redirect, scope:issue-specific
# Redirect half of the single-invocation allow rewrite (#2589, commit 2). The
# supervisor allow accepts one literal-root call whose redirects are fd duplication
# (&1 / &2) or literal /tmp/ files only. The command-ir representation the new
# predicates depend on (R2-4) is pinned first so a parser change fails here before
# the predicates silently drift. Single-invocation rows live in the sibling file.
# TL3 gap (what this test does NOT catch): a live PreToolUse chain in a real session.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.
set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not found"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPDIR_BASE="$(make_tmp)"; readonly TMPDIR_BASE
harness_isolate "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

ROOT_NODE="$(np "$SCRIPT_CHECKOUT_ROOT")"
GUARD_JS="$ROOT_NODE/hooks/enforce-worktree.js"

expect_eq() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "want=$want got=$got"; fi
}

REPO_RAW="$TMPDIR_BASE/repo"
mkdir -p "$REPO_RAW"
git -C "$REPO_RAW" init -q -b main
git -C "$REPO_RAW" config core.hooksPath /dev/null
git -C "$REPO_RAW" config user.email "test@example.com"
git -C "$REPO_RAW" config user.name "Test"
echo init > "$REPO_RAW/README.md"
git -C "$REPO_RAW" add README.md
git -C "$REPO_RAW" commit -q --no-verify -m initial
REPO="$(np "$REPO_RAW")"

# ── Table evaluator: one node process per table ─────────────────────────────
# ir  rows: want :: field :: cmd   (field of parse(cmd), JSON-encoded; see IR_FIELDS)
# rut rows: want :: suffix         (redirectsUnderTmp(singleInvocation("node a" + suffix)))
# sup rows: want :: cmd            (isAllowedSupervisorBinTool(cmd))
# gsc rows: want :: cmd            (gitSubcommand(singleInvocation(cmd)).sub, or null)
# pred rows: want :: fn :: cmd     (main-worktree-allows.js fn(cmd, @REPO@))
# Placeholders: @ROOT@ @REPO@ @AMR@ ($-form) @AMRB@ (${}-form). A missing module reads "ERROR: ...".
# The agents root is spliced in as a literal variable reference (AMR_REF / @AMR@) so no
# line of this file joins the root to a code directory (check-root-names structural).
AMR_REF='$AGENTS_MAIN_ROOT'
EVAL_JS='
const root = process.argv[1], kind = process.argv[2];
const fs = require("fs"), path = require("path");
const sub = (s) => s.split("@ROOT@").join(root).split("@REPO@").join(process.env.T_REPO)
  .split("@AMRB@").join("${AGENTS_MAIN_ROOT}").split("@AMR@").join("$AGENTS_MAIN_ROOT");
const first = (e) => String(e && e.message).split("\n")[0];
const load = (rel) => { try { return require(path.join(root, rel)); } catch (e) { return new Error(first(e)); } };
const MW = "hooks/enforce-worktree/main-worktree-allows";
const ir = load("hooks/lib/command-ir.js"), shape = load(MW + "/command-shape.js"), sup = load(MW + "/supervisor-bin.js");
const std = load(MW + ".js");
const pick = (r) => ({ op: r.op, target: r.target });
const IR_FIELDS = {
  redirects: (p) => p.segments[0].redirects.map(pick),
  cmd0: (p) => p.segments[0].cmd0,
  argv: (p) => p.segments[0].argv,
  separators: (p) => p.separators,
  segmentCount: (p) => p.segments.length,
  lastSegRedirects: (p) => p.segments[p.segments.length - 1].redirects.map(pick),
  targetRaw: (p) => p.segments[0].redirects.map((r) => r.targetRaw),
  parseFailure: (p) => p.parseFailure,
};
function evalRow(f) {
  if (kind === "ir") {
    if (ir instanceof Error) return "ERROR: " + ir.message;
    return JSON.stringify(IR_FIELDS[f[0]](ir.parse(sub(f[1]))));
  }
  if (kind === "rut") {
    if (shape instanceof Error) return "ERROR: " + shape.message;
    if (typeof shape.redirectsUnderTmp !== "function") return "ERROR: redirectsUnderTmp not exported";
    const seg = shape.singleInvocation("node a " + (f[0] === "(none)" ? "" : sub(f[0])));
    return seg ? String(shape.redirectsUnderTmp(seg)) : "no-seg";
  }
  if (kind === "gsc") {
    if (shape instanceof Error) return "ERROR: " + shape.message;
    const seg = shape.singleInvocation(sub(f[0]));
    if (!seg) return "no-seg";
    const g = shape.gitSubcommand(seg);
    return g ? g.sub : "null";
  }
  if (kind === "pred") {
    if (std instanceof Error) return "ERROR: " + std.message;
    if (typeof std[f[0]] !== "function") return "ERROR: " + f[0] + " not exported";
    return String(std[f[0]](sub(f[1]), process.env.T_REPO));
  }
  // cwd = checkout root, so a relative script path would resolve to a known tool if accepted.
  process.chdir(root);
  if (sup instanceof Error) return "ERROR: " + sup.message;
  if (typeof sup.isAllowedSupervisorBinTool !== "function") return "ERROR: isAllowedSupervisorBinTool not exported";
  return String(sup.isAllowedSupervisorBinTool(sub(f[0])));
}
const out = [];
for (const line of fs.readFileSync(0, "utf8").split("\n")) {
  if (!line.trim() || line.trim().startsWith("#")) continue;
  const parts = line.split(" :: ").map((s) => s.trim());
  const want = parts[0], f = parts.slice(1);
  if (kind === "pred") f.splice(1, f.length - 1, f.slice(1).join(" :: "));
  else if (kind !== "ir") f.splice(0, f.length, f.join(" :: "));
  let got;
  try { got = evalRow(f); } catch (e) { got = "ERROR: threw " + first(e); }
  out.push([kind + " " + f.join(" :: "), want, String(got).replace(/[\t\n]/g, " ")].join("\t"));
}
process.stdout.write(out.concat(["#ROWS\t" + out.length]).join("\n") + "\n");
'

run_table() {
    local kind="$1" out label want got rows=0 declared=""
    out="$(run_with_timeout 100 env "T_REPO=$REPO" node -e "$EVAL_JS" "$ROOT_NODE" "$kind" 2>&1)" \
        || { fail "table-$kind" "evaluator failed: ${out:0:300}"; return; }
    while IFS=$'\t' read -r label want got; do
        case "$label" in "") continue ;; "#ROWS") declared="$want"; continue ;; esac
        if [ -z "$want" ] || [ -z "$got" ]; then fail "table-$kind malformed row" "$label"; continue; fi
        rows=$((rows + 1))
        expect_eq "$label" "$got" "$want"
    done <<< "$out"
    expect_eq "table-$kind every evaluated row was asserted" "$rows" "${declared:-missing}"
}

# ── R2-4: pin the command-ir representation the predicates rely on ──────────
# Only op and target are asserted; any other field may change freely.
case_begin "command-ir-representation-pin" "hooks/lib/command-ir.js"
run_table ir <<'TABLE'
[{"op":">","target":"/tmp/a"},{"op":"2>","target":"&1"}] :: redirects :: node @ROOT@/bin/supervisor-write-alert > /tmp/a 2>&1
"X=1"                                                   :: cmd0      :: X=1 bash -c 'x'
["bash","-c","x"]                                       :: argv      :: X=1 bash -c 'x'
[{"op":">","target":"&2"}]                              :: redirects :: node a >&2
[{"op":">&","target":"~/x"}]                            :: redirects :: node a >& ~/x
[{"op":"2>","target":"&3"}]                             :: redirects :: node a 2>&3
[{"op":"2>","target":"&-"}]                             :: redirects :: node a 2>&-
[{"op":"<<<","target":"x"}]                             :: redirects :: node a <<< x
[{"op":">|","target":"/tmp/a"}]                         :: redirects :: node a >| /tmp/a
[{"op":"<","target":"~/.ssh/id_rsa"}]                   :: redirects :: node a < ~/.ssh/id_rsa
[{"op":">","target":"/tmp/../home/x"}]                  :: redirects :: node a > "/tmp/.."/home/x
["\"/tmp/..\"/home/x"]                                  :: targetRaw :: node a > "/tmp/.."/home/x
["&"]                                                   :: separators :: node a &> ~/x
[{"op":">","target":"~/x"}]                             :: lastSegRedirects :: node a &> ~/x
true                                                    :: parseFailure :: node a 'unclosed
TABLE
case_end

# ── redirectsUnderTmp: fd duplication &1/&2 and literal /tmp/ files only ────
case_begin "redirects-under-tmp" "hooks/enforce-worktree/main-worktree-allows/command-shape.js"
run_table rut <<'TABLE'
true   :: (none)
true   :: 2>&1
true   :: >&2
true   :: 1>&2
true   :: > /tmp/a 2>&1
true   :: >> /tmp/a
true   :: 2>> /tmp/err
true   :: 2> /tmp/err
true   :: >& /tmp/a
true   :: > "/tmp/a b"
false  :: > /tmp/$X
false  :: > /tmp/${X}
false  :: > /tmp/../home/x
false  :: > "/tmp/.."/home/x
false  :: > /tmp/*
false  :: > /tmp/a?
false  :: > /tmp/[ab]
false  :: > /tmpx/a
false  :: > tmp/a
false  :: > ~/x
false  :: >& ~/x
false  :: 2>&3
false  :: 2>&-
false  :: < ~/.ssh/id_rsa
false  :: < /tmp/a
false  :: <<< x
false  :: >| /tmp/a
false  :: > /tmp/a > ~/.bashrc
false  :: 2> ~/x
false  :: > /tmp/a 2> ~/x
no-seg :: &> /tmp/a
no-seg :: > /tmp/$(id)
TABLE
case_end

# ── isAllowedSupervisorBinTool (supervisor-bin.js) explicit rows ────────────
# `&> /tmp/a` splits into two segments in command-ir (`&` separator), so it is not
# one invocation and is rejected; the plan's &> op entry is unreachable today.
case_begin "supervisor-bin-explicit" "hooks/enforce-worktree/main-worktree-allows/supervisor-bin.js"
run_table sup <<'TABLE'
true  :: node "@ROOT@/bin/supervisor-write-alert" --session s
true  :: node @ROOT@/bin/supervisor-write-alert --session s
true  :: bash "@ROOT@/bin/supervisor-findings-codex" --session s
true  :: node "@ROOT@/bin/supervisor-write-alert" --session s 2>&1
true  :: node "@ROOT@/bin/supervisor-write-alert" --session s >&2
true  :: bash "@ROOT@/bin/supervisor-findings-codex" --session s > /tmp/a 2>&1
true  :: node "@ROOT@/bin/supervisor-write-alert" --session s 2>> /tmp/err
false :: node "@AMR@/bin/supervisor-write-alert" --session s
false :: node "@AMRB@/bin/supervisor-write-alert" --session s
false :: bash "@AMR@/bin/supervisor-findings-codex" --session s > /tmp/a
false :: NODE_OPTIONS=--require=/home/u/x.js node "@ROOT@/bin/supervisor-write-alert" --session s
false :: sh "@ROOT@/bin/supervisor-findings-codex" --session s
false :: python "@ROOT@/bin/supervisor-write-alert" --session s
false :: node "@ROOT@/bin/supervisor-evil" --session s
false :: node "/home/attacker/agents/bin/supervisor-write-alert" --session s
false :: node "@ROOT@/bin/supervisor-write-alert" --session s > /tmp/$(id)
false :: node "@ROOT@/bin/supervisor-write-alert" --session s &> /tmp/a
false :: node "@ROOT@/bin/supervisor-write-alert" --session s > /tmp/a > ~/.bashrc
false :: node "@ROOT@/bin/supervisor-write-alert" --session s 2> ~/x
false :: node "@ROOT@/bin/supervisor-write-alert" --session s < ~/.ssh/id_rsa
false :: echo x > ~/.bashrc; node "@ROOT@/bin/supervisor-write-alert" > /tmp/a
false :: node "@ROOT@/bin/supervisor-write-alert" --session s; rm -rf x
false :: rm -rf x node "@ROOT@/bin/supervisor-write-alert" --session s
false :: node "@ROOT@/bin/supervisor-write-alert" --session s 'unclosed
# A relative script path resolves against the hook's cwd, not the Bash tool's: rejected.
false :: node bin/supervisor-write-alert --session s
false :: bash ./bin/supervisor-findings-codex --session s
false :: node "bin/supervisor-write-alert" --session s 2>&1
true  :: bash @ROOT@/bin/supervisor-findings-codex --session s
TABLE
case_end

# ── --git-dir / --work-tree retarget the repository: no allow predicate accepts them ──
# The predicates validate only -C against the repo root, so a git invocation carrying
# either option (separated or attached) would run against another repository. An
# attached -C<path> is not parsed into the -C list, so it is rejected the same way.
case_begin "git-retarget-options-rejected" "hooks/enforce-worktree/main-worktree-allows/command-shape.js"
run_table gsc <<'TABLE'
merge :: git merge --abort
pull  :: git -C @REPO@ pull --ff-only
null  :: git --git-dir /tmp/other/.git merge --abort
null  :: git --git-dir=/tmp/other/.git merge --abort
null  :: git --work-tree /tmp/other pull --ff-only
null  :: git --work-tree=/tmp/other pull --ff-only
null  :: git -C @REPO@ --git-dir=/tmp/other/.git stash
null  :: git -C/tmp/other merge --abort
null  :: git -C/tmp/other stash
merge :: git -C @REPO@ merge --abort
TABLE
run_table pred <<'TABLE'
true  :: isAllowedMidOperationAbort   :: git merge --abort
true  :: isAllowedMidOperationAbort   :: git -C @REPO@ merge --abort
false :: isAllowedMidOperationAbort   :: git --git-dir /tmp/other/.git merge --abort
false :: isAllowedMidOperationAbort   :: git --git-dir=/tmp/other/.git merge --abort
false :: isAllowedMidOperationAbort   :: git --work-tree /tmp/other merge --abort
false :: isAllowedMidOperationAbort   :: git --work-tree=/tmp/other merge --abort
true  :: isAllowedFastForwardMerge    :: git pull --ff-only
false :: isAllowedFastForwardMerge    :: git --work-tree /tmp/other pull --ff-only
false :: isAllowedFastForwardMerge    :: git --work-tree=/tmp/other pull --ff-only
false :: isAllowedFastForwardMerge    :: git --git-dir /tmp/other/.git pull --ff-only
false :: isAllowedFastForwardMerge    :: git --git-dir=/tmp/other/.git merge --ff-only origin/main
# Repeated -C: git acts in a repository the hook did not judge. One -C stays accepted.
true  :: isAllowedFastForwardMerge    :: git -C @REPO@ pull --ff-only
false :: isAllowedFastForwardMerge    :: git -C /a -C /b pull --ff-only
false :: isAllowedFastForwardMerge    :: git -C /a -C /b merge --ff-only origin/main
# A single -C must name the judged repository; a foreign one acts elsewhere.
false :: isAllowedFastForwardMerge    :: git -C /tmp/other/repo pull --ff-only
false :: isAllowedFastForwardMerge    :: git -C /tmp/other/repo merge --ff-only origin/main
true  :: isAllowedMainWorktreeCleanup :: git stash
true  :: isAllowedMainWorktreeCleanup :: git checkout -- README.md
false :: isAllowedMainWorktreeCleanup :: git --git-dir /tmp/other/.git stash
false :: isAllowedMainWorktreeCleanup :: git --git-dir=/tmp/other/.git stash
false :: isAllowedMainWorktreeCleanup :: git --work-tree /tmp/other checkout -- README.md
false :: isAllowedMainWorktreeCleanup :: git --work-tree=/tmp/other checkout -- README.md
false :: isAllowedMidOperationAbort   :: git -C/tmp/other merge --abort
false :: isAllowedMainWorktreeCleanup :: git -C/tmp/other stash
false :: isAllowedMainWorktreeCleanup :: git -C/tmp/other checkout -- README.md
# Cleanup accepts only stash/restore/merge/checkout: other subcommands once fell into
# the checkout branch and were accepted while the fixture had no linked worktree.
false :: isAllowedMainWorktreeCleanup :: git commit -- README.md
false :: isAllowedMainWorktreeCleanup :: git reset -- README.md
false :: isAllowedMainWorktreeCleanup :: git clean -- README.md
false :: isAllowedMainWorktreeCleanup :: git add -- README.md
TABLE
case_end

# ── End-to-end on the real hook ─────────────────────────────────────────────
GUARD_ERR="$TMPDIR_BASE/guard.stderr"
assert_guard() {
    local label="$1" want="$2" cmd="$3" run_dir="${4:-$REPO_RAW}" payload out rc=0 got
    payload="$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$cmd")"
    out="$(cd "$run_dir" && printf '%s' "$payload" | run_with_timeout 30 env -u AGENTS_MAIN_ROOT -u AGENTS_HOOK_DEBUG \
        -u CLAUDE_CODE_SESSION_ID ENFORCE_WORKTREE=on "CLAUDE_PROJECT_DIR=$REPO" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$REPO" node "$GUARD_JS" 2>"$GUARD_ERR")" || rc=$?
    if [ "$rc" -ne 0 ]; then got="crash rc=$rc err=$(head -c 200 "$GUARD_ERR")"
    elif [ "$out" = "{}" ]; then got=allow
    elif printf '%s' "$out" | grep -q '"decision":"block"'; then got=block
    else got="neither: $out"; fi
    expect_eq "$label" "$got" "$want"
}

# S2-1 observation: the supervisor calls never reach the allow predicate end to end.
# A call with no file redirect (or only 2>&1) is not a write for detectWritePredicate,
# and a call whose only file target is /tmp/ is allowed earlier because every write
# target lies outside the session scope (Bug 2). Both forms therefore stay allowed
# whether the root is the variable or the literal spelling, and the caller docs need
# no change for the predicate rewrite.
case_begin "e2e-supervisor-observed-allow" "hooks/enforce-worktree.js"
assert_guard "E2E S2-1 variable root, no redirect: allow"   allow "node \"$AMR_REF/bin/supervisor-write-alert\" --session s"
assert_guard "E2E S2-1 variable root, 2>&1: allow"          allow "node \"$AMR_REF/bin/supervisor-write-alert\" --session s 2>&1"
assert_guard "E2E S2-1 variable root, > /tmp/x: allow"      allow "bash \"$AMR_REF/bin/supervisor-findings-codex\" --session s > /tmp/x 2>&1"
assert_guard "E2E S2-1 literal root, no redirect: allow"    allow "node \"$ROOT_NODE/bin/supervisor-write-alert\" --session s"
assert_guard "E2E S2-1 literal root, > /tmp/x: allow"       allow "bash \"$ROOT_NODE/bin/supervisor-findings-codex\" --session s > /tmp/x 2>&1"
case_end

# Security rows: an in-repo write target keeps Bug 2 out, so the predicate decides.
case_begin "e2e-supervisor-security" "hooks/enforce-worktree.js"
assert_guard "E2E in-repo write chained before variable-root supervisor call is blocked" block \
    "echo x > README.md; node \"$AMR_REF/bin/supervisor-write-alert\" > /tmp/a"
assert_guard "E2E in-repo write chained before literal-root supervisor call is blocked" block \
    "echo x > README.md; node \"$ROOT_NODE/bin/supervisor-write-alert\" > /tmp/a"
assert_guard "E2E literal-root supervisor call redirected into the repo is blocked" block \
    "node \"$ROOT_NODE/bin/supervisor-write-alert\" --session s > \"$REPO/out.txt\""
assert_guard "E2E variable-root supervisor call redirected into the repo is blocked" block \
    "node \"$AMR_REF/bin/supervisor-write-alert\" --session s > \"$REPO/out.txt\""
assert_guard "E2E /tmp/ redirect beside an in-repo redirect is blocked" block \
    "node \"$ROOT_NODE/bin/supervisor-write-alert\" --session s > /tmp/a 2> \"$REPO/err.txt\""
case_end

# Wiring: the supervisor predicate call in enforce-worktree.js is the ONLY allow for
# these rows. A quoted `<<EOF` text argument makes the raw-text hasHeredoc() true,
# which turns off both the universal allow and Bug 2, so the /tmp/ write falls to
# the main-checkout predicates. command-ir still sees one invocation with one /tmp/
# redirect. Deleting `if (isAllowedSupervisorBinTool(cmd)) done();` flips the allow
# row to block; the twins pin that the predicate, not some earlier path, decides.
case_begin "e2e-supervisor-wiring" "hooks/enforce-worktree.js"
HD_ARG="--note 'see <<EOF'"
assert_guard "E2E wiring: literal-root call reaching the predicate is allowed" allow \
    "node \"$ROOT_NODE/bin/supervisor-write-alert\" $HD_ARG > /tmp/a 2>&1"
assert_guard "E2E wiring twin: variable-root call reaching the predicate is blocked" block \
    "node \"$AMR_REF/bin/supervisor-write-alert\" $HD_ARG > /tmp/a"
assert_guard "E2E wiring twin: literal-root call with a non-/tmp/ target is blocked" block \
    "node \"$ROOT_NODE/bin/supervisor-write-alert\" $HD_ARG > ~/x"
assert_guard "E2E wiring twin: literal-root non-supervisor bin is blocked" block \
    "node \"$ROOT_NODE/bin/supervisor-evil\" $HD_ARG > /tmp/a"
case_end

# Wiring: enforce-worktree.js must hand the judged repo root to isAllowedFastForwardMerge.
# Only the predicate allows a write in the judged checkout, and it compares -C with the
# root it is given: dropping that argument makes this allow row flip to block.
# No foreign-repo twin here: a git -C into a repository outside the judged scope never
# reaches the predicate (the hook lets writes elsewhere through), so a block there would
# only prove the repo lookup; the foreign -C rejection is pinned by the predicate table.
case_begin "e2e-ff-merge-judged-repo-wiring" "hooks/enforce-worktree.js"
assert_guard "E2E ff wiring: git -C <judged repo> pull --ff-only is allowed" allow \
    "git -C \"$REPO\" pull --ff-only"
assert_guard "E2E ff wiring twin: ff-only chained after an in-repo write is blocked" block \
    "echo x > README.md; git -C \"$REPO\" pull --ff-only"
# The hook runs from a directory that is not the judged repo: the root handed to the predicate
# must be the judged repo, not process.cwd(), or this -C would read as naming another repository.
OTHER_CWD="$TMPDIR_BASE/other-cwd"
mkdir -p "$OTHER_CWD"
assert_guard "E2E ff wiring: git -C <judged repo> pull --ff-only from another cwd is allowed" allow \
    "git -C \"$REPO\" pull --ff-only" "$OTHER_CWD"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
