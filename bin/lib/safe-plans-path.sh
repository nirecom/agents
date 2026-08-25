#!/usr/bin/env bash
# bin/lib/safe-plans-path.sh
# Deriving, creating, publishing and deleting files inside the plans dir (#2025
# C6/C8/C9). Dependency-free and side-effect-free at source time: five callers
# source it and only one loads the ledger library, so a fix written against that
# library instead of this one would land in one caller out of five.

# --- token validation -------------------------------------------------------

# sp_valid_token <value> — true for a value that may be pasted into a derived
# path inside the plans dir. Rejects separators (/ and \), '..', a leading '-'
# (read as an option downstream), the empty string, a bare '.' (it names a
# directory), and every character outside [A-Za-z0-9._-].
sp_valid_token() {
    case "${1-}" in
        ''|.|-*) return 1 ;;
        *..*|*/*|*\\*) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

# --- path shape -------------------------------------------------------------

# _sp_is_winpath <path> — true for a drive-qualified or UNC path. '\' counts as
# a separator only there: on POSIX it is a legal filename character, and this
# bug's own Linux fixture creates a directory literally named 'a\b'. Splitting
# at '/' alone was the round-8 #4 defect — a pure-backslash --output put the
# temp in the *calling* directory, so the publishing rename quietly stopped
# being atomic. Named, bounded exception (CPR-UNV): a drive-relative '\foo' is
# not supported and is never produced here.
_sp_is_winpath() {
    case "${1-}" in
        [A-Za-z]:[/\\]*|[A-Za-z]:|\\\\*) return 0 ;;
    esac
    return 1
}

# _sp_strip_sep <path> — <path> minus one trailing separator; a bare root is
# left as it is.
_sp_strip_sep() {
    local p="${1-}"
    case "$p" in /|\\) printf '%s\n' "$p"; return 0 ;; esac
    if _sp_is_winpath "$p"; then p="${p%[/\\]}"; else p="${p%/}"; fi
    printf '%s\n' "$p"
}

# _sp_dirname <path> / _sp_basename <path> — the halves of <path>, split at its
# final separator under the rule above. Implemented here rather than shelling
# out to dirname(1)/basename(1) so the ledger library and the standalone
# scripts share one rule, and so a path with no separator answers '.' the way
# dirname does. A destination is always a file inside a directory, so a bare
# drive root is a degenerate input rather than a supported one.
_sp_dirname() {
    local p d
    p="$(_sp_strip_sep "${1-}")"
    if _sp_is_winpath "$p"; then
        case "$p" in *[/\\]*) d="${p%[/\\]*}" ;; *) d="." ;; esac
    else
        case "$p" in */*) d="${p%/*}" ;; *) d="." ;; esac
    fi
    case "$d" in
        '') d="/" ;;
        [A-Za-z]:) d="$d\\" ;;
    esac
    printf '%s\n' "$d"
}

_sp_basename() {
    local p
    p="$(_sp_strip_sep "${1-}")"
    if _sp_is_winpath "$p"; then
        printf '%s\n' "${p##*[/\\]}"
    else
        printf '%s\n' "${p##*/}"
    fi
}

# --- exclusive creation -----------------------------------------------------

# sp_mktemp_beside <dest> — an exclusively created, mode-0600, unpredictable
# temporary file in dest's own directory; prints its path. Same directory so
# the publishing rename stays inside one filesystem and stays atomic. mktemp
# opens with O_EXCL, so a pre-placed symlink cannot be followed. Never build a
# temp name from $$: the PID is predictable and `: > name` follows a symlink to
# whatever the attacker chose (#2025 C6). mktemp does not promise a private
# mode on every platform, so the mode is pinned here; on a filesystem with no
# POSIX modes the chmod is a no-op that still reports success — the named
# CPR-UNV exception rather than a silent assumption.
sp_mktemp_beside() {
    local d f
    # _sp_dirname, not dirname(1) (round 8 #4): dirname splits at '/' only, so
    # a pure-backslash destination would put the temp in the *calling*
    # directory and the publishing rename would quietly stop being
    # same-filesystem — and stop being atomic — without ever failing.
    d="$(_sp_dirname "$1")"
    # -- before the template: a dash-leading plans dir would otherwise reach
    # mktemp as an option rather than a path (#2025 C14).
    f="$(mktemp -- "$d/.sp-tmp.XXXXXXXX" 2>/dev/null)" || return 1
    chmod 600 "$f" 2>/dev/null || { rm -f "$f" 2>/dev/null; return 1; }
    printf '%s\n' "$f"
}

