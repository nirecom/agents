# tests/prompt-bash-node-calling-convention/exec-position-sweep.sh
# Tests: install/settings-allow-commands.txt, install/lib/settings-allow-rules.js
# Tags: prompt, permissions, calling-convention, ssot, scope:common, pwsh-not-required, TL2
# T50-T57: the execution-position sweep. Sourced AFTER exec-position-fixtures.sh, which owns
# the fixture trees, the runner and the reducer.

# T50 -- THE REAL REPO, AT ZERO. Every entry in install/settings-allow-commands.txt, in every
# prompt asset the sweep walks, must appear with a literal `bash`/`node` in execution position
# and the interpreter its shebang resolves to. The zero-offender claim is only evidence because
# the SAME code path, on the fixture trees below, really does report all four deviant verdicts.
EXCL_SET='rules/fx-exclusion-prose.md,rules/fx-exclusion-argument.md,rules/fx-exclusion-allow-rule.md'
DEV_SET='rules/fx-deviant-no-interpreter.md,rules/fx-deviant-unexpected-prefix.md,rules/fx-deviant-wrong-interpreter.md'

fx_min() { # <value> <min> -> at-least-<min> | TOO-FEW:<value> | NOT-A-NUMBER:<value>
    case "$1" in ''|*[!0-9]*) printf 'NOT-A-NUMBER:%s' "$1"; return ;; esac
    [ "$1" -ge "$2" ] && { printf 'at-least-%s' "$2"; return; }
    printf 'TOO-FEW:%s' "$1"
}

fx_rerun_probe() { # -> identical | DIFFERS | sentinel
    have_sweep || { missing_sweep; return; }
    cmp -s "$FX_JSON/main.json" "$FX_JSON/rerun.json" && { printf 'identical'; return; }
    printf 'DIFFERS'
}

fx_tree_probe() { # <unchanged|detector> -> verdict
    local mutated
    case "$1" in
        unchanged)
            [ "$FX_MAIN_AFTER" = "$FX_MAIN_BEFORE" ] && { printf 'unchanged'; return; }
            printf 'MODIFIED' ;;
        detector)
            printf '%s\n' 'intruder' > "$FX_MAIN/rules/fx-intruder.md"
            mutated="$(fx_manifest "$FX_MAIN")"
            rm -f "$FX_MAIN/rules/fx-intruder.md"
            [ "$mutated" != "$FX_MAIN_BEFORE" ] && { printf 'detected'; return; }
            printf 'BLIND' ;;
    esac
}

# THE FOURTH EXCLUSION CLASS IS EXCLUDED BY CONVENTION, NOT BY SWEEP LOGIC. A documentary path
# citation after a noun-phrase label is now written repo-relative -- `bin/foo`, no
# $AGENTS_CONFIG_DIR/ prefix -- per the calling convention recorded in
# docs/architecture/claude-code/settings.md, so it never matches an SSOT entry path and the
# sweep never sees it as an occurrence. exec-position-sweep.js itself is unchanged.
# T52[boundary-doc-run] is the proof that the carve-out is that spelling distinction and not
# "any bare-path span is excluded": keep the prefix and the span is still reported deviant.

