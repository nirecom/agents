# Usage: BODY="$body" extract_field <Background|Changes|Cause|Fix>
# Recognizes "Field: text", "## Field", "### Field" (case-insensitive). No synonym expansion.
# Capture ends at "##" or a "###"+ heading naming a known label; other "###"+ headings are body.

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
        # SSOT of heading labels that end a field: canonical four + Issue Forms labels
        # (.github/ISSUE_TEMPLATE/*.yml; parity checked by tests/bin/fix-2168-extract-field-capture.sh).
        function is_known_label(line,   t) {
            t = lc(line)
            sub(/^[ \t]*#+[ \t]+/, "", t)
            sub(/[ \t]+$/, "", t)
            sub(/[ \t]+#+$/, "", t)   # optional ATX closing sequence ("### Fix ###")
            return (t == "background" || t == "changes" || t == "cause" || t == "fix" || t == "sub-tasks (optional)")
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
            # "##" always ends capture. "###".."######" end it only for a known label
            # (else it is body text). Inline "Foo: bar" labels and H1 never terminate.
            if (indent <= 3) {
                if ($0 ~ /^[ \t]*##[ \t]+/) { cap = 0; next }
                # ATX headings stop at six "#"; seven or more is plain text, not a heading.
                if ($0 ~ /^[ \t]*###(#?#?#?)[ \t]+/ && is_known_label($0)) { cap = 0; next }
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
