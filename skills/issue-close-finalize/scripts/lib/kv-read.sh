# shellcheck shell=bash
# kv-read.sh (sourced). kv_read <text> <allowed-key>...
# Assigns each KEY=VALUE line of <text> whose KEY is in the allowed list, as a literal
# string: a value is never evaluated, and a key outside the list is ignored.
# Only the first occurrence of a key is assigned: a later duplicate line cannot override it.

kv_read() {
    local text="$1" line key val allowed seen=" "
    shift
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        [[ "$seen" == *" $key "* ]] && continue
        for allowed in "$@"; do
            if [[ "$key" == "$allowed" ]]; then
                printf -v "$key" '%s' "$val"
                seen+="$key "
                break
            fi
        done
    done <<<"$text"
}
