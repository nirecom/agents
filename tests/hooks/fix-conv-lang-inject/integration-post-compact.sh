# integration-post-compact.sh — T12, T13, T15, T16, T17, T19, T20: Integration tests for hooks/post-compact.js
# Tests: hooks/post-compact.js, hooks/lib/conv-lang.js, hooks/session-start.js
# Tags: conv-lang, post-compact, scope:common
# Sourced after helpers.sh; inherits all variables and functions.
#
# Split per rules/coding/file-split.md Pattern A (>500 lines): this file is now
# the fragment entrypoint and owns only the source order. The cases execute at
# source time, so this order IS the execution order — it matches the pre-split
# file exactly. ${BASH_SOURCE[0]} inside a sourced file is THIS file, so the
# sub-fragment dir resolves next to it, not next to the grandparent entrypoint.

PC_FRAGMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/integration-post-compact"
# shellcheck source=tests/fix-conv-lang-inject/integration-post-compact/conv-lang-cases.sh
. "$PC_FRAGMENT_DIR/conv-lang-cases.sh"
# shellcheck source=tests/fix-conv-lang-inject/integration-post-compact/progress-helpers.sh
. "$PC_FRAGMENT_DIR/progress-helpers.sh"
# shellcheck source=tests/fix-conv-lang-inject/integration-post-compact/progress-summary-cases.sh
. "$PC_FRAGMENT_DIR/progress-summary-cases.sh"
# shellcheck source=tests/fix-conv-lang-inject/integration-post-compact/resume-hint-cases.sh
. "$PC_FRAGMENT_DIR/resume-hint-cases.sh"
