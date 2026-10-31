#!/usr/bin/env bash
# Validates the frontmatter of test entrypoints: the `# Tests:` / `# Tags:` headers, flat
# placement, the helper-library load and self-implemented harnesses (#2507 D7: the logic lives in
# check-test-frontmatter/cli.js; this adapter keeps the bash entry point).
# Usage:
#   bin/check-test-frontmatter.sh --staged [--merge-parents <file>] <file1> [<file2>...]
#   bin/check-test-frontmatter.sh --all [<root>]
#   --merge-parents: the bin/merge-parents record file; without it, the parents are resolved here.
# Exit:  0 = all OK, 1 = validation failure, 2 = usage error, the registry unreadable or no node
if ! command -v node >/dev/null 2>&1; then echo "check-test-frontmatter.sh: node not found on PATH; install Node.js to run the frontmatter check" >&2; exit 2; fi
cli="$(dirname "${BASH_SOURCE[0]}")/check-test-frontmatter/cli.js"
if [ ! -f "$cli" ]; then echo "check-test-frontmatter.sh: predicate library unavailable ($cli not found)" >&2; exit 2; fi
exec node "$cli" "$@"