# THE READER FOR EVERY JSON-SHAPED ROW. One table, one reducer: a row cannot relax its own
# parsing, and a mode that stops existing answers UNKNOWN-MODE rather than an empty string.
t5x_json_table() {
    local id tag mode arg want label
    while IFS='|' read -r id tag mode arg want label; do
        [ -n "$id" ] || continue
        [ "$arg" = "-" ] && arg=""
        ROWS=$((ROWS + 1))
        assert_eq "$id: $label" "$want" "$(fx_q "$tag" "$mode" "$arg")"
    done <<'T5X_JSON_CASES'
T50[real-nonok]|real|nonok|-|none|every occurrence in the real repo carries a literal interpreter in execution position and the one its shebang resolves to
T51[verdict-ok]|main|file-summary|rules/fx-ok-control.md|2:ok@3,ok@5|POSITIVE CONTROL: the fixture tree can produce ok, so the deviant rows below are verdicts and not a broken fixture
T51[verdict-no-interpreter]|main|file-summary|rules/fx-deviant-no-interpreter.md|1:no-interpreter@3|the bare quoted path with nothing in front of it is REACHED and reported as no-interpreter, the exact shape #2262 opened on
T51[verdict-unexpected-prefix]|main|file-summary|rules/fx-deviant-unexpected-prefix.md|1:unexpected-prefix@3|a launcher that is neither bash nor node is reported as unexpected-prefix, not silently accepted
T51[verdict-wrong-interpreter]|main|file-summary|rules/fx-deviant-wrong-interpreter.md|1:wrong-interpreter@3|node in front of a bash-shebang entry is reported as wrong-interpreter, so the rule that would match is not the rule that exists
T51[verdict-unresolvable-entry]|orphan|file-summary|rules/fx-unresolvable.md|1:unresolvable-entry@3|CPR-ORTH: the fourth deviant verdict is reachable too -- an SSOT entry the generator emits no interpreter-bearing rule for fails closed rather than reading as ok
T51[verdict-unresolvable-control]|orphan|file-summary|rules/fx-orphan-control.md|1:ok@3|CONTROL: in the same tree an entry the generator DOES cover still reads ok, so the row above is about the missing rule and not a dead stub
T52[exclusion-prose]|main|file-summary|rules/fx-exclusion-prose.md|1:ok@6|EXCLUSION CLASS: two prose mentions outside any code span yield nothing, and only the sentinel command line on line 6 is reported
T52[exclusion-argument]|main|file-summary|rules/fx-exclusion-argument.md|1:ok@7|EXCLUSION CLASS: cat, git add and cp name the file rather than run it, so none of the three is reported and only the line 7 sentinel is
T52[exclusion-allow-rule]|main|file-summary|rules/fx-exclusion-allow-rule.md|1:ok@7|EXCLUSION CLASS: the Bash(...) allow-rule strings this repo quotes verbatim are not command lines, so only the line 7 sentinel is reported
T52[exclusion-total]|main|set-count|rules/fx-exclusion-prose.md,rules/fx-exclusion-argument.md,rules/fx-exclusion-allow-rule.md|3|the three exclusion files together contribute exactly their three sentinels -- one occurrence each, so no excluded form slipped in
T52[exclusion-statuses]|main|set-statuses|rules/fx-exclusion-prose.md,rules/fx-exclusion-argument.md,rules/fx-exclusion-allow-rule.md|ok|and not one of those three files produces a deviant verdict of any kind
T52[exclusion-doc-label]|doc|file-summary|rules/fx-doc-label-mention.md|1:ok@5|EXCLUSION CLASS, BY CONVENTION: a documentary citation naming where a file lives is written repo-relative (no $AGENTS_CONFIG_DIR/ prefix), so it never matches an SSOT entry path and drops out of the occurrence list entirely -- only the line 5 sentinel is reported
T52[boundary-doc-run]|doc|file-summary|rules/fx-doc-run-instruction.md|2:no-interpreter@3,ok@5|BOUNDARY, UNCHANGED: a span that still carries the $AGENTS_CONFIG_DIR/ prefix stays deviant even after a label and a colon introduce it, so the row above is the prefix-based spelling distinction and not "any bare-path span is excluded" -- Run: ends in a colon too
T53[overlap-nonok-files]|main|nonok-files|-|rules/fx-deviant-no-interpreter.md,rules/fx-deviant-unexpected-prefix.md,rules/fx-deviant-wrong-interpreter.md|ZERO OVERLAP: the files reported with a deviant verdict are exactly the three deviant fixtures, named rather than counted
T53[overlap-exclusion-clean]|main|nonok-among|rules/fx-exclusion-prose.md,rules/fx-exclusion-argument.md,rules/fx-exclusion-allow-rule.md|none|no exclusion fixture appears in the deviant set, so the carve-out is not over-narrow
T53[overlap-deviants-all-reported]|main|nonok-covers|rules/fx-deviant-no-interpreter.md,rules/fx-deviant-unexpected-prefix.md,rules/fx-deviant-wrong-interpreter.md|3/3|and every deviant fixture is still reported, so the carve-out is not over-wide either -- the two rows together are what stops it swallowing a real defect
T55[edge-env-prefix]|main|line-status|agents/fx-edge.md:3|ok|a leading FOO=1 assignment is skipped when the preceding token is looked for, so the interpreter behind it is still found
T55[edge-chained-segment]|main|line-status|agents/fx-edge.md:4|ok|a chained line is split on the chain operator, so the second segment is judged on its own first token rather than on cd
T55[edge-fenced-bash]|main|line-status|agents/fx-edge.md:7|ok|a line inside a fenced block is a command line too, not only an inline code span
T55[edge-fenced-node]|main|line-status|agents/fx-edge.md:8|ok|and the fence stays open for its second line rather than being toggled off by the first
T55[edge-longest-entry]|main|line-entry|skills/fx-skill/SKILL.md:3|bin/fx-bash-tool-extra|an entry whose text begins with another entry is matched WHOLE, so the longer one is not shadowed by its prefix
T55[edge-shared-root]|main|file-summary|skills/_shared/fx-shared.md|1:ok@3|skills/_shared/*.md is walked as well as agents, rules and skills SKILL.md -- a scan root dropped from the walker turns this red instead of shrinking the corpus in silence
T57[ssot-drop-entry-gone]|drop|entry-count|bin/fx-bash-tool|0|CONFIG-DEPENDENT: with the entry removed from the SSOT and the prompt text untouched, the sweep reports it no longer -- scope is read from install/settings-allow-commands.txt, not from a list baked into the sweep
T57[ssot-drop-entry-kept]|drop|entry-count|bin/fx-node-tool.js|2|and the entry still listed is still reported twice, so the row above is a scope change rather than a tree that stopped being scanned
T57[ssot-drop-total]|drop|total|-|2|the whole drop tree therefore yields exactly the two occurrences of the one surviving entry
T57[ssot-drop-statuses]|drop|statuses|-|ok|and they are ok, so removing an entry narrows the scope without turning the survivors deviant
T57[ssot-control-main]|main|entry-count|bin/fx-bash-tool|11|CONTROL: the SAME markdown in the tree whose SSOT does list the entry reports all eleven of its occurrences
T5X_JSON_CASES
}

# Thresholds, not exact counts: the real repo's corpus grows with every new prompt asset, and a
# row pinned to today's total would fail on the next unrelated commit.
t5x_min_table() {
    local id tag mode min label
    while IFS='|' read -r id tag mode min label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "$id: $label" "at-least-$min" "$(fx_min "$(fx_q "$tag" "$mode" "")" "$min")"
    done <<'T5X_MIN_CASES'
T50[real-scanned]|real|total|10|the real-repo sweep found occurrences at all -- without this the zero-offender row above would also be satisfied by a sweep that scanned nothing
T50[real-multi-file]|real|distinct-files|2|and they come from more than one file, so the corpus is not one asset the walker happened to reach
T5X_MIN_CASES
}

t5x_misc_probe() { # <id> -> verdict
    case "$1" in
        real-exit)        fx_rc real ;;
        noargv)           fx_usage ;;
        no-ssot)          fx_failclosed no-ssot ;;
        traversal)        fx_failclosed traversal ;;
        metachar)         fx_failclosed metachar ;;
        no-lib)           fx_failclosed no-lib ;;
        rerun-identical)  fx_rerun_probe ;;
        rerun-exit)       fx_rc rerun ;;
        tree-unchanged)   fx_tree_probe unchanged ;;
        tree-detector)    fx_tree_probe detector ;;
        *)                printf 'UNKNOWN-PROBE' ;;
    esac
}

# T50 exit, T54 fail-closed, T56 hygiene: verdicts that are not read out of the occurrence
# list, so they cannot share the JSON table above.
t5x_labelled_table() {
    local key id want label
    while IFS='|' read -r key id want label; do
        [ -n "$key" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "$id: $label" "$want" "$(t5x_misc_probe "$key")"
    done <<'T5X_LABELLED_CASES'
real-exit|T50[real-exit]|0|the real-repo sweep exits 0, so the empty offender list above is a finished scan rather than a crash that printed nothing
noargv|T54[failclosed-no-argv]|2/usage|SECURITY, FAIL-CLOSED: invoked with no agents root the sweep exits 2 with a usage line instead of defaulting to some root and reporting a clean sweep of it
no-ssot|T54[failclosed-missing-ssot]|fail-closed|a missing install/settings-allow-commands.txt aborts with no JSON on stdout -- an empty occurrence list would otherwise read as zero offenders
traversal|T54[failclosed-traversal-entry]|fail-closed|CWE-22: an SSOT entry containing .. aborts the sweep rather than being interpolated into a scan of a path outside the agents root
metachar|T54[failclosed-metachar-entry]|fail-closed|CWE-78: an SSOT entry carrying shell metacharacters aborts too, so a hostile line in the SSOT cannot widen what the sweep calls acceptable
no-lib|T54[failclosed-missing-lib]|fail-closed|and a missing spelling library aborts instead of treating every entry as unresolvable or as ok
rerun-identical|T56[hygiene-rerun-identical]|identical|IDEMPOTENCY: a second sweep of the same tree emits byte-identical JSON, so the ordering the rows above pin is stable rather than filesystem-dependent
rerun-exit|T56[hygiene-rerun-exit]|0|and the second run exits 0 as well, so the identity above is not two identical crashes
tree-unchanged|T56[hygiene-tree-readonly]|unchanged|the scanned tree is byte-identical after two sweeps -- the sweep reads prompt assets and writes nothing into them
tree-detector|T56[hygiene-tree-detector]|detected|CANARY: the manifest really notices a write into that tree, so the row above is evidence and not a no-op comparison
T5X_LABELLED_CASES
}

# T60 -- THE #2262 FIX MAP, PINNED PER FILE. entry-count aggregates one SSOT entry over the
# WHOLE repo, so `bin/concern-ledger` reading 4 says nothing about WHICH four files carry it:
# a converted call silently lost from one of them leaves that aggregate untouched. One row per
# converted file, naming the entries #2262 rewrote there, plus a total the reducer recomputes
# from the same map in one pass -- so a row skipped by the table's own guard cannot go unseen.
t60_fix_map_table() {
    local file entries want label agg="" total=0
    while IFS='|' read -r file entries want label; do
        [ -n "$file" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T60[$file]: $label" "$want" "$(fx_q real pin-ok "$file::$entries")"
        agg="$agg$file::$entries;"
        total=$((total + want))
    done <<'T60_CASES'
skills/_shared/non-github-remote-gate.md|bin/detect-non-github.sh|1|the shared gate's one-line call is swept as ok, so the wrapper every consumer copies from carries the converted spelling
skills/commit-push/SKILL.md|bin/detect-non-github.sh|1|the commit-push pre-flight call is swept as ok in ITS OWN file, not merely somewhere in the repo
skills/issue-close-stage/SKILL.md|bin/detect-non-github.sh|1|and so is the third caller of the same entry, so all three sites of the one entry are attributed rather than counted together
skills/make-detail-plan/SKILL.md|bin/concern-ledger,skills/_shared/assemble-mandatory.sh,bin/check-issues-class-coverage,skills/make-detail-plan/scripts/detect-scope-change.sh|4|the four converted calls in the densest file are all ok -- four different entries in one file, the case a per-entry count cannot separate
skills/make-outline-plan/SKILL.md|skills/_shared/assemble-mandatory.sh,bin/concern-ledger|3|three converted calls across two entries, one of which appears twice in this file alone
skills/review-plan-security/SKILL.md|bin/concern-ledger|1|the security-plan skill's ledger call is ok
skills/review-tests/SKILL.md|bin/resolve-worktree-path,skills/review-tests/scripts/select-staged-files.sh,bin/concern-ledger|3|and the three converted calls in review-tests, the file whose RT-0 prose #2262 also hardened
T60_CASES
    ROWS=$((ROWS + 1))
    assert_eq "T60[fix-map-total]: the seven files contribute exactly the fourteen occurrences #2262 converted -- a file that lost one turns its own row AND this one red, and a row dropped from the table above changes the left side" \
        "14/14" "$total/$(fx_q real pin-ok "$agg")"
}

t5x_json_table
t5x_min_table
t5x_labelled_table
t60_fix_map_table
