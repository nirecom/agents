# tests/feature-2119-settings-allow-ssot/orphan-classifier.sh
# Tests: install/gen-settings-allow.js, install/path-exposed-commands.txt
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T14-T16: --check as a classifier over the DEPLOYED file. Sourced AFTER write-and-drift.sh.

T14_WANT="nonzero/dropped-named/keep-silent"
T15_WANT="nonzero/gone-named/keep-silent"

# T14 -- ONE TEMPLATE PER ROW, and the pair is why there are twenty-four rather than twelve.
# Reverse-matching is regex work, and the argument-less spelling of a family differs from its
# argument-bearing sibling by exactly the trailing ` *` -- the character an over-eager pattern
# swallows and an under-eager one demands. T7b hands all twenty-four over at once, so recognising
# ONE is enough to pass there. Each spelling therefore gets its own fixture, deployed healthy
# first so the run has a real deployed file to classify, with the in-sync command asserted to
# stay OUT of the report so a "list everything" implementation cannot read as a classifier.
# Rows 17-24 are #2201's QUOTED absolute families, where the quote sits between the path and
# the wildcard -- the one place a reverse matcher is likeliest to swallow one character too many.
t14_path_template() { # <k 1..24> -> "nonzero/dropped-named/keep-silent" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local fx rcv named silent
    fx="$(mk_fixture "t14-path-$1")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    expected_path_rules bash bin/fx-keep "$fx" > "$fx/pre.txt"
    expected_path_rules bash bin/fx-dropped "$fx" | sed -n "$1p" >> "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --write
    run_gen "$fx" --check
    if [ "$GEN_RC" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-dropped'; then named="dropped-named"; else named="dropped-NOT-named"; fi
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-keep'; then silent="keep-REPORTED"; else silent="keep-silent"; fi
    printf '%s/%s/%s' "$rcv" "$named" "$silent"
}

t14_path_table() {
    local k label
    while IFS='|' read -r k label; do
        [ -n "$k" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T14[path-$k]: an orphan in the '$label' form alone is detected" \
            "$T14_WANT" "$(t14_path_template "$k")"
    done <<'T14_PATH_CASES'
1|<I> "$AGENTS_CONFIG_DIR/<P>" *
2|<I> "$AGENTS_CONFIG_DIR/<P>" (argument-less)
3|<I> <R>/<P> *
4|<I> <R>/<P> (argument-less)
5|<I> <R2W>\<P> * (Windows separators)
6|<I> <R2W>\<P> (Windows separators, argument-less)
7|<I> <P> *
8|<I> <P> (argument-less)
9|"$AGENTS_CONFIG_DIR/<P>" * (no interpreter prefix)
10|"$AGENTS_CONFIG_DIR/<P>" (no interpreter prefix, argument-less)
11|<R>/<P> * (no interpreter prefix)
12|<R>/<P> (no interpreter prefix, argument-less)
13|bash -c '<I> "$AGENTS_CONFIG_DIR/<P>" *'
14|bash -c '<I> "$AGENTS_CONFIG_DIR/<P>"' (argument-less)
15|bash -c 'cd "$AGENTS_CONFIG_DIR" && <I> "$AGENTS_CONFIG_DIR/<P>" *'
16|bash -c 'cd "$AGENTS_CONFIG_DIR" && <I> "$AGENTS_CONFIG_DIR/<P>"' (argument-less)
17|<I> "<R>/<P>" * (#2201 QUOTED absolute POSIX path)
18|<I> "<R>/<P>" (#2201 QUOTED absolute POSIX path, argument-less)
19|<I> "<R2W>\<W>" * (#2201 QUOTED absolute path, Windows separators)
20|<I> "<R2W>\<W>" (#2201 QUOTED absolute path, Windows separators, argument-less)
21|"<R>/<P>" * (#2201 QUOTED absolute POSIX path, no interpreter prefix)
22|"<R>/<P>" (#2201 QUOTED absolute POSIX path, no interpreter prefix, argument-less)
23|"<R2W>\<W>" * (#2201 QUOTED absolute Windows path, no interpreter prefix)
24|"<R2W>\<W>" (#2201 QUOTED absolute Windows path, no interpreter prefix, argument-less)
T14_PATH_CASES
}

# T15 -- THE SIX BARE FORMS, which T7b never exercises at all. They are keyed on a different
# SSOT (install/path-exposed-commands.txt) and extract a basename rather than a path, so an
# implementation can reverse-match all twenty-four path forms and still be blind to every one of
# these. The fixture's own command IS PATH-exposed, so its thirty rules are complete and
# the orphan is the only finding.
t15_bare_template() { # <k 1..6> -> "nonzero/gone-named/keep-silent" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local fx rcv named silent
    fx="$(mk_fixture "t15-bare-$1")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    printf '%s\n' 'fx-keep' >> "$fx/install/path-exposed-commands.txt"
    expected_path_rules bash bin/fx-keep "$fx" > "$fx/pre.txt"
    expected_bare_rules fx-keep >> "$fx/pre.txt"
    expected_bare_rules fx-gone | sed -n "$1p" >> "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --write
    run_gen "$fx" --check
    if [ "$GEN_RC" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-gone'; then named="gone-named"; else named="gone-NOT-named"; fi
    if printf '%s\n' "$GEN_OUT" | grep -q 'fx-keep'; then silent="keep-REPORTED"; else silent="keep-silent"; fi
    printf '%s/%s/%s' "$rcv" "$named" "$silent"
}

t15_bare_table() {
    local k label
    while IFS='|' read -r k label; do
        [ -n "$k" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T15[bare-$k]: a bare-form orphan in the '$label' form alone is detected" \
            "$T15_WANT" "$(t15_bare_template "$k")"
    done <<'T15_BARE_CASES'
1|<N> *
2|<N> (argument-less)
3|bash -c '<N> *'
4|bash -c '<N>' (argument-less)
5|bash -c 'cd "$AGENTS_CONFIG_DIR" && <N> *'
6|bash -c 'cd "$AGENTS_CONFIG_DIR" && <N>' (argument-less)
T15_BARE_CASES
}

T16_COMPLETE=""
T16_BOTH=""

# T16 -- THE REPORT IS THE PRODUCT. `--check` runs where a non-zero exit with a vague message
# costs a developer the whole diagnosis. Two properties are asserted: the missing list is
# COMPLETE (all thirty spellings for a command with nothing deployed, not just the first
# the loop noticed), and Missing and Orphaned are reported as two separate sections in the
# SAME run -- the state a real drifted machine is in. Both fixtures are DEPLOYED FIRST from an
# SSOT that lists nothing, and the SSOT is rewritten afterwards: that is what leaves the
# deployed file legitimately short of the wanted rules. A fixture that never deployed would
# exit non-zero because there is no deployed file to read, and every row below would pass
# without the classifier existing at all.
t16_setup() {
    T16_COMPLETE="$(mk_fixture t16-complete)"
    mk_tool "$T16_COMPLETE" bin/fx-keep env-bash
    : > "$T16_COMPLETE/install/settings-allow-commands.txt"
    write_settings "$T16_COMPLETE" --
    run_gen "$T16_COMPLETE" --write
    write_ssot "$T16_COMPLETE" bin/fx-keep
    printf '%s\n' 'fx-keep' >> "$T16_COMPLETE/install/path-exposed-commands.txt"
    {
        expected_path_rules bash bin/fx-keep "$T16_COMPLETE"
        expected_bare_rules fx-keep
    } > "$T16_COMPLETE/want.txt"

    T16_BOTH="$(mk_fixture t16-both)"
    mk_tool "$T16_BOTH" bin/fx-keep env-bash
    : > "$T16_BOTH/install/settings-allow-commands.txt"
    expected_path_rules bash bin/fx-dropped "$T16_BOTH" > "$T16_BOTH/pre.txt"
    write_settings "$T16_BOTH" "$T16_BOTH/pre.txt"
    run_gen "$T16_BOTH" --write
    write_ssot "$T16_BOTH" bin/fx-keep
}

# A section heading is a line that talks about missing or orphaned entries and is not itself a
# rule string, so a report that only lists `Bash(...)` lines cannot pass as sectioned output.
t16_probe() { # <complete|missing-section|orphan-section|both-named|rc> -> verdict | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local rule
    if [ "$1" = "complete" ]; then
        run_gen "$T16_COMPLETE" --check
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            printf '%s\n' "$GEN_OUT" | grep -Fq -- "$rule" || { printf 'NOT-REPORTED:%s' "$rule"; return; }
        done < "$T16_COMPLETE/want.txt"
        printf 'complete'
        return
    fi
    run_gen "$T16_BOTH" --check
    case "$1" in
        missing-section)
            printf '%s\n' "$GEN_OUT" | grep -vi '^ *Bash(' | grep -qi 'missing' \
                && { printf 'yes'; return; } ;;
        orphan-section)
            printf '%s\n' "$GEN_OUT" | grep -vi '^ *Bash(' | grep -qi 'orphan' \
                && { printf 'yes'; return; } ;;
        both-named)
            printf '%s\n' "$GEN_OUT" | grep -q 'fx-keep' \
                && printf '%s\n' "$GEN_OUT" | grep -q 'fx-dropped' \
                && { printf 'yes'; return; } ;;
        rc)
            [ "$GEN_RC" -ne 0 ] && { printf 'yes'; return; } ;;
    esac
    printf 'no'
}

t16_report_table() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T16[$id]: $label" "yes" "$(t16_probe "$id")"
    done <<'T16_CASES'
missing-section|a Missing section is named when spellings are absent from the deployed file
orphan-section|an Orphaned section is named in the SAME run
both-named|both the missing command and the orphaned one appear in one report
rc|a run carrying both findings exits non-zero
T16_CASES
    ROWS=$((ROWS + 1))
    assert_eq "T16[complete]: all thirty spellings are listed for a command with no deployed rules at all (not just the first)" \
        "complete" "$(t16_probe complete)"
}

# T35 -- THE BARE-ORPHAN GUARD, BOTH DIRECTIONS. A bare rule carries no path, so "is this one
# of ours?" is decided by heuristic: the name must look internal (it carries a `-` or `_` or
# `.`) AND must not be a real command living under bin/. T15 only ever shows the guard saying
# YES. A guard that always says yes passes every T15 row and then deletes a developer's own
# `Bash(my-tool *)` on the next --write. So each verdict is asserted in both name shapes.
t35_bare_guard() { # <name> <extant|ghost> -> "<claimed|not-claimed>/rc=<n>" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local fx claimed
    fx="$(mk_fixture "t35-$1")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    printf '%s\n' 'fx-keep' >> "$fx/install/path-exposed-commands.txt"
    [ "$2" = "extant" ] && mk_tool "$fx" "bin/$1" env-bash
    {
        expected_path_rules bash bin/fx-keep "$fx"
        expected_bare_rules fx-keep
        expected_bare_rules "$1"
    } > "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --write
    run_gen "$fx" --check
    if printf '%s\n' "$GEN_OUT" | grep -q -- "$1"; then claimed="claimed"; else claimed="not-claimed"; fi
    printf '%s/rc=%s' "$claimed" "$GEN_RC"
}

t35_guard_table() {
    local name kind want label
    while IFS='|' read -r name kind want label; do
        [ -n "$name" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T35[$name/$kind]: $label" "$want" "$(t35_bare_guard "$name" "$kind")"
    done <<'T35_CASES'
fx-ghost-cmd|ghost|claimed/rc=1|POSITIVE CONTROL: a separator-bearing name with no file under bin/ is the shape the generator itself emits, so it is claimed as an orphan
fx-extant-cmd|extant|not-claimed/rc=0|a separator-bearing name that IS a real command under bin/ is left alone -- being absent from the SSOT is not the same as being ours to delete
fxextantcmd|extant|not-claimed/rc=0|a separator-free name of a real bin/ command is left alone by both halves of the guard
fxghostcmd|ghost|not-claimed/rc=0|a separator-free name with no file anywhere is STILL left alone: the shape rule alone disqualifies it, so a hand-written `Bash(myscript *)` survives
T35_CASES
}

T47_A=""
T47_B=""

# T47 -- THE CLASSIFIER IS KEYED ON THE ROOT, and the root is now inside the rule string. Once
# the leading-wildcard spellings become the deploy-time absolute path, `isGeneratedShaped` can
# no longer answer "is this ours?" from shape alone: a rule generated under ANOTHER checkout is
# a foreign absolute path, and calling it ours would let one clone's --write delete a rule
# another clone deployed. Both directions are asserted, because a classifier that always says
# "not ours" passes one of them for free. The metachar root is the same question asked of the
# regex builder: the root is interpolated into a pattern, so a `.` or `+` that reaches it
# unescaped silently WIDENS the match instead of narrowing it (CPR-UNV).
t47_setup() {
    T47_A="$(mk_fixture 't47.root+a-b')"
    mk_tool "$T47_A" bin/fx-keep env-bash
    write_ssot "$T47_A" bin/fx-keep
    T47_B="$(mk_fixture 't47+other')"
    mk_tool "$T47_B" bin/fx-keep env-bash
    write_ssot "$T47_B" bin/fx-keep
}

# Both fixture roots carry a `+`, which `<P>` and `<W>` exclude: without it an absolute POSIX
# path would also satisfy the root-free repo-relative template, and "recognised under the other
# root" could not be told apart from "recognised as a relative path".
t47_probe() { # <mode> -> token | sentinel
    have_lib || { missing_lib; return; }
    run_with_timeout 20 node -e '
      const path = require("path");
      let M;
      try { M = require(process.argv[1]); }
      catch (e) { console.log("REQUIRE-FAILED:" + String(e.message).split("\n")[0]); process.exit(0); }
      const A = path.resolve(process.argv[2]), B = path.resolve(process.argv[3]), mode = process.argv[4];
      const gen = (root, tag) => {
        try { return M.generatedAllowRules({ agentsRoot: root }).rules; }
        catch (e) { console.log("GEN-FAILED-" + tag + ":" + String(e.message).split("\n")[0]); process.exit(0); }
      };
      const RA = gen(A, "A"), RB = gen(B, "B");
      const spell = (p) => [p, p.split("/").join("\\"), p.split("\\").join("/")];
      const carries = (r, root) => spell(root).some((s) => r.includes(s));
      const shaped = (r, root) => {
        try { return M.isGeneratedShaped(r, false, root); }
        catch (e) { return "THREW:" + String(e.message).split("\n")[0]; }
      };
      if (mode === "same-root") {
        for (const r of RA) {
          const s = shaped(r, A);
          if (s !== true) { console.log(typeof s === "string" ? s : "NOT-SHAPED:" + r); process.exit(0); }
        }
        console.log("all-shaped"); process.exit(0);
      }
      if (mode === "cross-root" || mode === "cross-root-back") {
        const fwd = mode === "cross-root";
        const src = fwd ? RA : RB, own = fwd ? A : B, other = fwd ? B : A;
        const bearing = src.filter((r) => carries(r, own));
        if (bearing.length === 0) { console.log("NO-ROOT-BEARING-RULES"); process.exit(0); }
        for (const r of bearing) {
          if (shaped(r, own) !== true) { console.log("NOT-SHAPED-AT-HOME:" + r); process.exit(0); }
          const o = shaped(r, other);
          if (o !== false) { console.log(typeof o === "string" ? o : "SHAPED-UNDER-OTHER-ROOT:" + r); process.exit(0); }
        }
        console.log("orphan-under-other-root"); process.exit(0);
      }
      if (mode === "metachar-nearmiss") {
        const bearing = RA.filter((r) => carries(r, A));
        if (bearing.length === 0) { console.log("NO-ROOT-BEARING-RULES"); process.exit(0); }
        const variants = [];
        for (const r of bearing) {
          for (const pair of [["47.root", "47Xroot"], ["t+a", "tta"]]) {
            if (r.includes(pair[0])) variants.push(r.split(pair[0]).join(pair[1]));
          }
        }
        if (variants.length === 0) { console.log("NO-VARIANTS"); process.exit(0); }
        for (const v of variants) {
          const s = shaped(v, A);
          if (s !== false) { console.log(typeof s === "string" ? s : "NEAR-MISS-MATCHED:" + v); process.exit(0); }
        }
        console.log("no-near-miss-match"); process.exit(0);
      }
      console.log("UNKNOWN-MODE");
    ' -- "$(node_path "$AGENTS_DIR/install/lib/settings-allow-rules.js")" \
         "$(node_path "$T47_A")" "$(node_path "$T47_B")" "$1" 2>&1
}

t47_root_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T47[$id]: $label" "$want" "$(t47_probe "$id")"
    done <<'T47_CASES'
same-root|all-shaped|CONTROL: every rule the generator emits for a root is recognised as generated-shaped under THAT root -- without this the two rows below could pass by classifying everything as foreign
cross-root|orphan-under-other-root|a rule generated under one checkout is NOT generated-shaped under a different one: the absolute root is part of the rule, so a second clone must read it as somebody else's and leave it alone rather than delete it
cross-root-back|orphan-under-other-root|CPR-ORTH, the other direction: the asymmetry holds whichever root is asked, so it is a property of the classifier and not of which fixture happened to be built first
metachar-nearmiss|no-near-miss-match|a root containing `.` and `+` is escaped before it reaches the matcher: a near-miss path that differs from the real root only where a regex metacharacter sits must NOT be claimed, or the rule quietly matches paths nobody deployed
T47_CASES
}

t14_path_table
t15_bare_table
t16_setup
t16_report_table
t35_guard_table
t47_setup
t47_root_table
