# tests/unit-quote-spans/deep-recursion.sh
# Tests: hooks/lib/quote-spans/transform.js, hooks/lib/strip-quoted-args.js
# Tags: hook, quote-spans, parser, unit, security, robustness, scope:common
#
# Sourced by tests/unit-quote-spans.sh. Section: deeply NESTED input.
#
# Defect: renderSpan and renderList are mutually recursive, one JS stack frame
# per nesting level, with no depth cap. A command carrying enough nested `$(`
# frames therefore raises RangeError out of blankQuoteSpans — and
# stripQuotedArgs, the wrapper hooks/enforce-worktree.js calls, has no try/catch
# of its own, so the exception escapes the PreToolUse hook entirely. A hook that
# dies is not a hook that blocks: the failure is fail-OPEN, and it is reachable
# from any single Bash command, since the payload is just a long string.
#
# Measured on the tree under test: the throw appears between depth 4000 and
# 6000. The exact threshold is a property of the machine's stack, not of the
# code, so the rows below sit far above it (20000) and the shallow control far
# below (100) — no row is pinned near the cliff.
#
# TL3 gap (what this TL1 test does NOT catch): the same input arriving as a real
# Claude Code Bash payload, where the crash surfaces as a non-zero hook exit
# rather than as a thrown Error. It is not driven at the hook boundary here
# because the fixture is ~60 KB, past the Windows 32 KB command-line limit.

run_deep_recursion_cases() {

# ============================================================================
# Nested-input robustness.
#
# The probe builds `echo "$($(...$(rm -f README.md)...))"` from a depth number
# and reports one of three outcome classes:
#
#   safe      — nothing was thrown AND the surviving text is on the danger
#               side: either the transform fail-closed (ok:false, or output
#               identical to input, so a later reader still sees the write) or
#               it rendered the write out into the open.
#   threw:X   — an exception escaped the transform. This is the defect.
#   hidden    — a clean, confident result that dropped the write. Never allowed.
#
# Both acceptable fixes (an iterative renderer, or an explicit depth cap that
# fails closed) land on "safe"; only the current unbounded recursion does not.
# ============================================================================
run_table <<'TABLE'
DEEP-scan-20000    |20000|deepsafe|scan   |safe
DEEP-blank-20000   |20000|deepsafe|blank  |safe
DEEP-unwrap-20000  |20000|deepsafe|unwrap |safe
DEEP-fold-20000    |20000|deepsafe|fold   |safe
DEEP-strip-20000   |20000|deepsafe|strip  |safe
DEEP-stripdq-20000 |20000|deepsafe|stripdq|safe
TABLE

# Shallow control: the same six transforms on the same shape, 200x smaller.
# These are green today, so a fix that made the deep rows pass by weakening the
# transforms shows up here immediately.
run_table <<'TABLE'
DEEP-scan-100    |100|deepsafe|scan   |safe
DEEP-blank-100   |100|deepsafe|blank  |safe
DEEP-unwrap-100  |100|deepsafe|unwrap |safe
DEEP-fold-100    |100|deepsafe|fold   |safe
DEEP-strip-100   |100|deepsafe|strip  |safe
DEEP-stripdq-100 |100|deepsafe|stripdq|safe
TABLE

# UNBALANCED deep input is the paired non-pin: `$(`x20000 with no closers makes
# the SCAN fail first, every renderer returns early, and no recursion happens at
# all. It is green today and proves the deep rows above are about the renderer,
# not about length.
run_table <<'TABLE'
DEEP-unbalanced-blank|20000|deepsafe|blank unbalanced|safe
DEEP-unbalanced-strip|20000|deepsafe|strip unbalanced|safe
TABLE

# Exactness pair for the verdict op: "safe" must still be backed by a real
# transform. At depth 2 the rendered bytes are pinned literally — quote span
# blanked, both substitution wrappers turned into spaces, the inner command
# left standing — so "always answer safe" and "stop transforming" both fail.
run_table <<'TABLE'
DEEP-render-blank-2 |2|deeprender|blank  |"echo \"\"   rm -f README.md   "
DEEP-render-unwrap-2|2|deeprender|unwrap |"echo \"\"   rm -f README.md   "
DEEP-render-strip-2 |2|deeprender|strip  |"echo \"\"   rm -f README.md   "
TABLE
}