# --- publishing -------------------------------------------------------------

# sp_publish_file_keep <tmp> <dest> — the publish primitive: rename an
# already-written temp over dest, reporting success only when dest really ends
# up holding it. On failure the temp is NOT destroyed — the path where its
# bytes are still readable is printed on stdout — because cl_write_json has a
# recovery duty over exactly those bytes (round 6 #1). rename(2) replaces a
# symlink at dest rather than following it, but cannot express "refuse a
# directory": it moves the temp *inside* and still exits 0, which `set -e`
# never catches. So the verdict is the post-condition after the rename, and
# the pre-check below is containment only, not the verdict.
sp_publish_file_keep() {
    local tmp="$1" dest="$2" base
    base="$(_sp_basename "$1")"
    # Refuse before renaming (round 8 #1): against a *pre-placed* directory —
    # or a symlink to one, which -d follows — the rename is what does the
    # damage. It parks a 0600 file of ledger content inside a directory the
    # attacker chose, and pulling it back cannot un-expose it. Pre-placing
    # needs no concurrent write access, so it is inside this PR's threat model.
    # A symlink to a regular file is left to the rename, which replaces the
    # link rather than writing through it.
    if [ -d "$dest" ]; then
        [ -f "$tmp" ] && printf '%s\n' "$tmp"
        return 1
    fi
    if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
        # The rename never happened, so the temp is untouched where it was.
        [ -f "$tmp" ] && printf '%s\n' "$tmp"
        return 1
    fi
    if [ -h "$dest" ] || [ ! -f "$dest" ]; then
        # dest was, or became, a directory: mv parked our temp inside it. Pull
        # it back rather than leave a 0600 copy of ledger content in a
        # directory we do not control — and pulling it back, rather than
        # deleting it, is what keeps the bytes available to a caller that still
        # has to recover them. The name moved is our own unpredictable temp
        # name, never one the attacker chose. If it cannot be pulled back,
        # delete it and report no kept copy: leaking is worse than losing here.
        if mv -f -- "$dest/$base" "$tmp" 2>/dev/null && [ -f "$tmp" ]; then
            printf '%s\n' "$tmp"
        else
            rm -f -- "$dest/$base" 2>/dev/null
        fi
        return 1
    fi
    return 0
}

# sp_publish_file <tmp> <dest> — sp_publish_file_keep for the callers that have
# no recovery duty: the same contract, plus the temp is removed on failure so
# no caller has to remember to. Callers that must inspect the temp *before*
# publishing (cl_stage's non-empty check) call this directly; the one caller
# that must read it *after* a failed publish (cl_write_json) calls _keep.
sp_publish_file() {
    local kept
    kept="$(sp_publish_file_keep "$1" "$2")" && return 0
    [ -n "$kept" ] && rm -f -- "$kept" 2>/dev/null
    return 1
}

# sp_publish_copy <src> <dest> — src's bytes at dest, without ever writing
# *through* dest.
sp_publish_copy() {
    local src="$1" dest="$2" tmp
    tmp="$(sp_mktemp_beside "$dest")" || return 1
    cp "$src" "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
    sp_publish_file "$tmp" "$dest"
}

