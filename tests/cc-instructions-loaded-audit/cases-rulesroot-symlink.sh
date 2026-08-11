# shellcheck shell=bash
# Tests: hooks/lib/instructions-loaded-receipt.js, hooks/instructions-loaded-audit.js
# Tags: rules-injection, instructions-loaded, rules-key, symlink, junction, path-traversal, security, pinned-gap, TL2, scope:common
#
# The symlink half of root anchoring. Sourced from cases-rulesroot.sh (file-split
# Pattern A: that file is at the 300-line WARN), so $RR, $REPO, fire(), read_field(),
# node_path(), pass() and fail() are already in scope.
#
# WHY (CPR-WPH): every reject row in cases-rulesroot.sh is LEXICAL — the path spells its
# way out of the root (`../`, an adjacent name, a foreign absolute path). A symlink says
# nothing of the kind. `<project>/rules/escape.md` is, character for character, a path
# under a known rules root; only the filesystem knows it resolves somewhere else. So this
# group asks the one question the table cannot: does containment survive a link?
#
# It does NOT. toRulesKey() resolves lexically by contract — path.resolve() only, never
# realpath()/stat() — so a link under a rules root keeps a readable `rules/<tail>` key and
# the linked-to file is read and classified as if it were a registered rule. That is the
# opposite of what the out-of-root digest exists to guarantee, so it is PINNED here as
# current behaviour, with the ideal spelled out, rather than asserted the way it ought to
# behave (this change is tests-only; the pin is the record, and the day the source starts
# resolving links these cases fail and the change gets reviewed).
#
# Scope of the exposure, stated plainly so the pin is not read as bigger than it is: the
# link has to already exist inside a rules root, which means an actor who can write into
# the rules directory — and such an actor could put a real file there instead. What the
# gap costs is the receipt's promise that anything outside a root is reduced to
# `out-of-root:<digest>`: through a link, an arbitrary absolute path's CONTENT reaches
# classify(), and its in-root-looking key is what gets recorded.

echo ""
echo "=== rules-key root anchoring: symlinks and junctions ==="

# rr_mklink <target> <link-path> <file|dir> -> prints "yes" when a REAL link exists at
# <link-path> afterwards, "no" otherwise.
#
# The verification is not optional. On this Windows host `ln -s` silently produces a COPY
# under the default MSYS behaviour, and a copy placed inside the rules root is genuinely
# in-root — the case would then assert the ordinary in-root behaviour and PASS while
# proving nothing about links. So: create, then lstat, and only report success when the
# entry is really a symbolic link.
rr_mklink() {
    local target="$1" link="$2" kind="$3"
    rm -rf "$link" 2>/dev/null
    ln -s "$target" "$link" 2>/dev/null
    if [ "$(rr_is_link "$link")" = "yes" ]; then printf 'yes'; return; fi
    # Fallback: node's symlink, with the win32-specific type. "junction" is the only
    # directory form Windows grants without developer mode or elevation.
    rm -rf "$link" 2>/dev/null
    node -e '
const fs = require("fs");
const type = process.argv[3] === "dir"
  ? (process.platform === "win32" ? "junction" : "dir")
  : "file";
try { fs.symlinkSync(process.argv[1], process.argv[2], type); } catch (_) { }
' "$(node_path "$target")" "$(node_path "$link")" "$kind" 2>/dev/null
    rr_is_link "$link"
}

# rr_is_link <path> -> yes when lstat says symlink (a junction also reports as one)
rr_is_link() {
    node -e '
const fs = require("fs");
try { process.stdout.write(fs.lstatSync(process.argv[1]).isSymbolicLink() ? "yes" : "no"); }
catch (_) { process.stdout.write("no"); }
' "$(node_path "$1")" 2>/dev/null
}

mkdir -p "$RR/linktarget/secretdir"
printf '# a file that is not under any rules root, with no paths: frontmatter\n' \
    > "$RR/linktarget/secret.md"
printf '# a file inside a directory that is not under any rules root\n' \
    > "$RR/linktarget/secretdir/x.md"

# --- C9a: a FILE symlink under the project rules root, resolving outside it ---------
RR_LNK="$REPO/rules/escape.md"
if [ "$(rr_mklink "$RR/linktarget/secret.md" "$RR_LNK" file)" != "yes" ]; then
    echo "SKIP: C9a: Skipped-Because: this host produced a copy rather than a symbolic link at $RR_LNK (ln -s and fs.symlinkSync both failed the lstat check), so the symlink traversal behaviour is UNVERIFIED here — asserting on the copy would pass for the wrong reason"
