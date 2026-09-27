# tests/bin/bin-concern-ledger-finalize/static-contracts.sh
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/format-params.sh, skills/review-code-security/scripts/run-quality-gates.sh, skills/review-code-security/scripts/run-codex-review-loop.sh
# Tags: concern-ledger, finalize, static-contracts, completion-sentinel, TL2, scope:common
# Sourced by tests/bin/bin-concern-ledger-finalize.sh.
# Detail-plan Test plan (finalize TL2) cases 8, 9 — the completion-sentinel
# blockade and the "no second implementation" contract, both fixed statically.
#
# These are documentation and topology pins: they assert what the repository
# says, not what it does at runtime. A skill whose table lists exit 7 but whose
# prose still marks the step complete passes here (see the suite's TL3 gap).

echo ""
echo "--- finalize 8/9: exit-7 blockade, single-implementation topology ---"

# file_has <path> <extended-regex> → yes | no | no-file  (case-insensitive)
file_has() {
    [ -f "$1" ] || { printf 'no-file'; return; }
    if grep -Eiq -- "$2" "$1" 2>/dev/null; then printf 'yes'; else printf 'no'; fi
}

# ref_files <literal> <root>... → the space-separated, repo-relative list of
# files that reference <literal> outside a comment.
ref_files() {
    local lit="$1" roots=() r
    shift
    for r in "$@"; do roots+=("$AGENTS_ROOT/$r"); done
    grep -rn -F -- "$lit" "${roots[@]}" 2>/dev/null \
        | grep -Ev ':[0-9]+:[[:space:]]*#' \
        | cut -d: -f1 \
        | sed "s|^$AGENTS_ROOT/||" \
        | sort -u \
        | tr '\n' ' ' \
        | sed 's/ $//'
}

# ---------------------------------------------------------------------------
# 8. Every consumer of a wrapper that can now exit 7 must document that exit,
#    and the non-wrapper consumer must document the check-finalized gate.
# ---------------------------------------------------------------------------
while IFS='~' read -r label path re; do
    label="$(trim "$label")"; path="$(trim "$path")"; re="$(trim "$re")"
    [ -z "$label" ] && continue
    case "$label" in \#*) continue ;; esac
    assert_eq "8: $label" "yes" "$(file_has "$AGENTS_ROOT/$path" "$re")"
done <<'TABLE'
codex-review-loop contract lists exit 7 ~ skills/_shared/codex-review-loop.md    ~ ^\|[[:space:]]*7[[:space:]]*\|
make-detail-plan documents exit 7       ~ skills/make-detail-plan/SKILL.md       ~ exit 7
make-outline-plan documents exit 7      ~ skills/make-outline-plan/SKILL.md      ~ exit 7
review-plan-security documents exit 7   ~ skills/review-plan-security/SKILL.md   ~ exit 7
review-tests documents exit 7           ~ skills/review-tests/SKILL.md           ~ exit 7
exit 7 is tied to withholding sentinel  ~ skills/_shared/codex-review-loop.md    ~ exit 7.*sentinel|sentinel.*exit 7|7 .*(do not|never).*sentinel
review-code-security routes through the review loop ~ skills/review-code-security/SKILL.md ~ scripts/run-codex-review-loop\.sh
review-code-security selects the security-code format ~ skills/review-code-security/scripts/run-codex-review-loop.sh ~ --format[= ]security-code
review-code-security names the check-finalized gate ~ skills/review-code-security/SKILL.md ~ check-finalized
review-code-security withholds the sentinel ~ skills/review-code-security/SKILL.md ~ (CHECK=FINALIZE-FAILED|check-finalized|exit 1).*(do not|does not|never).*(sentinel|WORKFLOW_MARK_STEP_review_security_complete)|(do not|does not|never).*(sentinel|WORKFLOW_MARK_STEP_review_security_complete).*(CHECK=FINALIZE-FAILED|check-finalized|exit 1)
TABLE

# The four wrapper consumers must all carry it — a single one silently skipped
# is exactly the asymmetry CPR-ORTH forbids, so the count is pinned too.
EXIT7_N=0
for _s in make-detail-plan make-outline-plan review-plan-security review-tests; do
    [ "$(file_has "$AGENTS_ROOT/skills/$_s/SKILL.md" 'exit 7')" = "yes" ] && \
        EXIT7_N=$((EXIT7_N + 1))
done
assert_eq "8: all four wrapper-consuming skills document exit 7" "4" "$EXIT7_N"

# ---------------------------------------------------------------------------
# 9. One implementation each — the topology the completion criteria demand.
# ---------------------------------------------------------------------------
assert_eq "9a: only the library writes the cap snapshot" \
    "bin/lib/concern-ledger.sh" "$(ref_files '-cap-snapshot.txt' bin)"

assert_eq "9b: run-codex-review-loop no longer copies the ledger itself" \
    "0" "$(grep -c 'cp "\$LEDGER"' "$AGENTS_ROOT/bin/run-codex-review-loop" 2>/dev/null || true)"

assert_eq "9c: only the library writes the unresolved-concerns artifact" \
    "bin/lib/concern-ledger.sh" "$(ref_files '-unresolved-concerns.json' bin)"

# #2276 folds the security code review into the one loop, so the reviewer is no
# longer named by a wrapper of its own: it is a column of the format table.
assert_eq "9d: the security-code format names its reviewer in the format table" \
    "yes" "$(file_has "$AGENTS_ROOT/bin/lib/codex-review-loop/format-params.sh" 'review-code-codex')"

assert_eq "9d: and the deleted ledger wrapper is referenced from nowhere" \
    "" "$(ref_files 'bin/review-code-ledger' bin skills)"

# The counterpart of 9(d): the codex review moved OUT of the security quality
# gate, so the gate script must no longer launch a reviewer at all — the loop
# owns that now, and a gate that still shells out to one would run it twice.
QG="$(cat "$AGENTS_ROOT/skills/review-code-security/scripts/run-quality-gates.sh" 2>/dev/null || true)"
assert_not_contains "9d: run-quality-gates.sh no longer runs the codex review itself" \
    "review-code-codex" "$QG"
assert_not_contains "9d: nor reaches it through the deleted ledger wrapper" \
    "review-code-ledger" "$QG"
