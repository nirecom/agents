#!/usr/bin/env bash
# bin/lib/concern-ledger/core.sh — value layer (text normalization, SLOT/DISCRIM hashes, severity, completeness); sourced by bin/lib/concern-ledger.sh.

# ---------------------------------------------------------------------------
# String helpers
# ---------------------------------------------------------------------------
_cl_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_cl_lower() { printf '%s' "${1,,}"; }

# _cl_norm <text> — case-folded, whitespace-collapsed, trimmed. Kept free of
# subprocesses: a reduce round computes hundreds of keys.
_cl_norm() {
    local -a w=()
    read -r -a w <<< "${1,,}"
    printf '%s' "${w[*]}"
}

declare -gA CL_HASH_CACHE=()

# cl_sha256 <text> — lowercase hex digest, portable across the usual toolchains.
cl_sha256() {
    if [ -n "${CL_HASH_CACHE[$1]+x}" ]; then
        printf '%s' "${CL_HASH_CACHE[$1]}"
        return 0
    fi
    local out=""
    if [ -z "${CL_SHA_TOOL:-}" ]; then
        if command -v sha256sum >/dev/null 2>&1; then CL_SHA_TOOL=sha256sum
        elif command -v shasum >/dev/null 2>&1; then CL_SHA_TOOL=shasum
        elif command -v openssl >/dev/null 2>&1; then CL_SHA_TOOL=openssl
        else CL_SHA_TOOL=cksum
        fi
    fi
    case "$CL_SHA_TOOL" in
        sha256sum) out="$(sha256sum <<< "$1" 2>/dev/null)" ;;
        shasum)    out="$(shasum -a 256 <<< "$1" 2>/dev/null)" ;;
        openssl)   out="$(openssl dgst -sha256 <<< "$1" 2>/dev/null)"; out="${out##*= }" ;;
        *)
            local a b
            a="$(cksum <<< "$1" 2>/dev/null)"; a="${a%% *}"
            b="$(cksum <<< "cl:$1" 2>/dev/null)"; b="${b%% *}"
            out="$(printf '%08x%08x' "$((a % 4294967296))" "$((b % 4294967296))")"
            ;;
    esac
    out="${out%% *}"
    out="${out,,}"
    CL_HASH_CACHE[$1]="$out"
    printf '%s' "$out"
}

# cl_slot <path> <anchor> <category> — 8 lowercase hex; the review "address".
cl_slot() {
    local p="$1" a="$2" c="$3" h
    p="${p//\\//}"
    while [ "${p#./}" != "$p" ]; do p="${p#./}"; done
    p="$(_cl_norm "$p")"
    a="$(_cl_norm "$a")"
    c="$(_cl_norm "$c")"
    h="$(cl_sha256 "$p|$a|$c")"
    printf '%s' "${h:0:8}"
}

# cl_slot_body <text> — 'b' + 8 hex; the slot of a concern that has no anchor.
# The prefix is what guarantees it can never collide with an anchor slot.
cl_slot_body() {
    local h
    h="$(cl_sha256 "body:$(_cl_norm "$1")")"
    printf 'b%s' "${h:0:8}"
}

# cl_discrim <text> — 8 hex over the case-folded, token-sorted text. Frozen at
# first observation, so a reworded restatement deliberately does NOT match.
cl_discrim() {
    local LC_ALL=C
    local -a w=()
    read -r -a w <<< "${1,,}"
    local i j key h
    for ((i = 1; i < ${#w[@]}; i++)); do
        key="${w[i]}"; j=$((i - 1))
        while [ "$j" -ge 0 ] && [[ "${w[j]}" > "$key" ]]; do
            w[j + 1]="${w[j]}"; j=$((j - 1))
        done
        w[j + 1]="$key"
    done
    h="$(cl_sha256 "${w[*]}")"
    printf '%s' "${h:0:8}"
}

_cl_sev_rank() {
    case "$1" in HIGH) printf 3 ;; MEDIUM) printf 2 ;; LOW) printf 1 ;; *) printf 0 ;; esac
}

_cl_sev_max() {
    if [ "$(_cl_sev_rank "$1")" -ge "$(_cl_sev_rank "$2")" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# _cl_label_min <a> <b> — COMPLETE > PARTIAL > ABSENT.
_cl_label_rank() {
    case "$1" in COMPLETE) printf 3 ;; PARTIAL) printf 2 ;; *) printf 1 ;; esac
}
_cl_label_min() {
    if [ "$(_cl_label_rank "$1")" -le "$(_cl_label_rank "$2")" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
_cl_delta_header() { head -1 "$1" 2>/dev/null; }

# cl_exec_completeness <exec-label> — the 3-valued projection of the reviewer's
# own execution marker. Already-projected values pass through unchanged.
cl_exec_completeness() {
    case "$1" in
        PERFORMED|COMPLETE) printf 'COMPLETE' ;;
        TRUNCATED|PARTIAL|BASE-*) printf 'PARTIAL' ;;
        *) printf 'ABSENT' ;;
    esac
}

# cl_declared_producers <format> — the producers a complete round must contain.
# An empty list means "whatever single producer staged this round".
cl_declared_producers() {
    case "$1" in
        review-security-shared) printf 'review-code-codex\nsecurity-scanner\n' ;;
        *) : ;;
    esac
}

# cl_admission <format> <round> — open | closed
cl_admission() {
    [ "${2:-1}" -le 1 ] && { printf 'open'; return; }
    case "$1" in
        review-security-shared) printf 'open' ;;
        *) printf 'closed' ;;
    esac
}

