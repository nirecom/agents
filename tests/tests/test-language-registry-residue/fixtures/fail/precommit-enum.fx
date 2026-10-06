=== hooks/lib/precommit-tests-frontmatter.sh
    while IFS= read -r f; do
        case "$f" in
            tests/hooks/*/*.Tests.ps1|tests/bin/*/*.Tests.ps1|tests/*/*/test_*.py) continue ;;
            tests/hooks/*.Tests.ps1|tests/bin/*.Tests.ps1|tests/hooks/test_*.py|tests/bin/test_*.py) _staged_tests+=("$f") ;;
            tests/*.Tests.ps1|tests/test_*.py) _staged_tests+=("$f") ;;
        esac
        echo "A test entrypoint (.sh / .Tests.ps1 / test_*.py) must live under tests/<category>/."
    done
