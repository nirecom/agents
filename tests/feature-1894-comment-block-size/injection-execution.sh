#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/injection-execution.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, injection, command-execution, side-effect, paths, extensions, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 11 - untrusted strings that must never be EXECUTED (review concern C2).

# special-paths.sh already proves a near-negative for a hostile filename: rc 0
# and no "command not found" / "syntax error" on stderr. That cannot separate
# "the name was never handed to a shell" from "it was handed to a shell that
# happened to stay quiet" - a successful `touch` prints nothing at all.

# So this file asserts the positive side-effect axis instead. Every fixture name
# (and every hostile extension value) embeds a command substitution or a command
# separator whose payload is `touch <unique marker>`. Two observables are then
# required together, which is what makes the pair meaningful:
#   (a) the marker file does not exist anywhere a forked shell could have put it;
#   (b) the fixture IS reported on a WARN: line.
# Without (b), (a) would also hold for a scanner that silently skipped the path.

# Sourced by the dispatcher; every helper and constant is defined there.

xpad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "x_$i=$i"; done; }
xcm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

# marker_seen <basename> - rc 0 when a file with exactly this basename exists in
# any directory the scanner could have been standing in. The scanner cd's to the
# repo toplevel, so a payload with no `/` lands there; $TMPDIR_BASE covers every
# fixture repo plus the temp area, and `./` covers the suite's own cwd.
marker_seen() {
    local m="$1"
    [ -e "./$m" ] && return 0
    find "$TMPDIR_BASE" -name "$m" 2>/dev/null | grep -q . && return 0
    return 1
}

# stage_attack <repo> <filename> - same guard shape as special-paths.sh's
# make_special and config-hostility.sh's stage_literal: write the file, stage it
# with the :(literal) magic prefix (the names here contain `$`, `&` and `;`, and
# one of them must never be read as a pathspec), then read the index back
# NUL-delimited and demand a byte-identical entry. A remap or a rejection returns
# 1 so the caller SKIPs with a reason naming the constraint.
stage_attack() {
    local repo="$1" fn="$2" entry
    ( { xpad 2; xcm 12 note; } > "$repo/$fn" ) 2>/dev/null || return 1
    [ -f "$repo/$fn" ] || return 1
    git -C "$repo" add -f -- ":(literal)$fn" >/dev/null 2>&1 || return 1
    while IFS= read -r -d '' entry; do
        [ "$entry" = "$fn" ] && return 0
    done < <(git -C "$repo" ls-files -z --)
    git -C "$repo" reset -q -- ":(literal)$fn" >/dev/null 2>&1 || true
    return 1
}

# ---------------------------------------------------------------------------
# X0 - the marker detector itself must not be vacuous
# ---------------------------------------------------------------------------
echo ""
echo "=== X0: marker detector proves itself before it is trusted ==="
XR="$(new_repo injexec)"
XV="XPWN-$$-vacuity"
: > "$XR/$XV"
if marker_seen "$XV"; then
    pass "X0/detector-reports-a-planted-marker"
else
    fail "X0/detector-reports-a-planted-marker" "planted $XR/$XV was not found"
fi
rm -f "$XR/$XV"
if marker_seen "$XV"; then
    fail "X0/detector-clean-after-removal" "marker $XV still reported after removal"
else
    pass "X0/detector-clean-after-removal"
fi

# ---------------------------------------------------------------------------
# X1 - a filename shaped like a command must not run as one (--staged)
# ---------------------------------------------------------------------------
echo ""
echo "=== X1: executable-shaped staged paths (staged mode) ==="
X_STAGED=""
X_MARKS=""
X_N=0