# sp_publish_stdin <dest> — stdin's bytes at dest, same guarantees. This is the
# replacement for every `printf ... > "$plans_dir_path"` and `: > "$marker"`:
# a plain redirect follows a symlink pre-placed at a predictable name and
# truncates whatever it points at (#2025 C6, round 4 #2).
sp_publish_stdin() {
    local dest="$1" tmp
    tmp="$(sp_mktemp_beside "$dest")" || return 1
    cat > "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
    sp_publish_file "$tmp" "$dest"
}

# --- containment ------------------------------------------------------------

# sp_real_dir <dir> — <dir> with every symlink component resolved, printed in
# whatever shape `pwd -P` uses on this host. Every comparison in this file puts
# *both* sides through this function (or through the same `cd -P` walk), so the
# msys/Windows path-shape rewrite cancels out instead of producing a false
# verdict — which is why `realpath` was rejected earlier. Empty output and rc 1
# when the directory cannot be entered: a path we cannot resolve is not a path
# we may judge contained. The redirection sits on the subshell rather than on
# `cd` so the single resolution reads as one expression — the shape pinned by
# tests/fix-2025-safe-plans-path.sh.
sp_real_dir() {
    [ -n "${1-}" ] || return 1
    ( cd -P -- "$1" && pwd -P ) 2>/dev/null || return 1
}

# _sp_deref <path> — <path> with its own final-component symlink chain followed;
# rc 1 when that chain cannot be read or does not terminate. Only the last
# component: the parents belong to the `cd -P` walks below.
_sp_deref() {
    local p="${1-}" t i=0
    while [ -h "$p" ]; do
        i=$((i + 1))
        [ "$i" -le 40 ] || return 1
        t="$(readlink -- "$p" 2>/dev/null)" || return 1
        [ -n "$t" ] || return 1
        if [ "${t#/}" != "$t" ] || _sp_is_winpath "$t"; then
            p="$t"
        else
            p="$(_sp_dirname "$p")/$t"
        fi
    done
    printf '%s\n' "$p"
}

