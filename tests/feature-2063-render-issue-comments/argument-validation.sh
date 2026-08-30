#!/usr/bin/env bash
# tests/feature-2063-render-issue-comments/argument-validation.sh
# Tests: bin/workflow/render-issue-comments, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/phases/write-context.js
# Tags: workflow-init, issue-comments, cli, contract, fail-closed, sentinel-strip, tl2, scope:common

# P8, P23 (#2063, input validation): argument abuse is exit 1 and never exit 3, and the numeric/collection/string boundaries either side of that line.

# TL3 gap: the prompt layer actually invoking this bridge and omitting the prefill
# section on a non-zero rc is not observable here — only a real workflow-init run
# shows that. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# --- P8 (security, input validation): argument rejection is exit 1, not exit 3 --
# Exit 3 means "read fine, no data"; argument abuse must stay distinguishable from
# it. `../../etc/passwd` is the path-traversal probe against --issue (CWE-22).
# rc + empty stdout alone would be satisfied by a node crash: the process dies before
# printing anything and exits 1 too. So the exit-1 path carries the SAME stderr
# discipline the exit-3 tokens do (CPR-ORTH) — one deterministic line, no stack frame,
# and no host path, since the diagnostic is read straight into a session transcript.
healthy_ckpt "$WORK/p8.json" 4008 "$TWO_COMMENTS"
check_p8() {  # <label> <args...>
    local label="$1"; shift
    run_cli "$@"
    assert_rc "P8/$label: exits 1" 1
    assert_out_empty "P8/$label: writes nothing to stdout"
    # With no CLI on disk, run_cli substitutes its own tidy one-line diagnostic, which
    # satisfies every stderr check below without the subject ever having run.
    if [ "$CLI_RC" = "127" ]; then
        fail "P8/$label: the CLI does not exist — its stderr discipline is not observable"
        return
    fi
    assert_err_one_line "P8/$label: stderr is exactly one non-empty line"
    assert_no_stack "P8/$label: no stack frame or TypeError on stderr"
    assert_no_leak "P8/$label: the checkpoint path is not echoed back" "$WORK"
    # `at ` and a `<file>.js:<line>` pair are the two traceback shapes a raw throw
    # leaves behind; assert_no_stack pins the first, this pins the second.
    case "$CLI_ERR" in
        *.js:[0-9]*) fail "P8/$label: a source location leaked onto stderr: '$(printf '%s' "$CLI_ERR" | head -c 200)'" ;;
        *)           pass "P8/$label: no <file>.js:<line> traceback location on stderr" ;;
    esac
    # Deterministic: the same abuse must produce the same line every time, so nothing
    # varying (a pid, a timestamp, a temp path) rides along in the diagnostic.
    local first="$CLI_ERR"
    run_cli "$@"
    assert_eq "P8/$label: the diagnostic is identical on a repeat run" "$first" "$CLI_ERR"
}
# The argv strings live in a table (skills/_shared/test-design/parser-regex-tests.md):
# argument parsing is a parser, and the cases below are one input domain, not seven
# unrelated scenarios. Three placeholders keep the rows literal — a heredoc cannot
# interpolate `$WORK`, and two of the values are whitespace-sensitive:
#   @CKPT@    the readable fixture checkpoint      @MISSING@  a path that does not exist
#   @EMPTY@   an empty-string argument value (a row cannot otherwise carry one)
CKPT_OK="$WORK/p8.json"
CKPT_NONE="$WORK/p8-absent.json"
build_args() {  # <argv-field> — fills the ARGS array, expanding the placeholders
    local tok
    ARGS=()
    for tok in $1; do
        case "$tok" in
            @CKPT@)    ARGS+=("$CKPT_OK") ;;
            @MISSING@) ARGS+=("$CKPT_NONE") ;;
            @EMPTY@)   ARGS+=("") ;;
            *)         ARGS+=("$tok") ;;
        esac
    done
}
while IFS='|' read -r name argv; do
    [[ -z "${name//[[:space:]]/}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    build_args "$argv"
    check_p8 "$name" ${ARGS[@]+"${ARGS[@]}"}
done <<'ARGV_ABUSE'
no-issue              | --checkpoint @CKPT@
no-checkpoint         | --issue 4008
no-arguments          |
non-numeric-issue     | --checkpoint @CKPT@ --issue abc
traversal-issue       | --checkpoint @CKPT@ --issue ../../etc/passwd
flag-shaped-issue     | --checkpoint @CKPT@ --issue -4008
empty-issue           | --checkpoint @CKPT@ --issue @EMPTY@
empty-checkpoint      | --checkpoint @EMPTY@ --issue 4008
unknown-flag          | --checkpoint @CKPT@ --issue 4008 --bogus
# A trailing flag has no value to consume: `argv[++i]` reads past the end, and the
# required-argument check must catch that instead of the CLI reading `undefined`.
issue-missing-value   | --checkpoint @CKPT@ --issue
ckpt-missing-value    | --issue 4008 --checkpoint
# The greedy form of the same bug: --checkpoint swallows the NEXT FLAG as its value,
# leaving `4008` as a stray positional. Either way the run must not be treated as valid.
ckpt-eats-next-flag   | --checkpoint --issue 4008
# Neither a bare positional nor `--` is part of this CLI's grammar (detail.md S5 adopts
# read-merge-base-baseline's rule: anything unrecognized is an immediate error), so the
# terminator must be rejected rather than silently ignored on either side of the flags.
extra-positional      | --checkpoint @CKPT@ --issue 4008 extra
trailing-terminator   | --checkpoint @CKPT@ --issue 4008 --
leading-terminator    | -- --checkpoint @CKPT@ --issue 4008
ARGV_ABUSE
# The inner-newline argument cannot ride in a line-oriented table, so it stays here.
check_p8 "newline-in-issue" --checkpoint "$CKPT_OK" --issue '4008
4008'
# The traversal probe again, on its own: the rejected value must not be echoed back
# either — a diagnostic that quotes `../../etc/passwd` hands the attacker's string to
# whatever reads the transcript, and a CLI that resolved it would say so here.
run_cli --checkpoint "$WORK/p8.json" --issue ../../etc/passwd
if [ "$CLI_RC" = "127" ]; then
    fail "P8/traversal: the CLI does not exist — the echo-back check is not observable"
    fail "P8/traversal: the CLI does not exist — the resolved-path check is not observable"
else
    assert_no_leak "P8/traversal: stderr does not echo the traversal payload" '../../etc/passwd'
    assert_no_leak "P8/traversal: stderr names no resolved /etc path" '/etc/passwd'
fi

# --- P8b (parser semantics): flag order and repeated flags -----------------------
# The rows above pin what is REJECTED; these pin what the parser does with input it
# accepts. Both are undefined behaviour until asserted, and both are what a caller
# assembling the command line from a template actually depends on. Order-independence
# and last-wins come from the parsing convention detail.md S5 adopts wholesale
# (`read-merge-base-baseline`: a `for` scan with `argv[++i]`, so a repeated flag
# overwrites the earlier value rather than erroring).
# Each duplicate case is asserted from BOTH directions with values whose outcomes
# differ: if the parser silently took the FIRST occurrence, the pair would swap rcs
# instead of both passing, so neither row can be satisfied by accident.
check_p8b() {  # <name> <want-rc> <args...>
    local name="$1" want="$2"; shift 2
    run_cli "$@"
    if [ "$CLI_RC" = "127" ]; then
        fail "P8b/$name: the CLI does not exist — its argv semantics are not observable"
        return
    fi
    assert_rc "P8b/$name: exits $want" "$want"
    if [ "$want" = "0" ]; then
        assert_out_has "P8b/$name: renders the cached issue's comment" '> first remark'
    else
        assert_out_empty "P8b/$name: writes nothing to stdout"
        assert_no_stack "P8b/$name: no stack frame on stderr"
    fi
}
while IFS='|' read -r name argv want; do
    [[ -z "${name//[[:space:]]/}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    build_args "$argv"
    check_p8b "$name" "$want" ${ARGS[@]+"${ARGS[@]}"}
done <<'ARGV_SEMANTICS'
# 4008 is the cached issue; 9999 is shape-valid but absent from the cache (exit 3),
# and @MISSING@ is an unreadable checkpoint path (exit 3).
canonical-order        | --checkpoint @CKPT@ --issue 4008              | 0
reversed-order         | --issue 4008 --checkpoint @CKPT@              | 0
dup-issue-last-cached  | --checkpoint @CKPT@ --issue 9999 --issue 4008 | 0
dup-issue-last-absent  | --checkpoint @CKPT@ --issue 4008 --issue 9999 | 3
dup-ckpt-last-readable | --checkpoint @MISSING@ --checkpoint @CKPT@ --issue 4008 | 0
dup-ckpt-last-absent   | --checkpoint @CKPT@ --checkpoint @MISSING@ --issue 4008 | 3
ARGV_SEMANTICS


# --- P23 (C9, boundaries): numeric argument edges, then collection/string edges ---
# `--issue` is validated by shape (/^\d+$/), so the boundary is between "shape-valid,
# just not cached" (exit 3) and "shape-invalid" (exit 1). Collapsing the two would hide
# a malformed argument behind a data-shaped failure.
healthy_ckpt "$WORK/p23.json" 4025 "$TWO_COMMENTS"
check_arg_rc() {  # <label> <issue-arg> <want-rc>
    run_cli --checkpoint "$WORK/p23.json" --issue "$2"
    assert_rc "P23/$1: --issue '$2' exits $3" "$3"
    assert_out_empty "P23/$1: --issue '$2' writes nothing to stdout"
}
check_arg_rc "zero"             0                     3
check_arg_rc "one"              1                     3
check_arg_rc "max safe integer" 9007199254740991      3
check_arg_rc "one above max"    9007199254740992      3
check_arg_rc "far above max"    99999999999999999999  3
check_arg_rc "leading zeros"    007                   3
check_arg_rc "decimal"          1.5                   1
check_arg_rc "exponent"         1e3                   1
check_arg_rc "signed"           +5                    1
check_arg_rc "trailing space"   '4025 '               1
check_arg_rc "inner newline"    '4025
4025'                                                 1
check_arg_rc "hex"              0x10                  1
check_arg_rc "empty string"     ''                    1
# Zero is a legal JSON key, so a cached "0" must render rather than be swallowed by a
# falsy-number check on the issue argument.
healthy_ckpt "$WORK/p23-zero.json" 0 "$TWO_COMMENTS"
run_cli --checkpoint "$WORK/p23-zero.json" --issue 0
assert_rc "P23: a cached issue #0 renders (no falsy-number swallow)" 0
assert_out_has "P23: issue #0 renders its comment" '> first remark'

DUP='[{"author":{"login":"alice"},"body":"same text","createdAt":"2026-07-02T00:00:00Z"},{"author":{"login":"alice"},"body":"same text","createdAt":"2026-07-02T00:00:00Z"}]'
healthy_ckpt "$WORK/p23-dup.json" 4026 "$DUP"
run_cli --checkpoint "$WORK/p23-dup.json" --issue 4026
assert_rc "P23: duplicate comments exit 0" 0
out_to_file "$WORK/p23-dup.out"
assert_count_re "P23: two identical comments render as two numbered entries" "$WORK/p23-dup.out" '^### Comment [12] — alice ' 2
assert_count_re "P23: neither duplicate is deduplicated away" "$WORK/p23-dup.out" '^> same text$' 2

EMPTY_META='[{"author":{"login":""},"body":"body with empty login","createdAt":""}]'
healthy_ckpt "$WORK/p23-meta.json" 4027 "$EMPTY_META"
run_cli --checkpoint "$WORK/p23-meta.json" --issue 4027
assert_rc "P23: empty metadata strings exit 0" 0
assert_out_has "P23: an empty login falls back to (unknown), not a blank gap" '### Comment 1 — (unknown) ((unknown))'
assert_out_has "P23: an empty-metadata comment keeps its body" '> body with empty login'

# A long body and a large array are the two shapes that expose an accidental truncation
# or a reordering: order and count are asserted, not just presence.
node -e '
const fs = require("fs");
const long = "L".repeat(20000);
const many = [];
for (let i = 1; i <= 200; i++) many.push({ author: { login: "u" + i }, body: "entry " + i, createdAt: "2026-07-01T00:00:00Z" });
const mk = (n, comments) => ({ version: 3, session_id: "ric", state: { issues: [n], issue_json_cache: { [n]: { number: n, title: "t", body: "b", labels: [], state: "OPEN", createdAt: "2026-07-01T00:00:00Z", comments } } } });
fs.writeFileSync(process.argv[1], JSON.stringify(mk(4028, [{ author: { login: "alice" }, body: long + "\nsecond line " + long, createdAt: "2026-07-02T00:00:00Z" }])));
fs.writeFileSync(process.argv[2], JSON.stringify(mk(4029, many)));
' "$WORK/p23-long.json" "$WORK/p23-many.json"
run_cli --checkpoint "$WORK/p23-long.json" --issue 4028
assert_rc "P23: a 40k-character body exits 0" 0
out_to_file "$WORK/p23-long.out"
# Asserted on exact line lengths: a truncation that kept the leading `> L…` prefix would
# still match any substring check, and losing 19k characters is the failure that matters.
P23_LONG="$(node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
const a = lines.find((l) => l === "> " + "L".repeat(20000));
const b = lines.find((l) => l === "> second line " + "L".repeat(20000));
process.stdout.write((a ? "1" : "0") + (b ? "1" : "0"));
' "$WORK/p23-long.out" 2>/dev/null || printf 'ERR')"
assert_eq "P23: both 20k-character lines survive quoting at full length" "11" "$P23_LONG"
run_cli --checkpoint "$WORK/p23-many.json" --issue 4029
assert_rc "P23: a 200-element comment array exits 0" 0
out_to_file "$WORK/p23-many.out"
assert_count_re "P23: all 200 comments are rendered" "$WORK/p23-many.out" '^### Comment [0-9]+ — ' 200
assert_count_re "P23: the first entry keeps position 1" "$WORK/p23-many.out" '^### Comment 1 — u1 ' 1
assert_count_re "P23: the last entry keeps position 200" "$WORK/p23-many.out" '^### Comment 200 — u200 ' 1
P23_ORDER="$(grep -oE '^> entry [0-9]+' "$WORK/p23-many.out" | sed 's/^> entry //' | tr '\n' ',')"
P23_WANT="$(node -e 'let a=[];for(let i=1;i<=200;i++)a.push(i);process.stdout.write(a.join(",")+",")')"
assert_eq "P23: every entry is preserved in input order" "$P23_WANT" "$P23_ORDER"


finish
