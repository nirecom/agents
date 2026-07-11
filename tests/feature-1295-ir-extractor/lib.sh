#!/usr/bin/env bash
# Shared helpers + JS bridges for feature-1295-ir-extractor part suites.
# Sourced by each part-N-*.sh. NOT run standalone.
#
# Contract with the dispatcher (feature-1295-ir-extractor.sh):
#   - $1 = WORKTREE root (agents repo). All node require() targets resolve here.
#   - Each part script sources this file, runs assert_eq cases, and exits $FAIL.
#
# Pre-implementation (WF-CODE-4 / write-tests): several APIs under test do NOT
# exist yet. NEW-API cases use a try/catch bridge that emits an "ERROR:..."
# sentinel instead of crashing, so a pre-impl run FAILS the assertion cleanly
# rather than aborting the suite. EXISTING infrastructure (string-API extractors,
# parse, collectBashWriteTargets string bridge) must PASS now and keep passing.

set -uo pipefail

PASS=0; FAIL=0

# Worktree root — passed by the dispatcher as $1; fall back to two-levels-up.
WORKTREE="${1:-}"
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found — skipping tests"; exit 77; }

# ---------------------------------------------------------------------------
# assert_eq — table-driven assertion (inlined per test-design.md; no shared lib).
# ---------------------------------------------------------------------------
assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# JS bridges — each shells out to node once per case. The command/segment string
# is passed as argv (process.argv[N]) to avoid quoting/escaping surprises from
# string-interpolating into the -e source (canary-2 pattern).
#
# NEW-API bridges (tok_quotes, ir_*, expand_raw, has_verb, collect_targets,
# *_ir) emit "ERROR:<why>" on the pre-impl absence path so the harness reports
# a clean FAIL rather than a node crash.
# ---------------------------------------------------------------------------

# tokenizeSegmentWithQuotes(seg) → JSON [{value,raw},...] ; "ERROR:not-exported" if missing.
# MSYS_NO_PATHCONV=1: git-bash on Windows rewrites a literal `/foo` argument (e.g. the
# unquoted suffix of "$HOME"/foo) into a native path (C:/Program Files/Git/foo),
# corrupting the token string before node sees it. These inputs are literal token
# text, not real paths, so path conversion must be suppressed for this bridge.
tok_quotes() {
  ( cd "$WORKTREE" && MSYS_NO_PATHCONV=1 node -e '
    const m = require("./hooks/lib/command-parser");
    if (typeof m.tokenizeSegmentWithQuotes !== "function") { process.stdout.write("ERROR:not-exported"); process.exit(0); }
    process.stdout.write(JSON.stringify(m.tokenizeSegmentWithQuotes(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# buildSegmentIR field bridges — read the first segment of parse(cmd).
ir_field() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const s = parse(process.argv[1]).segments[0] || {};
    process.stdout.write(JSON.stringify(s[process.argv[2]]));
  ' "$1" "$2" ) 2>/dev/null
}

# ir_separators <cmd> — top-level parse().separators (pipe/semicolon between segments).
# Not a segment field (lives on the parse result), so it needs its own bridge.
# EXISTING infra (PASS now).
ir_separators() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    process.stdout.write(JSON.stringify(parse(process.argv[1]).separators));
  ' "$1" ) 2>/dev/null
}

# ir_parsefailure <cmd> — top-level parse().parseFailure (whole-parse fail flag).
# Distinct from segments[0].parseFailure (undefined for unclosed quotes, since the
# segment list comes back empty). EXISTING infra (PASS now).
ir_parsefailure() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    process.stdout.write(JSON.stringify(parse(process.argv[1]).parseFailure));
  ' "$1" ) 2>/dev/null
}

ir_argvraw_len() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const s = parse(process.argv[1]).segments[0] || {};
    if (!Array.isArray(s.argvRaw)) { process.stdout.write("ERROR:no-argvRaw"); process.exit(0); }
    process.stdout.write(String(s.argvRaw.length));
  ' "$1" ) 2>/dev/null
}

ir_argv_len() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const s = parse(process.argv[1]).segments[0] || {};
    process.stdout.write(String((s.argv || []).length));
  ' "$1" ) 2>/dev/null
}

ir_targetraw() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const s = parse(process.argv[1]).segments[0] || {};
    const r = (s.redirects || [])[0];
    if (!r || !("targetRaw" in r)) { process.stdout.write("ERROR:no-targetRaw"); process.exit(0); }
    process.stdout.write(JSON.stringify(r.targetRaw));
  ' "$1" ) 2>/dev/null
}

