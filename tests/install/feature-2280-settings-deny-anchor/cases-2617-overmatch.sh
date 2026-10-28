# tests/install/feature-2280-settings-deny-anchor/cases-2617-overmatch.sh
# Tests: settings.json
# Tags: settings, permissions, deny, allow, force-push, force-with-lease, worktree-remove, git-clean, overmatch, scope:issue-specific, pwsh-not-required, TL2
# OV1-OV7 (#2617): the substring deny floor that over-matched is gone; the argv-aware hook owns it.

# WHY STATIC ROWS. `*` spans spaces, so the host denied `feature/2572-feature-x` through
# `Bash(git push *-f*)`. matcher.sh adds a word-boundary guard after `*` that the host does not
# have, so it reports NO-MATCH for those commands even while the rule is deployed: OV1 alone
# cannot see the bug. OV3 pins the removal by rule literal, and OV1 keeps the commands visible.

OV_H40="0123456789abcdef0123456789abcdef01234567"
OV_PEER='git -C C:/git/agents worktree remove C:/git/worktrees/2765-find-pr-by-marker-sh/agents'
OV_LEASE_PAT='git push *--force-with-lease=*:*'

# Re-homes permissions.allow as a `deny` array in a fixture so matcher.sh and deny_list_has
# answer allow questions without a second copy of the matcher.
OV_ALLOW_SPLIT_JS='
const fs = require("fs");
const [settingsPath, outFile] = process.argv.slice(-2);
let allow;
try { allow = JSON.parse(fs.readFileSync(settingsPath, "utf8")).permissions.allow; }
catch (e) { process.stdout.write("ERROR:unreadable-settings"); process.exit(0); }
fs.writeFileSync(outFile, JSON.stringify({ permissions: { deny: Array.isArray(allow) ? allow : [] } }));
process.stdout.write("ok");
'

# ov_static <id> <settings> <bare-pattern> <present|absent> -- one deny_list_has row.
ov_static() {
    local id="$1" file="$2" pat="$3" want="$4" got=absent
    ROWS=$((ROWS + 1))
    deny_list_has "$file" "$pat" && got=present
    assert_eq "$id: Bash($pat) is $want" "$want" "$got"
}

