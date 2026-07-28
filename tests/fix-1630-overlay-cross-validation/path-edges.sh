# tests/fix-1630-overlay-cross-validation/path-edges.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
# Tags: worktree, enforce, hook, config-dir, overlay, unit, path, scope:issue-specific
#
# STATUS: RED until C5 lands (stripRelSuffix is not exported yet, so every row
# reports `ERROR: stripRelSuffix is not exported`).
#
# C11 — path edge coverage for stripRelSuffix. The plan forbids a character
# slice (`abs.slice(0, abs.length - rel.length)`): the suffix must be removed
# SEGMENT-wise, splitting on /[/\\]+/ and rejoining with path.join. Every row
# below is a shape where a character slice, or a naive rejoin, produces a
# different answer than the segment-wise rule:
#
#   spaces / Unicode  — no encoding-dependent length arithmetic
#   drive & UNC roots — the root itself is a legitimate answer and must not
#                       degrade into a cwd-relative path
#   mixed separators  — one `\` in a `/` path changes the character length of
#                       the suffix but not its segment count
#   repeated slashes  — `//` collapses segment-wise, never character-wise
#   case differences  — comparison is lowercase on both sides (normLower)
#
# Expected values are lowercase because stripRelSuffix returns its result
# through the same `normLower` the three-way comparison uses.

run_path_edge_cases() {
    run_strip_table <<'TABLE'
STRIP-space          | strip | C:/a b/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/a b
STRIP-space-2        | strip | C:/Program Files/my agents/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/program files/my agents
STRIP-unicode        | strip | C:/プロジェクト/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/プロジェクト
STRIP-unicode-case   | strip | C:/Ünï/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/ünï
STRIP-drive-root     | strip | C:/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/
STRIP-mixed-sep      | strip | C:/a\skills/issue-close-finalize\scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/a
STRIP-double-sep     | strip | C:/a//skills/issue-close-finalize//scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/a
STRIP-rel-backslash  | strip | C:/a/skills/issue-close-finalize/scripts/run-initial.sh | skills\issue-close-finalize\scripts\run-initial.sh | c:/a
STRIP-case-fold      | strip | C:/a/SKILLS/Issue-Close-Finalize/Scripts/Run-Initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/a
STRIP-unc            | strip | //server/share/agents/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | //server/share/agents
STRIP-shortfall      | strip | C:/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | null
STRIP-tail-mismatch  | strip | C:/a/skills/issue-close-finalize/scripts/run-initial.sh.bak | skills/issue-close-finalize/scripts/run-initial.sh | null
TABLE

    # STRIP-unc is the sharpest of these: splitting on /[/\\]+/ yields a leading
    # EMPTY segment, so a rejoin that drops it turns an absolute UNC path into a
    # cwd-relative one — a path-confusion bug that would silently make an
    # attacker-hosted share look like a local candidate. The row fails unless the
    # UNC prefix survives.

    run_posix_root_rows
    run_separator_platform_rows
}

# ---------------------------------------------------------------------------
# POSIX root reconstruction (T5).
#
# Every row above carries a drive letter or a UNC prefix, and each of those
# exercises a DIFFERENT shape of the leading-segment problem:
#
#   C:/a/...        -> segs[0] = "C:"  — root is rebuilt as absSegs[0] + sep
#   //server/s/...  -> segs[0..1] = "", "" — root is rebuilt from TWO empties
#   /home/u/...     -> segs[0] = "" (exactly one) — root is rebuilt as sep + …
#
# Only the third shape is the everyday macOS/Linux layout, and it has its own
# branch in the implementation. If that branch drops the single empty segment,
# `/home/u/agents` rejoins as the cwd-relative `home/u/agents`; the derived root
# then differs from the anchor, the three-way comparison fails, and the whole
# finalize chain re-blocks on every POSIX host — the exact #1630 false-positive
# class this work exists to remove. Nothing above can catch it.
#
# Platform independence: the POSIX SHAPE is what is under test, so these rows
# run unchanged on win32 (where the split still yields exactly one leading empty
# segment and the branch is still taken). Only the final absolutisation differs
# per host, so the expected value is derived through the same `path.resolve` +
# lowercase that `normLower` applies — NOT through host `path.sep` string
# surgery, and never through stripRelSuffix itself. The segment-wise
# reconstruction, which is the behaviour under test, stays fully pinned.
# MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL: under Git Bash on win32, MSYS rewrites
# any argv element that looks like a POSIX absolute path ("/home/u/agents" ->
# "C:/Program Files/Git/home/u/agents") BEFORE the child sees it — which would
# silently convert every row below back into a drive-letter row and delete the
# coverage. Both variables are inert on a real POSIX host.
# Both wrappers use a subshell body so the export is scoped to the call.
#
# The expected root is derived the way `normLower` derives it (path.resolve +
# lowercase) and never via stripRelSuffix. `String.fromCharCode(92)` avoids a
# literal backslash so the expression survives every quoting layer unchanged.
norm_root() (
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    run_with_timeout 20 node -e \
        'const s=require("path").resolve(process.argv[1]);console.log(s.split(String.fromCharCode(92)).join("/").toLowerCase())' \
        "$1" 2>&1
)

