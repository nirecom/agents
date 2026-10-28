# Tests: bin/check-self-impl.sh
# Single-path header keeps the dummy header lines in the fixtures below from being read as this file's own.
# Fixture bodies for the --head rows (cli-head.sh, commit-time-langs.sh); sourced by the dispatcher.
# Per language <l> in sh, py, ps1, js: <l>-h-clean, -clean2 (another line edited), -ctr (a counter),
# -ctr2 (the counter kept, another line edited), -shift (a new function before the counter),
# -fail (a second counter added), -redef (a helper redefinition added), -syn (a syntax error).
# The hand-made counters and helper redefinitions live only inside the heredoc bodies.
# shellcheck shell=bash

# bash: the counter is on line 5 (7 in -shift); FAIL=0 and harness_isolate are on line 6.
cat > "$BODIES/sh-h-clean" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
source "$(dirname "$0")/../../tests/lib/harness.sh"
echo start
echo done
EOF
sed 's/^echo done$/echo finished/' "$BODIES/sh-h-clean" > "$BODIES/sh-h-clean2"
cat > "$BODIES/sh-h-ctr" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
source "$(dirname "$0")/../../tests/lib/harness.sh"
PASS=0
echo start
echo done
EOF
sed 's/^echo done$/echo finished/' "$BODIES/sh-h-ctr" > "$BODIES/sh-h-ctr2"
cat > "$BODIES/sh-h-shift" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
source "$(dirname "$0")/../../tests/lib/harness.sh"
extra_step() { echo extra; }
extra_step
PASS=0
echo start
echo done
EOF
sed 's/^PASS=0$/PASS=0\nFAIL=0/' "$BODIES/sh-h-ctr" > "$BODIES/sh-h-fail"
sed 's/^PASS=0$/PASS=0\nharness_isolate() { :; }/' "$BODIES/sh-h-ctr" > "$BODIES/sh-h-redef"
printf '%s\n' 'if then fi ((' 'echo "never closed' > "$BODIES/sh-h-syn"
# sh-h-dup: the counter twice (lines 5, 6); -dup2: another line edited; -dupfail: FAIL=0 on line 7.
sed 's/^PASS=0$/PASS=0\nPASS=0/' "$BODIES/sh-h-ctr" > "$BODIES/sh-h-dup"
sed 's/^echo done$/echo finished/' "$BODIES/sh-h-dup" > "$BODIES/sh-h-dup2"
sed 's/^echo start$/FAIL=0\necho start/' "$BODIES/sh-h-dup" > "$BODIES/sh-h-dupfail"

# pytest: the counter is on line 9 (12 in -shift); failed / isolate are on line 10.
cat > "$BODIES/py-h-clean" <<'EOF'
# Tests: bin/a.py
# Tags: scope:common
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness


def test_a():
    assert harness is not None
EOF
sed 's/^    assert harness is not None$/    assert harness/' "$BODIES/py-h-clean" > "$BODIES/py-h-clean2"
cat > "$BODIES/py-h-ctr" <<'EOF'
# Tests: bin/a.py
# Tags: scope:common
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness

passed = 0


def test_a():
    assert harness is not None
EOF
sed 's/^    assert harness is not None$/    assert harness/' "$BODIES/py-h-ctr" > "$BODIES/py-h-ctr2"
cat > "$BODIES/py-h-shift" <<'EOF'
# Tests: bin/a.py
# Tags: scope:common
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness

def extra_step():
    return None

passed = 0


def test_a():
    assert harness is not None
EOF
sed 's/^passed = 0$/passed = 0\nfailed = 0/' "$BODIES/py-h-ctr" > "$BODIES/py-h-fail"
sed 's/^passed = 0$/passed = 0\ndef isolate():\n    return None/' "$BODIES/py-h-ctr" > "$BODIES/py-h-redef"
printf '%s\n' 'def (:' > "$BODIES/py-h-syn"

# pester: the counter is on line 6 (7 in -shift); Failed / Enter-HarnessIsolation are on line 7.
cat > "$BODIES/ps1-h-clean" <<'EOF'
# Tests: bin/a.ps1
# Tags: scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
Describe 'a' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF
sed "s/It 'runs'/It 'still runs'/" "$BODIES/ps1-h-clean" > "$BODIES/ps1-h-clean2"
cat > "$BODIES/ps1-h-ctr" <<'EOF'
# Tests: bin/a.ps1
# Tags: scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
$script:Passed = 0
Describe 'a' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF
sed "s/It 'runs'/It 'still runs'/" "$BODIES/ps1-h-ctr" > "$BODIES/ps1-h-ctr2"
sed 's/^\$script:Passed = 0$/function Invoke-ExtraStep { }\n$script:Passed = 0/' "$BODIES/ps1-h-ctr" > "$BODIES/ps1-h-shift"
sed 's/^\$script:Passed = 0$/$script:Passed = 0\n$script:Failed = 0/' "$BODIES/ps1-h-ctr" > "$BODIES/ps1-h-fail"
sed 's/^\$script:Passed = 0$/$script:Passed = 0\nfunction Enter-HarnessIsolation { }/' "$BODIES/ps1-h-ctr" > "$BODIES/ps1-h-redef"
printf '%s\n' 'function { ((' > "$BODIES/ps1-h-syn"

# js: the counter is on line 4 (5 in -shift); FAIL / isolate are on line 5.
cat > "$BODIES/js-h-clean" <<'EOF'
// Tests: bin/a.js
// Tags: scope:common
const harness = require("../lib/harness");
console.log("start");
console.log(typeof harness);
EOF
sed 's/^console.log("start");$/console.log("begin");/' "$BODIES/js-h-clean" > "$BODIES/js-h-clean2"
cat > "$BODIES/js-h-ctr" <<'EOF'
// Tests: bin/a.js
// Tags: scope:common
const harness = require("../lib/harness");
let PASS = 0;
console.log("start");
console.log(typeof harness, PASS);
EOF
sed 's/^console.log("start");$/console.log("begin");/' "$BODIES/js-h-ctr" > "$BODIES/js-h-ctr2"
sed 's/^let PASS = 0;$/function extraStep() {}\nlet PASS = 0;/' "$BODIES/js-h-ctr" > "$BODIES/js-h-shift"
sed 's/^let PASS = 0;$/let PASS = 0;\nlet FAIL = 0;/' "$BODIES/js-h-ctr" > "$BODIES/js-h-fail"
sed 's/^let PASS = 0;$/let PASS = 0;\nfunction isolate() {}/' "$BODIES/js-h-ctr" > "$BODIES/js-h-redef"
printf '%s\n' 'function (( {' > "$BODIES/js-h-syn"

# <l>-h-synclean / -synctr: -clean / -ctr followed by the <l>-h-syn tail (a syntax error).
for _l in sh py ps1 js; do
  cat "$BODIES/$_l-h-clean" "$BODIES/$_l-h-syn" > "$BODIES/$_l-h-synclean"
  cat "$BODIES/$_l-h-ctr" "$BODIES/$_l-h-syn" > "$BODIES/$_l-h-synctr"
done
