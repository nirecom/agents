#!/usr/bin/env bash
# Corpus parse cache for bin/find-tests-for-source.sh (#2455). Sourced only;
# requires bin/lib/run-all-parallelism.sh and bin/lib/test-route-destination.sh
# first. Keyed by git state (constant git calls, never per file); every failure is
# fail-soft and returns what an uncached scan returns. Design:
# docs/architecture/claude-code/test-host-lanes.md.

TCC_SCHEMA=1
TCC_KEEP=16
TCC_DIGEST=""
TCC_STAMP=""
TCC_HIT_FILE=""
TCC_LOGIC_LIBS="test-route-destination.sh test-dup-group.sh test-frontmatter-fix.sh test-frontmatter-constants.sh test-corpus-cache.sh test-language-registry.sh"

# _tcc_bad_chars <string> — 0 when the string holds LF, TAB or CR (not storable).
_tcc_bad_chars() {
    case "$1" in
        *$'\n'*|*$'\t'*|*$'\r'*) return 0 ;;
    esac
    return 1
}

# tcc_key_into <root> — TCC_DIGEST from (a) HEAD:tests, (b) the corpus-path
# status records plus the content hash of each dirty file, (c) the parser libs,
# (d) the registry table and reader, (e) TCC_SCHEMA. At most 4 git calls; 1 = not cacheable.
tcc_key_into() {
    local root="$1" r p k tree=none has_head=1 rc="" rec="" list="" hashes="" logic line n=0 c g globs reg
    local -a specs=() dirty=()
    TCC_DIGEST=""
    [ -e "$root/.git" ] || return 1
    globs="$(tlr_globs case-marker)" && [ -n "$globs" ] || return 1
    for c in "${_TDG_CANONICAL_CATEGORIES[@]}"; do
        while IFS= read -r g; do specs+=(":(glob)tests/$c/$g"); done <<< "$globs"
    done
    while IFS= read -r -d '' r; do
        case "$r" in
            '#tcc-rc='*) rc="${r#'#tcc-rc='}"; continue ;;
            '# branch.oid (initial)') has_head=0; continue ;;
            '# '*) continue ;;
            '1 '*) p="$r"; for ((k = 0; k < 8; k++)); do p="${p#* }"; done ;;
            'u '*) p="$r"; for ((k = 0; k < 10; k++)); do p="${p#* }"; done ;;
            '? '*|'! '*) p="${r:2}" ;;
            *) return 1 ;;
        esac
        _tcc_bad_chars "$p" && return 1
        rec+="$r"$'\n'
        [ -f "$root/$p" ] && dirty+=("$p")
    done < <(git -C "$root" --no-optional-locks status --porcelain=v2 -z --branch --untracked-files=all \
        --ignored=matching --no-renames -- "${specs[@]}" 2>/dev/null; printf '#tcc-rc=%s\0' "$?")
    [ "$rc" = 0 ] || return 1
    if [ "$has_head" -eq 1 ]; then
        tree="$(git -C "$root" rev-parse -q --verify HEAD:tests 2>/dev/null)"
        case "$?" in
            0) ;;
            1) tree=none ;;
            *) return 1 ;;
        esac
    fi
    if [ "${#dirty[@]}" -gt 0 ]; then
        printf -v list '%s\n' "${dirty[@]}"
        hashes="$(git -C "$root" hash-object --no-filters --stdin-paths <<< "${list%$'\n'}" 2>/dev/null)" || return 1
        while IFS= read -r line; do [ -n "$line" ] && n=$((n + 1)); done <<< "$hashes"
        [ "$n" -eq "${#dirty[@]}" ] || return 1
    fi
    # shellcheck disable=SC2086  # TCC_LOGIC_LIBS is a fixed list of plain basenames
    reg="${TCC_REGISTRY_DIR:-$TLR_REGISTRY_DIR}"
    logic="$(git -C "${TCC_LOGIC_DIR:-$_TRD_DIR}" hash-object --no-filters -- $TCC_LOGIC_LIBS \
        "$reg/test-language-registry.json" "$reg/test-language-registry.js" 2>/dev/null)" || return 1
    TCC_DIGEST="$(run_all_id_digest "schema=$TCC_SCHEMA|tree=$tree|status=$rec|dirty=$hashes|logic=$logic")"
    [ -n "$TCC_DIGEST" ] && [ "$TCC_DIGEST" != nodigest ]
}

# _tcc_stamp — TCC_STAMP (%Y%m%dT%H%M%S); the date fork is the bash < 4.2 fallback only.
_tcc_stamp() {
    if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
        printf -v TCC_STAMP '%(%Y%m%dT%H%M%S)T' -1
    else
        TCC_STAMP="$(date +%Y%m%dT%H%M%S)"
    fi
}

