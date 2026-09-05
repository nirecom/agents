# tests/feature-2119-settings-allow-ssot/rt0-calling-convention.sh
# Tests: skills/review-tests/SKILL.md
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T48: RT-0's calling convention, as text, polarity included.

RT0_SKILL_REL="skills/review-tests/SKILL.md"
RT0_SKILL="$AGENTS_DIR/$RT0_SKILL_REL"
RT0_DIR=""
RT0_REGION=""

# T48 -- THE OTHER HALF OF THE FIX. The generated rules only stop the prompt for the spelling
# the model actually issues, and RT-0 is where this repo TELLS the model which spelling to
# issue: a rule for `Bash("<R>/bin/resolve-worktree-path")` buys nothing if the step is read as
# licence to add an argument, an env prefix or an `&& echo $?`. Each of those turns the command
# line into a string no generated rule matches, and the step falls back to `ask` -- the exact
# failure #2201 opened on. The four clauses are therefore asserted as text, not left to review.

# Scoped to RT-0's own block. SKILL.md talks about standalone commands in RT-1 as well, so a
# file-wide grep would report RT-0 as hardened while RT-0 said nothing.
rt0_region() { # <skill-md> <out-file>
    awk '
      /^[[:space:]]*RT-0a\./ || /^[[:space:]]*RT-[1-9]/ { inr = 0 }
      /^[[:space:]]*RT-0\./ { inr = 1 }
      inr { print }
    ' "$1" > "$2" 2>/dev/null
}

# ONE SSOT FOR THE CLAUSE PROBES, read by all three tables below: the real file, the reference
# fixture that proves the probes are satisfiable at all, and the mutants that prove they
# discriminate. A probe defined once cannot be relaxed for the real file alone.
# Alternation needs `|` for itself, so the list is `~`-delimited and every ERE must match the
# SAME line -- a prohibition split across two sentences is not what a reader obeys.
rt0_eres() { # <clause> -> ~-delimited ERE list
    case "$1" in
        one-command)   printf '%s' 'single standalone|standalone command|one standalone|a single command' ;;
        no-arguments)  printf '%s' '\bno\b|without|never|\bnot\b~argument|parameter|operand' ;;
        no-env-prefix) printf '%s' '\bno\b|without|never|\bnot\b~prefix~env|variable|=' ;;
        no-chaining)   printf '%s' '\bno\b|without|never|\bnot\b~chain|&&' ;;
        exit-separate) printf '%s' 'separate|subsequent|second|another~exit code|exit status|return code|[$]\?~command|call|invocation|line' ;;
        *)             printf '%s' 'UNKNOWN-CLAUSE-@@@' ;;
    esac
}

# POLARITY IS NOT VOCABULARY, and the list above matches vocabulary. Every keyword survives its
# own reversal: "Do not forbid chaining with `&&`" and "Do not use a separate command for the
# exit code" carry every token the probes look for while instructing the OPPOSITE, so a document
# hardened only in wording would satisfy all five clauses. Each clause therefore also owns a
# VETO -- a negation binding the clause's own directive verb, or the meta-verb a reversal has to
# reach for (forbid / require / necessary), disqualifies the line that would otherwise settle it.
RT0_NEG='(\bnot\b|\bno\b|\bnone\b|never|no longer|need not|nothing|don.t|doesn.t|isn.t|aren.t|cannot|can.t)'
RT0_META='(forbid|prohibit|disallow|avoid|refrain|require|insist|mandate|matter|prevent|claim|necessary)'

