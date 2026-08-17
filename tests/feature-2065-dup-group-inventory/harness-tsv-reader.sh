# Harness: TSV reader, escape codec, verdict extractors (#2065)
# Tests: bin/lib/test-dup-group.sh
# Tags: TL2, audit-tests, dup-groups, tsv, harness, scope:issue-specific
# Sourced first by tests/feature-2065-dup-group-inventory.sh — no cases here.

# TSV readers
# Column contract (S2): axis <TAB> key <TAB> count <TAB> files, preceded by a
# `#`-prefixed column-name comment that consumers skip. Keys and file names are
# escaped, so they travel through the environment rather than `awk -v` (which
# would re-interpret their backslash escapes).

row_field() { # <output> <axis> <key> <colnum>
    TDG_A="$2" TDG_K="$3" TDG_C="$4" awk -F'\t' '
        substr($0,1,1)=="#" { next }
        $1==ENVIRON["TDG_A"] && $2==ENVIRON["TDG_K"] { print $(ENVIRON["TDG_C"]+0); exit }
    ' <<< "$1"
}
row_count() { row_field "$1" "$2" "$3" 3; }
row_files() { row_field "$1" "$2" "$3" 4; }
row_exists() { if [[ -n "$(row_field "$1" "$2" "$3" 1)" ]]; then echo yes; else echo no; fi; }

axis_keys() { # <output> <axis> — keys in emitted order
    TDG_A="$2" awk -F'\t' 'substr($0,1,1)=="#"{next} $1==ENVIRON["TDG_A"]{print $2}' <<< "$1"
}
axis_row_count() { axis_keys "$1" "$2" | grep -c . || true; }

bad_col_rows() { # <output> — data rows whose column count is not 4
    awk -F'\t' 'substr($0,1,1)=="#"{next} NF==0{next} $0==""{next} NF!=4{n++} END{print n+0}' <<< "$1"
}

# ── Escape codec (reverses the S2 transform: \\ \t \n \r \, ) ───────────────

decode_element() { # <escaped-element> -> raw
    local s="$1" out="" i=0 c n
    while (( i < ${#s} )); do
        c="${s:i:1}"
        if [[ "$c" == "\\" ]]; then
            n="${s:i+1:1}"
            case "$n" in
                t) out+=$'\t' ;;
                n) out+=$'\n' ;;
                r) out+=$'\r' ;;
                *) out+="$n" ;;
            esac
            i=$((i + 2))
        else
            out+="$c"; i=$((i + 1))
        fi
    done
    printf '%s' "$out"
}

esc_count() { # <escaped-csv> -> element count
    local s="$1" i=0 n=1 c
    [[ -z "$s" ]] && { printf '0'; return 0; }
    while (( i < ${#s} )); do
        c="${s:i:1}"
        if [[ "$c" == "\\" ]]; then i=$((i + 2)); continue; fi
        [[ "$c" == "," ]] && n=$((n + 1))
        i=$((i + 1))
    done
    printf '%s' "$n"
}

esc_nth() { # <escaped-csv> <1-based-index> -> decoded element
    local s="$1" want="$2" i=0 idx=1 cur="" c
    while (( i < ${#s} )); do
        c="${s:i:1}"
        if [[ "$c" == "\\" ]]; then cur+="${s:i:2}"; i=$((i + 2)); continue; fi
        if [[ "$c" == "," ]]; then
            if (( idx == want )); then decode_element "$cur"; return 0; fi
            idx=$((idx + 1)); cur=""; i=$((i + 1)); continue
        fi
        cur+="$c"; i=$((i + 1))
    done
    if (( idx == want )); then decode_element "$cur"; fi
}

esc_members() { # <escaped-csv> — one decoded element per line (newline-free names)
    local s="$1" n i
    [[ -z "$s" ]] && return 0
    n="$(esc_count "$s")"
    for ((i = 1; i <= n; i++)); do esc_nth "$s" "$i"; printf '\n'; done
}

# ── Verdict extractors ──────────────────────────────────────────────────────

# _has_member — predicate form (exit status only), used by the extractors below.
_has_member() { # <output> <axis> <key> <relpath>
    local files n i
    files="$(row_field "$1" "$2" "$3" 4)"
    [[ -z "$files" ]] && return 1
    n="$(esc_count "$files")"
    for ((i = 1; i <= n; i++)); do
        [[ "$(esc_nth "$files" "$i")" == "$4" ]] && return 0
    done
    return 1
}

# row_has_member — assertable form: prints yes/no so cases can compare values.
row_has_member() { if _has_member "$@"; then echo yes; else echo no; fi; }

# file_skip_reason <output> <relpath> -> reason token, or "" when not skipped
file_skip_reason() {
    local out="$1" rel="$2" key
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if _has_member "$out" skip "$key" "$rel"; then printf '%s' "$key"; return 0; fi
    done < <(axis_keys "$out" skip)
    printf ''
}

# file_group_axes <output> <relpath> -> "" | full | token | full,token
file_group_axes() {
    local out="$1" rel="$2" axis key res=""
    for axis in full token; do
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            if _has_member "$out" "$axis" "$key" "$rel"; then res="${res:+$res,}$axis"; break; fi
        done < <(axis_keys "$out" "$axis")
    done
    printf '%s' "$res"
}

# verdict_of <output> <relpath> -> skip reason token, or "ok"
verdict_of() {
    local r; r="$(file_skip_reason "$1" "$2")"
    if [[ -n "$r" ]]; then printf '%s' "$r"; else printf 'ok'; fi
}

# skip_members_all <output> — every file listed by every skip row, one per line
skip_members_all() {
    local out="$1" key files
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        files="$(row_field "$out" skip "$key" 4)"
        [[ -z "$files" ]] && continue
        esc_members "$files"
    done < <(axis_keys "$out" skip)
}

# re_escape — quote a literal for use inside a sed address/pattern.
re_escape() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|/]/\\&/g'; }
