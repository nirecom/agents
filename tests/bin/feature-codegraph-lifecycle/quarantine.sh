# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js
# Tags: codegraph, lifecycle, quarantine, symlink, scope:issue-specific
# ST-18 L11-L11g: quarantine-and-reinit when the rebuild itself fails, and the
# bounded number of `codegraph` launches that path is allowed to make.

echo "--- L11: a failed rebuild quarantines the DB and re-inits once ---"
reset_env
export CG_STUB_FAIL=index
root="$(mkroot "l11")"
root_p="$(root_sh l11)"
make_db "$root" zero
run_cli init "$root"
assert_warned "L11"
if [ -f "$root_p/.codegraph/broken/codegraph.db" ]; then
    pass "L11 — the unusable DB was moved to .codegraph/broken/codegraph.db"
else
    fail "L11 — .codegraph/broken/codegraph.db does not exist"
fi
if [ -e "$root_p/.codegraph/codegraph.db" ]; then
    fail "L11 — .codegraph/codegraph.db should be gone after quarantine"
else
    pass "L11 — the quarantined DB no longer sits at its live path"
fi
assert_eq "L11 — index attempted exactly once" "1" "$(verb_count index)"
assert_eq "L11 — init -y called exactly once" "1" "$(verb_count init)"

echo "--- L11b: quarantining twice replaces, never nests ---"
# The two DBs carry distinct contents. Observing only that broken/codegraph.db still
# exists cannot tell "the second quarantine replaced the first" from "the second
# quarantine silently did nothing and the file we are looking at is L11's" — both leave
# a file at that path. The sentinels settle which DB is in the slot and whether the
# superseded one was really removed rather than tucked away somewhere under .codegraph.
reset_logs
export CG_STUB_FAIL=index
L11B_OLD="l11b-old-quarantine-sentinel"
L11B_NEW="l11b-new-quarantine-sentinel"
printf '%s\n' "$L11B_OLD" > "$root_p/.codegraph/broken/codegraph.db"
printf '%s\n' "$L11B_NEW" > "$root_p/.codegraph/codegraph.db"
run_cli init "$root"
assert_eq "L11b — exit 0" "0" "$RC"
if [ -f "$root_p/.codegraph/broken/codegraph.db" ]; then
    pass "L11b — the second quarantine landed in the same slot"
else
    fail "L11b — the second quarantine did not run, so nesting cannot be judged"
fi
assert_eq "L11b — the slot now holds the newly quarantined DB, not the superseded one" \
    "$L11B_NEW" "$(head -1 "$root_p/.codegraph/broken/codegraph.db" 2>/dev/null || true)"
assert_eq "L11b — the superseded quarantine is gone from .codegraph entirely" "" \
    "$(grep -rlF "$L11B_OLD" "$root_p/.codegraph" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
if [ -e "$root_p/.codegraph/codegraph.db" ]; then
    fail "L11b — the live path still holds a DB after the second quarantine"
else
    pass "L11b — the live path is empty after the second quarantine"
fi
if [ -e "$root_p/.codegraph/broken/broken" ]; then
    fail "L11b — quarantine nested itself at .codegraph/broken/broken"
else
    pass "L11b — no nested .codegraph/broken/broken directory"
fi
assert_eq "L11b — exactly one quarantine directory" "1" \
    "$(find "$root_p/.codegraph" -maxdepth 1 -name broken -print | wc -l | tr -d ' ')"
assert_eq "L11b — exactly one quarantined DB anywhere under .codegraph" "1" \
    "$(find "$root_p/.codegraph" -name 'codegraph.db' -print 2>/dev/null | wc -l | tr -d ' ')"

echo "--- L11c: a symlinked quarantine slot is refused, not followed ---"
reset_env
export CG_STUB_FAIL=index
root="$(mkroot "l11c")"
root_p="$(root_sh l11c)"
make_db "$root" zero
mkdir -p "$root_p/linked-away"
printf 'precious\n' > "$root_p/linked-away/keep.txt"
# node -e shifts argv: with -e the first user argument arrives as argv[1].
l11c_link_err="$("$NODE_EXE" -e 'const fs=require("node:fs");fs.symlinkSync(process.argv[1],process.argv[2],process.platform==="win32"?"junction":"dir")' \
    "$root/linked-away" "$root/.codegraph/broken" 2>&1)"
if [ ! -e "$root_p/.codegraph/broken" ]; then
    skip "L11c — this filesystem/user cannot create a directory symlink: $l11c_link_err"
