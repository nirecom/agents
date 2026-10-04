=== rules/test/fixture-isolation.md
---
paths:
  - "tests/**"
  - "**/*.Tests.ps1"
---

# Body text is not front matter: *.sh and *.Tests.ps1 here are never scanned.
Run `tests/run-all.sh` over *.sh and test_*.py files.
