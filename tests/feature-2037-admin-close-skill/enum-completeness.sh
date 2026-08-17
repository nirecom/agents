# shellcheck shell=bash
# Tests: skills/supervisor-report/SKILL.md, hooks/lib/supervisor-state-schema.js
# Tags: rules-injection, supervisor-report, enum-completeness, ssot, both-directions, TL2, scope:issue-specific

# WHY (CPR-WPH): the reporter picks a category and a severity from the tables in
# skills/supervisor-report/SKILL.md; the writer validates them against CATEGORIES and
# SEVERITY_VALUES in hooks/lib/supervisor-state-schema.js. Two files, one fact — so the
# failure is DRIFT, and it hurts in both directions.

# Doc names a value the schema does not: the reporter follows the table, appendFinding
# refuses, and the observation is lost at exactly the moment something went wrong.
# Schema accepts a value the doc does not name: the value exists but nobody can choose it,
# so observations pile into `other` and the category axis stops discriminating.

# S8 in supervisor-report-cli.sh already drives every DOCUMENTED value through the real CLI,
# which covers the first direction behaviourally. It cannot cover the second: a schema value
# absent from the doc is never generated, so nothing runs it. This file asserts the SET
# EQUALITY, so the unreachable-value direction is graded too.

# Both sides are derived from their real sources — the markdown tables are parsed out of the
# SKILL.md, and the schema arrays are require()d from the module (agents-owned code, not
# contributor-editable data, so require is the honest reader here). Nothing is restated as a
# literal, which is why adding a value to either side turns this red instead of silently
# widening the gap. Assumes AGENTS_DIR, TMPDIR_BASE, SR_SKILL, pass(), fail() from the entry.

echo ""
echo "=== S12: the SKILL.md enum tables and the schema arrays are the same set ==="

EC_SCHEMA="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"

if [ ! -f "$SR_SKILL" ] || [ ! -f "$EC_SCHEMA" ]; then
    fail "S12: IMPLEMENTATION MISSING: ${SR_SKILL:-<unset>} or hooks/lib/supervisor-state-schema.js"