# _tcc_lookup <dir> — TCC_HIT_FILE = the newest file carrying TCC_DIGEST, or "".
_tcc_lookup() {
    local LC_ALL=C f
    TCC_HIT_FILE=""
    for f in "$1"/corpus."$TCC_SCHEMA".*."$TCC_DIGEST".tsv; do
        [ -f "$f" ] && TCC_HIT_FILE="$f"
    done
    return 0
}

# _tcc_read <file> <root> — non-evaluating loader (never source/eval). Validates
# the header, every row's ntok against its token count, and the #end count.
_tcc_read() {
    local file="$1" line ntok n=0 ended=0 joined j
    local -a fl=()
    {
        IFS= read -r line || return 1
        [ "$line" = $'#trd-corpus\tschema='"$TCC_SCHEMA" ] || return 1
        _trd_corpus_reset "$2"
        while IFS=$'\t' read -r -a fl; do
            [ "$ended" -eq 0 ] || return 1
            if [ "${fl[0]-}" = "#end" ]; then
                [ "${#fl[@]}" -eq 2 ] && [ "${fl[1]}" = "$n" ] || return 1
                ended=1
                continue
            fi
            [[ ${fl[0]-} =~ ^[0-9]{1,6}$ ]] || return 1
            ntok=$((10#${fl[0]}))
            [ "$ntok" -ge 1 ] && [ "${#fl[@]}" -eq $((ntok + 2)) ] || return 1
            joined="${fl[2]}"
            for ((j = 3; j < ${#fl[@]}; j++)); do joined+=$'\n'"${fl[j]}"; done
            TRD_CORPUS_FILES+=("${fl[1]}")
            TRD_CORPUS_TOKENS+=("$joined")
            TRD_CORPUS_NTOK+=("$ntok")
            n=$((n + 1))
        done
    } 2>/dev/null < "$file"
    [ "$ended" -eq 1 ]
}

# _tcc_write <dir> <damaged-file|""> — atomic tmp + mv publish, then one rm for
# the retention overflow (oldest first by name = stamp) and the damaged file.
_tcc_write() {
    local dir="$1" damaged="$2" body i n="${#TRD_CORPUS_FILES[@]}" tmp name f k
    local -a all=() del=()
    body=$'#trd-corpus\tschema='"$TCC_SCHEMA"$'\n'
    for ((i = 0; i < n; i++)); do
        _tcc_bad_chars "${TRD_CORPUS_FILES[i]}" && return 0
        case "${TRD_CORPUS_TOKENS[i]}" in *$'\t'*|*$'\r'*) return 0 ;; esac
        body+="${TRD_CORPUS_NTOK[i]}"$'\t'"${TRD_CORPUS_FILES[i]}"$'\t'"${TRD_CORPUS_TOKENS[i]//$'\n'/$'\t'}"$'\n'
    done
    body+=$'#end\t'"$n"$'\n'
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
    [ -d "$dir" ] || return 0
    _tcc_stamp
    name="$dir/corpus.$TCC_SCHEMA.$TCC_STAMP.$TCC_DIGEST.tsv"
    tmp="$dir/.tmp.$$.$RANDOM"
    { printf '%s' "$body" > "$tmp"; } 2>/dev/null || return 0
    mv -f "$tmp" "$name" 2>/dev/null || return 0
    local LC_ALL=C
    for f in "$dir"/corpus."$TCC_SCHEMA".*.tsv; do [ -f "$f" ] && all+=("$f"); done
    k=$((${#all[@]} - TCC_KEEP))
    for ((i = 0; i < k; i++)); do [ "${all[i]}" != "$name" ] && del+=("${all[i]}"); done
    [ -n "$damaged" ] && [ "$damaged" != "$name" ] && [ -f "$damaged" ] && del+=("$damaged")
    [ "${#del[@]}" -gt 0 ] && rm -f "${del[@]}" 2>/dev/null
    return 0
}

# tcc_load_corpus_cached <root> — find-tests' only corpus entry point: a hit
# deserializes, a miss scans (trd_load_corpus) and stores. Always 0.
tcc_load_corpus_cached() {
    local root="$1" dir
    if [ "${FIND_TESTS_CORPUS_CACHE:-}" = off ] || ! tcc_key_into "$root"; then
        trd_load_corpus "$root"
        return 0
    fi
    dir="${THL_CACHE_ROOT:-}"
    [ -n "$dir" ] || dir="$(run_all_cache_dir)"
    dir="$dir/corpus"
    _tcc_lookup "$dir"
    if [ -n "$TCC_HIT_FILE" ] && _tcc_read "$TCC_HIT_FILE" "$root"; then return 0; fi
    trd_load_corpus "$root"
    _tcc_write "$dir" "$TCC_HIT_FILE"
    return 0
}
