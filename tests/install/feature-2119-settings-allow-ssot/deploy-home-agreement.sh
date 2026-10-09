# tests/install/feature-2119-settings-allow-ssot/deploy-home-agreement.sh
# Tests: install/lib/settings-deploy.js, install/assemble-settings.js, tests/lib/home-userprofile-pin.sh
# Tags: install, settings, deploy, home-resolution, fixture-isolation, scope:issue-specific, pwsh-not-required, TL2
# T54-T56 (#2561 S4-7): a test re-pointed HOME alone, Node resolved the home from USERPROFILE,
# and the deploy overwrote the developer's real ~/.claude/settings.json. Sourced LAST.
# Every home below is a fixture directory: a red run writes into a temp dir, never a real home.

. "$SCRIPT_CHECKOUT_ROOT/tests/lib/home-userprofile-pin.sh"

T54_VERDICTS=""

t54_seed() { # <name> -> fixture with one tool and one marker rule
    local dir
    dir="$(mk_fixture "$1")"
    mk_tool "$dir" bin/fx-tool env-bash
    write_ssot "$dir" bin/fx-tool
    printf '%s\n' 'Bash(t54-base-marker *)' > "$dir/pre.txt"
    write_settings "$dir" "$dir/pre.txt"
    write_ext "$dir" --
    printf '%s\n' "$dir"
}

t54_dir_state() { # <dir> -> untouched|settings-written|DIRTY
    if [ -f "$1/.claude/settings.json" ]; then printf 'settings-written'; return; fi
    if [ -n "$(find "$1" -mindepth 1 2>/dev/null | head -n 1)" ]; then printf 'DIRTY'; return; fi
    printf 'untouched'
}

t54_rules() { # <home> -> rules-present|RULES-MISSING
    if grep -Fq 't54-base-marker' "$1/.claude/settings.json" 2>/dev/null; then printf 'rules-present'
    else printf 'RULES-MISSING'; fi
}

# Can HOME and the platform home be made to disagree here? Only where Node ignores HOME (win32).
t54_probe() { # <home-a> <home-b> -> disagree|same|NODE-ERROR
    local out
    out="$( (cd "$TMPROOT" && unset CLAUDE_CODE_SESSION_ID && \
        HOME="$1" USERPROFILE="$(node_path "$2")" node -e '
          const fs = require("fs"), os = require("os");
          const r = (p) => { try { return fs.realpathSync(p); } catch (e) { return p; } };
          process.stdout.write(r(os.homedir()) === r(process.argv[1]) ? "same" : "disagree");
        ' "$(node_path "$1")") 2>/dev/null )" || out="NODE-ERROR"
    printf '%s' "$out"
}

# (a) HOME and USERPROFILE at two different fixture homes, no homeDir: refuse, write nothing.
t54_disagree() { # -> "probe/rc/a-state/b-state/named" | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir a b probe rc=0 out rcv named
    dir="$(t54_seed t54-disagree)"
    a="$dir/t54-home-a"; b="$dir/t54-home-b"
    mkdir -p "$a" "$b"
    probe="$(t54_probe "$a" "$b")"
    if [ "$probe" != "disagree" ]; then printf '%s/-/-/-/-' "$probe"; return; fi
    out="$( (cd "$dir" && unset CLAUDE_CODE_SESSION_ID && \
        HOME="$a" USERPROFILE="$(node_path "$b")" CLAUDE_CONFIG_DIR="$a/.claude" \
        run_with_timeout 60 node install/assemble-settings.js) 2>&1 )" || rc=$?
    if [ "$rc" -ne 0 ]; then rcv="nonzero"; else rcv="ZERO"; fi
    named="NOT-NAMED"
    if printf '%s\n' "$out" | grep -Fq 't54-home-a' && printf '%s\n' "$out" | grep -Fq 't54-home-b' \
        && printf '%s\n' "$out" | grep -Fq 'HOME'; then named="named"; fi
    printf '%s/%s/%s/%s/%s' "$probe" "$rcv" "$(t54_dir_state "$a")" "$(t54_dir_state "$b")" "$named"
}

# (b) both at the same fixture home, through the shared pin: the ordinary deploy.
t54_agree() { # -> "-/rc/state/rules" | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir h rc=0 rcv
    dir="$(t54_seed t55-agree)"
    h="$dir/t55-home-same"
    mkdir -p "$h"
    ( cd "$dir" && unset CLAUDE_CODE_SESSION_ID && pin_home_and_userprofile "$h" && \
      CLAUDE_CONFIG_DIR="$h/.claude" run_with_timeout 60 node install/assemble-settings.js ) > "$dir/t55.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then rcv="zero"; else rcv="NONZERO"; fi
    printf -- '-/%s/%s/%s' "$rcv" "$(t54_dir_state "$h")" "$(t54_rules "$h")"
}

