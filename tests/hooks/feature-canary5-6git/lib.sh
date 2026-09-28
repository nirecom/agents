#!/usr/bin/env bash
# tests/hooks/feature-canary5-6git/lib.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/enforce-worktree/bash-write-scope.js
# Tags: enforce-worktree, test-helper, scope:issue-specific, pwsh-not-required, batch-harness
# Shared helpers + batched node driver for the canary5-6git suite parts; sourced
# by each part, NOT run standalone. $1 = WORKTREE root (agents repo). Parts queue
# rows with bq_row/bq_table, evaluate them with bq_flush (ONE node per flush), and
# exit $FAIL. RED-pending ops guard require()/typeof and emit "ERROR:<why>".

set -uo pipefail

# Git Bash / MSYS2 rewrites POSIX-looking argv (e.g. `/usr/bin/git`) into Windows
# paths before exec. Rows travel over stdin, but keep the conversion off for the
# git fixture calls. No-op on non-MSYS platforms.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

PASS=0; FAIL=0; SKIP=0

# Worktree root — passed by the dispatcher as $1; fall back to two-levels-up.
WORKTREE="${1:-}"
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found — skipping tests"; exit 77; }

# Node-friendly (forward-slash) worktree path for require() strings.
if command -v cygpath >/dev/null 2>&1; then
  WT_NODE="$(cygpath -m "$WORKTREE")"
else
  WT_NODE="$WORKTREE"
fi
GUARD_JS="${WT_NODE}/hooks/enforce-worktree.js"

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
  fi
}
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