else
    # ec_doc <heading-regex> — the first-column code spans of the table under that heading.
    # Deliberately its own extractor rather than a call into supervisor-report-cli.sh's
    # sr_table(): that helper is defined inside a conditional block there, so borrowing it
    # would make this file's result depend on whether S8's preconditions happened to hold.
    ec_doc() {
        awk -v h="$1" 'tolower($0) ~ h {f=1; next} f && /^##+ /{exit} f{print}' "$SR_SKILL" \
            | grep -oE '^\|[[:space:]]*`[a-z_-]+`' | grep -oE '[a-z_-]+' | sort -u
    }
    # ec_code <export-name> — the array as the module itself exposes it.
    ec_code() {
        node -e '
const s = require(process.argv[1]);
const v = s[process.argv[2]];
process.stdout.write(Array.isArray(v) ? v.slice().sort().join("\n") : "");
' "$(if command -v cygpath >/dev/null 2>&1; then cygpath -m "$EC_SCHEMA"; else echo "$EC_SCHEMA"; fi)" "$2" 2>/dev/null
    }

    EC_DOC_CATS="$(ec_doc '^##+ .*categor')"
    EC_DOC_SEVS="$(ec_doc '^##+ .*severit')"
    EC_CODE_CATS="$(ec_code x CATEGORIES)"
    EC_CODE_SEVS="$(ec_code x SEVERITY_VALUES)"

    ec_count() { printf '%s\n' "$1" | grep -c '[a-z]' || true; }

    # --- S12-floor: the non-vacuity guard. Every assertion below is a set COMPARISON, and
    # two empty sets compare equal — a broken awk pattern, a renamed heading or a schema that
    # stopped exporting would make this file pass loudest at the moment it sees nothing. The
    # floors are well under the current sizes, so they catch collapse without pinning counts. ---
    EC_NC="$(ec_count "$EC_DOC_CATS")"; EC_NS="$(ec_count "$EC_DOC_SEVS")"
    EC_MC="$(ec_count "$EC_CODE_CATS")"; EC_MS="$(ec_count "$EC_CODE_SEVS")"
    EC_LIVE=1
    for pair in "doc-categories:$EC_NC:5" "doc-severities:$EC_NS:2" \
                "schema-categories:$EC_MC:5" "schema-severities:$EC_MS:2"; do
        ec_name="${pair%%:*}"; ec_rest="${pair#*:}"
        ec_got="${ec_rest%%:*}"; ec_floor="${ec_rest##*:}"
        if [ "${ec_got:-0}" -lt "$ec_floor" ]; then
            EC_LIVE=0
            fail "S12-floor [$ec_name]: extracted $ec_got value(s), below the sanity floor of $ec_floor — the set comparisons below would be vacuous, so the extraction is broken rather than the enums being equal"
        fi
    done
    if [ "$EC_LIVE" -eq 1 ]; then
        pass "S12-floor: all four sets extracted above their floors (doc $EC_NC/$EC_NS, schema $EC_MC/$EC_MS) — the comparisons are live"
    fi

    # ec_compare <label> <axis> <doc-set> <code-set> — both directions, reported separately
    # so the diagnostic names WHICH kind of drift happened, not merely that they differ.
    ec_compare() {
        local label="$1" axis="$2" only_doc only_code
        only_doc="$(comm -23 <(printf '%s\n' "$3") <(printf '%s\n' "$4") | tr '\n' ' ' | sed 's/ *$//')"
        only_code="$(comm -13 <(printf '%s\n' "$3") <(printf '%s\n' "$4") | tr '\n' ' ' | sed 's/ *$//')"
        if [ -n "$only_doc" ] && [ -n "$only_code" ]; then
            fail "$label: the two sources disagree in BOTH directions — documented but not accepted: $only_doc; accepted but not documented: $only_code"
        elif [ -n "$only_doc" ]; then
            fail "$label: the skill documents $axis value(s) the schema rejects: $only_doc — a reporter who follows the table loses the observation in appendFinding()"
        elif [ -n "$only_code" ]; then
            fail "$label: the schema accepts $axis value(s) the skill never documents: $only_code — the value exists and nobody can choose it, so observations that belong there land in the catch-all instead"
        else
            pass "$label: the documented $axis set and the accepted $axis set are identical"
        fi
    }

    if [ "$EC_LIVE" -eq 1 ]; then
        ec_compare "S12a" "category" "$EC_DOC_CATS" "$EC_CODE_CATS"
        ec_compare "S12b" "severity" "$EC_DOC_SEVS" "$EC_CODE_SEVS"
    fi

    # --- S12-mut: the comparison must be able to fail. S12a/S12b assert an equality that is
    # currently true, so on their own they cannot distinguish a working oracle from one whose
    # comm invocation always answers "identical". The SAME ec_compare is driven over two
    # deliberately-skewed sets, once per direction, and each must be reported by name. ---
    EC_MUT_BASE="$(printf 'alpha\nbeta\ngamma\n')"
    EC_MUT_EXTRA="$(printf 'alpha\nbeta\ndelta\ngamma\n')"

    ec_mut_probe() {
        local label="$1" doc="$2" code="$3" want="$4" got
        got="$( ec_compare "MUT" "probe" "$doc" "$code" )"
        case "$got" in
            *"$want"*) pass "$label" ;;
            *) fail "$label: want the diagnostic to name '$want', got: $(printf '%s' "$got" | tr '\n' ' ' | cut -c1-220)" ;;
        esac
    }

    ec_mut_probe "S12-mut-a: a doc-only value is reported as documented-but-rejected" \
        "$EC_MUT_EXTRA" "$EC_MUT_BASE" "documents probe value(s) the schema rejects: delta"
    ec_mut_probe "S12-mut-b: a schema-only value is reported as accepted-but-undocumented" \
        "$EC_MUT_BASE" "$EC_MUT_EXTRA" "accepts probe value(s) the skill never documents: delta"
    ec_mut_probe "S12-mut-c: identical sets are reported as identical (the control that keeps a-b from passing for an always-failing comparer)" \
        "$EC_MUT_BASE" "$EC_MUT_BASE" "are identical"
fi
