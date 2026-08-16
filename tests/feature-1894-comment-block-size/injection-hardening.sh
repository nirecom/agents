#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/injection-hardening.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, injection, control-bytes, escaping, spoofing, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 8 — untrusted strings the report PRINTS (third surface, CPR-SC): path (F1)
# and $CODE_FILE_EXTENSIONS (F5) interpolated into stdout. `git ... -z` emits raw
# bytes; the line-oriented grammar (`^WARN: `, `^ERROR: `) lets an LF forge a
# finding and ESC repaint a terminal. Escaping: \xHH uppercase hex; literal `\` stays (SP1 pin).
# Sourced by the dispatcher; every helper and constant is defined there.

ipad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "i_$i=$i"; done; }
icm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

# 0x0A is the report's own line separator, so it is excluded from the class the
# scan looks for; a newline that slipped through unescaped is caught instead by
# the line-count assertions (a forged line changes the counts).
CTRL_CLASS=$'[\001-\011\013-\037\177]'
assert_no_ctrl_bytes() {
    local name="$1" hay="$2" n
    n="$(printf '%s\n' "$hay" | LC_ALL=C grep -c "$CTRL_CLASS" || true)"
    if [ "$n" = "0" ]; then pass "$name"; else fail "$name" "$n output line(s) carry a raw 0x01-0x1F/0x7F byte"; fi
}

# cb_count_re <extended-regex> — how many stdout lines match.
cb_count_re() { printf '%s\n' "$CB_OUT" | grep -cE "$1" || true; }

# stage_blob_path <repo> <path> — record an over-threshold blob in the index at
# exactly the byte sequence <path>, without touching the filesystem. Unlike
# make_special (special-paths.sh, the filesystem route), staged mode reads only
# the index, so this additionally covers hosts whose FILESYSTEM refuses a byte
# git's index accepts (every control byte on Windows/MSYS) — without it that
# finding would never run there. Guard matches make_special's: read the index
# back NUL-delimited and require a byte-identical entry, else SKIP with a reason.
stage_blob_path() {
    local repo="$1" fn="$2" sha entry
    sha="$( { ipad 2; icm 12 note; } | git -C "$repo" hash-object -w --stdin 2>/dev/null )" || return 1
    [ -n "$sha" ] || return 1
    printf '100644 %s\t%s\0' "$sha" "$fn" \
        | git -C "$repo" -c core.protectNTFS=false update-index -z --index-info >/dev/null 2>&1 || return 1
    while IFS= read -r -d '' entry; do
        [ "$entry" = "$fn" ] && return 0
    done < <(git -C "$repo" ls-files -z --)
    return 1
}

# ---------------------------------------------------------------------------
# I1 — a control byte in a staged path never reaches stdout raw (--staged)
# ---------------------------------------------------------------------------
echo ""
echo "=== I1: control bytes in staged paths (F1) ==="
INJP="$(new_repo injpaths)"
{ ipad 2; icm 12 plain; } > "$INJP/a.sh"
git -C "$INJP" add -f a.sh >/dev/null 2>&1

# name | filename  (each forges a different line of the report's own grammar)
I1_STAGED=""
I1_N=1   # a.sh
while IFS='|' read -r name fn; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    fn="${fn# }"
    fn="$(printf '%b' "$fn")"
    if stage_blob_path "$INJP" "$fn"; then
        I1_STAGED="$I1_STAGED$name "
        I1_N=$((I1_N + 1))
    else
        skip "I1/$name: git's index refuses this byte in a path on this host — path escaping unverified for it"
    fi
done <<'TABLE'
plain-newline   | two\nlines.sh
esc             | esc\x1Bfile.sh
forge-warn      | nl-a\nWARN: forged-by-path.sh — longest comment run 99 lines\nnl-b.sh
forge-header    | nl-c\n## Comment-block Size Review: PERFORMED (staged mode)\nnl-d.sh
forge-error     | nl-e\nERROR: forged.sh — staged blob unreadable\nnl-f.sh
TABLE

run_cb "$INJP" -- --staged
cb_expect_rc "I1/staged-rc"
# (a) one WARN line per staged file — no more, no fewer.
assert_eq "I1/staged-warn-count-equals-staged-files" "$I1_N" "$(cb_warn_count)"
# (b) exactly one real header, and no ERROR line at all.
assert_eq "I1/staged-exactly-one-header" "1" "$(cb_count_re '^## Comment-block Size Review')"
assert_eq "I1/staged-no-forged-error-line" "0" "$(cb_count_re '^ERROR:')"
# (c) no raw control byte anywhere on stdout.
assert_no_ctrl_bytes "I1/staged-stdout-has-no-raw-control-byte" "$CB_OUT"
assert_no_ctrl_bytes "I1/staged-stderr-has-no-raw-control-byte" "$CB_ERR"

# Positive escaping contract: \xHH, uppercase hex.
case " $I1_STAGED" in
    *" plain-newline "*)
        assert_contains "I1/newline-renders-as-\\x0A" "$CB_FIND: two\x0Alines.sh" "$CB_OUT" ;;
    *) skip "I1/newline-renders-as-\\x0A: the plain-newline name could not be staged on this host" ;;
esac
case " $I1_STAGED" in
    *" esc "*)
        assert_contains "I1/esc-renders-as-\\x1B" "$CB_FIND: esc\x1Bfile.sh" "$CB_OUT" ;;
    *) skip "I1/esc-renders-as-\\x1B: the ESC name could not be staged on this host" ;;
esac