# Batch driver: stdin rows "op<TAB>arg...", stdout "@@BQ<TAB>idx<TAB>got". Each op
# mirrors a former one-node bridge: caught errors keep their ERROR:* string, an
# uncaught throw maps to "" (the old bridge crashed to empty stdout). Isolation:
# ops are pure functions of their args (no per-call caches in these modules);
# guard/blockhook still spawn the real hook as a fresh child, sequentially.
BQ_DRIVER='
const WT = process.argv[1];
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");
const R = (p) => require(WT + "/" + p);
const parse = (c) => R("hooks/lib/command-ir").parse(c);
const scope = () => R("hooks/enforce-worktree/bash-write-scope");
const grd = () => R("hooks/enforce-worktree/git-repo-detection");
const nul = (s) => (s === "__NULL__" ? null : s);
const guarded = (f, err) => { try { return f(); } catch (e) { return err; } };
const OPS = {
  classify: (a) => R("hooks/lib/bash-write-patterns").classify(parse(a[0])),
  ro_interp_c: (a) => String(R("hooks/lib/bash-write-patterns").isReadOnlyInterpreterC(a[0])),
  green: (a) => {
    const fn = R("hooks/lib/bash-write-targets")[a[0]];
    if (typeof fn !== "function") return "ERROR:not-exported";
    return guarded(() => String(fn(parse(a[1]))), "ERROR:threw");
  },
  git_write: (a) => {
    const m = R("hooks/lib/bash-write-patterns/patterns");
    if (typeof m.isGitWriteIR !== "function") return "ERROR:not-exported";
    return guarded(() => String(m.isGitWriteIR(parse(a[0]))), "ERROR:threw");
  },
  kind_count: (a) => String(R("hooks/lib/bash-write-patterns/patterns").WRITE_PATTERNS.filter((p) => p.kind === a[0]).length),
  strip_has: (a) => String(R("hooks/lib/bash-write-patterns/patterns").STRIP_KINDS.has(a[0])),
  collect_first: (a) => {
    const out = R("hooks/lib/bash-write-targets").collectWriteTargetsFromSegments(parse(a[0]).segments);
    return (!out.targets || out.targets.length === 0) ? "null" : JSON.stringify(out.targets[0]);
  },
  extractor_str: (a) => JSON.stringify(R("hooks/lib/bash-write-targets/" + a[0])[a[1]](a[2])),
  idem: (a) => {
    const ir = parse(a[0]);
    return guarded(() => {
      const x = JSON.stringify(scope().collectBashWriteTargets(ir));
      const y = JSON.stringify(scope().collectBashWriteTargets(ir));
      return x === y ? "identical" : ("DIFF:" + x + "|" + y);
    }, "ERROR:threw");
  },
  sc_self: (a) => {
    const roots = new Set([grd().normalizeForCompare(a[0])]);
    return guarded(() => String(scope().areAllBashTargetsOutsideSessionScope([{ resolveVia: "self", path: a[1] }], roots)), "ERROR:threw");
  },
  sc_ancestor: (a) => {
    const roots = new Set([grd().normalizeForCompare(grd().findRepoRoot(a[0]))]);
    return guarded(() => String(scope().areAllBashTargetsOutsideSessionScope([{ resolveVia: "ancestor", path: a[0] }], roots)), "ERROR:threw");
  },
  sc_plans_pd: () => {
    let pd;
    try { pd = R("hooks/lib/workflow-plans-dir").getWorkflowPlansDir(); } catch (_) { return "ERROR:no-plans-dir"; }
    const t = [{ resolveVia: "ancestor", path: path.join(pd, "f.json") }];
    return guarded(() => String(scope().areAllBashTargetsUnderPlansDir(t)), "ERROR:threw");
  },
  sc_plans: (a) => guarded(() => String(scope().areAllBashTargetsUnderPlansDir([{ resolveVia: "ancestor", path: a[0] }])), "ERROR:threw"),
  bs_outside: (a) => guarded(() => { scope().areAllBashTargetsOutsideSessionScope([a[0]], new Set()); return "true"; }, "THREW"),
  bs_plans: (a) => guarded(() => { scope().areAllBashTargetsUnderPlansDir([a[0]]); return "true"; }, "THREW"),
  outside_json: (a) => String(scope().areAllBashTargetsOutsideSessionScope(JSON.parse(a[0]), new Set(JSON.parse(a[1])))),
  plans_json: (a) => String(scope().areAllBashTargetsUnderPlansDir(JSON.parse(a[0]))),
  blockhook: (a) => {
    const command = a[1].split("@HOME@").join(os.homedir());
    const r = cp.spawnSync(process.execPath, ["hooks/" + a[0]], { cwd: WT, encoding: "utf8", timeout: 30000,
      input: JSON.stringify({ tool_name: "Bash", tool_input: { command } }) });
    return guarded(() => String(JSON.parse(r.stdout).decision), "none");
  },
  guard: (a) => {
    const r = cp.spawnSync(process.execPath, [WT + "/hooks/enforce-worktree.js"], { cwd: a[0], encoding: "utf8", timeout: 30000,
      env: Object.assign({}, process.env, { ENFORCE_WORKTREE: "on" }),
      input: JSON.stringify({ session_id: "test", tool_name: "Bash", tool_input: { command: a[1] } }) + "\n" });
    return /"decision":"block"/.test(r.stdout || "") ? "block" : "allow";
  },
  extract_git: (a) => {
    let m;
    try { m = R("hooks/lib/bash-write-targets/git"); } catch (e) { return "ERROR:no-module"; }
    if (typeof m.extractGitWriteTargets !== "function") return "ERROR:not-exported";
    const ir = parse(a[0]);
    return guarded(() => JSON.stringify(m.extractGitWriteTargets(ir, nul(a[1]))), "ERROR:threw");
  },
  collect_git: (a) => {
    const ir = parse(a[0]);
    return guarded(() => JSON.stringify(a[2] === "omit" ? scope().collectBashWriteTargets(ir) : scope().collectBashWriteTargets(ir, nul(a[1]))), "ERROR:threw");
  },
  collect_git_pf: (a) => (/"parseFailure":true/.test(OPS.collect_git(a)) ? "true" : "false"),
  ese_default: (a) => String(scope().isEverySegmentExcluded(parse(a[0]), a[1], R("hooks/enforce-worktree/shared-cmd-utils").getExcludePatterns())),
  ese: (a) => String(scope().isEverySegmentExcluded(parse(a[0]), a[2], JSON.parse(a[1]))),
  ppf: (a) => { const r = grd().parseGitPathFlag(a[0], a[1]); return r === null ? "null" : String(r); },
  ppf_nonempty: (a) => guarded(() => { const r = grd().parseGitPathFlag(a[0], a[1]); return (r === null ? "null" : String(r)) !== "" ? "true" : "false"; }, "false"),
  ssot_src: () => {
    const src = fs.readFileSync(WT + "/hooks/lib/bash-write-patterns/git-write-ir.js", "utf8");
    return String(!/GIT_VALUE_TAKING_GLOBAL_FLAGS\s*=\s*new Set/.test(src) && /GIT_VALUE_TAKING_GLOBAL_FLAGS\s*=\s*FLAGS_WITH_ARG/.test(src));
  },
  wt_target: (a) => grd().parseGitPathFlag(a[0], "--work-tree") || grd().parseGitCPath(a[0]) || "null",
  frb: (a) => grd().findRepoRootForBash(a[0], a[1]) || "null",
  write_signal: (a) => {
    const { classify, isGitWriteIR } = R("hooks/lib/bash-write-patterns");
    const t = R("hooks/lib/bash-write-targets");
    const ir = parse(a[0]);
    return String(classify(ir) === "write" || isGitWriteIR(ir) || t.isPosixRedirWriteIR(ir) || t.isPwshWriteIR(ir) ||
      t.isFileOpWriteIR(ir) || t.isCommandSubstWriteIR(ir) || t.isNewlineInjectedWriteIR(ir) ||
      t.isExoticExecWriteIR(ir) || t.isInterpreterCWriteIR(ir));
  },
};
const rows = fs.readFileSync(0, "utf8").split("\n").filter((l) => l.length > 0);
const realWrite = process.stdout.write.bind(process.stdout);
let cap = "";
process.stdout.write = (c) => { cap += String(c); return true; };
const results = rows.map((line, i) => {
  const [op, ...a] = line.split("\t");
  cap = "";
  let got;
  try {
    if (!OPS[op]) throw new Error("unknown op " + op);
    const v = OPS[op](a);
    got = v === undefined ? "" : String(v);
  } catch (e) { got = ""; }
  got = (cap + got).replace(/\r/g, "\\r").replace(/\n/g, "\\n").replace(/\t/g, "\\t");
  return "@@BQ\t" + i + "\t" + got;
});
process.stdout.write = realWrite;
realWrite(results.join("\n") + "\n");
'

