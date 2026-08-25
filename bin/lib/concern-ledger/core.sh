#!/usr/bin/env bash
# bin/lib/concern-ledger/core.sh — value layer (text normalization, SLOT/DISCRIM hashes, severity, completeness); sourced by bin/lib/concern-ledger.sh.

# The path/publish primitives this module and its siblings build on. `dirname`
# is the one place an external split is unavoidable: _sp_dirname is defined by
# the very file this line locates, and ${BASH_SOURCE[0]} is bash's own answer
# for where this script lives — not caller input (round 10 C2 exception 2).
_CL_SAFE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/safe-plans-path.sh"
if [ ! -f "$_CL_SAFE_LIB" ]; then
    printf 'concern-ledger: required library not found at %s — incomplete installation\n' "$_CL_SAFE_LIB" >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=../safe-plans-path.sh
if ! source "$_CL_SAFE_LIB"; then
    printf 'concern-ledger: failed to load %s\n' "$_CL_SAFE_LIB" >&2
    return 1 2>/dev/null || exit 1
fi

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

# ---------------------------------------------------------------------------
# Discovery — enumerating staging files without pathname expansion
# ---------------------------------------------------------------------------

# _cl_sort0 — LC_ALL=C byte order for a NUL-delimited stream, with no external
# `sort`: `sort -z` is a GNU/BSD extension and a `cat` fallback is not
# deterministic, while callers do depend on order (reduce.sh takes the last
# file declaring a given producer). A path cannot contain NUL, so sorting in
# an array here is NUL-safe and host-independent. NOT an equivalent
# replacement for `compgen -G`: that order followed the caller's LC_COLLATE,
# this one is always LC_ALL=C (round 9 #4).
_cl_sort0() {
    local LC_ALL=C
    local -a a=()
    local x j
    while IFS= read -r -d '' x; do
        j=${#a[@]}
        a+=("$x")
        # `>` inside [[ ]] is a byte-wise string comparison under LC_ALL=C; it
        # does not glob, so the right-hand side needs no quoting for
        # correctness. It is quoted anyway so that a later edit to `==` or `!=`
        # — which DO pattern-match an unquoted right side — cannot turn this
        # into a silent mis-sort (round 10 C5).
        while [ "$j" -gt 0 ] && [[ ${a[j-1]} > "$x" ]]; do
            a[j]=${a[j-1]}
            j=$((j-1))
        done
        a[j]=$x
    done
    # The empty-array guard is load-bearing, not defensive noise (round 10 C1).
    # bash < 4.4 — RHEL/CentOS 7 ships 4.2 — treats "${a[@]}" on an empty array
    # as unbound, and this function inherits `set -u` from bin/concern-ledger.
    # Without it a zero-match round kills the subshell while the caller still
    # sees rc 0 and no output: #2088's own failure mode, reintroduced by its
    # own fix. `${#a[@]}` is safe on an empty array even in 4.2.
    [ "${#a[@]}" -gt 0 ] || return 0
    for x in "${a[@]}"; do printf '%s\0' "$x"; done
    return 0
}

# ---------------------------------------------------------------------------
# The discovery failure channel
# ---------------------------------------------------------------------------

# Three readers consume the helper below through
# `done < <(_cl_list_pattern_files ...)`. That is a subshell: after the loop
# `$?` is the loop's own, and a variable the helper set is gone with the fork
# (verified, not assumed). So a failed `find` reached every caller as "this
# round staged nothing", and the round was reduced and published as if it had
# been read (#2025 C6). A file is the one channel that survives the fork: the
# caller opens one before the loop and reads the verdict back after it.
CL_DISCOVERY_FLAG=""

# _cl_discovery_arm — open the channel; one is armed at a time, and no caller
# nests two discovery loops. A caller that cannot open it must refuse the round:
# an unarmed channel reports every failure as a success, which is the bug.
_cl_discovery_arm() {
    _cl_discovery_disarm
    CL_DISCOVERY_FLAG="$(mktemp 2>/dev/null)" || { CL_DISCOVERY_FLAG=""; return 1; }
    return 0
}

# _cl_discovery_failed — rc 0 when the discovery run since the last arm could
# not read its directory. An unarmed channel answers "nothing recorded", which
# is why arming is checked at the call site rather than here.
_cl_discovery_failed() {
    [ -n "${CL_DISCOVERY_FLAG:-}" ] || return 1
    [ -s "$CL_DISCOVERY_FLAG" ]
}

# _cl_discovery_disarm — close the channel. Paired with every arm, so a verdict
# left by an earlier round can never be read as this round's.
_cl_discovery_disarm() {
    [ -n "${CL_DISCOVERY_FLAG:-}" ] && rm -f -- "$CL_DISCOVERY_FLAG" 2>/dev/null
    CL_DISCOVERY_FLAG=""
    return 0
}

# _cl_discovery_note <dir> <status> — one stderr line naming the mechanism,
# plus the record an armed caller reads back. It names the *listing* and not the
# round: "nothing staged yet" is a normal retryable state for these callers and
# "the directory could not be read" is not, so the two may never be reported in
# the same words.
_cl_discovery_note() {
    printf 'concern-ledger: discovery failed: could not list %s (%s); refusing to report the round as empty\n' \
        "$1" "$2" >&2
    [ -n "${CL_DISCOVERY_FLAG:-}" ] || return 0
    printf '%s|%s\n' "$2" "$1" >> "$CL_DISCOVERY_FLAG" 2>/dev/null || true
    return 0
}

# _cl_list_pattern_files <pattern> — the directory entries matching <pattern>,
# NUL-delimited, LC_ALL=C ordered. The pattern is never handed to shell
# pathname expansion: the directory component is find's start point and is
# taken literally, so a backslash in it is a path character and not a glob
# escape (a Windows plans-dir made `compgen -G` match nothing, #2088). Only the
# basename component is pattern-matched, by find's own -name. A directory
# component holding glob metacharacters is the named unsupported case.
# A directory that cannot be stat'd, and any stage of the pipeline that fails,
# are refused (rc 3) rather than returned as an empty directory — see the
# channel above. Empty output *with* rc 0 is the only "nobody staged anything".
_cl_list_pattern_files() {
    local pat="$1" dir base f bn
    local -a st=()
    # Split via the shared path-shape helpers, not a local */* case (round 8
    # #4): they treat '\' as a separator only in a Windows-shaped path, so
    # 'C:\plans/sess-*.txt' splits at its final separator of either kind while
    # a POSIX name containing a backslash keeps it as an ordinary character —
    # which this bug's own Linux fixture depends on. One rule (CPR-SSOT).
    dir="$(_sp_dirname "$pat")"
    base="$(_sp_basename "$pat")"
    # A directory that is not there — or cannot be stat'd — is not a round
    # nobody staged. Returning 0 here made the two indistinguishable, and the
    # consumers then reduced, finalized and published over a ledger whose round
    # they had never read: #2088's silent loss reached through the fix's own
    # early exit.
    if [ ! -d "$dir" ]; then
        _cl_discovery_note "$dir" "not a readable directory"
        return 3
    fi
    # find's default -P never follows a symlink, including one used as the
    # start point itself; -mindepth 1 then suppresses that link (its only
    # depth-0 entry), so a symlinked plans dir would silently yield zero
    # matches at rc 0 — the exact #2088 failure mode, for a directory
    # `[ -d "$dir" ]` above already reports as real. A trailing slash forces
    # the OS-level lookup through the link without changing -P's treatment
    # of any symlink found while walking.
    case "$dir" in */) ;; *) dir="$dir/" ;; esac
    # './' rather than '--': BSD/macOS find takes '--' as a literal path operand
    # instead of an option terminator, so the old spelling made discovery fail
    # unconditionally off GNU. The prefix is what actually keeps a dash-leading
    # directory from being read as an option, which is all '--' was there for.
    case "$dir" in -*) dir="./$dir" ;; esac
    # The reader is the pipeline's last stage rather than `< <( )` so that find's
    # status lands in *this* shell, where it can still become a return value
    # (#2025 C6). All three stages are read from PIPESTATUS on the line straight
    # after the pipeline: `$?` there is only the last stage's, and a sort or
    # output stage that dies truncates the listing exactly as a failed find does.
    # The loop sets nothing that has to outlive the subshell — it only writes to
    # stdout.
    # -type f: without it a symlink planted under a delta file name is returned
    # here, and every consumer's `[ -f "$f" ]` follows it and reads the target's
    # bytes into the published ledger.
    find "$dir" -maxdepth 1 -mindepth 1 -name "$base" -type f -print0 2>/dev/null \
        | _cl_sort0 \
        | while IFS= read -r -d '' f; do
              # find always joins its start point and the entry with '/', so
              # this split is find's contract rather than a re-implemented path
              # rule (round 10 C2 exception 3).
              bn="${f##*/}"
              # Pathname expansion never lets a leading '*' match a dotfile;
              # find does. Keep the old visibility rule so the swap changes
              # nothing but the escape semantics.
              case "$bn" in
                  .*) case "$base" in .*) ;; *) continue ;; esac ;;
              esac
              printf '%s\0' "$f"
          done
    st=("${PIPESTATUS[@]}")
    if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ] || [ "${st[2]}" -ne 0 ]; then
        _cl_discovery_note "$dir" "find/sort/read exited ${st[0]}/${st[1]}/${st[2]}"
        return 3
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Untrusted-input guards
# ---------------------------------------------------------------------------

