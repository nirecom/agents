#!/bin/bash
# tests/feature-2121-heredoc-strip-widening.sh
# Tests: hooks/lib/strip-quoted-args.js
# Tags: heredoc, strip-quoted-args, parser, regex, write-detector, enforce-worktree, TL1, pwsh-not-required, scope:issue-specific, dup-group-keep:distinct-layer
#
# #2121 — stripHeredocBody()'s regex requires a literal `cat` before the opener and
# a \w+ delimiter, so `tee out <<'EOF'` and `<<'EOF-1.2'` bodies are never stripped
# and their body text is misread as shell sequencing. This file is the table-driven
# unit layer for that regex; tests/feature-2120-...sh carries the seam-level cases.

set -u

# THE ONE CONSTRAINT THE WIDENING MUST KEEP (see also feature-2120 Section M7):
# an INTERPRETER heredoc EXECUTES its body. A quoted delimiter stops the SHELL
# expanding the body — it does nothing to stop bash/python from running it, and
# callers (bash-write-targets.js isNewlineInjectedWriteIR, nested-commands.js
# normalizeToLines) strip BEFORE hunting the body for writes. So the fix must drop
# the cat-ONLY restriction while still refusing interpreter-prefixed openers.
# Section H3 is the executable form of that constraint.

# TL3 gap: a live bash/dash/zsh parse of nested/escaped delimiters is out of
# scope here. Closest-to-action mitigation: the seam-level write-visibility
# consequence is covered by tests/feature-2120-...-heredoc.sh Section M7.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then AN="$(cygpath -m "$AGENTS_DIR")"; else AN="$AGENTS_DIR"; fi
SQA="$AN/hooks/lib/strip-quoted-args.js"

SUITE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-2121-heredoc-strip-widening"

# Entrypoint only (rules/coding/file-split.md Pattern A): frontmatter, the source
# path under test, and the run order. The harness comes first (tallies, the H0
# availability guards that abort the suite, and the node probes), then the case
# files. All of them live in the sibling folder.
# shellcheck source=./feature-2121-heredoc-strip-widening/helpers.sh
. "$SUITE_DIR/helpers.sh"

# shellcheck source=./feature-2121-heredoc-strip-widening/cases-matcher.sh
. "$SUITE_DIR/cases-matcher.sh"
# shellcheck source=./feature-2121-heredoc-strip-widening/cases-interpreter.sh
. "$SUITE_DIR/cases-interpreter.sh"
# shellcheck source=./feature-2121-heredoc-strip-widening/cases-robustness.sh
. "$SUITE_DIR/cases-robustness.sh"
# shellcheck source=./feature-2121-heredoc-strip-widening/cases-opener-line.sh
. "$SUITE_DIR/cases-opener-line.sh"
# shellcheck source=./feature-2121-heredoc-strip-widening/cases-sink-list.sh
. "$SUITE_DIR/cases-sink-list.sh"
# shellcheck source=./feature-2121-heredoc-strip-widening/cases-substitution-capture.sh
. "$SUITE_DIR/cases-substitution-capture.sh"
# shellcheck source=./feature-2121-heredoc-strip-widening/cases-line-continuation.sh
. "$SUITE_DIR/cases-line-continuation.sh"

run_H1; run_H2; run_H3; run_H4; run_H5; run_H6; run_H7; run_H8; run_H9; run_H10; run_H11
run_H12

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
