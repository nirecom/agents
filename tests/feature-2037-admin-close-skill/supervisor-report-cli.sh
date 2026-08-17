# shellcheck shell=bash
# Tests: skills/supervisor-report/SKILL.md, bin/supervisor-report
# Tags: rules-injection, progressive-disclosure, supervisor-report, executable-doc, enum-validation, TL2, scope:issue-specific

# The supervisor-report half of #2037: rules/supervisor-reporting.md keeps its "When to
# Report" section unconditional and moves the CLI mechanics into a skill. These cases grade
# that skill against its real consumer, bin/supervisor-report.

# Split out of the entry file on the target-skill axis (rules/coding/file-split.md Pattern
# A): everything here is about supervisor-report, everything left there is about
# issue-close-verified.

# Assumes AGENTS_DIR, TMPDIR_BASE, SR_SKILL, SR_CLI, WORKFLOW_PLANS_DIR,
# fresh_workflow_dir(), run_with_timeout(), pass(), fail() from the entry file.
echo ""
echo "=== S5: the supervisor-report skill's CLI call satisfies the CLI's own required flags ==="

if [ ! -f "$SR_SKILL" ]; then
    fail "S5: skills/supervisor-report/SKILL.md does not exist"
elif [ ! -f "$SR_CLI" ]; then
    fail "S5: IMPLEMENTATION MISSING: bin/supervisor-report"
else
    # The expected flag set is taken from the CLI's own required-flag assertions rather
    # than written out here, so adding a required flag turns this red automatically
    # instead of leaving the skill quietly incomplete (CPR-SSOT).
    S5_REQUIRED="$(grep -oE 'usage\("--[a-z-]+ required"\)' "$SR_CLI" | grep -oE '\-\-[a-z-]+' | sort -u)"
    S5_N="$(printf '%s\n' "$S5_REQUIRED" | grep -c '^--' || true)"
    if [ "${S5_N:-0}" -lt 1 ]; then
        fail "S5: no required flags could be extracted from bin/supervisor-report's usage() calls — the expectation would be empty and S5 would pass vacuously"
    else
        S5_MISSING=""
        for flag in $S5_REQUIRED; do
            grep -qF -- "$flag" "$SR_SKILL" || S5_MISSING="$S5_MISSING $flag"
        done
        if [ -z "$S5_MISSING" ]; then
            pass "S5: the skill's documented call passes all $S5_N flag(s) bin/supervisor-report requires ($(printf '%s' "$S5_REQUIRED" | tr '\n' ' '))"
        else
            fail "S5: the skill's documented call omits required flag(s) —$S5_MISSING; running it as written would abort in usage() and the observation would be lost"
        fi
    fi
fi

echo ""
echo "=== S8: the supervisor-report skill's documented call is accepted by the real CLI ==="

# S5 compares flag NAMES as substrings, which a prose sentence listing the flags also
# satisfies. That is the false-green shape: the skill can name every required flag and
# still document a call the CLI rejects — wrong flag order is fine, but a flag that takes
# a value and is documented as a bare switch, or a value spelled outside the accepted
# enum (a category or severity that does not exist), aborts in usage() at run time. So the
# flag set is handed to the real CLI with test values and the exit code is the assertion.
if [ ! -f "$SR_SKILL" ] || [ ! -f "$SR_CLI" ]; then
    fail "S8: IMPLEMENTATION MISSING: ${SR_SKILL##"$AGENTS_DIR/"} or bin/supervisor-report"
else
    # EVERY documented value is exercised, not one sample: the skill's tables are what a
    # reporter chooses from, and a single stale row is enough to lose the one observation
    # that happened to fit it. The values are read out of the tables themselves, with no
    # hardcoded fallback — an empty extraction means the skill documents nothing choosable
    # and is reported as such rather than quietly replaced by a default that would pass.
    # sr_table <heading-regex> — the first-column code spans under that heading.
    sr_table() {
        awk -v h="$1" 'tolower($0) ~ h {f=1; next} f && /^##+ /{exit} f{print}' "$SR_SKILL" \
            | grep -oE '^\|[[:space:]]*`[a-z-]+`' | grep -oE '[a-z-]+' | sort -u
    }
    S8_CATS="$(sr_table '^##+ .*categor')"
    S8_SEVS="$(sr_table '^##+ .*severit')"

    if [ -z "$S8_CATS" ]; then
        fail "S8-setup: no category rows found under the skill's Categories heading — the table a reporter picks from is missing or in a shape nothing can read"
    fi
    if [ -z "$S8_SEVS" ]; then
        fail "S8-setup: no severity rows found under the skill's Severity heading — same failure, on the axis that decides how loudly an observation lands"
    fi

    # The exit code alone is a weak assertion: a CLI that validates its flags and then
    # drops the finding on the floor exits 0 on every documented value. What the reporter
    # actually needs is that the observation SURVIVED, with the fields intact — so each
    # probe reads back the isolated supervisor state and grades the persisted record.
    # Symmetrically, a rejected value must leave NOTHING behind; a CLI that appends first
    # and validates second would otherwise pass the negative controls.

    # sr_findings <sid> — prints "<n>|<categories-csv>|<severity>|<detail>|<reporter>"
    # for the single finding, or "0|" when the state file holds none / does not exist.
    cat > "$TMPDIR_BASE/findings.js" <<'FIND_EOF'