# ir_targetraw_at <cmd> <index> — redirects[<index>].targetRaw (NEW; "ERROR:no-targetRaw" pre-impl).
# Used by C6 multi-redirect alignment: asserts targetRaw[i] tracks target[i] index-for-index.
ir_targetraw_at() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const s = parse(process.argv[1]).segments[0] || {};
    const r = (s.redirects || [])[Number(process.argv[2])];
    if (!r || !("targetRaw" in r)) { process.stdout.write("ERROR:no-targetRaw"); process.exit(0); }
    process.stdout.write(JSON.stringify(r.targetRaw));
  ' "$1" "$2" ) 2>/dev/null
}

# ir_target_at <cmd> <index> — redirects[<index>].target (EXISTING; PASS now).
# The alignment anchor C6 compares targetRaw against.
ir_target_at() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const s = parse(process.argv[1]).segments[0] || {};
    const r = (s.redirects || [])[Number(process.argv[2])] || {};
    process.stdout.write(JSON.stringify(r.target));
  ' "$1" "$2" ) 2>/dev/null
}

# call_hook <hook-basename> <command> → "block"|"approve"|"ERROR:<why>".
# L2 caller bridge (C1): spawns the REAL block-*.js hook as a subprocess with a
# PreToolUse Bash event on stdin and reads the {decision} it prints. Exercises the
# hook's whole bashHitsProtected/bashHitsMemory path end-to-end (extractors +
# path-match), NOT a live claude session (that is L3). No function export needed —
# the hooks are process-exit scripts, so subprocess is the only L2-viable seam.
call_hook() {
  local hook="$1" cmd="$2"
  local ev
  ev="$( ( cd "$WORKTREE" && node -e '
    process.stdout.write(JSON.stringify({ tool_name: "Bash", tool_input: { command: process.argv[1] } }));
  ' "$cmd" ) 2>/dev/null )"
  ( cd "$WORKTREE" && printf '%s' "$ev" | node "hooks/$hook" ) 2>/dev/null \
    | ( cd "$WORKTREE" && node -e '
        let s = ""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
          try { process.stdout.write(String(JSON.parse(s).decision)); }
          catch (_e) { process.stdout.write("ERROR:no-decision"); }
        });
      ' ) 2>/dev/null
}

# call_hook_raw <hook-basename> <raw-json> → "block"|"approve"|"ERROR:no-decision".
# C4 variant: pipes arbitrary (possibly malformed) JSON directly to the hook and
# reads {decision}. Used to pin fail-open behavior on bad input: hooks must return
# {decision:"approve"} (not throw/crash) when given malformed JSON, missing
# tool_input.command, or a non-string command value.
call_hook_raw() {
  local hook="$1" raw_json="$2"
  ( cd "$WORKTREE" && printf '%s' "$raw_json" | node "hooks/$hook" ) 2>/dev/null \
    | ( cd "$WORKTREE" && node -e '
        let s = ""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
          try { process.stdout.write(String(JSON.parse(s).decision)); }
          catch (_e) { process.stdout.write("ERROR:no-decision"); }
        });
      ' ) 2>/dev/null
}

# call_hook_output_keys <hook-basename> <command> → comma-sorted top-level JSON keys.
# C4 security probe: asserts the hook output contains ONLY the expected keys
# (no "command" or other fields that would echo back user command content).
call_hook_output_keys() {
  local hook="$1" cmd="$2"
  local ev
  ev="$( ( cd "$WORKTREE" && node -e '
    process.stdout.write(JSON.stringify({ tool_name: "Bash", tool_input: { command: process.argv[1] } }));
  ' "$cmd" ) 2>/dev/null )"
  ( cd "$WORKTREE" && printf '%s' "$ev" | node "hooks/$hook" ) 2>/dev/null \
    | ( cd "$WORKTREE" && node -e '
        let s = ""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
          try { process.stdout.write(Object.keys(JSON.parse(s)).sort().join(",")); }
          catch (_e) { process.stdout.write("ERROR:parse"); }
        });
      ' ) 2>/dev/null
}