else
    RR_LNK_NODE="$(node_path "$RR_LNK")"
    RR_C9A_RC="$(fire c9asymlink "$RR_LNK_NODE" OMIT)"
    RR_C9A_FP="$(read_field c9asymlink "$RR_LNK_NODE" file_path)"
    RR_C9A_V="$(read_field c9asymlink "$RR_LNK_NODE" verdict)"
    if [ "${RR_C9A_RC%%|*}" != "0" ]; then
        fail "C9a: the hook must fail open on a symlinked path, got rc=${RR_C9A_RC%%|*}"
    elif [ "$RR_C9A_FP" = "rules/escape.md" ] && [ "$RR_C9A_V" = "S-MISSING" ]; then
        # PINNED CURRENT BEHAVIOUR (gap, deliberately not fixed here).
        # IDEAL: file_path="out-of-root:<digest>" and verdict="ok" — the link resolves
        # outside every rules root, so its content should never reach classify().
        echo "  GAP: [C9a] a symlink under <project>/rules/ that resolves to $RR/linktarget/secret.md keeps the in-root key 'rules/escape.md' and its content IS classified; the out-of-root digest does not hold across links because toRulesKey() resolves lexically (path.resolve, no realpath/stat)"
        pass "C9a: current behaviour pinned — a symlinked rule keeps a readable in-root key (file_path=$RR_C9A_FP, verdict=$RR_C9A_V), gap recorded above"
    elif [ "${RR_C9A_FP#out-of-root:}" != "$RR_C9A_FP" ] && [ "$RR_C9A_V" = "ok" ]; then
        fail "C9a: the hook now redacts a symlink that escapes the rules root (file_path=$RR_C9A_FP verdict=$RR_C9A_V) — this is the IDEAL behaviour, so the gap is closed: update this case to assert it instead of the pin"
    else
        fail "C9a: neither the pinned nor the ideal behaviour — file_path='$RR_C9A_FP' verdict='$RR_C9A_V'"
    fi
fi

# --- C9b: a DIRECTORY link (junction on win32) under the rules root. CPR-ORTH: the
# file and directory forms are symmetric members of the same class, and the directory
# form is the one that escapes with an arbitrary TAIL rather than a fixed name. ---
RR_DLNK="$REPO/rules/escapedir"
if [ "$(rr_mklink "$RR/linktarget/secretdir" "$RR_DLNK" dir)" != "yes" ]; then
    echo "SKIP: C9b: Skipped-Because: this host would not create a directory symlink or junction at $RR_DLNK (ln -s and fs.symlinkSync both failed the lstat check), so the directory-link traversal behaviour is UNVERIFIED here"
else
    RR_DLNK_FILE="$(node_path "$REPO/rules/escapedir/x.md")"
    RR_C9B_RC="$(fire c9bjunction "$RR_DLNK_FILE" OMIT)"
    RR_C9B_FP="$(read_field c9bjunction "$RR_DLNK_FILE" file_path)"
    RR_C9B_V="$(read_field c9bjunction "$RR_DLNK_FILE" verdict)"
    if [ "${RR_C9B_RC%%|*}" != "0" ]; then
        fail "C9b: the hook must fail open on a junctioned path, got rc=${RR_C9B_RC%%|*}"
    elif [ "$RR_C9B_FP" = "rules/escapedir/x.md" ] && [ "$RR_C9B_V" = "S-MISSING" ]; then
        # PINNED CURRENT BEHAVIOUR. IDEAL: out-of-root digest, verdict ok.
        echo "  GAP: [C9b] a directory link under <project>/rules/ carries its whole tail into the key ('rules/escapedir/x.md'), so ANY file under the linked-to directory is classified as a registered rule"
        pass "C9b: current behaviour pinned — a directory link keeps a readable in-root key (file_path=$RR_C9B_FP, verdict=$RR_C9B_V), gap recorded above"
    elif [ "${RR_C9B_FP#out-of-root:}" != "$RR_C9B_FP" ] && [ "$RR_C9B_V" = "ok" ]; then
        fail "C9b: the hook now redacts a directory link that escapes the rules root (file_path=$RR_C9B_FP verdict=$RR_C9B_V) — the IDEAL behaviour; update this case to assert it instead of the pin"
    else
        fail "C9b: neither the pinned nor the ideal behaviour — file_path='$RR_C9B_FP' verdict='$RR_C9B_V'"
    fi
fi

# --- C9c: the link detector itself must be able to answer "no". Without this, a
# rr_is_link() that returned "yes" unconditionally would turn both HARD SKIPs above into
# silent passes over ordinary files. ---
printf '# an ordinary file, not a link\n' > "$REPO/rules/not-a-link.md"
RR_C9C_PLAIN="$(rr_is_link "$REPO/rules/not-a-link.md")"
RR_C9C_ABSENT="$(rr_is_link "$REPO/rules/does-not-exist-at-all.md")"
if [ "$RR_C9C_PLAIN" = "no" ] && [ "$RR_C9C_ABSENT" = "no" ]; then
    pass "C9c: the link check answers 'no' for an ordinary file and for a missing path — the C9a/C9b skip guards are real, not decorative"
else
    fail "C9c: the link check is not discriminating (plain file='$RR_C9C_PLAIN', missing path='$RR_C9C_ABSENT') — the C9a/C9b guards cannot be trusted"
fi