# (c) an explicit homeDir wins whatever the environment says, agreeing or not.
t54_explicit() { # <env-disagree|env-agree> -> "-/rc/explicit-state/env-state" | sentinel
    have_lib || { missing_lib; return; }
    local dir x y e rc=0 rcv envs
    dir="$(t54_seed "t56-$1")"
    x="$dir/t56-env-x"; y="$dir/t56-env-y"; e="$dir/t56-explicit"
    mkdir -p "$x" "$y" "$e"
    [ "$1" = "env-agree" ] && y="$x"
    ( cd "$dir" && unset CLAUDE_CODE_SESSION_ID && \
      HOME="$x" USERPROFILE="$(node_path "$y")" CLAUDE_CONFIG_DIR="$x/.claude" \
      run_with_timeout 60 node -e '
        const d = require(process.argv[1] + "/install/lib/settings-deploy.js");
        Promise.resolve()
          .then(() => d.deployAssembledSettings({ agentsRoot: process.argv[1], homeDir: process.argv[2] }))
          .catch((err) => { console.error(String(err && err.message || err)); process.exit(1); });
      ' "$(node_path "$dir")" "$(node_path "$e")" ) > "$dir/t56.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then rcv="zero"; else rcv="NONZERO"; fi
    envs="env-untouched"
    [ "$(t54_dir_state "$x")" = "untouched" ] || envs="ENV-HOME-WRITTEN"
    [ "$(t54_dir_state "$y")" = "untouched" ] || envs="ENV-HOME-WRITTEN"
    printf -- '-/%s/%s/%s' "$rcv" "$(t54_dir_state "$e")" "$envs"
}

t54_setup() {
    T54_VERDICTS="disagree=$(t54_disagree)
agree=$(t54_agree)
env-disagree=$(t54_explicit env-disagree)
env-agree=$(t54_explicit env-agree)
"
}

t54_slot() { # <slot> -> verdict
    printf '%s\n' "$T54_VERDICTS" | grep "^$1=" | sed "s/^$1=//"
}

# Rows on stdin: slot|field|want|label. A slot the platform cannot build is SKIPPED per row,
# with ROWS still counted so the T10 budget is the same on every platform.
t54_run_rows() { # <id>
    local id="$1" slot field want label verdict
    while IFS='|' read -r slot field want label; do
        [ -n "$slot" ] || continue
        ROWS=$((ROWS + 1))
        verdict="$(t54_slot "$slot")"
        if [ "$slot" = "disagree" ] && [ "$(t40_field "$verdict" 1)" = "same" ]; then
            skip "$id[$slot/f$field]: this platform's Node resolves the home from HOME, so HOME and the platform home cannot disagree here (win32 only)"
            continue
        fi
        assert_eq "$id[$slot/f$field]: $label" "$want" "$(t40_field "$verdict" "$field")"
    done
}

t54_setup

case_begin "t54-home-disagreement-refused" "install/lib/settings-deploy.js"
t54_run_rows T54 <<'T54_CASES'
disagree|2|nonzero|HOME and the platform home name two different directories and no homeDir was passed: the deploy refuses instead of picking one
disagree|3|untouched|nothing at all is created under the HOME directory -- the check runs before the destination directory is made
disagree|4|untouched|and nothing under the platform home either, which is where the unguarded deploy wrote (the incident)
disagree|5|named|the message states both directories and the variable, so the operator can see which two values disagree
T54_CASES
case_end

case_begin "t55-home-agreement-deploys" "install/assemble-settings.js"
t54_run_rows T55 <<'T55_CASES'
agree|2|zero|HOME and USERPROFILE pinned at one directory by pin_home_and_userprofile is the ordinary path: exit 0
agree|3|settings-written|and the deployed file lands in that directory
agree|4|rules-present|carrying the base's rules
T55_CASES
case_end

case_begin "t56-explicit-homedir-wins" "install/lib/settings-deploy.js"
t54_run_rows T56 <<'T56_CASES'
env-disagree|2|zero|an explicit homeDir is not subject to the agreement check: a disagreeing environment does not stop it
env-disagree|3|settings-written|the file is written under the explicit homeDir
env-disagree|4|env-untouched|and neither environment home receives anything
env-agree|2|zero|with an agreeing environment the explicit homeDir still succeeds
env-agree|3|settings-written|and still decides the destination
env-agree|4|env-untouched|rather than the home the environment names
T56_CASES
case_end