# The two REQUIREMENT clauses veto a negation of their own directive as well: "do not run it as a
# standalone command" reverses one-command without touching a meta-verb. The three PROHIBITION
# clauses cannot do the same -- "do not chain" IS their correct form -- so only the double
# negation is vetoed there.
rt0_anti_eres() { # <clause> -> ERE a satisfying line must NOT match
    case "$1" in
        one-command)   printf '%s' "$RT0_NEG[^.]{0,24}($RT0_META|\brun\b|\binvoke\b|\bissue\b|\bcall\b|\btreat\b|\buse\b|\bwrite\b|standalone|\bsingle\b)" ;;
        exit-separate) printf '%s' "$RT0_NEG[^.]{0,24}($RT0_META|\buse\b|\brun\b|inspect|\bcheck\b|\bread\b|\bissue\b|\bwrite\b|\bput\b|separate|second|subsequent|another)" ;;
        no-arguments|no-env-prefix|no-chaining) printf '%s' "$RT0_NEG[^.]{0,24}$RT0_META" ;;
        *)             printf '%s' 'UNKNOWN-CLAUSE-@@@' ;;
    esac
}

# The veto is applied to the SAME line the positives are read from, never file-wide: a clause
# stated correctly on one line is not undone by a negation three paragraphs away.
rt0_probe() { # <text-file> <clause> -> satisfied|NOT-SATISFIED|sentinel
    local file="$1" anti line ere ok old_ifs
    local -a probes=()
    [ -f "$RT0_SKILL" ] || { printf '<MISSING:%s>' "$RT0_SKILL_REL"; return; }
    [ -s "$file" ] || { printf '<EMPTY-TEXT:%s>' "$(basename "$file")"; return; }
    anti="$(rt0_anti_eres "$2")"
    old_ifs="$IFS"; IFS='~'; set -f
    # shellcheck disable=SC2206
    probes=($(rt0_eres "$2"))
    set +f; IFS="$old_ifs"
    while IFS= read -r line; do
        printf '%s\n' "$line" | grep -Eqi -- "$anti" && continue
        ok=yes
        for ere in "${probes[@]}"; do
            printf '%s\n' "$line" | grep -Eqi -- "$ere" || { ok=no; break; }
        done
        [ "$ok" = yes ] && { printf 'satisfied'; return; }
    done < "$file"
    printf 'NOT-SATISFIED'
}

# THE FIXTURE IS WRITTEN HERE, NOT READ FROM THE REPO. A negative case has to be text that
# omits or contradicts one clause, and the only text guaranteed to do that is text this file
# owns: pointing the mutants at the real file would make them pass for as long as the file
# stays unhardened and start failing the day it is fixed. One clause per line, so a mutant
# drops or contradicts exactly one and the other four keep answering `satisfied`.
rt0_fixture() { # <case> <out-file>
    local cmd args envp chain exitc
    cmd='RT-0. Run `"$AGENTS_CONFIG_DIR/bin/resolve-worktree-path"` as a single standalone command.'
    args='  Pass it no positional arguments.'
    envp='  Use no environment-variable prefix on the invocation.'
    chain='  Use no command chaining: no `&&`, no `;` and no `|` on that command line.'
    exitc='  Inspect its exit code in a separate, subsequent command.'
    case "$1" in
        hardened)              : ;;
        omit-one-command)      cmd='RT-0. Run `"$AGENTS_CONFIG_DIR/bin/resolve-worktree-path"`.' ;;
        omit-arguments)        args='' ;;
        contradict-arguments)  args='  Pass the worktree path to it as a positional argument.' ;;
        omit-env-prefix)       envp='' ;;
        contradict-env-prefix) envp='  Set `CLAUDE_SESSION_ID=abc` as a prefix on the invocation.' ;;
        omit-chaining)         chain='' ;;
        contradict-chaining)   chain='  Chain the exit-code check onto it with `&&`.' ;;
        omit-exit)             exitc='' ;;
        contradict-exit)       exitc='  Inspect its exit code on the same command line as the run itself.' ;;
        invert-one-command)     cmd='RT-0. Do not run it as a single standalone command.' ;;
        invert-one-command-need) cmd='RT-0. Running it as a single standalone command is no longer required.' ;;
        invert-arguments)       args='  Do not forbid a positional argument on that command line.' ;;
        invert-arguments-need)  args='  Passing it no positional arguments is not required.' ;;
        invert-env-prefix)      envp='  It is not forbidden to set an environment-variable prefix on the invocation.' ;;
        invert-env-prefix-need) envp='  Using no environment-variable prefix is not necessary.' ;;
        invert-chaining)        chain='  Do not forbid chaining with `&&` on that command line.' ;;
        invert-chaining-need)   chain='  Chaining with `&&` is not forbidden on that command line.' ;;
        invert-exit)            exitc='  Do not use a separate command for the exit code.' ;;
        invert-exit-need)       exitc='  Inspecting the exit code in a separate command is no longer required.' ;;
        *)                     printf '%s\n' 'UNKNOWN-FIXTURE-CASE' > "$2"; return ;;
    esac
    printf '%s\n' "$cmd" "$args" "$envp" "$chain" "$exitc" > "$2"
}