posix_probe() (
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    run_with_timeout 30 node "$OVERLAY_PROBE" "$@" 2>&1
)

run_posix_root_rows() {
    local rel="skills/issue-close-finalize/scripts/run-initial.sh"
    local bs='\'

    assert_eq "STRIP-posix-root single leading empty segment is rebuilt as an absolute root" \
        "$(posix_probe strip "/home/u/agents/$rel" "$rel")" "$(norm_root /home/u/agents)"
    assert_eq "STRIP-posix-nested deeper POSIX root survives the same rebuild" \
        "$(posix_probe strip "/home/u/w/agents/$rel" "$rel")" "$(norm_root /home/u/w/agents)"
    assert_eq "STRIP-posix-fs-root stripping everything yields the filesystem root, not an empty path" \
        "$(posix_probe strip "/$rel" "$rel")" "$(norm_root /)"

    # LOW — POSIX counterparts of the drive-letter separator rows, proving the
    # segment-wise split is independent of the drive-letter prefix.
    # Separator semantics are PLATFORM-dependent (defect F, resolved): `\` splits
    # on win32 and is an ordinary filename character on POSIX, where the segment
    # tail therefore never matches `rel` and the strip declines. This row is the
    # POSIX-shaped half of the pair described in run_separator_platform_rows
    # below; its expectation now follows the same platform rule instead of
    # asserting the unconditional split that was the defect.
    local mixed_sep_want
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*|Windows_NT) mixed_sep_want="$(norm_root /home/u/agents)" ;;
        *) mixed_sep_want="null" ;;
    esac
    assert_eq "STRIP-posix-mixed-sep backslash separators inside a POSIX path split segment-wise only on win32" \
        "$(posix_probe strip "/home/u/agents/skills${bs}issue-close-finalize/scripts${bs}run-initial.sh" "$rel")" \
        "$mixed_sep_want"
    assert_eq "STRIP-posix-double-sep repeated slashes collapse without eating the root" \
        "$(posix_probe strip "/home/u//agents/skills//issue-close-finalize/scripts/run-initial.sh" "$rel")" \
        "$(norm_root /home/u/agents)"
}

# ---------------------------------------------------------------------------
# Separator semantics are PLATFORM-dependent (defect F).
#
# stripRelSuffix splits on /[/\\]+/ unconditionally, so `\` is treated as a path
# separator on every host. On win32 that is correct. On macOS/Linux it is not:
# `\` is an ordinary filename character there, so
#
#     /trusted/acd\skills/issue-close-finalize/scripts/run-initial.sh
#
# is ONE directory literally named `acd\skills` — a path an attacker can create
# inside any directory they can write to, entirely outside /trusted/acd. Reading
# it as a separator makes the function report `/trusted/acd` as the implied
# root, so the three-way cross-validation compares a trusted root against a
# script that does not live under it, and the overlay's identity check is
# defeated by a filename.
#
# The two hosts therefore want OPPOSITE answers for the same string, which is
# why this is the only section in the file that branches on the platform. The
# same-shape control (a path with no `\` at all) must keep deriving the root on
# BOTH hosts, so a fix cannot pass by refusing everything.
#
# Relationship to STRIP-posix-mixed-sep above: that row asserts the CURRENT
# unconditional-split behaviour under a POSIX-shaped path. On win32 both it and
# the row below pass. On a genuine POSIX host they state opposite expectations
# — deliberately left standing, because it is exactly that row which encodes the
# defect, and it is the fixing change's job to resolve the pair (not this
# test's job to pre-decide it by deleting one side).
#
# HOST NOTE: this suite runs on win32 today, so only the win32 branch is
# executed here; the POSIX branch is unverified on this machine by construction.
run_separator_platform_rows() {
    local rel="skills/issue-close-finalize/scripts/run-initial.sh"
    local bs='\'
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo unknown)"

    # Control (both platforms): the identical path with a real `/` separator
    # must still derive the root. Pairs with every row below.
    assert_eq "STRIP-sep-control a genuine separator still derives the root" \
        "$(posix_probe strip "/trusted/acd/$rel" "$rel")" "$(norm_root /trusted/acd)"

    case "$uname_s" in
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
            assert_eq "STRIP-sep-win32 backslash IS a separator on win32, so the root is derived" \
                "$(posix_probe strip "/trusted/acd${bs}$rel" "$rel")" "$(norm_root /trusted/acd)"
            assert_eq "STRIP-sep-win32-deep an interior backslash segment resolves on win32" \
                "$(posix_probe strip "/trusted/acd${bs}sub/$rel" "$rel")" "$(norm_root "/trusted/acd/sub")"
            ;;
        *)
            assert_eq "STRIP-sep-posix backslash is a FILENAME character on POSIX, not a separator" \
                "$(posix_probe strip "/trusted/acd${bs}$rel" "$rel")" "null"
            assert_eq "STRIP-sep-posix-deep a backslash-bearing directory name is not a root boundary" \
                "$(posix_probe strip "/trusted/acd${bs}sub/$rel" "$rel")" \
                "$(norm_root "/trusted/acd${bs}sub")"
            ;;
    esac
}
