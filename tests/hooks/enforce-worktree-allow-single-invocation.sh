#!/bin/bash
# tests/hooks/enforce-worktree-allow-single-invocation.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/command-shape.js, hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/enforce-worktree/main-worktree-allows/worktree-command.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js
# Tags: hook, worktree, enforce, security, allow-predicate, command-ir, scope:issue-specific
# Every main-worktree allow predicate accepts one invocation only (#2589, commit 2):
# a canonical shape passes, and the same shape with chaining, substitution, process
# substitution, heredoc, group, a stray redirect, or a non-leading position does not.
# The tables run in one node process; the end-to-end rows keep the security verdicts
# on the real hook. Redirect / supervisor rows live in the -redirects.sh sibling.
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

fixture_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    echo init > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q --no-verify -m initial
}

# REPO: main + one linked worktree (worker-script, worktree-command, the rest).
REPO_RAW="$TMPDIR_BASE/repo"
fixture_repo "$REPO_RAW"
git -C "$REPO_RAW" worktree add -q -b feature/x "$REPO_RAW/.wt/x" >/dev/null 2>&1
REPO="$(np "$REPO_RAW")"

# SOLO: no linked worktree (cleanup gate), upstream origin/main, one outgoing
# commit touching notes.md only (push-all-excluded).
ORIGIN_RAW="$TMPDIR_BASE/origin.git"
git init -q --bare "$ORIGIN_RAW"
git -C "$ORIGIN_RAW" config core.hooksPath /dev/null
SOLO_RAW="$TMPDIR_BASE/solo"
fixture_repo "$SOLO_RAW"
git -C "$SOLO_RAW" remote add origin "$ORIGIN_RAW"
git -C "$SOLO_RAW" push -q -u origin main >/dev/null 2>&1
echo note > "$SOLO_RAW/notes.md"
git -C "$SOLO_RAW" add notes.md
git -C "$SOLO_RAW" commit -q --no-verify -m notes
SOLO="$(np "$SOLO_RAW")"

EXT="$(np "$TMPDIR_BASE")/ext-wt"

# ── Table evaluator: one node process per table ─────────────────────────────
# pred rows : want :: fn[#exclude] :: REPO|SOLO|- :: cmd   (want=gen expands VARIANTS)
# shape rows: want :: fn :: cmd
# Placeholders: @ROOT@ @AMR@ @REPO@ @SOLO@ @EXT@ @NL@. A missing module reads "ERROR: ...".
EVAL_JS='
const root = process.argv[1], kind = process.argv[2];
const fs = require("fs"), path = require("path"), E = process.env;
const sub = (s) => [["@ROOT@", root], ["@AMR@", "$AGENTS_MAIN_ROOT"], ["@REPO@", E.T_REPO], ["@SOLO@", E.T_SOLO], ["@EXT@", E.T_EXT], ["@NL@", "\n"]]
  .reduce((a, [k, v]) => a.split(k).join(v), s);
