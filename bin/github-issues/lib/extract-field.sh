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
        # Leading-whitespace width in COLUMNS, never in characters: a tab
        # advances to the next multiple of 4 (CommonMark tab stop). Stated
        # here so the 4-column rule cannot depend on the environment.
        function indent_cols(s,   i, c, w) {
            w = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == " ") { w += 1 }
                else if (c == "\t") { w += 4 - (w % 4) }
                else { break }
            }
            return w
        }
        BEGIN { cap = 0; out = ""; target = lc(F); fenced = 0 }
        {
            # A "## ..." line inside a fenced code block is a code comment, not
            # a heading, so no terminator may fire while a fence is open. Fence
            # state is per-invocation, so it never leaks between fields; a body
            # that ends with the fence still open keeps all of its content.
            stripped = $0
            sub(/^[ \t]+/, "", stripped)
            indent = indent_cols($0)
            run = 0; ch = ""
            if (match(stripped, /^`+/)) { ch = "`"; run = RLENGTH }
            else if (match(stripped, /^~+/)) { ch = "~"; run = RLENGTH }
            # CommonMark 4.5: a delimiter indented 4+ columns is an indented
            # code block, not a fence, and a CLOSING run may be followed by
            # whitespace only -- an info string marks an opening fence alone.
            tail = substr(stripped, run + 1)
            # CommonMark 4.5: the info string of a BACKTICK opener may not contain a
            # backtick -- such a line is no fence at all. Tilde fences are
            # exempt: the restriction is on the fence char, not the info text.
            can_open = (run >= 3 && indent <= 3 && (ch != "`" || tail !~ /`/))
            can_close = (run > 0 && indent <= 3 && tail ~ /^[ \t]*$/)
            if (fenced) {
                if (can_close && ch == fence_ch && run >= fence_len) { fenced = 0 }
                if (cap && $0 ~ /[^ \t]/) { out = (out == "" ? $0 : out " " $0) }
                next
            }
            if (can_open) { fenced = 1; fence_ch = ch; fence_len = run }
            line_lc = lc($0)
            # CommonMark 4.2/4.4: a heading is a heading only at 0-3 columns of
            # indent; at 4+ the line is an indented code block, so it is plain
            # field content -- it neither starts nor ends capture. Same
            # indent_cols() rule the fence predicates use.
            if (indent <= 3 && line_lc ~ /^[ \t]*(##[ \t]+|###[ \t]+)?(background|changes|cause|fix)([ \t]*:.*)?$/) {
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
            # Any other ATX heading is a section boundary too. Without this,
            # an unrecognized heading (the optional "### Sub-tasks (optional)"
            # textarea in task.yml) and its body are swallowed into the field
            # captured just above it. Inline "Foo: bar" labels deliberately do
            # NOT terminate: prose contains colons, and terminating on them
            # would truncate legitimate field bodies. H1 is excluded on the
            # same ground: a "# comment" line in a fenced code block is far
            # commoner in a field body than a real H1, and Issue Forms render
            # every textarea label as "###".
            if (indent <= 3) {
                if ($0 ~ /^[ \t]*##+[ \t]+/) { cap = 0; next }
            }
            if (cap && $0 ~ /[^ \t]/) { out = (out == "" ? $0 : out " " $0) }
        }
        END { print out }
    '
}

# extract_field_or_marker <Field>: extract_field's value, or "(no <Field> recorded)"
# when empty. <Field> is Background|Changes|Cause|Fix — these 4 forms are the whole
# marker set; any other name is rejected (stderr, return 2, no stdout).
# extract_field itself failing -> stderr, return 3, no marker: a parse failure is not
# the fact "unrecorded", and asserting it would be the fabrication #2098 removes —
# as is reusing title/body. Find: \(no (Background|Changes|Cause|Fix) recorded\)
extract_field_or_marker() {
    local field="$1"
    local label
    case "$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]')" in
        background) label="Background" ;;
        changes)    label="Changes" ;;
        cause)      label="Cause" ;;
        fix)        label="Fix" ;;
        *)
            printf 'extract_field_or_marker: unknown field name: %s\n' "$field" >&2
            return 2
            ;;
    esac
    local result
    result="$(extract_field "$field")" || {
        printf 'extract_field_or_marker: extract_field failed for field: %s\n' "$field" >&2
        return 3
    }
    if [[ -z "$result" ]]; then
        result="(no ${label} recorded)"
    fi
    printf '%s' "$result"
    return 0
}