else
    run_cli init "$root"
    assert_warned "L11c"
    if [ -f "$root_p/linked-away/keep.txt" ]; then
        pass "L11c — files behind the symlink are untouched"
    else
        fail "L11c — a file behind the .codegraph/broken symlink was deleted"
    fi
    if [ -f "$root_p/.codegraph/codegraph.db" ]; then
        pass "L11c — the live DB was not renamed into the symlink"
    else
        fail "L11c — the live DB was moved despite the symlinked quarantine slot"
    fi
fi

echo "--- L11d: an unrenamable DB moves nothing (POSIX) ---"
if [ "$IS_WIN32" -eq 1 ]; then
    skip "L11d — a read-only directory does not block rename on win32"
elif [ "$(id -u)" = "0" ]; then
    skip "L11d — running as root, a read-only directory does not block rename"
else
    reset_env
    export CG_STUB_FAIL=index
    root="$(mkroot "l11d")"
    root_p="$(root_sh l11d)"
    make_db "$root" zero
    : > "$root_p/.codegraph/codegraph.db-wal"
    : > "$root_p/.codegraph/codegraph.db-shm"
    chmod a-w "$root_p/.codegraph"
    run_cli init "$root"
    chmod u+w "$root_p/.codegraph"
    assert_warned "L11d"
    for leftover in codegraph.db codegraph.db-wal codegraph.db-shm; do
        if [ -f "$root_p/.codegraph/$leftover" ]; then
            pass "L11d — $leftover stayed in place"
        else
            fail "L11d — $leftover was moved even though rename must fail"
        fi
    done
fi

echo "--- L11e: a failing re-init stops the ladder, it does not loop ---"
reset_env
export CG_STUB_FAIL=index,init
root="$(mkroot "l11e")"
make_db "$root" zero
run_cli init "$root"
assert_warned "L11e"
assert_eq "L11e — index attempted exactly once" "1" "$(verb_count index)"
assert_eq "L11e — the post-quarantine init -y was attempted exactly once" "1" "$(verb_count init)"
l11e_calls="$(verb_calls)"
if [ "$l11e_calls" -le 3 ]; then
    pass "L11e — codegraph launched $l11e_calls time(s), within the ceiling of 3"
else
    fail "L11e — codegraph launched $l11e_calls times, above the ceiling of 3"
fi

echo "--- L11g: a symlinked .codegraph itself grants no reach outside the root ---"
# L11c links the quarantine slot; here the whole index directory is the link,
# so every path the repair touches resolves outside <root>. R-17 exists to stop
# exactly that, and the sentinel file proves the blast radius empirically.
reset_env
export CG_STUB_FAIL=index
l11g_ext="$TMP_BASE/external/l11g"
rm -rf "$l11g_ext"
mkdir -p "$l11g_ext/broken"
printf 'do-not-touch\n' > "$l11g_ext/sentinel.txt"
printf 'keep\n' > "$l11g_ext/broken/keep.txt"
: > "$l11g_ext/codegraph.db"
: > "$l11g_ext/codegraph.db-wal"
: > "$l11g_ext/codegraph.db-shm"
root="$(mkroot "l11g")"
root_p="$(root_sh l11g)"
l11g_err="$("$NODE_EXE" -e 'const fs=require("node:fs");fs.symlinkSync(process.argv[1],process.argv[2],process.platform==="win32"?"junction":"dir")' \
    "$(to_native "$l11g_ext")" "$root/.codegraph" 2>&1)"
l11g_is_link="$("$NODE_EXE" -e 'const fs=require("node:fs");let v="no";try{v=fs.lstatSync(process.argv[1]).isSymbolicLink()?"yes":"no"}catch(e){v="missing"};process.stdout.write(v)' \
    "$root/.codegraph")"
if [ "$l11g_is_link" != "yes" ] || [ ! -f "$root_p/.codegraph/sentinel.txt" ]; then
    skip "L11g — this filesystem/user cannot link a directory (lstat=$l11g_is_link): $l11g_err"
else
    run_cli init "$root"
    assert_warned "L11g"
    for keep in sentinel.txt codegraph.db codegraph.db-wal codegraph.db-shm broken/keep.txt; do
        if [ -e "$l11g_ext/$keep" ]; then
            pass "L11g — external $keep survived the repair attempt"
        else
            fail "L11g — external $keep was removed or renamed through the .codegraph link"
        fi
    done
    if [ -e "$l11g_ext/broken/codegraph.db" ]; then
        fail "L11g — a DB was quarantined into a directory outside the root"
    else
        pass "L11g — nothing was written into the external broken/ directory"
    fi
    assert_eq "L11g — .codegraph is still the link, not a replacement directory" "yes" \
        "$("$NODE_EXE" -e 'const fs=require("node:fs");let v="no";try{v=fs.lstatSync(process.argv[1]).isSymbolicLink()?"yes":"no"}catch(e){v="missing"};process.stdout.write(v)' "$root/.codegraph")"
fi
