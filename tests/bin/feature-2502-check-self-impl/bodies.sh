# Tests: bin/check-self-impl.sh
# Single-path header keeps the dummy header lines in the fixtures below from being read as this file's own.
# Fixture test bodies for tests/bin/feature-2502-check-self-impl.sh (sourced by it).
# The hand-made counters and helper redefinitions live only inside the heredoc bodies.
# shellcheck shell=bash

# sh-bad: counter on line 5, redefinition of the helper's pass on line 6.
cat > "$BODIES/sh-bad" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
source "$(dirname "$0")/../../tests/lib/harness.sh"
PASS=0
pass() { echo ok; }
echo done
EOF
cat > "$BODIES/sh-clean" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
source "$(dirname "$0")/../../tests/lib/harness.sh"
echo done
EOF
# sh-bad-edit: sh-clean with sh-bad's counter added, for a file HEAD already has.
cat > "$BODIES/sh-bad-edit" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
source "$(dirname "$0")/../../tests/lib/harness.sh"
PASS=0
echo done
EOF
# sh-bad-edit-unrelated: sh-bad-edit with only an unrelated line changed (existing debt kept).
cat > "$BODIES/sh-bad-edit-unrelated" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
source "$(dirname "$0")/../../tests/lib/harness.sh"
PASS=0
echo finished
EOF
# sh-bad-edit-dup: sh-bad-edit with its counter written twice (lines 5 and 6).
sed 's/^PASS=0$/PASS=0\nPASS=0/' "$BODIES/sh-bad-edit" > "$BODIES/sh-bad-edit-dup"

# pytest-bad: counter on line 5, redefinition of the helper's isolate on line 8.
cat > "$BODIES/pytest-bad" <<'EOF'
# Tests: bin/a.py
# Tags: scope:common
import pytest

passed = 0


def isolate():
    return None


def test_a():
    assert pytest is not None
EOF
cat > "$BODIES/pytest-clean" <<'EOF'
# Tests: bin/a.py
# Tags: scope:common
import pytest


def test_a():
    assert pytest is not None
EOF

# pester-bad: counter on line 6, redefinition of Enter-HarnessIsolation on line 7.
cat > "$BODIES/pester-bad" <<'EOF'
# Tests: bin/a.ps1
# Tags: scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
$script:Passed = 0
function Enter-HarnessIsolation { }
Describe 'a' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF
cat > "$BODIES/pester-clean" <<'EOF'
# Tests: bin/a.ps1
# Tags: scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
Describe 'a' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF

# js-bad: counter on line 4, redefinitions of gitInit on line 5 and isolate on line 6.
cat > "$BODIES/js-bad" <<'EOF'
// Tests: bin/a.js
// Tags: scope:common
const harness = require("../lib/harness");
let PASS = 0;
function gitInit() {}
const isolate = () => null;
console.log(typeof harness, PASS, gitInit, isolate);
EOF
cat > "$BODIES/js-clean" <<'EOF'
// Tests: bin/a.js
// Tags: scope:common
const harness = require("../lib/harness");
console.log(typeof harness);
EOF

# ts-bad: a recognized-only language, which has no caseEmbedRules.
cat > "$BODIES/ts-bad" <<'EOF'
// Tests: bin/a.js
// Tags: scope:common
let PASS = 0;
console.log(PASS);
EOF