# _sp_has_dotdot <rest> <win> — true when a path *component* of <rest> is
# literally '..'. <win> is 1 when '\' is a separator in <rest>, in which case
# the backslashes are folded to '/' first so one scan covers both shapes; on
# POSIX they are ordinary name characters and must not be folded. Wrapping the
# string in separators turns "is some component exactly '..'" into a single
# glob, so user..name and a..b.txt are left alone.
_sp_has_dotdot() {
    local rest="${1-}"
    [ "${2-}" = 1 ] && rest="${rest//\\//}"
    case "/$rest/" in */../*) return 0 ;; esac
    return 1
}

# _sp_lexical_gate <path> <dir> — the filesystem-free half of containment: the
# separator after the prefix is the whole point (a bare prefix test also
# matches the sibling /plans-evil when dir is /plans), and no component the
# caller appended after <dir> may be '..'. Which separator counts follows
# _sp_is_winpath (round 8 #4). Only the part *after* <dir> is scanned for '..'
# (round 9 #3): the old whole-string match refused every publish inside a
# perfectly legal "user..name" directory component. <dir> is a complete caller-supplied
# path and deliberately not validated; what must be refused is the relative
# escape a caller appends to it. Containment proper is the physical half.
_sp_lexical_gate() {
    local path="$1" dir rest win=0
    dir="$(_sp_strip_sep "$2")"
    [ -n "$path" ] || return 1
    [ -n "$dir" ] || return 1
    _sp_is_winpath "$dir" && win=1
    case "$path" in "$dir") return 0 ;; esac
    if [ "$win" = 1 ]; then
        case "$path" in "$dir"[/\\]*) rest="${path#"$dir"?}" ;; *) return 1 ;; esac
    else
        case "$path" in "$dir"/*) rest="${path#"$dir"/}" ;; *) return 1 ;; esac
    fi
    # A literal '\' in the appended part is refused on every platform, not only
    # where _sp_is_winpath calls it a separator. On msys/Cygwin with a POSIX-
    # spelled plans dir the detection says win=0 while the OS still splits on
    # '\', so '..' spelled with backslashes was never folded and
    # "$dir/x\..\..\evil.txt" passed this gate before `cd -P` resolved it outside
    # (#2025 C8). sp_valid_token already forbids '\' in every other derived
    # token here, so this is the same rule, not a new one.
    case "$rest" in *\\*) return 1 ;; esac
    _sp_has_dotdot "$rest" "$win" && return 1
    return 0
}

# _sp_real_contains <resolved-dir> <resolved-candidate> — pure string
# comparison of two *already resolved* directories. It never touches the
# filesystem: a helper that resolved anything itself would be a second walk,
# and a second walk is a second chance for a swapped symlink (round 5 #1).
# Which character ends the prefix is decided by the *resolved* path's own shape
# (round 9 #1). Accepting '\' everywhere was a containment hole, not a
# portability nicety: with a sibling directory literally named `plans\evil`,
# $plans/link pointing at it read as "inside plans" and the C6/C8 attacks land.
# On a drive-qualified host both characters really are separators, so this
# stays one rule rather than a platform branch (CPR-UNV).
_sp_real_contains() {
    local rdir="$1" cand="$2"
    [ -n "$rdir" ] || return 1
    [ -n "$cand" ] || return 1
    [ "$cand" = "$rdir" ] && return 0
    if _sp_is_winpath "$rdir"; then
        case "$cand" in "$rdir"[/\\]*) return 0 ;; esac
    else
        case "$cand" in "$rdir"/*) return 0 ;; esac
    fi
    return 1
}

# sp_within_dir <path> <dir> — true only when <path> names an entry inside
# <dir>. Lexical gate first, then the physical one: <path>'s parent directory,
# with every symlink component resolved, must be <dir> resolved the same way.
# The lexical gate alone was the round-4 defect — $plans/link/victim passes a
# textual prefix test while 'link' points outside the plans dir (#2025 C8).
# The final component is deliberately not resolved: `rm` unlinks a symlink
# itself rather than its target, so a symlink sitting at <path> is contained by
# definition. This is the *predicate*; it is not what sp_contained_rm uses to
# authorise a delete — see there for why.
sp_within_dir() {
    local path="$1" dir pdir rdir
    dir="$(_sp_strip_sep "$2")"
    _sp_lexical_gate "$path" "$dir" || return 1
    case "$path" in "$dir") return 0 ;; esac
    pdir="$(sp_real_dir "$(_sp_dirname "$path")")" || return 1
    rdir="$(sp_real_dir "$dir")" || return 1
    _sp_real_contains "$rdir" "$pdir"
}

# sp_contained_rm <path> <dir> — delete <path> only when it physically sits in
# <dir>. rc 0 = judged contained and rm ran; rc 1 = refused, nothing deleted.
# It deliberately does NOT call sp_within_dir: that resolves the parent once
# for the verdict and again for the unlink, and an attacker who swaps an
# intermediate symlink between the two gets a delete outside the plans dir with
# a "contained" verdict attached (round 5 #1) — the attack C8 exists to stop.
# Here the parent is resolved exactly once and that one resolution is held
# open: in POSIX shell the working directory *is* the open directory
# descriptor, so `pwd -P` judges the pinned inode and `rm` names an entry
# relative to it. Nothing in between re-walks a path string.
sp_contained_rm() {
    local path="$1" dir base rdir
    dir="$(_sp_strip_sep "$2")"
    _sp_lexical_gate "$path" "$dir" || return 1
    # Deleting is the irreversible half, so an unjudgeable path is always
    # refused, and <path> == <dir> is refused outright: the plans dir is not
    # its own entry.
    case "$path" in "$dir") return 1 ;; esac
    base="$(_sp_basename "$path")"
    case "$base" in ''|.|..) return 1 ;; esac
    rdir="$(sp_real_dir "$dir")" || return 1
    # The subshell scopes the `cd` — the caller's working directory is never
    # disturbed — and its exit status carries the verdict back. Nothing else
    # crosses out, which is why this function returns no path.
    (
        cd -P -- "$(_sp_dirname "$path")" 2>/dev/null || exit 1
        here="$(pwd -P)" || exit 1
        _sp_real_contains "$rdir" "$here" || exit 1
        rm -f -- "$base" 2>/dev/null || exit 1
        exit 0
    ) || return 1
    return 0
}

# --- containment-checked publishing -----------------------------------------

# sp_contained_publish_stdin <dest> <dir> — stdin's bytes at <dest>, but only
# when <dest>'s parent *physically* resolves inside <dir>. rc 0 published;
# rc 2 refused for containment, nothing created anywhere; rc 1 the publish
# itself failed inside a directory judged contained. The two failure codes stay
# distinct because rc 2 is a configuration problem and rc 1 an environment one.
# sp_publish_stdin is not enough for a caller-supplied override: it mktemps
# first, so CL_LEDGER_OVERRIDE under a symlink puts the 0600 temp and the
# ledger text outside the plans dir before containment is asked (round 7 #1).
# Structure matches sp_contained_rm's for the same reason (CPR-ORTH).
sp_contained_publish_stdin() {
    local dest="$1" dir base rdir
    dir="$(_sp_strip_sep "$2")"
    _sp_lexical_gate "$dest" "$dir" || return 2
    case "$dest" in "$dir") return 2 ;; esac
    base="$(_sp_basename "$dest")"
    case "$base" in ''|.|..) return 2 ;; esac
    rdir="$(sp_real_dir "$dir")" || return 2
    # The subshell's status is returned verbatim, never through `|| return 1`:
    # that would flatten rc 2 into rc 1 and merge the two verdicts.
    (
        cd -P -- "$(_sp_dirname "$dest")" 2>/dev/null || exit 2
        here="$(pwd -P)" || exit 2
        _sp_real_contains "$rdir" "$here" || exit 2
        # Contained. From here every name is relative to the pinned directory.
        # The template carries a '/', so mktemp uses it as given and TMPDIR has
        # no say in where this lands.
        tmp="$(mktemp ./.sp-tmp.XXXXXXXX 2>/dev/null)" || exit 1
        chmod 600 "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; exit 1; }
        cat > "$tmp" || { rm -f -- "$tmp" 2>/dev/null; exit 1; }
        sp_publish_file "$tmp" "$base" || exit 1
        exit 0
    )
}

# sp_contained_publish_copy <src> <dest> <dir> — the same, filled from <src>.
# The redirection is performed by *this* shell, before the subshell's `cd`, so
# <src> resolves in the caller's working directory and the subshell inherits an
# already-open descriptor: no path to re-walk, nothing for a swapped symlink to
# re-point, and no need to absolutise <src> — which on msys would mean
# reconciling the drive-letter and mount-point spellings of the same path,
# the very mismatch sp_real_dir avoids. An
# unreadable <src> fails the redirection, having created nothing.
sp_contained_publish_copy() {
    local real
    # That redirection reads *through* <src>'s final-component symlink, which
    # nothing here ever judged: a link sitting *inside* <dir> and pointing out of
    # it copied the target's whole contents into the destination (#2025 C8, the
    # cl_finalize cap-snapshot path). A <src> that does not name itself inside
    # <dir> claims no containment and is copied as before; one that does must
    # physically resolve there. rc 2, the containment refusal, so a caller reads
    # "nothing was written" rather than "the publish failed".
    if _sp_lexical_gate "$1" "$3"; then
        real="$(_sp_deref "$1")" || return 2
        sp_within_dir "$real" "$3" || return 2
    fi
    sp_contained_publish_stdin "$2" "$3" < "$1"
}

:  # load-success rc for callers that source this with an explicit rc check
