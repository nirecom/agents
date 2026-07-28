# Sourceable helpers: intent_extract_title() / intent_extract_body()
# Usage: intent_extract_title <intent_path>
#        intent_extract_body  <intent_path>
# Turns a session intent.md into issue-ready Title / Body text for Path C of
# clarify-commit-scope.sh.
#
# Title source order: `**Title:** <text>` line → H1 with a trailing `— <sid>`
# stripped → literal `Tracking issue (<session-id>)` (warned on stderr).
# Body: ONLY exact-match Background/Scope H2 sections, re-emitted under
# normalized headings in original file order. Exact-match (not prefix) keeps
# confusable internal headings (`## Background – Internal Notes`,
# `## Scope Decision Log`, `## Constraints`) out of the public issue body.

intent_extract_title() {
    local intent_path="$1"
    local title=""

    title="$(grep -m1 '^\*\*Title:\*\*' "$intent_path" 2>/dev/null || true)"
    title="${title#\*\*Title:\*\*}"
    title="$(printf '%s' "$title" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ -z "$title" ]; then
        title="$(grep -m1 '^# ' "$intent_path" 2>/dev/null || true)"
        title="${title#\# }"
        title="$(printf '%s' "$title" | sed -e 's/—.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    fi

    if [ -z "$title" ]; then
        local sid
        sid="$(basename "$intent_path")"
        sid="${sid%-intent.md}"
        title="Tracking issue ($sid)"
        printf 'intent-to-issue: no usable title in %s — falling back to "%s"\n' "$intent_path" "$title" >&2
    fi

    printf '%s\n' "$title"
}

intent_extract_body() {
    local intent_path="$1"
    awk '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function flush_section() {
            if (heading != "") {
                if (out != "") { out = out "\n" }
                out = out heading "\n" body
            }
            heading = ""; body = ""
        }
        BEGIN { heading = ""; body = ""; out = "" }
        /^## / {
            flush_section()
            h = trim(substr($0, 4))
            if (h == "Background / Motivation" || h == "Background/Motivation" || h == "Background") {
                heading = "## Background / Motivation"
            } else if (h == "Scope" || h == "Scope / Constraints" || h == "Scope/Constraints") {
                heading = "## Scope"
            }
            next
        }
        { if (heading != "") { body = body $0 "\n" } }
        END { flush_section(); printf "%s", out }
    ' "$intent_path"
}