t_2617_overmatch() {
    local rows=() row id cmd pat want ids=() cmds=() pats=() wants=() i
    local prefixes=("git " "git -C * " "git -c * " "git --no-pager ") prefix trig fx fx_np res got

    # OV1/OV2/OV7: matcher rows against the real settings.json (id@@command@@pattern@@want).
    rows=(
        "OV1-hyphen-f-branch@@git push -u origin feature/2572-feature-x@@any@@NO-MATCH"
        "OV1-inner-plus@@git push origin a+b@@any@@NO-MATCH"
        "OV1-wt-path-hyphen-f@@git worktree remove ../wt-feature-x@@any@@NO-MATCH"
        "OV1-clean-path-fd@@git clean -n -- dir-fd@@any@@NO-MATCH"
        "OV1-explicit-lease@@git push --force-with-lease=main:$OV_H40 origin main@@any@@NO-MATCH"
        "OV1-peer-worktree@@$OV_PEER@@any@@NO-MATCH"
        "OV2-matching-refspec@@git push origin :@@git push origin :*@@MATCHED"
        "OV2-repo-colon-delete@@git push --repo origin :old@@git push *origin :*@@MATCHED"
        # OV7: the retained positional floor `push *-f *` (the -f between remote and refspec) MATCHES in every launch form.
        "OV7-bare-mid-f@@git push origin -f main@@git push *-f *@@MATCHED"
        "OV7-dashC-mid-f@@git -C /x push origin -f main@@git -C * push *-f *@@MATCHED"
        "OV7-dashc-mid-f@@git -c a.b=c push origin -f main@@git -c * push *-f *@@MATCHED"
        "OV7-nopager-mid-f@@git --no-pager push origin -f main@@git --no-pager push *-f *@@MATCHED"
    )
    for row in "${rows[@]}"; do
        if ! row_is_well_formed "$row" 4; then echo "FAIL: harness -- malformed OV row [$row]"; exit 1; fi
        id="${row%%@@*}"; row="${row#*@@}"
        cmd="${row%%@@*}"; row="${row#*@@}"
        pat="${row%%@@*}"; want="${row#*@@}"
        ids+=("$id"); cmds+=("$cmd"); pats+=("$pat"); wants+=("$want")
        dp_req "$id" "$SETTINGS" "$cmd"
    done
    dp_run "2617-overmatch"
    for i in "${!ids[@]}"; do
        check_deny_row "${ids[$i]}" "${cmds[$i]}" "${pats[$i]}" "${wants[$i]}" no
    done

    # OV3: the over-matching substring floors are gone in every launch form (20 rows).
    for trig in "push *-f*" "push *+*" "clean *-f*d*" "clean *-d*f*" "worktree remove*-f*"; do
        for prefix in "${prefixes[@]}"; do
            ov_static "OV3-removed" "$SETTINGS" "${prefix}${trig}" absent
        done
    done

    # OV4: the `:` refspec floor (delete and matching push) stays in every launch form (8 rows).
    for trig in "push origin :*" "push *origin :*"; do
        for prefix in "${prefixes[@]}"; do
            ov_static "OV4-kept" "$SETTINGS" "${prefix}${trig}" present
        done
    done

    # OV5: permissions.allow auto-approves only the explicit lease; `-c` stays out (it can inject config).
    fx="$TMPROOT/ov-allow-as-deny.json"
    dp_node_path "$TMPROOT"; fx_np="$DP_NODE_PATH/ov-allow-as-deny.json"
    dp_node_path "$SETTINGS"
    res="$(node -e "$OV_ALLOW_SPLIT_JS" "$DP_NODE_PATH" "$fx_np")"
    if [ "$res" != "ok" ]; then echo "FAIL: harness -- allow split returned [$res]"; exit 1; fi
    ov_static "OV5-allow" "$fx" "$OV_LEASE_PAT" present
    ov_static "OV5-allow" "$fx" "git -C * push *--force-with-lease=*:*" present
    ov_static "OV5-allow" "$fx" "git --no-pager push *--force-with-lease=*:*" present
    ov_static "OV5-allow" "$fx" "git push *--force-with-lease*" absent
    ov_static "OV5-allow" "$fx" "git -C * push *--force-with-lease*" absent
    ov_static "OV5-allow" "$fx" "git -c * push *--force-with-lease=*:*" absent

    # OV6: what the allow rules actually approve -- explicit lease yes, value-less lease no.
    dp_req OV6-explicit "$fx" "git push --force-with-lease=main:$OV_H40 origin main"
    dp_req OV6-bare "$fx" "git push --force-with-lease origin main"
    dp_req OV6-ref-only "$fx" "git push --force-with-lease=main origin main"
    dp_run "2617-allow-lease"
    ROWS=$((ROWS + 1))
    dp_get OV6-explicit
    got="NO"; deny_hits_contain "$OV_LEASE_PAT" && got="YES"
    assert_eq "OV6-explicit: the explicit lease is approved through Bash($OV_LEASE_PAT)" "MATCHED|YES" "$DENY_VERDICT|$got"
    ROWS=$((ROWS + 1))
    dp_get OV6-bare
    assert_eq "OV6-bare: no allow rule approves the value-less lease (hits: ${DENY_HITS:-none})" "NO-MATCH" "$DENY_VERDICT"
    ROWS=$((ROWS + 1))
    dp_get OV6-ref-only
    assert_eq "OV6-ref-only: no allow rule approves the ref-only lease (hits: ${DENY_HITS:-none})" "NO-MATCH" "$DENY_VERDICT"
}
