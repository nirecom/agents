# --dup-groups keys each file on its own registry header.commentPrefix (#2500)
# Tests: bin/lib/test-dup-group.sh, bin/audit-tests.sh
# Tags: TL2, audit-tests, dup-groups, frontmatter, scope:issue-specific
# Sourced by tests/bin/feature-2065-dup-group-inventory.sh
# A fixture checkout whose table adds slash-lang (*.slt, "//", with a case-marker
# reader so the corpus scan includes it). A line in the other language's prefix is
# a decoy: it must neither form a group nor split one.

# shellcheck source=../../lib/harness.sh
if ! declare -f case_begin >/dev/null 2>&1; then
  AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  source "$AGENTS_ROOT/tests/lib/harness.sh"
fi
# shellcheck source=../test-language-registry/slash-header-fixture.sh
. "$AGENTS_ROOT/tests/bin/test-language-registry/slash-header-fixture.sh"

case_begin "comment-prefix-dup-groups" "bin/lib/test-dup-group.sh"

CP_CO="$TMPDIR_BASE/cp-co"
slash_fx_checkout "$CP_CO" "$AGENTS_ROOT" bin/audit-tests.sh
for cp_src in bin/x.sh bin/y.sh bin/z.sh bin/dec-a.sh bin/dec-b.sh; do
  add_src "$CP_CO" "$cp_src"
done
# Same `//` value, different `#` decoys: one group on the `//` key only.
slash_write "$CP_CO/tests/bin/s-a.slt" '// Tests: bin/x.sh, bin/y.sh' '# Tests: bin/dec-a.sh' '// Tags: TL2, scope:common'
slash_write "$CP_CO/tests/bin/s-b.slt" '// Tests: bin/x.sh, bin/y.sh' '# Tests: bin/dec-b.sh' '// Tags: TL2, scope:common'
# bash keeps `#`: a leading `//` decoy naming the .slt key must not pull h-a into it.
slash_write "$CP_CO/tests/bin/h-a.sh" '#!/usr/bin/env bash' '// Tests: bin/x.sh, bin/y.sh' '# Tests: bin/z.sh' '# Tags: TL2, scope:common'
slash_write "$CP_CO/tests/bin/h-b.sh" '#!/usr/bin/env bash' '# Tests: bin/z.sh' '# Tags: TL2, scope:common'
commit_repo "$CP_CO" "comment prefix fixture"

run_dup "$CP_CO" "$CP_CO/bin/audit-tests.sh"
CP_TAB="$(printf '\t')"
CP_WANT="$(printf '%s\n' \
  "#axis${CP_TAB}key${CP_TAB}count${CP_TAB}files" \
  "full${CP_TAB}bin/x.sh,bin/y.sh${CP_TAB}2${CP_TAB}tests/bin/s-a.slt,tests/bin/s-b.slt" \
  "full${CP_TAB}bin/z.sh${CP_TAB}2${CP_TAB}tests/bin/h-a.sh,tests/bin/h-b.sh" \
  "token${CP_TAB}bin/x.sh${CP_TAB}2${CP_TAB}tests/bin/s-a.slt,tests/bin/s-b.slt" \
  "token${CP_TAB}bin/z.sh${CP_TAB}2${CP_TAB}tests/bin/h-a.sh,tests/bin/h-b.sh")"
assert_eq "CP1 --dup-groups exit 0 (groups exist)" "0" "$RC"
assert_eq "CP2 groups are keyed on // for .slt and # for .sh; decoys group nothing" "$CP_WANT" "$OUT"

case_end
grp_done comment-prefix.sh