const first = (e) => String(e && e.message).split("\n")[0];
const load = (rel) => { try { return require(path.join(root, rel)); } catch (e) { return new Error(first(e)); } };
const MW = "hooks/enforce-worktree/main-worktree-allows";
const std = load(MW + ".js"), sup = load(MW + "/supervisor-bin.js"), shape = load(MW + "/command-shape.js");
function pred(spec, repoKey, cmd) {
  const [fn, ex] = spec.split("#");
  const mod = fn === "isAllowedSupervisorBinTool" ? sup : std;
  if (mod instanceof Error) return "ERROR: " + mod.message;
  if (typeof mod[fn] !== "function") return "ERROR: " + fn + " not exported";
  const args = [cmd, repoKey === "SOLO" ? E.T_SOLO : repoKey === "REPO" ? E.T_REPO : null];
  if (fn === "isAllowedPushAllExcluded") args.push([ex || "notes.md"]);
  try { return String(mod[fn](...args)); } catch (e) { return "ERROR: threw " + first(e); }
}
function shp(fn, cmd) {
  if (shape instanceof Error) return "ERROR: " + shape.message;
  if (typeof shape[fn] !== "function") return "ERROR: " + fn + " not exported";
  try {
    if (fn === "singleInvocation" || fn === "cdTailInvocation") return shape[fn](cmd) ? "seg" : "null";
    if (fn === "leadingAssignments") {
      const s = shape.singleInvocation(cmd);
      if (!s) return "no-seg";
      const r = shape[fn](s);
      return r ? r.assignments.map((a) => a.name + "=" + a.value).join(",") + ">" + r.seg.cmd0 : "null";
    }
  } catch (e) { return "ERROR: threw " + first(e); }
  return "ERROR: unknown fn " + fn;
}
const VARIANTS = [
  ["chain-semi-after", (c) => c + "; rm -rf x"], ["chain-semi-before", (c) => "rm -rf x; " + c],
  ["chain-and-after", (c) => c + " && rm -rf x"], ["chain-and-before", (c) => "rm -rf x && " + c],
  ["chain-or", (c) => c + " || rm -rf x"], ["pipe-after", (c) => c + " | tee x"],
  ["pipe-before", (c) => "cat x | " + c], ["cmdsub-arg", (c) => c + " $(rm -rf x)"],
  ["backtick-arg", (c) => c + " `rm -rf x`"], ["procsub-in", (c) => c + " <(rm -rf x)"],
  ["procsub-out", (c) => c + " >(rm -rf x)"], ["heredoc", (c) => c + " <<EOF\nx\nEOF"],
  ["group", (c) => "{ " + c + "; }"], ["redir-home", (c) => c + " > ~/.bashrc"],
  ["redir-tmp-then-home", (c) => c + " > /tmp/a > ~/.bashrc"], ["redir-stderr-home", (c) => c + " 2> ~/x"],
  ["redir-input", (c) => c + " < ~/.ssh/id_rsa"], ["unclosed-quote", (c) => c + " " + String.fromCharCode(39) + "unclosed"],
  ["non-leading", (c) => "rm -rf x " + c],
];
const out = [];
const emit = (label, want, got) => out.push([label, want, String(got).replace(/[\t\n]/g, " ")].join("\t"));
for (const line of fs.readFileSync(0, "utf8").split("\n")) {
  if (!line.trim() || line.trim().startsWith("#")) continue;
  const f = line.split(" :: ").map((s) => s.trim());
  if (kind === "pred") {
    const [want, fn, repo] = f, raw = f.slice(3).join(" :: "), cmd = sub(raw);
    if (want === "gen") {
      emit(fn + "[canonical] " + raw, "true", pred(fn, repo, cmd));
      for (const [n, g] of VARIANTS) emit(fn + "[" + n + "] " + raw, "false", pred(fn, repo, g(cmd)));
    } else emit(fn + " " + raw, want, pred(fn, repo, cmd));
  } else {
    const [want, fn] = f, raw = f.slice(2).join(" :: ");
    emit(fn + " " + raw, want, shp(fn, sub(raw)));
  }
}
process.stdout.write(out.concat(["#ROWS\t" + out.length]).join("\n") + "\n");
'

run_table() {
    local kind="$1" out label want got rows=0 declared=""
    out="$(run_with_timeout 100 env "T_REPO=$REPO" "T_SOLO=$SOLO" "T_EXT=$EXT" \
        node -e "$EVAL_JS" "$ROOT_NODE" "$kind" 2>&1)" || { fail "table-$kind" "evaluator failed: ${out:0:300}"; return; }
    while IFS=$'\t' read -r label want got; do
        case "$label" in "") continue ;; "#ROWS") declared="$want"; continue ;; esac
        if [ -z "$want" ] || [ -z "$got" ]; then fail "table-$kind malformed row" "$label"; continue; fi
        rows=$((rows + 1))
        expect_eq "$label" "$got" "$want"
    done <<< "$out"
    expect_eq "table-$kind every evaluated row was asserted" "$rows" "${declared:-missing}"
}

# The command text a user types names the agents root as a literal variable reference.
# It is spliced in from AMR_REF (shell) / @AMR@ (tables) so no line of this file joins
# the root to a code directory (check-root-names structural).
AMR_REF='$AGENTS_MAIN_ROOT'
PROBE="bash -c 'cd \"$AMR_REF\" && bash \"$AMR_REF/bin/confirm-off\" CONFIRM_OUTLINE on'"