"use strict";
const fs = require("fs");
const path = require("path");
const file = path.join(process.argv[2], `${process.argv[3]}-supervisor-state.json`);
let f = [];
try { f = JSON.parse(fs.readFileSync(file, "utf8")).layer1.findings || []; } catch (_) { f = []; }
if (f.length !== 1) { process.stdout.write(`${f.length}|`); process.exit(0); }
const x = f[0];
process.stdout.write([1, (x.categories || []).join(","), x.severity, x.detail, x.reporter].join("|"));
FIND_EOF

    SR_PROBE_N=0
    SR_DETAIL="S8 probe - documented call shape"
    SR_REPORTER="feature-2037-admin-close-skill"

    # sr_probe <label> <categories> <severity> <want-rc0|want-rcfail>
    sr_probe() {
        local label="$1" cat="$2" sev="$3" want="$4" wf out rc sid got wantrec
        SR_PROBE_N=$((SR_PROBE_N + 1))
        # A fresh session id per probe: findings accumulate per session and adjacent
        # rows would otherwise de-dupe or pile up, making "exactly one" unassertable.
        sid="s8sid2037-$SR_PROBE_N"
        wf="$(fresh_workflow_dir)"
        rc=0
        out="$(run_with_timeout 60 env \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            "CLAUDE_WORKFLOW_DIR=$wf" \
            "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
            node "$SR_CLI" --categories "$cat" --severity "$sev" \
                --detail "$SR_DETAIL" \
                --reporter "$SR_REPORTER" \
                --session-id "$sid" 2>&1)" || rc=$?
        got="$(node "$TMPDIR_BASE/findings.js" "$WORKFLOW_PLANS_DIR" "$sid" 2>/dev/null || echo "ERR|")"
        if [ "$want" = "want-rc0" ]; then
            wantrec="1|$(printf '%s' "$cat" | tr -d ' ')|$sev|$SR_DETAIL|$SR_REPORTER"
            if [ "$rc" != "0" ]; then
                fail "$label — the real CLI exited $rc on a value the skill documents (--categories $cat --severity $sev), so a reporter following the table loses the observation; output: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
            elif [ "$got" != "$wantrec" ]; then
                fail "$label — the CLI exited 0 but the persisted finding does not match: want '$wantrec', got '$got'; an accepted call that stores nothing (or stores the wrong fields) loses the observation just as completely as a rejected one"
            else
                pass "$label (accepted, and the finding is persisted with the fields intact)"
            fi
        else
            if [ "$rc" = "0" ]; then
                fail "$label — the CLI accepted '$cat/$sev', which no table documents; the enum is not enforced, so every 'documented value accepted' case above passes for a CLI that accepts anything"
            elif [ "${got%%|*}" != "0" ]; then
                fail "$label — the CLI rejected the value (exit $rc) but still left a record behind (got '$got'); a reject that appends first and validates second corrupts the audit trail with values no table documents"
            else
                pass "$label (rejected, and nothing was appended)"
            fi
        fi
    }

    for c in $S8_CATS; do
        sr_probe "S8a [$c]: the real CLI accepts the documented category" "$c" "notice" want-rc0
    done
    for s in $S8_SEVS; do
        sr_probe "S8b [$s]: the real CLI accepts the documented severity" "other" "$s" want-rc0
    done

    # Multi-select is documented ("comma-separated"), and it is its own code path: a CLI
    # that validates only the first token would pass every S8a row above.
    if [ -n "$S8_CATS" ]; then
        S8_MULTI="$(printf '%s\n' "$S8_CATS" | head -2 | paste -sd, -)"
        sr_probe "S8c: a comma-separated category list is accepted ($S8_MULTI)" "$S8_MULTI" "notice" want-rc0
    fi

    # The negative control for S8a/S8b. Without it, all of the above is satisfied by a CLI
    # that never validates its enums at all.
    sr_probe "S8d: an UNdocumented category is rejected" "definitely-not-a-category" "notice" want-rcfail
    sr_probe "S8e: an UNdocumented severity is rejected" "other" "catastrophic" want-rcfail
fi

echo ""
echo "=== S10: the skill's own documented invocation, handed to the real CLI ==="

