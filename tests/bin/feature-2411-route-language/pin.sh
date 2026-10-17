# Today's rows for a bash query and a document query, whole line, without --with-language.
# Sourced by tests/bin/feature-2411-route-language.sh. Green before and after #2411.
# shellcheck shell=bash

echo ""
echo "=== pin: rows without --with-language ==="

# pin_row <label> <row> <want>
pin_row() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "want [$3] got [$2]"
  fi
}

# no_other_language <label> <row>
no_other_language() {
  case "$2" in
    *.js*|*.ps1*|*.py*) fail "$1" "a test in another language is listed: $2" ;;
    "") fail "$1" "no row" ;;
    *) pass "$1: only bash tests are listed" ;;
  esac
}

case_begin "pin-bash-query-rows" "bin/lib/test-route-destination.sh"
pin_row "--sources src/b.sh" "$(row "$N_SRC" 0)" \
  $'src/b.sh\tappend\texact\ttests/bin/b1.sh\t4\ttests/bin/b1.sh\\,4\\,0,tests/bin/b2.sh\\,4\\,1\ttests/bin/b1.sh\\,4\\,0,tests/bin/b2.sh\\,4\\,1\t-'
pin_row "--test-file $T/b1.sh" "$(row "$N_TF" 0)" \
  $'tests/bin/b1.sh\tappend\tsuperset\ttests/bin/b2.sh\t4\ttests/bin/b2.sh\\,4\\,1\ttests/bin/b2.sh\\,4\\,1\t-'
no_other_language "--sources src/b.sh" "$(row "$N_SRC" 0)"
no_other_language "--test-file $T/b1.sh" "$(row "$N_TF" 0)"
case_end

case_begin "pin-document-query-rows-bash-only-corpus" "bin/lib/test-route-destination.sh"
pin_row "--sources docs/u.md" "$(row "$N_SRC" 1)" \
  $'docs/u.md\tappend\texact\ttests/bin/doc.sh\t4\ttests/bin/doc.sh\\,4\\,0,tests/bin/doc2.sh\\,4\\,0\ttests/bin/doc.sh\\,4\\,0,tests/bin/doc2.sh\\,4\\,0\t-'
pin_row "--test-file $T/doc.sh" "$(row "$N_TF" 1)" \
  $'tests/bin/doc.sh\tappend\texact\ttests/bin/doc2.sh\t4\ttests/bin/doc2.sh\\,4\\,0\ttests/bin/doc2.sh\\,4\\,0\t-'
case_end
