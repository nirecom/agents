# bin/check-case-markers.sh reports a test it cannot read instead of passing it silently, and
# takes the original path as --rel when it reads a temp copy (#2502 S3-0, S3-5).
# Sourced by tests/bin/feature-2411-gate-three-languages.sh.
# shellcheck shell=bash

echo ""
echo "=== gate: unsupported languages and --rel (#2502) ==="

REPO_UNS="$TMPBASE/repo-unsupported"
mkrepo "$REPO_UNS"
# Both comment prefixes carry the two-path header, so the path count never depends on which
# prefix the checker falls back to for a file no reader covers.
printf '%s\n' '# Tests: bin/a.sh, bin/b.sh' '// Tests: bin/a.js, bin/b.js' '# Tags: scope:common' > "$BODIES/uns-two-paths"
printf '%s\n' '# Tests: bin/a.sh' '// Tests: bin/a.js' '# Tags: scope:common' > "$BODIES/uns-one-path"
put "$REPO_UNS" tests/bin/u.test.ts uns-two-paths
put "$REPO_UNS" tests/bin/u.rb uns-two-paths
put "$REPO_UNS" tests/bin/one.test.ts uns-one-path
printf '%s\n' '# Tags: scope:common' 'echo x' > "$BODIES/uns-no-tests"
put "$REPO_UNS" tests/bin/none.test.ts uns-no-tests
printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/a.sh' '# Tags: scope:common' 'echo x' > "$BODIES/sh-one-path"
printf '%s\n' '#!/usr/bin/env bash' '# Tags: scope:common' 'echo x' > "$BODIES/sh-no-tests"
put "$REPO_UNS" tests/bin/one.sh sh-one-path
put "$REPO_UNS" tests/bin/none.sh sh-no-tests

case_begin "gate-unsupported-recognized-only-warns" "bin/check-case-markers.sh"
_f="$REPO_UNS/tests/bin/u.test.ts"
ck "$_f"
ck_exact "recognized-only language: WARN, exit 0" 0 \
  "WARN: $_f: case markers not checked (no test case reader for this language) code=CASE_MARKER_READER_UNSUPPORTED" ""
case_end

case_begin "gate-unsupported-unmatched-warns" "bin/check-case-markers.sh"
_f="$REPO_UNS/tests/bin/u.rb"
ck "$_f"
ck_exact "unregistered language: WARN, exit 0" 0 \
  "WARN: $_f: case markers not checked (no test case reader for this language) code=CASE_MARKER_READER_UNSUPPORTED" ""
case_end

case_begin "gate-unsupported-warns-for-every-header-shape" "bin/check-case-markers.sh"
# The unsupported WARN comes before the header's path count: no Tests: line, one path and two
# paths all warn (#2502 S3-5), so an unread language never passes silently.
for _f in "$REPO_UNS/tests/bin/none.test.ts" "$REPO_UNS/tests/bin/one.test.ts" "$REPO_UNS/tests/bin/u.test.ts"; do
  ck "$_f"
  ck_exact "recognized-only ${_f##*/}: WARN, exit 0" 0 \
    "WARN: $_f: case markers not checked (no test case reader for this language) code=CASE_MARKER_READER_UNSUPPORTED" ""
done
case_end

case_begin "gate-bash-without-marker-target-stays-silent" "bin/check-case-markers.sh"
# Control: a supported language with no Tests: line or one path is still no marker target.
for _f in "$REPO_UNS/tests/bin/none.sh" "$REPO_UNS/tests/bin/one.sh"; do
  ck "$_f"
  ck_exact "bash ${_f##*/}: silent, exit 0" 0 "" ""
done
case_end

case_begin "gate-rel-arg-matches-the-original-path" "bin/check-case-markers.sh"
mkdir -p "$TMPBASE/x"
cp "$BODIES/pytest-missing" "$TMPBASE/x/copy.tmp"
ck --rel tests/bin/test_x.py "$TMPBASE/x/copy.tmp"
if [ "$CK_RC" = 1 ]; then pass "--rel copy: exit 1"; else fail "--rel copy" "want rc=1 got rc=$CK_RC out=[$CK_OUT] err=[$CK_ERR]"; fi
has "--rel copy judged as pytest" "$CK_OUT" "HIGH: tests/bin/test_x.py (2 paths in # Tests: header, no @pytest.mark.target markers) code=MISSING_CASE_MARKERS"
lacks "--rel copy" "$CK_OUT$CK_ERR" "copy.tmp"
case_end