# expandRawToken(rawTok) → JSON of return value (null → "null"); "ERROR:not-exported" if missing.
expand_raw() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets/helpers");
    if (typeof m.expandRawToken !== "function") { process.stdout.write("ERROR:not-exported"); process.exit(0); }
    process.stdout.write(JSON.stringify(m.expandRawToken(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# ---- EXISTING string-API extractors (expected to PASS now) ----------------

# extractRedirectTargets(cmdString) → JSON string[] | null.
call_redirect() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets/redirect");
    process.stdout.write(JSON.stringify(m.extractRedirectTargets(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# expandStaticShellTokens(s, {fromQuotedContext}) → JSON string | null.
call_expand_static() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets/redirect");
    process.stdout.write(JSON.stringify(m.expandStaticShellTokens(process.argv[1], { fromQuotedContext: process.argv[2] })));
  ' "$1" "$2" ) 2>/dev/null
}

# extractTeeTargets(cmdString) → JSON string[] | null.
call_tee() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets/tee");
    process.stdout.write(JSON.stringify(m.extractTeeTargets(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# extractCpMvDestination(cmdString) → JSON string | null (returns a string, not array).
call_cpmv() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets/cp-mv");
    process.stdout.write(JSON.stringify(m.extractCpMvDestination(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# extractRmTargets(cmdString) → JSON string[] | null.
call_rm() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets/rm");
    process.stdout.write(JSON.stringify(m.extractRmTargets(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# extractPwshWriteTargets(cmdString) → JSON string[] | null.
call_pwsh() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets/pwsh");
    process.stdout.write(JSON.stringify(m.extractPwshWriteTargets(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# collectBashWriteTargets(cmdString) → JSON {targets,parseFailure} (AT-DP2 bridge; string in).
call_collect_bash() {
  ( cd "$WORKTREE" && node -e '
    const {collectBashWriteTargets} = require("./hooks/enforce-worktree/bash-write-scope");
    process.stdout.write(JSON.stringify(collectBashWriteTargets(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# ---- NEW IR-form extractor bridges (post-migration; expected to FAIL now) --
# Each builds a SegmentIR via parse(cmd).segments[<idx>] then calls the extractor
# with the IR object. Pre-impl the extractors only accept strings, so they throw
# or return a non-array → the try/catch emits "ERROR:not-ir-api".

# call_redirect_ir <cmd> — extractRedirectTargets(segmentIR), segment chosen by having redirects.
call_redirect_ir() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const m = require("./hooks/lib/bash-write-targets/redirect");
    const segs = parse(process.argv[1]).segments;
    const seg = segs.find(s => (s.redirects || []).length > 0) || segs[0];
    try {
      const r = m.extractRedirectTargets(seg);
      if (!Array.isArray(r)) throw new Error("not-array");
      process.stdout.write(JSON.stringify(r));
    } catch (e) { process.stdout.write("ERROR:not-ir-api"); }
  ' "$1" ) 2>/dev/null
}

# call_extractor_ir <module-basename> <export> <cmd> <verb> — generic IR-form bridge.
# Picks the segment whose cmd0 matches <verb>; calls export(seg).
# Pre-impl the extractor only accepts strings and returns null for a non-string
# (object) input; that null is treated as the not-implemented signal and mapped
# to "ERROR:not-ir-api" (mirrors the redirect_ir bridge). Post-migration the IR
# form returns the real array/string and the assertion's expected value matches.
call_extractor_ir() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const m = require("./hooks/lib/bash-write-targets/" + process.argv[1]);
    const fn = m[process.argv[2]];
    const verb = process.argv[4];
    const segs = parse(process.argv[3]).segments;
    const seg = segs.find(s => s.cmd0 === verb) || segs[0];
    try {
      const r = fn(seg);
      if (Array.isArray(r) || typeof r === "string") {
        process.stdout.write(JSON.stringify(r));
      } else { throw new Error("not-ir-api"); }
    } catch (e) { process.stdout.write("ERROR:not-ir-api"); }
  ' "$1" "$2" "$3" "$4" ) 2>/dev/null
}

# call_extractor_ir_null_ok <module-basename> <export> <cmd> <verb> — IR-form bridge
# that accepts null return values (fail-closed probes). Like call_extractor_ir but
# does NOT treat null as an error — used to assert fail-closed IR paths where the
# extractor legitimately returns null on unresolvable tokens.
call_extractor_ir_null_ok() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const m = require("./hooks/lib/bash-write-targets/" + process.argv[1]);
    const fn = m[process.argv[2]];
    const verb = process.argv[4];
    const segs = parse(process.argv[3]).segments;
    const seg = segs.find(s => s.cmd0 === verb) || segs[0];
    try {
      const r = fn(seg);
      process.stdout.write(JSON.stringify(r));
    } catch (e) { process.stdout.write("ERROR:threw:" + e.message); }
  ' "$1" "$2" "$3" "$4" ) 2>/dev/null
}

# call_ir_null <module-basename> <export> — fail-closed null-input probe (C5).
# Calls export(null) on the per-verb extractor module and JSON.stringifies the
# result; a throw is mapped to "ERROR:null-threw". Both the current string-API and
# the post-migration IR-form extractor must return null (not throw) on null/garbage
# input — this bridge pins that fail-closed null-safety across the migration.
call_ir_null() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets/" + process.argv[1]);
    const fn = m[process.argv[2]];
    try { process.stdout.write(JSON.stringify(fn(null))); }
    catch (e) { process.stdout.write("ERROR:null-threw"); }
  ' "$1" "$2" ) 2>/dev/null
}

# ---- NEW barrel verb-set + segment-collector bridges ----------------------

# has_verb <SET_NAME> <verb> → "true"/"false"/"ERROR:no-set".
has_verb() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets");
    const set = m[process.argv[1]];
    if (!set || typeof set.has !== "function") { process.stdout.write("ERROR:no-set"); process.exit(0); }
    process.stdout.write(String(set.has(process.argv[2])));
  ' "$1" "$2" ) 2>/dev/null
}

# collect_targets <cmd> <SET_NAME> → JSON targets | "ERROR:not-exported".
collect_targets() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const m = require("./hooks/lib/bash-write-targets");
    if (typeof m.collectWriteTargetsFromSegments !== "function") { process.stdout.write("ERROR:not-exported"); process.exit(0); }
    const verbs = m[process.argv[2]];
    const segs = parse(process.argv[1]).segments;
    const out = m.collectWriteTargetsFromSegments(segs, { verbs });
    process.stdout.write(JSON.stringify(out.targets));
  ' "$1" "$2" ) 2>/dev/null
}

# collect_parsefailure <cmd> → "true"/"false".
# Runs collectWriteTargetsFromSegments on the parsed command and returns parseFailure flag.
collect_parsefailure() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const {collectWriteTargetsFromSegments} = require("./hooks/lib/bash-write-targets");
    const ir = parse(process.argv[1]);
    const result = collectWriteTargetsFromSegments(ir.segments);
    process.stdout.write(result.parseFailure ? "true" : "false");
  ' "$1" ) 2>/dev/null
}

# collect_targets_segs <SET_NAME> <segments-json> → JSON targets | "ERROR:not-exported".
# Passes an explicit segments array (used for empty / single-non-write edge cases).
collect_targets_segs() {
  ( cd "$WORKTREE" && node -e '
    const m = require("./hooks/lib/bash-write-targets");
    if (typeof m.collectWriteTargetsFromSegments !== "function") { process.stdout.write("ERROR:not-exported"); process.exit(0); }
    const verbs = m[process.argv[1]];
    const segs = JSON.parse(process.argv[2]);
    const out = m.collectWriteTargetsFromSegments(segs, { verbs });
    process.stdout.write(JSON.stringify(out.targets));
  ' "$1" "$2" ) 2>/dev/null
}

# try_resolve_plans <var_name> <suffix> → resolved path or "null".
# Calls tryResolveEnvUnderPlansDir with the given variable name and path suffix.
# Returns "null" when resolution fails (unset var, traversal, etc.).
# MSYS_NO_PATHCONV=1: suppress git-bash path conversion for /suffix arguments.
try_resolve_plans() {
  ( cd "$WORKTREE" && MSYS_NO_PATHCONV=1 node -e '
    const {tryResolveEnvUnderPlansDir} = require("./hooks/lib/bash-write-targets/helpers");
    const result = tryResolveEnvUnderPlansDir(process.argv[1], process.argv[2]);
    process.stdout.write(result === null ? "null" : String(result));
  ' "$1" "$2" ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# Shared expected-expansion values, computed via the SAME code the implementation
# uses so assertions are platform-independent. WORKFLOW_PLANS_DIR must resolve
# under HOME for the plans-dir-constrained paths (R2/E2) to be accepted.
# ---------------------------------------------------------------------------
# Normalize via path.sep (NOT a /\\/g regex): the test harness collapses a literal
# double-backslash in an inline -e body, corrupting the regex. path.sep carries no
# literal backslash in the source, so it survives the harness intact.
HOME_DIR="$(cd "$WORKTREE" && node -e 'const p=require("path"); process.stdout.write(require("os").homedir().split(p.sep).join("/"))')"
export WORKFLOW_PLANS_DIR="${WORKFLOW_PLANS_DIR:-$HOME_DIR/.workflow-plans}"

EXP_HOME_PLANS="$(cd "$WORKTREE" && WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" node -e '
  const {expandStaticShellTokens}=require("./hooks/lib/bash-write-targets/redirect");
  process.stdout.write(expandStaticShellTokens("$HOME/.workflow-plans/f.json",{fromQuotedContext:"double"}));
')"
EXP_HOME_FOO_TXT="$(cd "$WORKTREE" && node -e '
  const {expandStaticShellTokens}=require("./hooks/lib/bash-write-targets/redirect");
  process.stdout.write(expandStaticShellTokens("~/foo.txt",{fromQuotedContext:"unquoted"}));
')"
