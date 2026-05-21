# Sourceable helper: extract_field()
# Usage: BODY="$body" extract_field <FieldName>
#   FieldName in: Background | Changes | Cause | Fix
# Recognized shape variants (case-insensitive on field name):
#   - inline label:  "Background: <text>"
#   - H2 header:     "## Background"
#   - H3 header:     "### Background"
# Shape-variant recognition only — canonical 4 field names, no synonym expansion.

extract_field() {
    printf '%s\n' "$BODY" | awk -v F="$1" '
        function lc(s) { return tolower(s) }
        BEGIN { cap = 0; out = ""; target = lc(F) }
        {
            line_lc = lc($0)
            if (line_lc ~ /^[ \t]*(##[ \t]+|###[ \t]+)?(background|changes|cause|fix)([ \t]*:.*)?$/) {
                field_name = line_lc
                sub(/^[ \t]*(##[ \t]+|###[ \t]+)?/, "", field_name)
                sub(/[ \t]*:.*$/, "", field_name)
                gsub(/[ \t]+/, "", field_name)
                if (field_name == target) {
                    cap = 1
                    rest = $0
                    if (sub(/^[ \t]*(##[ \t]+|###[ \t]+)?[A-Za-z]+[ \t]*:[ \t]*/, "", rest) && rest != "") {
                        out = rest
                    }
                    next
                } else { cap = 0; next }
            }
            if (cap && $0 ~ /[^ \t]/) { out = (out == "" ? $0 : out " " $0) }
        }
        END { print out }
    '
}
