=== bin/notes.sh
# for f in tests/hooks/*.sh tests/hooks/*.Tests.ps1; do bash "$f"; done
  // if (id === "js") return; tests/*.Tests.ps1
   * pester and pytest both live under tests/
echo ok
=== bin/lib/test-language-parts/bash.sh
for f in tests/hooks/*.sh tests/hooks/*.Tests.ps1; do :; done
=== skills/synced/demo/scripts/run.sh
for f in tests/*.sh tests/*.Tests.ps1; do :; done
=== skills/demo/SKILL.md
Run tests/*.sh and tests/*.Tests.ps1 with bash or pester.
=== docs/guide.md
for f in tests/*.sh tests/*.Tests.ps1; do :; done
=== tests/hooks/some-test.sh
for f in tests/*.sh tests/*.Tests.ps1; do bash "$f"; done
=== rules/test.md
# No front matter in this file, so nothing is scanned: tests/*.sh tests/*.Tests.ps1
=== hooks/lib/test-language-registry.js
if (id === "bash" || id === "pester") return "tests/*.sh tests/*.Tests.ps1";