t48_setup() {
    RT0_DIR="$TMPROOT/t48"
    mkdir -p "$RT0_DIR"
    RT0_REGION="$RT0_DIR/rt0-region.txt"
    rt0_region "$RT0_SKILL" "$RT0_REGION"
    rt0_fixture hardened "$RT0_DIR/hardened.txt"
}

# The extraction is asserted before anything is read out of it: an awk range that silently
# matched nothing would report every clause as NOT-SATISFIED and read as a hardening failure.
rt0_region_probe() { # <found|names-tool> -> yes|no|sentinel
    [ -f "$RT0_SKILL" ] || { printf '<MISSING:%s>' "$RT0_SKILL_REL"; return; }
    case "$1" in
        found)      [ -s "$RT0_REGION" ] && { printf 'yes'; return; } ;;
        names-tool) grep -Fq 'bin/resolve-worktree-path' "$RT0_REGION" 2>/dev/null \
                        && { printf 'yes'; return; } ;;
    esac
    printf 'no'
}

t48_region_table() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T48[region-$id]: $label" "yes" "$(rt0_region_probe "$id")"
    done <<'T48_REGION_CASES'
found|PRECONDITION: the RT-0 block is found in $RT0_SKILL_REL -- a renamed or renumbered step would otherwise report every clause below as missing prose
names-tool|PRECONDITION: the extracted block is RT-0 and not a neighbour -- it names bin/resolve-worktree-path, the command whose spelling the clauses govern
T48_REGION_CASES
}

t48_skill_table() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T48[skill-$id]: RT-0 in $RT0_SKILL_REL $label" \
            "satisfied" "$(rt0_probe "$RT0_REGION" "$id")"
    done <<'T48_SKILL_CASES'
one-command|says the tool is run as ONE standalone command, the shape the generated rules are written for
no-arguments|says it takes no arguments: a trailing argument is admitted only by the ` *` half of the pair, and the argument-less rule is the one this repo pins for it
no-env-prefix|says no environment-variable prefix precedes it -- a `FOO=1 cmd` line begins with a token no generated rule starts with, so the whole rule set misses it
no-chaining|says the command is not chained -- the permission engine matches the WHOLE command string, so `cmd && echo` is a different string from `cmd` and matches nothing
exit-separate|says the exit code is inspected in a SEPARATE command, which is the only way to obey the no-chaining clause and still branch on failure
T48_SKILL_CASES
}

# The reference fixture is the falsifiability control: without it, five unsatisfiable regexes
# would be indistinguishable from five clauses the document has yet to state.
t48_reference_table() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T48[reference-$id]: $label" \
            "satisfied" "$(rt0_probe "$RT0_DIR/hardened.txt" "$id")"
    done <<'T48_REFERENCE_CASES'
one-command|CONTROL: a text that does state the standalone-command clause satisfies the probe
no-arguments|CONTROL: the no-arguments probe is satisfiable by ordinary prose, not only by one exact wording
no-env-prefix|CONTROL: so is the no-env-prefix probe
no-chaining|CONTROL: so is the no-chaining probe
exit-separate|CONTROL: so is the separate-exit-code probe
T48_REFERENCE_CASES
}