# _cl_reject_bad_tokens <caller> <token>... — rc 2 and a named diagnostic when
# any token may not be pasted into a derived path. Refusing where the name is
# built keeps a traversal out of every file the subsystem writes, rather than
# relying on each writer to notice (#2025 C3).
_cl_reject_bad_tokens() {
    local caller="$1"; shift
    local t
    for t in "$@"; do
        if ! sp_valid_token "$t"; then
            printf 'concern-ledger: %s: refusing to build a path from %s\n' \
                "$caller" "$(printf '%q' "$t")" >&2
            return 2
        fi
    done
    return 0
}

# _cl_defang_untrusted — stdin→stdout. Neutralises reviewer-forgeable sentinels
# once (CPR-SSOT/CPR-E2C; siblings: bin/review-code-codex:459-460,
# bin/review-loop-summarize-concerns' sanitize()). Loops to a fixed point (t
# branch) so nested decoys can't reassemble after one pass, and the reason
# class is `.*` (not `[^>]*`) to stay a superset of hooks/lib/sentinel-
# patterns.js's greedy RESET_FROM_LOOKSLIKE_RE (#2025 security-scanner F1).
_cl_defang_untrusted() {
    sed -E \
        -e 's/\[PRIOR CONCERNS START\]/(PRIOR CONCERNS START)/g' \
        -e 's/\[PRIOR CONCERNS END\]/(PRIOR CONCERNS END)/g' \
        -e 's/\[DIFF START\]/(DIFF START)/g' \
        -e 's/\[DIFF END\]/(DIFF END)/g' \
        -e ':lp' \
        -e 's/<<(WORKFLOW_[A-Z_]+.*|DETAIL_SKIPPABLE_BY_PLANNER:.*)>>//g' \
        -e 'tlp'
}

# _cl_placehold_empty_concerns — keep the concern, replace the text.
# Round 7 #2: the awk has already built "- <id> [<sev>] <text>" when the
# defanger runs, so a sentinel-only <text> leaves the husk "- C1 [HIGH] " —
# non-empty, so [ -n "$body" ] would open a PRIOR block that says nothing.
# Round 8 #2: deleting that husk is worse. The ID is the ledger's only handle
# on the concern; a reviewer who never sees C1 cannot restate it, and the next
# COMPLETE round then reads "not restated" as "resolved". The replacement is
# static — no delimiter, sentinel, '|' or bracket — so it is neither
# re-defanged nor mistaken for a field break. One record is one line, and a
# continuation line would not start with '- ', so this errs toward keeping.
_cl_placehold_empty_concerns() {
    sed -E 's/^(- [^ ]+ \[[^]]*\])[[:space:]]*$/\1 (text withheld: this concern was recorded with control-sentinel text only; reference the ID and restate it)/'
}

:  # load-success rc for the entrypoint's source check

