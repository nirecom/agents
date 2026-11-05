# resolve-project/cache.sh — project-resolve.tsv cache for lib/resolve-project.sh (sourced by it).
# Row: owner/repo, project owner, number, project id, Content Date, Status, Todo, In Progress, Done,
#   session-id field id, schema tag. Only an 11-column row tagged $_RESOLVE_PROJECT_CACHE_SCHEMA is a
#   hit, so rows from before the session-id rename (10 columns) are refetched once and rewritten.
# Writes go through mktemp + mv; every failure is warn-only (rc 1) and never aborts the caller.

_RESOLVE_PROJECT_CACHE_SCHEMA="sid1"

# _resolve_project_cache_dir <dir-of-resolve-project.sh> — cache dir under the global state root;
# rc 1, no output, for a relative WORKFLOW_STATE_DIR (the caller then runs uncached).
_resolve_project_cache_dir() {
    local root=""
    root="$(node "$1/../../workflow-state-dir" --global 2>/dev/null)" || root=""
    root="${root%$'\r'}"
    if [[ -z "$root" ]]; then
        root="${WORKFLOW_STATE_DIR:-$HOME/.workflow-state}"
        [[ "$root" == /* || "$root" =~ ^[A-Za-z]:[\\/] ]] || return 1
    fi
    printf '%s/cache\n' "$root"
}

# _resolve_project_cache_file — the cache file path; rc 1 when the cache dir is unavailable.
_resolve_project_cache_file() {
    local dir
    dir="$(_resolve_project_cache_dir "$_RESOLVE_PROJECT_LIB_DIR")" || return 1
    [[ -n "$dir" ]] || return 1
    printf '%s/project-resolve.tsv\n' "$dir"
}

# _resolve_project_read_cache_row <cache-file> <key> <require-wip-fields 0|1> — prints the hit row.
# rc 1 on a miss: no row, wrong width or tag, empty owner/number/id, or (with the flag) any empty
# column among 6-10 (Status, its three options, session-id).
_resolve_project_read_cache_row() {
    local cache_file="$1" key="$2" require="$3"
    [[ -n "$cache_file" && -f "$cache_file" ]] || return 1
    awk -F'\t' -v key="$key" -v tag="$_RESOLVE_PROJECT_CACHE_SCHEMA" -v req="$require" '
        $1 == key {
            if (NF != 11 || $11 != tag || $2 == "" || $3 == "" || $4 == "") exit 1
            if (req == "1") { for (i = 6; i <= 10; i++) if ($i == "") exit 1 }
            print; found = 1; exit 0
        }
        END { if (!found) exit 1 }' "$cache_file" 2>/dev/null
}

# _resolve_project_write_cache <cache-dir> <cache-file> <key> <owner> <num> <pid> <content-date>
#   <status> <todo> <in-progress> <done> <session-id> — replace the key's row with an 11-column row.
_resolve_project_write_cache() {
    local cache_dir="$1" cache_file="$2" key="$3"
    local p_owner="$4" p_num="$5" p_id="$6" p_field="$7"
    local p_status_field="${8:-}" p_todo_opt="${9:-}" p_in_progress_opt="${10:-}"
    local p_done_opt="${11:-}" p_sid_field="${12:-}"

    [[ -n "$cache_dir" ]] || return 0
    if ! mkdir -p "$cache_dir" 2>/dev/null; then
        echo "warn: resolve-project: cache write failed (mkdir $cache_dir)" >&2
        return 1
    fi

    local tmp
    tmp=$(mktemp "$cache_dir/.project-resolve.XXXXXX" 2>/dev/null) || {
        echo "warn: resolve-project: cache write failed (mktemp)" >&2
        return 1
    }

    if [ -f "$cache_file" ]; then
        awk -F'\t' -v key="$key" 'BEGIN{OFS="\t"} $1!=key {print}' "$cache_file" > "$tmp" 2>/dev/null || true
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$key" "$p_owner" "$p_num" "$p_id" "$p_field" \
        "$p_status_field" "$p_todo_opt" "$p_in_progress_opt" "$p_done_opt" "$p_sid_field" \
        "$_RESOLVE_PROJECT_CACHE_SCHEMA" >> "$tmp"

    if ! mv "$tmp" "$cache_file" 2>/dev/null; then
        echo "warn: resolve-project: cache write failed (mv)" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

# resolve_project_drop_cache_row <key> — remove the key's row (other keys stay). rc 1 + warn on failure.
resolve_project_drop_cache_row() {
    local key="${1:-}" cache_file cache_dir tmp
    [[ -n "$key" ]] || return 1
    cache_file="$(_resolve_project_cache_file)" || return 1
    [[ -f "$cache_file" ]] || return 0
    cache_dir="$(dirname "$cache_file")"
    if ! tmp=$(mktemp "$cache_dir/.project-resolve.XXXXXX" 2>/dev/null); then
        echo "warn: resolve-project: cache row drop failed (mktemp)" >&2
        return 1
    fi
    awk -F'\t' -v key="$key" '$1 != key {print}' "$cache_file" > "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$cache_file" 2>/dev/null; then
        echo "warn: resolve-project: cache row drop failed (mv)" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}
