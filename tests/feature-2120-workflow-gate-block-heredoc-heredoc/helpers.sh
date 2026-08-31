# Tests: hooks/enforce-worktree.js, hooks/workflow-gate/early-gate-messages.js, hooks/lib/alt-target-remedy.js
# Tags: workflow-gate, enforce-worktree, heredoc, block-message, helpers, scope:issue-specific
# Shared harness: tallies, hook-output decoders, payload builders and the #2120
# remedy-wording contract. Sourced by
# feature-2120-workflow-gate-block-heredoc-heredoc.sh before any case file.
# No cases here — the assertions that pin verdict_of() itself live in
# cases-verdict-helper.sh (M13).

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Pure-bash substring matching, not `printf | grep -q`: grep -q exits on first
# hit and SIGPIPEs printf, which prints an "Aborted" job line per assertion and
# buries the real results. No subshell, no pipe, no exit-status coupling.
has()   { case "$3" in (*"$2"*) pass "$1";; (*) fail "$1 -- missing [$2] in: $3";; esac; }
lacks() { case "$3" in (*"$2"*) fail "$1 -- unexpected [$2] in: $3";; (*) pass "$1";; esac; }
has_i() { local h="${3,,}" n="${2,,}"; case "$h" in (*"$n"*) pass "$1";; (*) fail "$1 -- missing [$2] in: $3";; esac; }

# alt_target_wording <label> <reason> — the #2120 remedy contract, one call per site.
# C4 (test-review round 1): the two has_i calls below only prove the NOUNS "plans"
# and "scratchpad" occur -- a reason that says "these targets are forbidden too"
# would pass them trivially. Strengthened per the approved detail plan
# (c37ddc25 intent.md Change #3: model pattern is the existing
# enforce-worktree.js:216-222 remedy, "use Edit/Write tools or set
# ENFORCE_WORKTREE=off") to also require an actionable write-tool name next to
# the target nouns, and to reject a prohibition verb paired with either noun.
alt_target_wording() {
    local label="$1" reason="$2"
    has_i "$label: names the plans dir as an alternative write target" "plans" "$reason"
    has_i "$label: names the scratchpad as an alternative write target" "scratchpad" "$reason"
    # Affirmative/actionable guard: the agent must be told WHICH tool reaches the
    # target, not just that the target exists -- "these targets are forbidden
    # too" names no tool and would fail this check where it wrongly passed the
    # two has_i calls above.
    case "$reason" in
        (*Write*|*Edit*|*MultiEdit*)
            pass "$label: names a write-capable tool (Write/Edit/MultiEdit) alongside the target" ;;
        (*)
            fail "$label: wording lacks a write-capable tool name -- reads as description, not remedy: $reason" ;;
    esac
    # Negative-framing guard: reject the exact adversarial shape from the review
    # ("plans"/"scratchpad" paired with a prohibition verb instead of a remedy).
    local lc="${reason,,}"
    if [[ "$lc" == *"plans"*"forbidden"* || "$lc" == *"scratchpad"*"forbidden"* \
       || "$lc" == *"plans"*"not allowed"* || "$lc" == *"scratchpad"*"not allowed"* \
       || "$lc" == *"plans"*"disallowed"* || "$lc" == *"scratchpad"*"disallowed"* ]]; then
        fail "$label: plans/scratchpad wording reads as a prohibition, not a remedy: $reason"
    else
        pass "$label: plans/scratchpad wording is not phrased as a prohibition"
    fi
}

# reason_of <hook stdout> → decoded `reason` (empty when absent)
reason_of() {
    printf '%s' "$1" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  const lines=d.trim().split("\n").filter(Boolean);
  for(let i=lines.length-1;i>=0;i--){try{const j=JSON.parse(lines[i]);if(j&&typeof j.reason==="string"){process.stdout.write(j.reason);return;}}catch(e){}}
});'
}
is_block() { printf '%s' "$1" | grep -qF '"decision":"block"'; }

ew_run() {
    local cwd="$1" payload="$2"
    printf '%s' "$payload" | ( cd "$cwd" || exit 1; MSYS_NO_PATHCONV=1 run_with_timeout 60 node "$EW_HOOK" 2>/dev/null )
}
bash_payload() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},session_id:process.argv[2]}))' -- "$1" "$SID"; }
edit_payload() { node -e 'process.stdout.write(JSON.stringify({tool_name:process.argv[3],tool_input:{file_path:process.argv[1],content:"x"},session_id:process.argv[2]}))' -- "$1" "$SID" "${2:-Write}"; }

