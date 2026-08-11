# shellcheck shell=bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, instructions-loaded, path-identity, normalization, cross-root, TL2, scope:common
#
# The TL3 gate runs the SAME fixture twice from two DIFFERENT roots (base/ and judge/)
# and then compares the two receipt sets: the Q1 completeness barrier asks whether
# every path observed in RUN-BASE also appeared in RUN-JUDGE. That comparison is only
# meaningful if a rule's recorded identity is independent of the root it was loaded
# from. If the receipt stored the absolute path, EXPECTED_SET and the judge set would
# be disjoint by construction: Q1 could never be satisfied, the gate would report
# INCONCLUSIVE forever, or — worse, if only the target were compared by basename —
# absence would be "proven" against a set that never had a chance to match.
#
# CONTRACT NOTE (asserted here):
#   - The receipt's file_path is REPO-RELATIVE and POSIX-separated: no drive letter,
#     no leading slash, no backslash, no ../ segment.
#   - Cross-run identity is carried by the RECORDED file_path, not by the entry
#     filename. The key stays sha1(file_path as received) so a receipt remains
#     addressable from the payload alone, without re-deriving the project root.
#   - A path outside the project root has no repo-relative form; it must still be
#     recorded deterministically and identically for the same input, never crash.

echo ""
echo "=== path identity: the same rule from two different roots ==="

# A second project root holding the same relative rule. This is the base/ vs judge/
# split of the TL3 gate, reproduced without spawning claude.
REPO2="$BASE/repo2"
mkdir -p "$REPO2/rules"
git -C "$REPO2" init -q
git -C "$REPO2" config core.hooksPath /dev/null
printf '# same relative rule, different root\n' > "$REPO/rules/pathid.md"
printf '# same relative rule, different root\n' > "$REPO2/rules/pathid.md"

# fire_in <project_dir> <session_id> <abs_file_path> -> prints "<rc>"
fire_in() {
    local pd="$1" sid="$2" fp="$3" payload rc=0
    payload="$(node -e 'console.log(JSON.stringify({session_id:process.argv[1],file_path:process.argv[2],hook_event_name:"InstructionsLoaded"}))' "$sid" "$fp")"
    printf '%s' "$payload" \
        | (cd "$BASE" && CLAUDE_PROJECT_DIR="$(node_path "$pd")" node "$(node_path "$HOOK")" >/dev/null 2>/dev/null) || rc=$?
    echo "$rc"
}

# entry_of <sid> -> prints "<entry-filename>|<recorded file_path>" for the single entry
entry_of() {
    node -e "
const fs=require('fs'), path=require('path');
const dir=path.join(process.argv[1], process.argv[2] + '.instructions-loaded');
let names=[];
try { names=fs.readdirSync(dir).filter((n)=>n.endsWith('.json')); } catch (_) {}
if (names.length !== 1) { console.log('COUNT:' + names.length + '|-'); process.exit(0); }
let fp='-';
try { fp=String(JSON.parse(fs.readFileSync(path.join(dir,names[0]),'utf8')).file_path); } catch (_) { fp='UNPARSEABLE'; }
console.log(names[0] + '|' + fp);
" "$(node_path "$WFDIR")" "$2" 2>/dev/null || echo "ERR|-"
}

PID_BASE_SID="pathidbase"
PID_JUDGE_SID="pathidjudge"
pid_rc1="$(fire_in "$REPO" "$PID_BASE_SID" "$(node_path "$REPO/rules/pathid.md")")"
pid_rc2="$(fire_in "$REPO2" "$PID_JUDGE_SID" "$(node_path "$REPO2/rules/pathid.md")")"

PID_A="$(entry_of "$WFDIR" "$PID_BASE_SID")"
PID_B="$(entry_of "$WFDIR" "$PID_JUDGE_SID")"
KEY_A="${PID_A%%|*}"; FP_A="${PID_A#*|}"
KEY_B="${PID_B%%|*}"; FP_B="${PID_B#*|}"

# --- N1: both firings succeeded and produced exactly one entry each ---
if [ "$pid_rc1" = "0" ] && [ "$pid_rc2" = "0" ] \
   && [ "${KEY_A#COUNT:}" = "$KEY_A" ] && [ "${KEY_B#COUNT:}" = "$KEY_B" ]; then
    pass "N1: the same rule loaded from two roots produced one receipt each"
else
    fail "N1: want one receipt per root (rc $pid_rc1/$pid_rc2), got A=[$PID_A] B=[$PID_B]"
fi

