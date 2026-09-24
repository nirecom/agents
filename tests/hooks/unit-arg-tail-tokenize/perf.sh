# tests/unit-arg-tail-tokenize/perf.sh
# Tests: hooks/enforce-worktree/arg-tail-guard.js
# Tags: hook, worktree, enforce, arg-tail, unit, security, performance, scope:common
#
# Sourced by tests/unit-arg-tail-tokenize.sh. Section 10: the cost ceiling for
# tokenizeArgTail.
#
# Why a perf row belongs in a SECURITY suite: tokenizeArgTail runs inside the
# enforce-worktree PreToolUse hook, on the hook's critical path, over an arg
# tail an untrusted command line supplies. A quadratic tokenizer is therefore a
# denial-of-service surface on the guard itself, not a tuning nicety — a large
# but perfectly legal-looking arg tail stalls every Bash tool call.
#
# Measurement lives inside the node probe (process.hrtime.bigint) so neither
# node startup nor bash quoting of a 128 KB fixture is charged to the number.

run_tokenize_perf_cases() {

# ============================================================================
# 10. Cost ceiling.
#
# Because: the current tokenizer resolves each character's quote owner by
# walking the WHOLE span list, once per character — cost grows with
# (length x spans), i.e. quadratically in the length of an input whose span
# count grows with its length. Measured on the tree under test: 8 KB ~ 25 ms,
# 64 KB ~ 1.6 s, 128 KB ~ 7.4 s. That is the 8x-input / 64x-time signature of
# an O(n^2) scan; a linear tokenizer finishes all three in single-digit ms.
#
# Two rows, deliberately:
#   ATP-perf-64k   is the contract ceiling (2 s for a 64 KB tail). It is
#                  MARGINAL on the tree under test (~1.6 s) and would flake on
#                  a slower host — that marginality is itself the finding, and
#                  the row becomes decisive-green (single-digit ms) once the
#                  scan is linear.
#   ATP-perf-128k  is the unambiguous pin: ~7.4 s today against the same 2 s
#                  ceiling, far outside any plausible machine-speed spread.
#
# Non-vacuity: "fast" is printed only when the tail ALSO parsed (ok:true) and
# produced exactly one token per unit, so a tokenizer that got quick by
# failing closed or by mis-splitting words cannot pass either row. The 8 KB
# row is the paired control — an implementation slow enough to blow the
# ceiling on a small input fails it while the two large rows would still be
# "explained away" by a slow host.
# ============================================================================
run_table <<'TABLE'
ATP-perf-8k%8192%bench%2000%fast
ATP-perf-64k%65536%bench%2000%fast
ATP-perf-128k%131072%bench%2000%fast
TABLE
}