# multiedit_payload <top_file_path_or_empty> [edit_path ...] — builds a genuine
# MultiEdit/batch tool_input with a real `edits[]` array (C1), so the
# handle-edit-write.js batch branch (Array.isArray(toolInput.edits) &&
# toolInput.edits.length > 0) is actually reached, not just the single-path
# fall-through. With no edit_path args, mirrors the REAL MultiEdit shape (the
# path lives only at the top level; edits[] entries carry old_string/new_string
# but no path of their own). With edit_path args, mirrors the generic batch
# shape collectEditWritePaths also supports: each edits[] entry names its own
# path, additive with the top-level one.
multiedit_payload() {
    node -e '
const argv = process.argv.slice(1);
const top = argv[0];
const sid = argv[1];
const editPaths = argv.slice(2);
const ti = {};
if (top) ti.file_path = top;
ti.edits = editPaths.length
    ? editPaths.map((p) => ({ file_path: p, old_string: "a", new_string: "b" }))
    : [{ old_string: "a", new_string: "b" }];
process.stdout.write(JSON.stringify({ tool_name: "MultiEdit", tool_input: ti, session_id: sid }));
' -- "$1" "$SID" "${@:2}"
}

# verdict_of <hook stdout> → "block" | "allow" | "unknown-decision:<v>" | "non-canonical:<keys>" | "non-object" | "unparseable"
# enforce-worktree.js done() (hooks/enforce-worktree.js:52-68) prints exactly ONE
# JSON object: {"decision":"block","reason":...} to block, and the CANONICAL EMPTY
# OBJECT {} to allow — nothing else. C5 (round 3): the previous mapping credited
# EVERY non-"block" object as an allow, so an error object, a `{"decision":"allow"}`
# typo, or any future non-canonical shape scored as a passing allow. Only `{}` is
# an allow now; every other shape gets its own distinguishable verdict so
# assert_allowed/assert_blocked fail loudly instead of silently crediting it.
verdict_of() {
    printf '%s' "$1" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  const lines=d.trim().split("\n").filter(Boolean);
  for(let i=lines.length-1;i>=0;i--){
    let j; try { j=JSON.parse(lines[i]); } catch(e) { continue; }
    if (!j || typeof j !== "object") continue;
    if (Array.isArray(j)) { process.stdout.write("non-object"); return; }
    if (j.decision === "block") { process.stdout.write("block"); return; }
    if (Object.prototype.hasOwnProperty.call(j, "decision")) {
      process.stdout.write("unknown-decision:" + String(j.decision)); return;
    }
    const keys = Object.keys(j);
    if (keys.length === 0) { process.stdout.write("allow"); return; }
    process.stdout.write("non-canonical:" + keys.join(",")); return;
  }
  process.stdout.write("unparseable");
});'
}

# assert_allowed <label> <cwd> <payload> — the FALSE-GREEN GUARD (C7, test-review
# round 2). `if is_block "$out"; then fail; else pass` treats absence-of-block as
# an allow, so a hook crash, a run_with_timeout kill (exit 124), or empty stdout
# would silently score as "allowed" — the exact false-green rules/test.md forbids.
# An allow is only credited when the hook exited 0 AND emitted a parseable JSON
# object AND that object is not a block.
assert_allowed() {
    local label="$1" cwd="$2" payload="$3" out st verdict
    out="$(ew_run "$cwd" "$payload")"; st=$?
    if [ "$st" -ne 0 ]; then
        fail "$label: hook exited non-zero ($st) — crash/timeout, not an allow"; return
    fi
    if [ -z "$out" ]; then
        fail "$label: hook produced EMPTY stdout — no verdict was emitted, not an allow"; return
    fi
    verdict="$(verdict_of "$out")"
    case "$verdict" in
        (allow) pass "$label" ;;
        (block) fail "$label: expected allow, got block: $out" ;;
        (*)     fail "$label: hook stdout is not a parseable JSON verdict: $out" ;;
    esac
}

# assert_blocked <label> <cwd> <payload> [needle] — sibling of assert_allowed.
# A block is only credited when the hook emitted a real block verdict; a crash or
# empty stdout fails loudly instead of counting as "well, it didn't allow it".
assert_blocked() {
    local label="$1" cwd="$2" payload="$3" needle="${4:-}" out
    out="$(ew_run "$cwd" "$payload")"
    if [ -z "$out" ]; then fail "$label: hook produced EMPTY stdout — no verdict, not a block"; return; fi
    case "$(verdict_of "$out")" in
        (block) pass "$label" ;;
        (allow) fail "$label: expected block, got allow: $out"; return ;;
        (*)     fail "$label: hook stdout is not a parseable JSON verdict: $out"; return ;;
    esac
    [ -n "$needle" ] && has "$label: reason names the expected diagnosis" "$needle" "$(reason_of "$out")"
}

# hd <target> [payload-body] — a `cat`-sink heredoc writing to <target>, with real
# newlines. The body carries `;` on purpose: it is exactly the body-internal
# operator that used to be misread as command sequencing (#2121).
hd() { printf '%b' "cat <<'EOF' > $1\nfoo; bar\nEOF\n"; }