BQ_OPS=(); BQ_NAMES=(); BQ_WANTS=(); BQ_TRIED=0; declare -A BQ_HDR_AT=()

# bq_hdr <text> — section header, printed in order just before the next row.
bq_hdr() { BQ_HDR_AT[${#BQ_NAMES[@]}]+="$1"$'\n'; }

# bq_row <name> <want> <op> [arg...] — queue one assertion row.
bq_row() {
  BQ_TRIED=$((BQ_TRIED + 1))
  local name="$1" want="$2"; shift 2
  local joined tabs IFS=$'\t'
  joined="$*"
  tabs="${joined//[!$'\t']/}"
  if [[ "$joined" == *$'\n'* || ${#tabs} -ne $(( $# - 1 )) ]]; then
    fail "$name — bq_row: argument contains a TAB or newline (unbatchable)"; return
  fi
  BQ_OPS+=("$joined"); BQ_NAMES+=("$name"); BQ_WANTS+=("$want")
}

# bq_flush — evaluate every queued row in ONE node process, then assert each row
# with its original name / want. Vacuity guard: a missing row result, an
# unparsed driver line, or a result-count mismatch each FAIL loudly.
bq_flush() {
  local n=${#BQ_NAMES[@]} out="" line i got_n=0
  local re=$'^@@BQ\t([0-9]+)\t(.*)$'
  local -A got_at=()
  if [[ $n -gt 0 ]]; then
    out="$(printf '%s\n' "${BQ_OPS[@]}" | run_with_timeout 900 node -e "$BQ_DRIVER" -- "$WT_NODE" 2>/dev/null)"
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ $re ]]; then
      got_at[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"; got_n=$((got_n + 1))
    else
      fail "bq_flush: unparsed driver output line: $(printf '%q' "$line")"
    fi
  done <<< "$out"
  for ((i = 0; i < n; i++)); do
    [[ -n "${BQ_HDR_AT[$i]:-}" ]] && printf '%s' "${BQ_HDR_AT[$i]}"
    if [[ -v "got_at[$i]" ]]; then
      assert_eq "${BQ_NAMES[$i]}" "${BQ_WANTS[$i]}" "${got_at[$i]}"
    else
      fail "${BQ_NAMES[$i]} — batch driver returned no result for this row"
    fi
  done
  [[ -n "${BQ_HDR_AT[$n]:-}" ]] && printf '%s' "${BQ_HDR_AT[$n]}"
  [[ $got_n -ne $n ]] && fail "bq_flush: driver returned $got_n result lines for $n queued rows"
  [[ $n -eq 0 ]] && fail "bq_flush: no rows queued (vacuous batch)"
  [[ $BQ_TRIED -ne $n ]] && fail "bq_flush: $BQ_TRIED bq_row calls but only $n rows queued"
  BQ_OPS=(); BQ_NAMES=(); BQ_WANTS=(); BQ_TRIED=0; BQ_HDR_AT=()
  return 0
}

# bq_table <op> [fixed-arg...] — queue rows from a `name^cmd^want` table on
# stdin; each row runs <op> [fixed-arg...] <cmd>.
bq_table() {
  local name cmd want
  while IFS='^' read -r name cmd want; do
    [ -z "$name" ] && continue
    bq_row "$name" "$want" "$@" "$cmd"
  done
}

# TMP fixture root (Windows-safe forward-slash path).
mk_tmp_root() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/canary56-$1-XXXXXX")"
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

# setup a main-worktree git repo under $1 (base dir) named $2 → prints node path.
setup_main_checkout() {
  local base="$1" name="$2"
  local repo="$base/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" config core.hooksPath /dev/null
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q --no-verify -m "initial"
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$repo"; else echo "$repo"; fi
}

report_totals() {
  echo ""
  echo "Totals[$(basename "${BASH_SOURCE[1]:-part}")]: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
}
