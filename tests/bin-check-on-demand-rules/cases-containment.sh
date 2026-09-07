# shellcheck shell=bash
# Tests: bin/check-on-demand-rules.sh, bin/lib/check-on-demand-rules.js
# Tags: rules-injection, on-demand-rules, static-check, containment, symlink, lstat, traversal, TL2, scope:issue-specific

# WHY (CPR-WPH): resolveInRoot answers containment LEXICALLY — path.resolve and
# path.relative never touch the filesystem. That is deliberate (a policy value must never
# be followed out of the tree), but it leaves one hole: a symlink that SITS inside the
# root and POINTS outside it satisfies the lexical test, and a stat() then follows it. The
# checker would report a file the repo does not own as an owned reader, and the pointer
# check would read whatever is on the far end.

echo ""
echo "=== containment: lstat-based reader/pointer checks and the reserved-token probe ==="

# The containment helper now uses lstat, so a link is judged as a link. Two consumers get
# it — the reader-existence check and the minimized-pointer check — and a third, the
# reserved-token existence probe, previously built its path with path.join(root, ...) and
# so probed outside the root whenever the token carried `..`; it now goes through the same
# helper (existsInRoot).

CT_N=0

# Every reject case here is paired with a REGULAR FILE in the identical position, because
# "refuses a symlink" and "refuses everything at that path" produce the same output.
# Symlink creation needs privilege on Windows; when it is unavailable the symlink cases
# SKIP loudly rather than passing on a copy that was never a link.
# Assumes TOKEN, MARKER, BASE, node_path(), wr(), mk_tree(), run_checker(), outfile_for(),
# rd_policy(), rd_base(), rd_min_base(), rd_expect(), emit_minimized(), pass(), fail().

# ct_symlink <link> <target> -> 0 when a REAL symlink now exists at <link>.
# `ln -s` on Windows without the privilege silently copies, so the link bit is what is
# tested, never the exit status.
ct_symlink() {
    rm -f "$1" 2>/dev/null
    ln -s "$2" "$1" 2>/dev/null
    [ -L "$1" ]
}

# The escape target is a REAL file outside every fixture root. A traversal case whose
# target does not exist proves nothing — it would pass on a checker that resolves outside
# the tree, merely because the resolution found nothing there.
CT_OUTSIDE="$BASE/ct-outside"
mkdir -p "$CT_OUTSIDE"
printf '# a file the checked tree does not own\n' > "$CT_OUTSIDE/escapee.md"

if [ ! -f "$CT_OUTSIDE/escapee.md" ]; then
    fail "CT-setup: the out-of-root escape target was not created — every symlink case below would pass vacuously"
else
    pass "CT-setup: the escape target exists outside every fixture root"
fi

# --- S1/S2: a declared READER that is an in-root symlink to an out-of-root file. ---
CT_N=$((CT_N + 1)); d="$BASE/ct-reader-link$CT_N"
rd_base "$d"
mkdir -p "$d/skills/linked"
if ct_symlink "$d/skills/linked/SKILL.md" "$CT_OUTSIDE/escapee.md"; then
    rd_policy "$d" '["rules/od.md|skills/linked/SKILL.md"]' '["rules/plain.md"]'
    rd_expect "S1: a declared reader that is a SYMLINK out of the root is READER_TARGET_MISSING — containment is lexical, so only lstat can see the link" \
        "$d" READER_TARGET_MISSING yes "rules/od.md"
else
    echo "SKIP: S1 — symlink creation is unavailable on this host (ln -s produced no link; Windows needs the create-symlink privilege or Developer Mode), so the lstat-vs-stat distinction cannot be exercised here"
fi

# S2 is S1's positive control, in the IDENTICAL position: same declared path, same policy,
# a real file instead of a link. Without it S1 also passes on a checker that rejects
# skills/linked/SKILL.md for any reason at all.
CT_N=$((CT_N + 1)); d="$BASE/ct-reader-real$CT_N"
rd_base "$d"
wr "$d/skills/linked/SKILL.md" <<'EOF'
# Linked owner

Read `rules/od.md` before continuing.
EOF
rd_policy "$d" '["rules/od.md|skills/linked/SKILL.md"]' '["rules/plain.md"]'
rd_expect "S2: a REGULAR file at the same declared reader path is accepted — S1 rejects the link, not the position" \
    "$d" READER_TARGET_MISSING no