# S5 compares flag NAMES; S8 runs the real CLI but builds its OWN command line. Between
# them sits the failure neither sees: the skill documents every required flag, each value
# it names is individually valid, and the line as written still aborts — a value-taking
# flag documented as a bare switch, a stray placeholder, a flag pair in a shape usage()
# rejects. The line is therefore taken from the skill verbatim, tokenized (never eval'd —
# the document is data here, same contract as the policy file), placeholders filled in,
# and the result handed to bin/supervisor-report.
if [ ! -f "$SR_SKILL" ] || [ ! -f "$SR_CLI" ]; then
    fail "S10: IMPLEMENTATION MISSING: ${SR_SKILL} or ${SR_CLI}"
else
    cat > "$TMPDIR_BASE/argv.js" <<'ARGV_EOF'
"use strict";
// argv: <skill.md> <category> <severity> <expected-json-out>
//   -> NUL-separated CLI args on stdout, and the record those args should persist as JSON.

// Filling a placeholder by its PRECEDING flag alone is what makes this case forgeable: a
// skill that documents --detail "<reporter name>" --reporter "<what was observed>" has the
// two values swapped for every human who copies it, yet the harness would rewrite both by
// position and the CLI would accept the result. So each placeholder is also read for whose
// slot it names, and the filled values are exported for a field-by-field comparison against
// what actually landed on disk — "one finding exists" cannot distinguish the swap either.
const fs = require("fs");
const [, , skill, cat, sev, expectedOut] = process.argv;
const src = fs.readFileSync(skill, "utf8");
const raw = src.split(/\r?\n/).find((l) => l.includes("bin/supervisor-report") && l.includes("--"));
if (!raw) process.exit(3);
// Backticks are markdown code fencing, not shell quoting. A skill that wraps the whole
// invocation in one `...` span would otherwise tokenize to a single argument, and the
// case would run a command line nobody wrote. Strip them before tokenizing; the shell
// quoting that actually groups values ("..." / '...') is left intact.
const line = raw.replace(/`/g, " ");
const toks = line.match(/"[^"]*"|'[^']*'|\S+/g) || [];

const SLOT_OF = {
  "--categories": "categories", "--severity": "severity",
  "--detail": "detail", "--reporter": "reporter", "--session-id": "sessionId",
};
const FILL = {
  categories: cat, severity: sev, sessionId: "s10sid2037",
  detail: "S10 probe - the skill's own line", reporter: "feature-2037-admin-close-skill",
};

// Which slot a placeholder's own wording claims. Unrecognisable wording (<x>, $VAR) claims
// nothing and is left to the flag — only a placeholder that names SOME slot can name the
// wrong one.
const CLAIMS = [
  ["categories", /categor|cats\b/], ["severity", /sever|\bsev\b/],
  ["sessionId", /session|\bsid\b/], ["reporter", /report(er)?\b|who\b|name\b/],
  ["detail", /detail|text|observ|what\b/],
];
function whoseSlot(tok) {
  const s = String(tok).toLowerCase();
  const hits = CLAIMS.filter(([, re]) => re.test(s));
  return hits.length === 1 ? hits[0][0] : null;
}

const expected = {};
const misnamed = [];
const out = [];
let started = false;
for (let i = 0; i < toks.length; i += 1) {
  let t = toks[i].replace(/^["']|["']$/g, "");
  if (!started) { if (t.includes("bin/supervisor-report")) started = true; continue; }
  // Trailing sentence punctuation is prose, not an argument.
  if (/^[.,;:)]+$/.test(t)) continue;
  if (t.startsWith("--")) { out.push(t); continue; }
  // A value position: swap anything that is a placeholder for a real value.
  const prev = out[out.length - 1];
  if (/[<>$]/.test(t) || t === "") {
    const slot = SLOT_OF[prev];
    if (slot) {
      const claimed = whoseSlot(t);
      if (claimed && claimed !== slot) misnamed.push(`${prev} is filled by a ${claimed} placeholder (${t})`);
      t = FILL[slot];
      expected[slot] = t;
    } else t = "x";
  } else if (SLOT_OF[prev]) expected[SLOT_OF[prev]] = t;
  out.push(t);
}
if (!out.length) process.exit(4);
if (expectedOut) fs.writeFileSync(expectedOut, JSON.stringify({ expected, misnamed }));
process.stdout.write(out.join("\0"));
ARGV_EOF

    S10_CAT="$(printf '%s\n' "${S8_CATS:-}" | head -1)"
    S10_SEV="$(printf '%s\n' "${S8_SEVS:-}" | head -1)"
    [ -z "$S10_CAT" ] && S10_CAT="other"
    [ -z "$S10_SEV" ] && S10_SEV="notice"

    # The NUL stream goes to a FILE, never through $( ). Command substitution strips NUL
    # bytes, so capturing it in a variable would silently collapse the separators and hand
    # xargs -0 one giant argument — the case would then grade a command line the skill
    # never documented, which is exactly the shape S10 exists to rule out.
    S10_ARGV_FILE="$TMPDIR_BASE/s10-argv.bin"
    S10_EXP_FILE="$TMPDIR_BASE/s10-expected.json"
    S10_ARGS_RC=0
    node "$TMPDIR_BASE/argv.js" "$SR_SKILL" "$S10_CAT" "$S10_SEV" "$S10_EXP_FILE" >"$S10_ARGV_FILE" 2>/dev/null || S10_ARGS_RC=$?
    S10_NULS=0
    [ -s "$S10_ARGV_FILE" ] && S10_NULS="$(tr -dc '\0' < "$S10_ARGV_FILE" | wc -c | tr -d ' ')"
    if [ "$S10_ARGS_RC" != "0" ] || [ ! -s "$S10_ARGV_FILE" ]; then
        fail "S10-setup: no runnable bin/supervisor-report invocation could be read out of the skill (rc=$S10_ARGS_RC) — the procedure is described but never shown as a command, so a reader has to reconstruct it"
    elif [ "${S10_NULS:-0}" -lt 1 ]; then
        fail "S10-setup: the tokenized argv reached the harness with no NUL separators ($S10_NULS found), so xargs -0 would receive one merged argument and S10 would grade a command line the skill never wrote"
    else
        pass "S10-setup: the skill's invocation line was extracted and tokenized ($S10_NULS NUL separator(s) survived to the harness)"
        S10_WF="$(fresh_workflow_dir)"
        S10_SID="s10sid2037"
        S10_OUT=""; S10_RC=0
        # xargs -0 reads the NUL stream straight from the file — the tokenization is
        # preserved end to end, and values containing spaces stay single arguments.
        S10_OUT="$(run_with_timeout 60 env \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            "CLAUDE_WORKFLOW_DIR=$S10_WF" \
            "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
            xargs -0 node "$SR_CLI" <"$S10_ARGV_FILE" 2>&1)" || S10_RC=$?
        S10_GOT="$(node "$TMPDIR_BASE/findings.js" "$WORKFLOW_PLANS_DIR" "$S10_SID" 2>/dev/null || echo "ERR|")"
        # The record the skill's own line, as written, should have produced.
        S10_WANT="$(node -e '
const e = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).expected;
process.stdout.write([1, String(e.categories || "").replace(/ /g, ""), e.severity, e.detail, e.reporter].join("|"));
' "$S10_EXP_FILE" 2>/dev/null || echo "WANT-UNREADABLE")"
        S10_MISNAMED="$(node -e '
process.stdout.write((JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).misnamed || []).join("; "));
' "$S10_EXP_FILE" 2>/dev/null || echo "")"
        if [ -n "$S10_MISNAMED" ]; then
            fail "S10: the documented line labels a value slot with another slot's placeholder — $S10_MISNAMED. Every reporter who copies it files the observation into the wrong field, and the CLI accepts it, so nothing downstream ever complains"
        elif [ "$S10_RC" != "0" ]; then
            fail "S10: the skill's documented line exits $S10_RC on the real CLI — a reporter who copies it loses the observation; args=$(tr '\0' ' ' < "$S10_ARGV_FILE" | cut -c1-300); output: $(printf '%s' "$S10_OUT" | tr '\n' ' ' | cut -c1-300)"
        elif [ "${S10_GOT%%|*}" != "1" ]; then
            fail "S10: the skill's documented line exited 0 but left no single persisted finding under its own --session-id (got '$S10_GOT') — the command is copyable and still silently reports nothing"
        elif [ "$S10_WANT" = "WANT-UNREADABLE" ]; then
            fail "S10: the expected-record sidecar could not be read, so the persisted finding cannot be compared field by field and only its existence would be graded"
        elif [ "$S10_GOT" != "$S10_WANT" ]; then
            fail "S10: the skill's documented line persisted a DIFFERENT record than it names. want '$S10_WANT', got '$S10_GOT' (fields: n|categories|severity|detail|reporter) — a supervisor reading the audit trail sees values the reporter never wrote"
        else
            pass "S10: the skill's own documented line succeeds on the real CLI and persists exactly the record it names, field by field"
        fi
    fi
fi

# --- S9: the guard sequence. Split into a sibling file because this one crossed the
# 300-line WARN (rules/coding/file-split.md Pattern A); sourced from here so the extracted
# sentinel commands and the fixture helpers above stay in scope. ---
GUARD_CASES="$AGENTS_DIR/tests/feature-2037-admin-close-skill/guard-sequence.sh"