t48_negative_table() {
    local case_ clause label out
    while IFS='|' read -r case_ clause label; do
        [ -n "$case_" ] || continue
        ROWS=$((ROWS + 1))
        out="$RT0_DIR/$case_.txt"
        rt0_fixture "$case_" "$out"
        assert_eq "T48[negative-$case_]: $label" \
            "NOT-SATISFIED" "$(rt0_probe "$out" "$clause")"
    done <<'T48_NEGATIVE_CASES'
omit-one-command|one-command|a text that never says "standalone command" fails the standalone clause -- the probe is reading the clause, not the step label
omit-arguments|no-arguments|dropping the no-arguments sentence is detected, so the row above cannot be passing on the other four clauses
contradict-arguments|no-arguments|and text that INSTRUCTS a positional argument fails too: the probe requires a prohibition, not merely the word "argument"
omit-env-prefix|no-env-prefix|dropping the env-prefix sentence is detected
contradict-env-prefix|no-env-prefix|text that instructs an env-variable prefix fails, so the clause cannot be satisfied by a passage that merely mentions one
omit-chaining|no-chaining|dropping the no-chaining sentence is detected
contradict-chaining|no-chaining|text that tells the reader to chain with `&&` fails -- an example of the forbidden shape is not a prohibition of it
omit-exit|exit-separate|dropping the separate-exit-code sentence is detected
contradict-exit|exit-separate|text that puts the exit-code check on the SAME command line fails, which is the wording the no-chaining clause alone would leave admissible
T48_NEGATIVE_CASES
}

# THE INVERSE MUTANTS. Every row below RETAINS each keyword its clause matches and reverses only
# the polarity -- the one mutation a co-occurrence probe cannot see, and the one a hurried edit
# to SKILL.md really produces ("do not forbid", "is no longer required"). Without them the whole
# T48 block would certify a document that licenses exactly the command lines #2201 exists to stop.
# Two shapes per clause: the negated directive itself, and the negated OBLIGATION to obey it.
t48_inverse_table() {
    local case_ clause label out
    while IFS='|' read -r case_ clause label; do
        [ -n "$case_" ] || continue
        ROWS=$((ROWS + 1))
        out="$RT0_DIR/$case_.txt"
        rt0_fixture "$case_" "$out"
        assert_eq "T48[inverse-$case_]: $label" \
            "NOT-SATISFIED" "$(rt0_probe "$out" "$clause")"
    done <<'T48_INVERSE_CASES'
invert-one-command|one-command|"Do not run it as a single standalone command" keeps every word the standalone probe matches and reverses it, so keyword presence alone cannot settle the clause
invert-one-command-need|one-command|and neither can a sentence that keeps the clause but cancels the obligation ("is no longer required")
invert-arguments|no-arguments|"Do not forbid a positional argument" is a double negation carrying both the negation word and the noun the no-arguments probe reads
invert-arguments-need|no-arguments|"Passing it no positional arguments is not required" states the clause and then withdraws it in the same breath
invert-env-prefix|no-env-prefix|"It is not forbidden to set an environment-variable prefix" LICENSES the `FOO=1 cmd` shape while matching every env-prefix keyword
invert-env-prefix-need|no-env-prefix|and so does cancelling the obligation to omit the prefix
invert-chaining|no-chaining|Codex's own example: "Do not forbid chaining with `&&`" -- the exact sentence that would leave `cmd && echo $?` admissible with the clause apparently present
invert-chaining-need|no-chaining|and "Chaining with `&&` is not forbidden", the same reversal in the passive voice a reviewer skims past
invert-exit|exit-separate|Codex's other example: "Do not use a separate command for the exit code" reverses the only clause that makes the no-chaining prohibition obeyable
invert-exit-need|exit-separate|and cancelling that requirement outright is caught too, so the clause cannot be satisfied by a sentence that merely mentions a separate command
T48_INVERSE_CASES
}

t48_setup
t48_region_table
t48_skill_table
t48_reference_table
t48_negative_table
t48_inverse_table
