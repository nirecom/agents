# tests/bin/feat-2529-glossary-docs/helpers.sh
# Tests: rules/docs/glossary.md, docs/glossary.md, docs/glossary/user.md, docs/glossary/internal.md
# Tags: TL1, static, docs, glossary, scope:issue-specific
# Assertion and parsing helpers sourced by tests/bin/feat-2529-glossary-docs.sh after its
# harness_isolate pin; expects R and TMP_ROOT set, and GLOBS set before glob_hits runs.
# The helpers hold no assertions: each case-marker block below only attributes a helper group
# to the Tests: path it serves, so retire can split this file per path (its records resolve
# UNOBSERVED and are dropped from the report).

case_begin "helpers-assertions-and-entry-parsing" "docs/glossary.md"
has() {
    if [ -f "$2" ] && grep -Eqi -- "$3" "$2"; then pass "$1"
    else fail "$1" "/$3/ not found in ${2#"$R"/}"; fi
}
# An absence over a missing or empty file proves nothing.
lacks() {
    if [ ! -s "$2" ]; then fail "$1" "${2#"$R"/} missing or empty; absence not provable"
    elif grep -Eqi -- "$3" "$2"; then fail "$1" "/$3/ still present in ${2#"$R"/}"
    else pass "$1"; fi
}

# entry <file> <term> — the body of one "### <term>" entry.
entry() { awk -v h="### $2" '{ sub(/\r$/, "") } $0 == h { on = 1; next } /^##+ / { on = 0 } on' "$1" 2>/dev/null; }

# slugs <file> — GitHub anchor slugs of the file's "### " headings, one per line.
slugs() {
    awk '{ sub(/\r$/, "") } /^### / { s = tolower(substr($0, 5)); gsub(/[^a-z0-9 _-]/, "", s); gsub(/ /, "-", s); print s }' "$1" 2>/dev/null
}
case_end

case_begin "helpers-entry-form-checker" "docs/glossary/user.md"
# The entry-form checker program (bin/lib/glossary-format.js spec, restated independently).
FORMAT_AWK="$TMP_ROOT/glossary-format.awk"
cat > "$FORMAT_AWK" <<'AWK'
      function err(m) { print m }
      function flush() {
        if (term == "") return
        if (defs != 1) err("entry \"" term "\": " defs " Definition line(s), want 1")
        if (deflines > 2) err("entry \"" term "\": Definition spans " deflines " lines, want <= 2")
        if (rels != 1) err("entry \"" term "\": " rels " Related line(s), want 1")
        if (rels == 1 && links != 1) err("entry \"" term "\": Related has " links " link(s), want 1")
      }
      { sub(/\r$/, "") }
      /^# / { h1++; if (term != "") err("line " NR ": H1 after the first entry"); next }
      /^## / { err("line " NR ": section heading: " $0); next }
      /^####/ { err("line " NR ": deeper heading: " $0); next }
      /^### / {
        flush(); term = substr($0, 5); lt = tolower(term)
        if (prev != "" && lt < prev) err("order: \"" term "\" after \"" prevt "\"")
        prev = lt; prevt = term; defs = 0; deflines = 0; rels = 0; links = 0; indef = 0; next
      }
      term == "" { next }
      /^- \*\*Definition\*\*:/ { defs++; deflines = 1; indef = 1; next }
      /^- \*\*Related\*\*:/ { rels++; indef = 0; s = $0; links += gsub(/\]\([^)]*\)/, "", s); next }
      /^[ \t]*[-*+] / { err("entry \"" term "\": extra bullet: " $0); indef = 0; next }
      /^[ \t]*$/ { indef = 0; next }
      /^<!--.*-->$/ { next }
      { if (indef) deflines++; else err("entry \"" term "\": stray line: " $0) }
      END { flush(); if (h1 != 1) err("H1 count " h1 + 0 ", want 1") }
AWK

# format_violations <file> — one line per entry-form violation (empty when the file conforms).
format_violations() {
    LC_ALL=C awk -f "$FORMAT_AWK" "$1" 2>/dev/null
}
case_end

case_begin "helpers-related-link-checker" "docs/glossary/internal.md"
# related_violations <file> [base-dir] — every Related link must be an in-repo file, never an
# issue URL; links resolve against base-dir (default: the file's own directory).
related_violations() {
    local file="$1" dir line target path
    dir="${2:-$(dirname "$file")}"
    grep -E '^- \*\*Related\*\*:' "$file" 2>/dev/null | tr -d '\r' | grep -oE '\]\([^)]*\)' | sed -E 's/^\]\((.*)\)$/\1/' |
    while IFS= read -r target; do
        case "$target" in
            *"/issues/"*) echo "issue URL: $target"; continue ;;
            http://*|https://*) echo "external URL: $target"; continue ;;
        esac
        path="${target%%#*}"
        [ -e "$dir/$path" ] || echo "missing target: $target"
    done
}
case_end

case_begin "helpers-rule-paths-glob-expander" "rules/docs/glossary.md"
# glob_hits <root> — every file under <root> some paths: glob ($GLOBS) matches, expanded by the
# shell (a real pathname glob: `*` never crosses `/`, `**` does under globstar), repo-relative.
glob_hits() {
    local root="$1" g f
    (
        shopt -s nullglob globstar
        cd "$root" || exit 0
        while IFS= read -r g; do
            [ -n "$g" ] || continue
            # shellcheck disable=SC2086
            for f in $g; do [ -f "$f" ] && printf '%s\n' "$f"; done
        done <<< "$GLOBS"
    ) | sort -u
}
case_end