# name | filename   (@M@ is replaced by a per-row unique marker basename)
while IFS='|' read -r name fn; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    fn="${fn# }"
    fn="${fn%"${fn##*[![:space:]]}"}"
    mk="XPWN-$$-$name"
    fn="${fn//@M@/$mk}"
    if stage_attack "$XR" "$fn"; then
        X_STAGED="$X_STAGED$name|$fn"$'\n'
        X_MARKS="$X_MARKS$name|$mk"$'\n'
        X_N=$((X_N + 1))
    else
        skip "X1/$name: this filesystem or index refuses $(printf '%q' "$fn") - execution axis unverified for it"
    fi
done <<'TABLE'
cmd-sub    | a$(touch @M@)b.sh
backtick   | a`touch @M@`b.sh
semicolon  | a;touch @M@;b.sh
ampersand  | a&touch @M@&b.sh
bare-sub   | $(touch @M@).sh
TABLE

if [ "$X_N" -eq 0 ]; then
    skip "X1: no executable-shaped filename could be staged on this host - the whole staged execution axis is unverified"
else
    run_cb "$XR" -- --staged
    assert_eq "X1/rc-is-zero" "0" "$CB_RC"
    assert_eq "X1/warn-count-matches-staged-count" "$X_N" "$(cb_warn_count)"
    while IFS='|' read -r name fn; do
        [ -z "$name" ] && continue
        assert_contains "X1/$name-was-actually-scanned" "WARN: $fn" "$CB_OUT"
    done <<< "$X_STAGED"
    while IFS='|' read -r name mk; do
        [ -z "$name" ] && continue
        if marker_seen "$mk"; then
            fail "X1/$name-payload-did-not-run" "marker $mk was created - the path reached a shell"
        else
            pass "X1/$name-payload-did-not-run"
        fi
    done <<< "$X_MARKS"
fi

# ---------------------------------------------------------------------------
# X2 - the --all walk is the symmetric member (CPR-ORTH)
# ---------------------------------------------------------------------------
# run_all reads the same names from `ls-files -z` and feeds them to `wc -c`,
# `awk < "$f"` and the `-L` / `-f` tests. Hardening applied to run_staged only
# would leave this half open, so the same two-sided assertion runs here.
echo ""
echo "=== X2: executable-shaped paths on the --all walk ==="
if [ "$X_N" -eq 0 ]; then
    skip "X2: no executable-shaped filename exists in this worktree - the --all execution axis is unverified"
else
    run_cb "$XR" -- --all
    assert_eq "X2/rc-is-zero" "0" "$CB_RC"
    assert_eq "X2/warn-count-matches-file-count" "$X_N" "$(cb_warn_count)"
    while IFS='|' read -r name fn; do
        [ -z "$name" ] && continue
        assert_contains "X2/$name-was-actually-scanned" "WARN: $fn" "$CB_OUT"
    done <<< "$X_STAGED"
    while IFS='|' read -r name mk; do
        [ -z "$name" ] && continue
        if marker_seen "$mk"; then
            fail "X2/$name-payload-did-not-run" "marker $mk was created during the --all walk"
        else
            pass "X2/$name-payload-did-not-run"
        fi
    done <<< "$X_MARKS"
fi

# ---------------------------------------------------------------------------
# X3 - the same names on the BASELINE seam
# ---------------------------------------------------------------------------
# X1 and X2 only reach `git show ":./$dst"` and the worktree readers: every
# fixture there is new, so find_baseline finds nothing and the baseline branch is
# never taken. Committing them and re-staging a grown version makes find_baseline
# build "HEAD:./$src" out of the same untrusted bytes and hand it to a second
# `git show`. `no baseline` must therefore be absent from the report - that is
# what proves this run exercised the branch X1/X2 could not.
echo ""
echo "=== X3: executable-shaped paths on the baseline seam ==="
if [ "$X_N" -eq 0 ]; then
    skip "X3: no executable-shaped filename could be committed on this host - the baseline seam is unverified"
else
    git -C "$XR" commit -q -m "attack fixtures" >/dev/null 2>&1
    while IFS='|' read -r name fn; do
        [ -z "$name" ] && continue
        ( { xpad 2; xcm 20 note; } > "$XR/$fn" ) 2>/dev/null || true
        git -C "$XR" add -f -- ":(literal)$fn" >/dev/null 2>&1 || true
    done <<< "$X_STAGED"
    run_cb "$XR" -- --staged
    assert_eq "X3/rc-is-zero" "0" "$CB_RC"
    assert_eq "X3/warn-count-matches-staged-count" "$X_N" "$(cb_warn_count)"
    assert_absent "X3/baseline-branch-was-really-taken" "no baseline" "$CB_OUT"
    while IFS='|' read -r name fn; do
        [ -z "$name" ] && continue
        assert_contains "X3/$name-was-actually-scanned" "WARN: $fn" "$CB_OUT"
    done <<< "$X_STAGED"
    while IFS='|' read -r name mk; do
        [ -z "$name" ] && continue
        if marker_seen "$mk"; then
            fail "X3/$name-payload-did-not-run" "marker $mk was created while resolving the baseline"
        else
            pass "X3/$name-payload-did-not-run"
        fi
    done <<< "$X_MARKS"
fi

# ---------------------------------------------------------------------------
# X4 - CODE_FILE_EXTENSIONS shaped like a command
# ---------------------------------------------------------------------------
# config-hostility.sh already pins the SCOPE axis for this variable (a glob in it
# must not widen the scan) and injection-hardening.sh pins the OUTPUT axis (a
# control byte in it must not forge a report line). The third axis is added here:
# the value is read with `IFS=';' read -r -a` and printed through esc, so it must
# never be evaluated - no marker, and the ordinary contract still holds.
echo ""
echo "=== X4: executable-shaped CODE_FILE_EXTENSIONS ==="
XE="$(new_repo injexecexts)"
{ xpad 2; xcm 12 plain; } > "$XE/a.sh"
git -C "$XE" add -A >/dev/null 2>&1

while IFS='|' read -r name val; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    val="${val# }"
    val="${val%"${val##*[![:space:]]}"}"
    mk="XPWNE-$$-$name"
    val="${val//@M@/$mk}"
    run_cb "$XE" "CODE_FILE_EXTENSIONS=$val" -- --staged
    assert_eq "X4/$name-rc" "0" "$CB_RC"
    assert_eq "X4/$name-header-is-staged-mode" \
        "## Comment-block Size Review: PERFORMED (staged mode)" "$(cb_header)"
    assert_contains "X4/$name-sh-still-selects-a.sh" "WARN: a.sh" "$CB_OUT"
    assert_eq "X4/$name-warn-count-is-1" "1" "$(cb_warn_count)"
    if marker_seen "$mk"; then
        fail "X4/$name-payload-did-not-run" "marker $mk was created - the value reached a shell"
    else
        pass "X4/$name-payload-did-not-run"
    fi
done <<'TABLE'
cmd-sub    | sh;$(touch @M@)
backtick   | sh;`touch @M@`
semicolon  | sh;x;touch @M@
ampersand  | sh;x&touch @M@
TABLE

# Same axis on the --all walk: the value steers ext_ok there too.
run_cb "$XE" "CODE_FILE_EXTENSIONS=sh;\$(touch XPWNE-$$-all)" -- --all
assert_eq "X4/all-rc" "0" "$CB_RC"
assert_contains "X4/all-sh-still-selects-a.sh" "WARN: a.sh" "$CB_OUT"
if marker_seen "XPWNE-$$-all"; then
    fail "X4/all-payload-did-not-run" "marker XPWNE-$$-all was created during the --all walk"
else
    pass "X4/all-payload-did-not-run"
fi
