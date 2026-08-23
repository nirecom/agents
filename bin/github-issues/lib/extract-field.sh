# Usage: BODY="$body" extract_field <Background|Changes|Cause|Fix>
# Recognizes "Field: text", "## Field", "### Field" (case-insensitive). No synonym expansion.

extract_field() {
    printf '%s\n' "$BODY" | awk -v F="$1" '
        function lc(s) { return tolower(s) }
        # Width in columns (tab -> next multiple of 4, CommonMark tab stop), not characters.
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
            # No terminator fires inside an open fence, so a "##" code comment cannot end capture.
            stripped = $0
            sub(/^[ \t]+/, "", stripped)
            indent = indent_cols($0)
            run = 0; ch = ""
            if (match(stripped, /^`+/)) { ch = "`"; run = RLENGTH }
            else if (match(stripped, /^~+/)) { ch = "~"; run = RLENGTH }
            # CommonMark 4.5: 4+ columns indent -> indented code block, not a fence.
            tail = substr(stripped, run + 1)
            # A backtick opener info string may not itself contain a backtick; tildes are exempt.
            can_open = (run >= 3 && indent <= 3 && (ch != "`" || tail !~ /`/))
            can_close = (run > 0 && indent <= 3 && tail ~ /^[ \t]*$/)
            if (fenced) {
                if (can_close && ch == fence_ch && run >= fence_len) { fenced = 0 }
                if (cap && $0 ~ /[^ \t]/) { out = (out == "" ? $0 : out " " $0) }
                next
            }
            if (can_open) { fenced = 1; fence_ch = ch; fence_len = run }
            line_lc = lc($0)
            # 4+ columns indent -> indented code block, not a heading (same rule as the fence check).
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
            # Any other ATX heading (##+) also ends capture, so an unrecognized textarea
            # heading is not swallowed into the field above it. Inline "Foo: bar" labels
            # do not terminate (prose has colons); nor does H1 (Issue Forms render
            # textarea labels as "###", so a real H1 is rarer than a "# comment" in a
            # fenced code block).
            if (indent <= 3) {
                if ($0 ~ /^[ \t]*##+[ \t]+/) { cap = 0; next }
            }
            if (cap && $0 ~ /[^ \t]/) { out = (out == "" ? $0 : out " " $0) }
        }
        END { print out }
    '
}

# extract_field_or_marker <Field>: value, or "(no <Field> recorded)" when empty.
# Unknown field -> return 2. Parse failure -> return 3, no marker (a parse failure
# isn't "unrecorded" — asserting it would be the fabrication #2098 removes).
# Find: \(no (Background|Changes|Cause|Fix) recorded\)
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
