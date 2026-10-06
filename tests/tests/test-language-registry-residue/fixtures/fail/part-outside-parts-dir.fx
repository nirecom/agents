=== bin/lib/test-retire-predicate/case-parser.sh
case "$f" in
  *.sh|*.Tests.ps1) kind=1 ;;
esac
[[ "$lang" = pester ]] && kind=2
=== bin/lib/test-language-parts/bash.sh
case "$f" in
  *.sh|*.Tests.ps1) kind=1 ;;
esac
[[ "$lang" = pester ]] && kind=2