# --- S3/S4: the same pair for a minimized POINTER (CPR-ORTH: symmetric member, same
# treatment). The pointer is the path a stuck session is sent to, so a link pointing out
# of the repo is a pointer at something the repo cannot vouch for. ---
CT_N=$((CT_N + 1)); d="$BASE/ct-ptr-link$CT_N"
rd_min_base "$d" "skills/linked/SKILL.md"
mkdir -p "$d/skills/linked"
wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Details: `skills/linked/SKILL.md`.
EOF
if ct_symlink "$d/skills/linked/SKILL.md" "$CT_OUTSIDE/escapee.md"; then
    rd_expect "S3: a minimized POINTER that is a SYMLINK out of the root is MINIMIZED_POINTER_TARGET_MISSING" \
        "$d" MINIMIZED_POINTER_TARGET_MISSING yes "rules/min.md"
else
    echo "SKIP: S3 — symlink creation is unavailable on this host (see the S1 skip), so the pointer-side lstat check cannot be exercised here"
fi

CT_N=$((CT_N + 1)); d="$BASE/ct-ptr-real$CT_N"
rd_min_base "$d" "skills/linked/SKILL.md"
wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Details: `skills/linked/SKILL.md`.
EOF
wr "$d/skills/linked/SKILL.md" <<'EOF'
# Linked escape hatch procedure
EOF
rd_expect "S4: a REGULAR file at the same pointer path is accepted — S3 rejects the link, not the position" \
    "$d" MINIMIZED_POINTER_TARGET_MISSING no

# --- T: the reserved-token existence probe. The token is a policy VALUE like any other,
# so a token carrying `..` or a drive letter must be refused by the containment helper
# instead of stat-ing a path outside the checked tree. ---

# ct_tree <dir> <token> — the smallest tree the probe can run against: no on-demand rules
# at all, so the only thing the checker can say about the token is whether it EXISTS.
ct_tree() {
    local d="$1" tok="$2"
    mk_tree "$d"
    wr "$d/rules/plain.md" <<'EOF'
# Plain unconditional rule
EOF
    mkdir -p "$d/hooks/lib"
    {
        printf '"use strict";\n'
        printf 'const ON_DEMAND_TOKEN = "%s";\n' "$tok"
        printf 'const ON_DEMAND_MARKER_RE = /<!--\\s*injection:\\s*on-demand-only(?!-?\\w)/;\n'
        printf 'const ON_DEMAND_READERS = [];\n'
        printf 'const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];\n'
        emit_minimized "$FX_MINIMIZED_DEFAULT" "$FX_MAXBYTES_DEFAULT"
        printf 'module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };\n'
    } > "$d/hooks/lib/rules-injection-policy.js"
}

# T0 is the control the two traversal cases depend on: the probe must genuinely fire when
# a file really does sit at the reserved path INSIDE the root. Without it, T1/T2 would
# also pass on a checker that had stopped probing altogether.
CT_N=$((CT_N + 1)); d="$BASE/ct-token-inside$CT_N"
ct_tree "$d" "$TOKEN"
mkdir -p "$d/.on-demand-only"
printf 'this real path must never exist\n' > "$d/$TOKEN"
rd_expect "T0: a real file at the reserved in-root token is RESERVED_PATH_EXISTS — the probe is live" \
    "$d" RESERVED_PATH_EXISTS yes "$TOKEN"

CT_N=$((CT_N + 1)); d="$BASE/ct-token-traverse$CT_N"
ct_tree "$d" "../ct-outside/escapee.md"
rd_expect "T1: a token carrying '..' is refused by the containment helper — the probe never stats the existing file it points at outside the root" \
    "$d" RESERVED_PATH_EXISTS no

CT_N=$((CT_N + 1)); d="$BASE/ct-token-abs$CT_N"
CT_ABS="$(node_path "$CT_OUTSIDE/escapee.md")"
ct_tree "$d" "$CT_ABS"
rd_expect "T2: an ABSOLUTE / drive-letter token is refused the same way, though the file it names EXISTS" \
    "$d" RESERVED_PATH_EXISTS no