# ── command-shape.js units ──────────────────────────────────────────────────
case_begin "command-shape-units" "hooks/enforce-worktree/main-worktree-allows/command-shape.js"
run_table shape <<'TABLE'
seg  :: singleInvocation :: node a b
seg  :: singleInvocation :: node a > /tmp/x
seg  :: singleInvocation :: node a '<(x)'
null :: singleInvocation :: node a; node b
null :: singleInvocation :: node a && node b
null :: singleInvocation :: node a || node b
null :: singleInvocation :: node a | node b
null :: singleInvocation :: node a $(id)
null :: singleInvocation :: node a `id`
null :: singleInvocation :: node a <(id)
null :: singleInvocation :: node a >(id)
null :: singleInvocation :: cat <<EOF@NL@x@NL@EOF
null :: singleInvocation :: { node a; }
null :: singleInvocation :: (node a)
null :: singleInvocation :: node 'unclosed
CONV_LANG=ja>bash :: leadingAssignments :: CONV_LANG=ja bash -c 'x'
>bash             :: leadingAssignments :: bash -c 'x'
X=1,Y=2>bash      :: leadingAssignments :: X=1 Y=2 bash -c 'x'
null              :: leadingAssignments :: CONV_LANG=ja
seg  :: cdTailInvocation :: git worktree add /x -b f && cd /x
seg  :: cdTailInvocation :: git worktree add /x -b f && cd "/x y"
null :: cdTailInvocation :: git worktree add /x -b f && cd /x && rm -rf y
null :: cdTailInvocation :: git worktree add /x -b f && rm -rf y
null :: cdTailInvocation :: git worktree add /x -b f || cd /x
null :: cdTailInvocation :: git worktree add /x -b f; cd /x
null :: cdTailInvocation :: git worktree add /x -b f && cd $(rm -rf y)
null :: cdTailInvocation :: git worktree add $(rm -rf y) -b f && cd /x
TABLE
case_end

# ── standard.js predicates: canonical shape + generated attack variants ─────
case_begin "standard-predicates-single-invocation" "hooks/enforce-worktree/main-worktree-allows/standard.js"
run_table pred <<'TABLE'
gen   :: isAllowedFastForwardMerge    :: REPO :: git pull --ff-only
true  :: isAllowedFastForwardMerge    :: REPO :: git merge --ff-only origin/main
false :: isAllowedFastForwardMerge    :: REPO :: git commit -m "merge --ff-only"
false :: isAllowedFastForwardMerge    :: REPO :: X=1 git pull --ff-only
gen   :: isAllowedMidOperationAbort   :: REPO :: git merge --abort
true  :: isAllowedMidOperationAbort   :: REPO :: git rebase --abort
false :: isAllowedMidOperationAbort   :: REPO :: git rm -rf foo git merge --abort
gen   :: isAllowedMainWorktreeCleanup :: SOLO :: git stash
true  :: isAllowedMainWorktreeCleanup :: SOLO :: git restore --staged README.md
true  :: isAllowedMainWorktreeCleanup :: SOLO :: git checkout -- README.md
true  :: isAllowedMainWorktreeCleanup :: SOLO :: git merge --no-edit origin/main
false :: isAllowedMainWorktreeCleanup :: REPO :: git stash
gen   :: isAllowedPushAllExcluded     :: SOLO :: git push
false :: isAllowedPushAllExcluded#other.md :: SOLO :: git push
false :: isAllowedPushAllExcluded     :: SOLO :: rm -rf x git push
gen   :: isAllowedComposeDocAppend    :: REPO :: bash "@ROOT@/bin/compose-doc-append-entry" --subject x
false :: isAllowedComposeDocAppend    :: REPO :: bash "@AMR@/bin/compose-doc-append-entry" --subject x
gen   :: isAllowedClarifyGuardLoop    :: REPO :: bash "@ROOT@/bin/github-issues/clarify-guard-loop.sh" 1234
false :: isAllowedClarifyGuardLoop    :: REPO :: bash "@AMR@/bin/github-issues/clarify-guard-loop.sh" 1234
gen   :: isAllowedReadOnlyWorkflowCli :: REPO :: bash -c 'cat README.md'
gen   :: isAllowedSupervisorBinTool   :: REPO :: node "@ROOT@/bin/supervisor-write-alert" --session s
gen   :: isAllowedSupervisorBinTool   :: REPO :: bash "@ROOT@/bin/supervisor-findings-codex" --session s
TABLE
case_end