# ---------------------------------------------------------------------------
# I2 — a literal backslash is data, not an escape (SP1 regression)
# ---------------------------------------------------------------------------
# The escaper introduced for I1 must not start rewriting backslashes: SP1 pins
# `WARN: back\slash.sh` verbatim, and a naive `\` -> `\\` pass would break it.
# Filesystem route on purpose — on Windows `\` is a path separator, so the index
# accepts the name while `git show ":./back\slash.sh"` cannot read it back; that
# is a platform limitation, not the escaping contract, so it must SKIP not FAIL.
echo ""
echo "=== I2: literal backslash stays literal (F1 regression) ==="
BSR="$(new_repo injbackslash)"
if make_special "$BSR" 'back\slash.sh'; then
    run_cb "$BSR" -- --staged
    cb_expect_rc "I2/rc"
    assert_contains "I2/backslash-not-escaped" "$CB_FIND: back\slash.sh" "$CB_OUT"
    assert_absent "I2/backslash-not-doubled" 'back\\slash.sh' "$CB_OUT"
    assert_no_ctrl_bytes "I2/stdout-has-no-raw-control-byte" "$CB_OUT"
else
    skip "I2: this filesystem cannot hold a literal backslash in a filename (Windows path separator) — backslash regression unverified here"
fi

# ---------------------------------------------------------------------------
# I3 — --all walks with the same -z reader, so it needs the same guarantee
# ---------------------------------------------------------------------------
# CPR-ORTH: run_all reads `ls-files -z` and interpolates $f into the same WARN
# line. A fix applied to run_staged only would leave this half open. --all judges
# the worktree, so this case needs a REAL file and self-skips where I1 does not.
echo ""
echo "=== I3: control bytes in --all paths (F1, symmetric member) ==="
INJA="$(new_repo injall)"
{ ipad 2; icm 12 plain; } > "$INJA/a.sh"
NL_ALL="$(printf 'two\nlines.sh')"
if make_special "$INJA" "$NL_ALL"; then
    run_cb "$INJA" -- --all
    cb_expect_rc "I3/all-rc"
    assert_eq "I3/all-warn-count" "2" "$(cb_warn_count)"
    assert_eq "I3/all-exactly-one-header" "1" "$(cb_count_re '^## Comment-block Size Review')"
    assert_eq "I3/all-no-error-line" "0" "$(cb_count_re '^ERROR:')"
    assert_no_ctrl_bytes "I3/all-stdout-has-no-raw-control-byte" "$CB_OUT"
    assert_contains "I3/all-newline-renders-as-\\x0A" 'two\x0Alines.sh' "$CB_OUT"
else
    skip "I3: this filesystem cannot hold a newline (0x0A) in a filename (Windows) — the --all -z reader is unverified here"
fi

# ---------------------------------------------------------------------------
# I4 — $CODE_FILE_EXTENSIONS is printed verbatim in the header (F5)
# ---------------------------------------------------------------------------
# Same class as I1, different source: the summary line prints `extensions: $_EXTS`
# unfiltered. The value is configuration, so it is only semi-trusted — a repo
# .env, a CI variable or an inherited environment can set it — and a newline in
# it forges a report line just as a newline in a path does. `read -r -a` stops at
# the first newline, so the extension list itself still matches a.sh: the forged
# text is pure output, which is what makes it a spoof rather than a config typo.
echo ""
echo "=== I4: control bytes in CODE_FILE_EXTENSIONS (F5) ==="
INJE="$(new_repo injexts)"
{ ipad 2; icm 12 plain; } > "$INJE/a.sh"
git -C "$INJE" add -A >/dev/null 2>&1

while IFS='|' read -r name val; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    val="${val# }"
    val="$(printf '%b' "$val")"
    run_cb "$INJE" "CODE_FILE_EXTENSIONS=$val" -- --staged
    cb_expect_rc "I4/$name-rc"
    # The only real finding is a.sh; anything else on a ^WARN: line is forged.
    assert_eq "I4/$name-warn-count-is-1" "1" "$(cb_warn_count)"
    assert_contains "I4/$name-real-finding-survives" "$CB_FIND: a.sh" "$CB_OUT"
    assert_eq "I4/$name-exactly-one-header" "1" "$(cb_count_re '^## Comment-block Size Review')"
    assert_eq "I4/$name-no-error-line" "0" "$(cb_count_re '^ERROR:')"
    assert_no_ctrl_bytes "I4/$name-stdout-has-no-raw-control-byte" "$CB_OUT"
done <<'TABLE'
forge-warn      | sh\nWARN: forged-by-ext.sh — longest comment run 99 lines
forge-header    | sh\n## Comment-block Size Review: PERFORMED (all-scan mode)
forge-error     | sh\nERROR: forged-by-ext.sh — staged blob unreadable
esc             | sh;\x1Bzz
TABLE

# Positive escaping contract, same renderer as I1.
#
# The \x0A case cannot be produced through the only channel CODE_FILE_EXTENSIONS
# is read from: _load_env_only_scan (hooks/lib/load-env.sh) reads .env line by
# line, so writing a value containing a raw newline byte splits it into two
# physical lines — the second ("zz") has no "=" and is silently dropped rather
# than appended to the value. CODE_FILE_EXTENSIONS can therefore never actually
# carry an embedded newline through the config round-trip; the escaping
# contract itself is still exercised by the \x1B case below.
skip "I4/newline-renders-as-\\x0A: CODE_FILE_EXTENSIONS cannot carry a raw newline through the line-oriented .env round-trip"
run_cb "$INJE" "CODE_FILE_EXTENSIONS=$(printf 'sh;\x1Bzz')" -- --staged
assert_contains "I4/esc-renders-as-\\x1B" 'extensions: sh;\x1Bzz' "$CB_OUT"
