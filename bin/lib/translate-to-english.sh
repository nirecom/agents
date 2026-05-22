# Sourceable helper: source this file, then call translate_to_english <text>
# Per rules/language.md: history.md entries are always English (regardless of visibility).
# Currently a pass-through + non-ASCII warning. Real translation API: separate issue.
translate_to_english() {
    local text="$1"
    # Portable non-ASCII detection — BSD grep has no -P; use awk
    if printf '%s' "$text" | awk '/[^\x00-\x7F]/{found=1; exit} END{exit !found}'; then
        echo "Warning: non-ASCII text detected; history.md requires English (rules/language.md). Review manually." >&2
    fi
    printf '%s' "$text"
}