# ── ReadOnlyConfigCheck: explicit leading-assignment analysis (R2-5) ────────
case_begin "read-only-config-check-assignments" "hooks/enforce-worktree/main-worktree-allows/standard.js"
run_table pred <<'TABLE'
gen   :: isAllowedReadOnlyConfigCheck :: - :: bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
true  :: isAllowedReadOnlyConfigCheck :: - :: CONV_LANG=ja bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
true  :: isAllowedReadOnlyConfigCheck :: - :: CONV_LANG=ja bash -c "cd \"$AGENTS_MAIN_ROOT\" && bash \"@AMR@/bin/confirm-off\" CONFIRM_DETAIL off"
false :: isAllowedReadOnlyConfigCheck :: - :: BASH_ENV=/home/u/x.sh bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: ENV=x bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: PATH=/tmp/bin bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: SHELLOPTS=xtrace bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: IFS=x bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: CONV_LANG=$(id) bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: CONV_LANG=`id` bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: CONV_LANG="a b" bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: X=1 Y=2 bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
false :: isAllowedReadOnlyConfigCheck :: - :: CONV_LANG=ja
false :: isAllowedReadOnlyConfigCheck :: - :: CONV_LANG=ja bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on' > /tmp/a
false :: isAllowedReadOnlyConfigCheck :: - :: CONV_LANG=ja bash -x -c 'cd "$AGENTS_MAIN_ROOT" && bash "@AMR@/bin/confirm-off" CONFIRM_OUTLINE on'
TABLE
case_end

# ── Re-exported siblings: worktree-command (#982 cd tail) ───────────────────
case_begin "worktree-command-single-invocation" "hooks/enforce-worktree/main-worktree-allows/worktree-command.js"
run_table pred <<'TABLE'
gen   :: isAllowedWorktreeCommand :: REPO :: git worktree add "@EXT@" -b feat-x
true  :: isAllowedWorktreeCommand :: REPO :: git worktree add "@EXT@" -b feat-x && cd "@EXT@"
true  :: isAllowedWorktreeCommand :: REPO :: git worktree prune
true  :: isAllowedWorktreeCommand :: REPO :: git worktree remove "@EXT@"
false :: isAllowedWorktreeCommand :: REPO :: git worktree add "@EXT@" -b feat-x && cd "@EXT@" && rm -rf x
false :: isAllowedWorktreeCommand :: REPO :: git worktree add "@EXT@" -b feat-x || cd "@EXT@"
false :: isAllowedWorktreeCommand :: REPO :: git worktree add "@EXT@" -b feat-x && cd $(rm -rf x)
false :: isAllowedWorktreeCommand :: REPO :: rm -rf x git worktree prune
false :: isAllowedWorktreeCommand :: REPO :: git worktree remove --force "@EXT@"
false :: isAllowedWorktreeCommand :: REPO :: git worktree add "@REPO@/inside" -b feat-y
TABLE
case_end

# ── Re-exported siblings: worker-script (#1679 companion exception) ─────────
case_begin "worker-script-single-invocation" "hooks/enforce-worktree/main-worktree-allows/worker-script.js"
run_table pred <<'TABLE'
gen   :: isAllowedWorkerScriptInvocation :: REPO :: bash "@ROOT@/bin/check-unstaged-tracked.sh"
true  :: isAllowedWorkerScriptInvocation :: REPO :: git status && bash "@ROOT@/bin/check-unstaged-tracked.sh"
false :: isAllowedWorkerScriptInvocation :: REPO :: export AGENTS_MAIN_ROOT=/evil && bash "@ROOT@/bin/check-unstaged-tracked.sh"
false :: isAllowedWorkerScriptInvocation :: REPO :: bash "@AMR@/bin/check-unstaged-tracked.sh"
false :: isAllowedWorkerScriptInvocation :: REPO :: BASH_ENV=/home/u/x.sh bash "@ROOT@/bin/check-unstaged-tracked.sh"
TABLE
case_end

