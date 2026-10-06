=== hooks/pre-commit
for f in tests/hooks/x; do :; done
done <<< "$(git diff --cached --name-only -- '*.sh')"
const WORDS = ["pytest", "pester", "jest"];
=== @allowlist
# path<TAB>text on the line<TAB>reason
hooks/pre-commit	-- '*.sh')	executable-bit check over staged shell scripts; not test discovery
hooks/pre-commit	"pytest", "pester"	test-runner command words for classifying ad-hoc commands
