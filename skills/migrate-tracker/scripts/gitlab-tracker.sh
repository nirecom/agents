#!/usr/bin/env bash
# gitlab-tracker.sh — sourced by run-issue-setup.sh for a gitlab origin (glab only, never gh).
# gl_labels <repo> <labels.yml>: one `glab label create` per entry; "already exists" is not a failure.
# gl_check_board <repo>: rc=0 when an issue board exists with a list per status:* label;
#   rc=1 when it is absent or incomplete; rc=2 when the boards cannot be read.
# gl_ensure_board <repo>: reuse or create the board, then one list per status:* label;
#   rc=1 when a status:* label still has no list afterwards or the lists cannot be read.
# Content Date has no GitLab counterpart: gl_ensure_board says so and skips it.

_gl_enc() { printf '%s' "${1//\//%2F}"; }

# _gl_label_rows <labels.yml> — prints name<TAB>color<TAB>description per entry.
_gl_label_rows() {
    local file="${1:?labels.yml required}" line name="" color="" desc=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^-[[:space:]]+name:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]]; then
            [[ -n "$name" ]] && printf '%s\t%s\t%s\n' "$name" "$color" "$desc"
            name="${BASH_REMATCH[1]}"; color=""; desc=""
        elif [[ "$line" =~ ^[[:space:]]+color:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]]; then
            color="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+description:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]]; then
            desc="${BASH_REMATCH[1]}"
        fi
    done <"$file"
    [[ -n "$name" ]] && printf '%s\t%s\t%s\n' "$name" "$color" "$desc"
    return 0
}

gl_labels() {
    local repo="${1:?repo required}" file="${2:?labels.yml required}" name color desc out failed=0
    [[ -f "$file" ]] || { echo "Error: labels file not found: $file" >&2; return 1; }
    while IFS=$'\t' read -r name color desc; do
        if ! out="$(glab label create --repo "$repo" --name "$name" --color "#${color:-cccccc}" --description "$desc" 2>&1)"; then
            if [[ "$out" =~ [Aa]lready|[Tt]aken ]]; then
                echo "label exists: $name"
            else
                echo "Error: glab label create failed for $name: $out" >&2
                failed=1
            fi
        fi
    done < <(_gl_label_rows "$file")
    return "$failed"
}

# _gl_first_id — reads a JSON object or array on stdin, prints the first id (empty when none).
_gl_first_id() {
    node -e 'let s="";process.stdin.on("data",(c)=>s+=c).on("end",()=>{let j;try{j=JSON.parse(s)}catch(e){process.exit(1)}const o=Array.isArray(j)?j[0]:j;process.stdout.write(o&&o.id!==undefined?String(o.id):"")})'
}

# _gl_status_label_ids <enc> — prints the id of every status:* label, one per line. The server-side
# search keeps the status:* labels on the first page however many other labels the project has.
_gl_status_label_ids() {
    glab api "projects/${1:?enc required}/labels?search=status%3A&per_page=100" | node -e 'let s="";process.stdin.on("data",(c)=>s+=c).on("end",()=>{let j=[];try{j=JSON.parse(s)}catch(e){process.exit(1)}for(const l of j){if(/^status:/.test(l.name))console.log(l.id)}})'
}

# _gl_board_lists_complete <enc> <board> — rc=0 when every status:* label has a list on the board;
# rc=1 when one is missing (ids named on stderr) or the labels / lists cannot be read.
_gl_board_lists_complete() {
    local enc="${1:?enc required}" board="${2:?board required}" labels lists missing
    labels="$(_gl_status_label_ids "$enc")" || {
        echo "Error: glab could not read the labels of $enc" >&2; return 1; }
    lists="$(glab api "projects/$enc/boards/$board/lists")" || {
        echo "Error: glab could not read the lists of board $board for $enc" >&2; return 1; }
    # shellcheck disable=SC2086 # $labels is a whitespace-separated id list, one argv entry per id
    missing="$(printf '%s' "$lists" | node -e 'let s="";process.stdin.on("data",(c)=>s+=c).on("end",()=>{let j;try{j=JSON.parse(s)}catch(e){process.exit(1)}if(!Array.isArray(j))process.exit(1);const have=new Set(j.map((l)=>l&&l.label?String(l.label.id):""));process.stdout.write(process.argv.slice(1).filter((id)=>!have.has(id)).join(" "))})' $labels)" || {
        echo "Error: board $board lists of $enc are not a JSON array" >&2; return 1; }
    [[ -z "$missing" ]] || {
        echo "Error: board $board of $enc has no list for status label id(s): $missing" >&2; return 1; }
}

gl_check_board() {
    local repo="${1:?repo required}" enc id
    enc="$(_gl_enc "$repo")"
    id="$(glab api "projects/$enc/boards" | _gl_first_id)" || return 2
    [[ -n "$id" ]] || return 1
    _gl_board_lists_complete "$enc" "$id"
}

gl_ensure_board() {
    local repo="${1:?repo required}" enc board labels lid
    enc="$(_gl_enc "$repo")"
    board="$(glab api "projects/$enc/boards" | _gl_first_id)" || board=""
    if [[ -z "$board" ]]; then
        board="$(glab api "projects/$enc/boards" -X POST -f "name=Issues" | _gl_first_id)" || board=""
        [[ -n "$board" ]] || { echo "Error: glab could not create an issue board for $repo" >&2; return 1; }
        echo "created issue board $board for $repo"
    else
        echo "reusing issue board $board for $repo"
    fi
    labels="$(_gl_status_label_ids "$enc")" || {
        echo "Error: glab could not read the labels of $repo" >&2; return 1; }
    for lid in $labels; do
        glab api "projects/$enc/boards/$board/lists" -X POST -f "label_id=$lid" >/dev/null ||
            echo "warn: board list for label $lid not created (it may already exist)" >&2
    done
    _gl_board_lists_complete "$enc" "$board" || return 1
    echo "Content Date: GitLab has no counterpart field — skip"
    return 0
}