# ── S2-1b inventory: every documented NAME=… bash -c prefix is allow-listed ──
# The ReadOnlyConfigCheck allow-list is CONV_LANG only (#1421). Any other prefix a
# skill, agent, hook, or rule documents in front of `bash -c` (or of a confirm-off
# probe) would turn from allow to block, so it has to be added to the list first.
case_begin "config-check-prefix-inventory" "hooks/enforce-worktree/main-worktree-allows/standard.js"
ALLOWED_PREFIX_NAMES=" CONV_LANG "
# A value may be quoted ("a b" / 'x'), so the value part is any non-space run.
INV_RE='(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+bash[[:space:]]+-[A-Za-z]*c([^A-Za-z]|$)'
inv_names="$(cd "$SCRIPT_CHECKOUT_ROOT" && grep -rhoE "$INV_RE" skills agents hooks rules 2>/dev/null | sed -E 's/^[^A-Za-z_]//; s/=.*//' | sort -u)"
inv_bad=""
for n in $inv_names; do
    case "$ALLOWED_PREFIX_NAMES" in *" $n "*) ;; *) inv_bad="$inv_bad $n" ;; esac
done
expect_eq "S2-1b every NAME=… bash -c prefix under skills/agents/hooks/rules is allow-listed" "${inv_bad# }" ""
probe_count="$(cd "$SCRIPT_CHECKOUT_ROOT" && grep -rlF "bash \"$AMR_REF/bin/confirm-off\"" skills 2>/dev/null | wc -l | tr -d ' ')"
if [ "${probe_count:-0}" -ge 1 ]; then
    pass "S2-1b anti-vacuity: confirm-off probes are present in skills/ ($probe_count files)"
else
    fail "S2-1b anti-vacuity" "no confirm-off probe found under skills/ — the inventory grep is looking at nothing"
fi
case_end

# ── End-to-end: the real hook on the security-relevant rows ─────────────────
# Each attack row carries a separator or an in-repo target so that no earlier
# allow (universal target allow, Bug 2) answers before the predicates do.
GUARD_ERR="$TMPDIR_BASE/guard.stderr"
assert_guard() {
    local label="$1" want="$2" repo_raw="$3" cmd="$4" repo_node payload out rc=0 got
    repo_node="$(np "$repo_raw")"
    payload="$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$cmd")"
    out="$(cd "$repo_raw" && printf '%s' "$payload" | run_with_timeout 30 env -u AGENTS_MAIN_ROOT -u AGENTS_HOOK_DEBUG \
        -u CLAUDE_CODE_SESSION_ID ENFORCE_WORKTREE=on "CLAUDE_PROJECT_DIR=$repo_node" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo_node" node "$GUARD_JS" 2>"$GUARD_ERR")" || rc=$?
    if [ "$rc" -ne 0 ]; then got="crash rc=$rc err=$(head -c 200 "$GUARD_ERR")"
    elif [ "$out" = "{}" ]; then got=allow
    elif printf '%s' "$out" | grep -q '"decision":"block"'; then got=block
    else got="neither: $out"; fi
    expect_eq "$label" "$got" "$want"
}

case_begin "e2e-single-invocation" "hooks/enforce-worktree.js"
assert_guard "E2E ff-only behind a non-leading rm is blocked"            block "$REPO_RAW" "rm -rf x git pull --ff-only"
assert_guard "E2E merge --abort as an argument of git rm is blocked"     block "$REPO_RAW" "git rm -rf foo git merge --abort"
assert_guard "E2E stash behind a non-leading rm is blocked"              block "$SOLO_RAW" "rm -rf x git stash"
assert_guard "E2E worktree prune behind a non-leading rm is blocked"     block "$REPO_RAW" "rm -rf x git worktree prune"
assert_guard "E2E chained in-repo write before ff-only is blocked"       block "$REPO_RAW" "echo x > README.md; git pull --ff-only"
assert_guard "E2E BASH_ENV prefix on the confirm-off probe is blocked"   block "$REPO_RAW" "BASH_ENV=/home/u/x.sh $PROBE"
assert_guard "E2E control: git pull --ff-only is allowed"                allow "$REPO_RAW" "git pull --ff-only"
assert_guard "E2E control: git stash is allowed (no linked worktree)"    allow "$SOLO_RAW" "git stash"
assert_guard "E2E control: git worktree prune is allowed"                allow "$REPO_RAW" "git worktree prune"
assert_guard "E2E control: CONV_LANG=ja confirm-off probe is allowed"    allow "$REPO_RAW" "CONV_LANG=ja $PROBE"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