# --- N2: the recorded file_path is identical across the two roots. This is the
# assertion the Q1 barrier rests on; without it EXPECTED_SET and the judge set can
# never intersect. ---
if [ "$FP_A" = "$FP_B" ] && [ "$FP_A" != "-" ] && [ "$FP_A" != "UNPARSEABLE" ]; then
    pass "N2: file_path normalizes to the same value from both roots ($FP_A)"
else
    fail "N2: file_path differs across roots — base='$FP_A' judge='$FP_B'"
fi

# --- N3: that value is repo-relative and POSIX-separated. An absolute or
# backslash-separated value would compare equal only by accident of layout. ---
if [ "$FP_A" = "rules/pathid.md" ]; then
    pass "N3: file_path is the repo-relative POSIX path (rules/pathid.md)"
else
    fail "N3: want file_path 'rules/pathid.md', got '$FP_A'"
fi

# --- N4: no receipt carries a root-dependent path shape. Checked over every receipt
# written so far (the verdict and frontmatter groups run before this file), not just
# this pair, so one normalized call site cannot hide an unnormalized sibling. The
# deliberately hostile and out-of-root inputs are introduced only AFTER this scan —
# they have no repo-relative form and are governed by N6 and the security group. ---
BAD_SHAPES="$(node -e "
const fs=require('fs'), path=require('path');
const root=process.argv[1];
const bad=[];
let dirs=[];
try { dirs=fs.readdirSync(root).filter((n)=>n.endsWith('.instructions-loaded')); } catch (_) {}
for (const d of dirs) {
  let names=[];
  try { names=fs.readdirSync(path.join(root,d)); } catch (_) { continue; }
  for (const n of names) {
    let fp;
    try { fp=JSON.parse(fs.readFileSync(path.join(root,d,n),'utf8')).file_path; } catch (_) { continue; }
    if (typeof fp !== 'string' || fp === '') continue;
    if (/^[A-Za-z]:/.test(fp) || fp.startsWith('/') || fp.includes('\\\\') || fp.includes('../')) {
      bad.push(d + '/' + n + ' -> ' + fp);
    }
  }
}
console.log(bad.slice(0, 5).join(' ; '));
" "$(node_path "$WFDIR")" 2>&1)"
if [ -z "${BAD_SHAPES// /}" ]; then
    pass "N4: no receipt records a drive letter, absolute path, backslash, or ../ segment"
else
    fail "N4: root-dependent path shapes recorded — $BAD_SHAPES"
fi

# --- N5: the entry filename stays sha1(file_path AS RECEIVED). Cross-run identity is
# the recorded file_path (N2/N3); the key is an addressing detail, and keeping it on
# the received value means a receipt can be located from the payload alone, without
# re-deriving which project root was active. Pinning it prevents a "fix" that
# normalizes the key and silently breaks every payload-addressed lookup. ---
WANT_KEY_A="$(sha1_of "$(node_path "$REPO/rules/pathid.md")").json"
WANT_KEY_B="$(sha1_of "$(node_path "$REPO2/rules/pathid.md")").json"
if [ "$KEY_A" = "$WANT_KEY_A" ] && [ "$KEY_B" = "$WANT_KEY_B" ]; then
    pass "N5: the entry filename is sha1(file_path as received) in both roots"
else
    fail "N5: want keys $WANT_KEY_A / $WANT_KEY_B, got $KEY_A / $KEY_B"
fi

# --- N6: a file OUTSIDE the project root has no repo-relative form. It must still be
# recorded deterministically (same input -> same key), and must not crash or escape. ---
OUT_RULE="$BASE/outside-root.md"
printf '# outside every project root\n' > "$OUT_RULE"
n6_rc1="$(fire_in "$REPO" "pathidout1" "$(node_path "$OUT_RULE")")"
n6_rc2="$(fire_in "$REPO" "pathidout2" "$(node_path "$OUT_RULE")")"
N6_A="$(entry_of "$WFDIR" pathidout1)"
N6_B="$(entry_of "$WFDIR" pathidout2)"
if [ "$n6_rc1" != "0" ] || [ "$n6_rc2" != "0" ]; then
    fail "N6: an out-of-root file must fail open, got rc $n6_rc1/$n6_rc2"
elif [ "${N6_A%%|*}" != "${N6_B%%|*}" ] || [ "${N6_A#*|}" != "${N6_B#*|}" ]; then
    fail "N6: an out-of-root file was recorded non-deterministically — [$N6_A] vs [$N6_B]"
else
    pass "N6: an out-of-root file is recorded deterministically (${N6_A#*|})"
fi
