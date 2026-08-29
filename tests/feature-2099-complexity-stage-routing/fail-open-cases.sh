#!/bin/bash
# tests/feature-2099-complexity-stage-routing/fail-open-cases.sh
# Tests: hooks/workflow-state.js, hooks/workflow-state/complexity-routing.js, hooks/workflow-state/skip-signal-resolver.js, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level, bin/workflow/record-complexity-evaluation, bin/workflow/record-complexity-and-skip
# Tags: complexity, routing, fail-open, isolation-fixture, exit-codes, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# The corruption is applied to an ISOLATED copy of hooks/ + bin/ so the barrel's
# relative require("./complexity-routing") actually resolves to the broken file
# (detail.md R3-C7: the old in-place-copy fixture never did).

D2099_ISO="$TMPDIR_BASE/iso"

d2099_build_isolated_tree() {
    mkdir -p "$D2099_ISO"
    cp -r "$AGENTS_DIR/hooks" "$D2099_ISO/hooks"
    cp -r "$AGENTS_DIR/bin" "$D2099_ISO/bin"

    # Corrupt ONLY the routing table's data, never its syntax: the module must
    # still parse and load. Patterns are anchored on the D2 field names, which
    # the design fixes; if none matches, say so loudly rather than silently
    # testing an intact table.
    ISO_CR="$(to_node_path "$D2099_ISO/hooks/workflow-state/complexity-routing.js")" \
    run_with_timeout node -e '
const fs = require("fs");
const p = process.env.ISO_CR;
const src = fs.readFileSync(p, "utf8");
const PATTERNS = [
  [/undecidable_level\s*:\s*"high"/, "undecidable_level: \"maybe\""],
  [/default_level\s*:\s*"low"/, "default_level: \"maybe\""],
];
for (const [re, rep] of PATTERNS) {
  if (re.test(src)) {
    fs.writeFileSync(p, src.replace(re, rep));
    process.stdout.write("CORRUPTED");
    process.exit(0);
  }
}
process.stdout.write("NO_PATTERN_MATCHED");
' 2>&1
}

d2099_isolation_barrel() {
    local corrupted got
    corrupted=$(d2099_build_isolated_tree)
    assert_eq "FO-1 the isolated fixture's routing table was actually corrupted" "CORRUPTED" "$corrupted"

    # (a) requiring the barrel must NOT throw — a broken complexity table may not
    # take down enforce-worktree.js / session-start.js with it.
    got=$(ISO_BARREL="$(to_node_path "$D2099_ISO/hooks/workflow-state.js")" run_with_timeout node -e '
let loaded;
try { loaded = require(process.env.ISO_BARREL); }
catch (e) { console.log("REQUIRE_THREW:" + (e && e.name)); process.exit(0); }
const cr = require(require("path").join(require("path").dirname(process.env.ISO_BARREL), "workflow-state", "complexity-routing.js"));
const out = ["REQUIRE_OK", "valid=" + cr.ROUTING_TABLE_VALID, "errors=" + (cr.ROUTING_TABLE_ERRORS.length > 0)];
// (b) the error must fire only when a derivation is actually CALLED.
try { loaded.deriveStageLevel("detail", []); out.push("derive=NO_THROW"); }
catch (e) { out.push("derive=" + (e && e.name)); }
try { loaded.deriveAggregateLevel([]); out.push("aggregate=NO_THROW"); }
catch (e) { out.push("aggregate=" + (e && e.name)); }
// Unrelated state APIs on the same barrel must stay usable.
out.push("unrelated=" + (typeof loaded.readState === "function" ? "OK" : "BROKEN"));
console.log(out.join(" "));
' 2>&1)
    assert_eq "FO-2 a corrupt table loads clean and only throws when a derivation is called" \
        "REQUIRE_OK valid=false errors=true derive=RoutingTableUnavailableError aggregate=RoutingTableUnavailableError unrelated=OK" \
        "$got"

    # The resolver's existing try/catch must swallow it into the no-auto-skip
    # direction, matching the current fail-open direction.
    local sid
    sid=$(new_session foresolve)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "" >/dev/null 2>&1
    got=$(ISO_RESOLVER="$(to_node_path "$D2099_ISO/hooks/workflow-state/skip-signal-resolver.js")" SID="$sid" run_with_timeout node -e '
const r = require(process.env.ISO_RESOLVER);
let v;
try { v = r.resolveSkipConditionsFromComplexity(process.env.SID, "outline"); }
catch (e) { v = "THREW:" + (e && e.name); }
console.log(v === null ? "NULL" : JSON.stringify(v));
' 2>&1)
    assert_eq "FO-3 resolveSkipConditionsFromComplexity fails open to no-auto-skip on a broken table" "NULL" "$got"
}

# Seed a LEGACY-shaped record (level/signals but no `levels` map) via a raw
# event, through the INTACT tree's barrel. resolveStageLevels() (complexity.js)
# trusts a well-formed stored `levels` AS-IS without ever consulting the routing
# table, so seeding through $BIN_RECORD — which always derives and persists a
# full `levels` map — can never actually exercise the "table unusable, must
# re-derive" path this file tests. A legacy record with no `levels` forces
# resolveStageLevels() to call deriveLegacyStageLevels() for real, which is what
# reaches (and fails against) the corrupted table in $D2099_ISO.
d2099_seed_legacy_record() {
    local tag="$1" level="$2" signals_json="$3"
    BARREL="$BARREL_N" TAG="$tag" LEVEL="$level" SIGNALS_JSON="$signals_json" \
        run_with_timeout node -e '
const fs = require("fs");
const path = require("path");
const b = require(process.env.BARREL);
const sid = "s2099-fo-" + process.pid + "-" + process.env.TAG;
const s = b.createInitialState(sid);
s.events = (s.events || []).concat([{
  kind: "complexity_evaluation", provenance: "observed", origin: "test-fail-open",
  level: process.env.LEVEL, signals: JSON.parse(process.env.SIGNALS_JSON),
  at: new Date().toISOString(),
}]);
s.events.forEach(function (e, i) { e.seq = i + 1; });
const p = b.getStatePath(sid);
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify(s, null, 2));
process.stdout.write(sid);
' 2>/dev/null
}

# Per-consumer fail-open behaviour, run against the isolated broken tree.
d2099_consumer_fail_open() {
    local sid out rc
    # Seed a legacy-shaped record (no `levels`) through the INTACT tree so the
    # consumers have something to read whose per-stage view genuinely depends on
    # the (broken) derivation.
    sid=$(d2099_seed_legacy_record foconsumer high '["S2-architecture"]')

    rc=0; out=$(run_with_timeout node "$D2099_ISO/bin/workflow/read-complexity-evaluation" --session "$sid" --stage detail 2>/dev/null) || rc=$?
    assert_eq "FO-4 read-complexity-evaluation --stage degrades to the existing NONE protocol" "NONE" "$out"
    assert_eq "FO-5 ... and still exits 0 so consumers take their normal fallback branch" "0" "$rc"

    out=$(run_with_timeout node "$D2099_ISO/bin/workflow/read-complexity-evaluation" --session "$sid" --stage detail 2>&1 >/dev/null)
    assert_contains "FO-6 ... with a ROUTING_TABLE_UNAVAILABLE diagnostic on stderr" "ROUTING_TABLE_UNAVAILABLE" "$out"

    rc=0; out=$(run_with_timeout node "$D2099_ISO/bin/workflow/derive-complexity-level" --stage write_tests --signals "" 2>/dev/null) || rc=$?
    assert_eq "FO-7 derive-complexity-level always answers, erring toward capability" "level=high" "$out"
    assert_eq "FO-8 ... and exits 0 (NONE is not in its vocabulary)" "0" "$rc"

    out=$(run_with_timeout node "$D2099_ISO/bin/workflow/derive-complexity-level" --stage write_tests --signals "" 2>&1 >/dev/null)
    assert_contains "FO-9 ... with a DERIVATION_UNAVAILABLE diagnostic on stderr" "DERIVATION_UNAVAILABLE" "$out"

    local sid2
    sid2=$(new_session forecord)
    rc=0; out=$(run_with_timeout node "$D2099_ISO/bin/workflow/record-complexity-evaluation" --session "$sid2" --signals "S3-security" 2>&1) || rc=$?
    assert_eq "FO-10 record-complexity-evaluation refuses to persist unverifiable levels (exit 1)" "1" "$rc"
    assert_contains "FO-11 ... naming DERIVATION_UNAVAILABLE" "DERIVATION_UNAVAILABLE" "$out"

    out=$(run_with_timeout node "$BIN_READ" --session "$sid2" --stage detail 2>/dev/null)
    assert_eq "FO-12 ... leaving no record at all, so every consumer sees NONE" "NONE" "$out"
}

# FO-19..: the NO---stage backward-compat mode against the same broken table.
# `level` and `signals` are read straight off the persisted record and owe the
# routing table nothing, so they must survive; only `levels=` (the one line that
# needs a derivation) is dropped. Collapsing the whole output to NONE here would
# silently break every pre-#2099 reader (detail.md D4).
d2099_backcompat_mode_fail_open() {
    local sid out rc lines
    # Legacy-shaped seed (no `levels`) through the INTACT tree: S2-architecture ->
    # aggregate level high, per-stage view left to derivation (see
    # d2099_seed_legacy_record above for why $BIN_RECORD cannot exercise this path).
    sid=$(d2099_seed_legacy_record fobackcompat high '["S2-architecture"]')

    rc=0; out=$(run_with_timeout node "$D2099_ISO/bin/workflow/read-complexity-evaluation" \
        --session "$sid" 2>/dev/null) || rc=$?
    lines=$(printf '%s\n' "$out" | tr '\n' ';')
    assert_eq "FO-19 the no---stage mode still emits level= and signals= from the record" \
        "level=high;signals=S2-architecture;" "$lines"
    assert_eq "FO-20 ... and exits 0" "0" "$rc"
    assert_not_contains "FO-21 ... while the derivation-dependent levels= line is omitted" "levels=" "$out"

    out=$(run_with_timeout node "$D2099_ISO/bin/workflow/read-complexity-evaluation" \
        --session "$sid" 2>&1 >/dev/null)
    assert_contains "FO-22 ... with ROUTING_TABLE_UNAVAILABLE explaining the omission on stderr" \
        "ROUTING_TABLE_UNAVAILABLE" "$out"

    # Control: the identical call through the INTACT tree does carry levels=, so
    # FO-21 is attributable to the corruption and not to the line never existing.
    out=$(run_with_timeout node "$BIN_READ" --session "$sid" 2>/dev/null)
    assert_contains "FO-23 control: the unbroken tree emits levels= for the same session" "levels=" "$out"
}

# The bash wrapper normalizes every --advance-path failure to exit 3, and owns
# its own --signals presence detection (detail.md R3-C4).
d2099_wrapper_contract() {
    local sid rc out
    sid=$(new_session wrapper)

    rc=0; out=$(AGENTS_CONFIG_DIR="$D2099_ISO" run_with_timeout bash "$D2099_ISO/bin/workflow/record-complexity-and-skip" \
        --session "$sid" --signals "S3-security" --target outline --advance 2>&1) || rc=$?
    assert_eq "FO-13 the --advance path normalizes a broken-table failure to exit 3" "3" "$rc"

    local sid2
    sid2=$(new_session wrapper2)
    rc=0; out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid2" --target outline 2>&1) || rc=$?
    assert_eq "FO-14 omitting --signals is a wrapper usage error (exit 2)" "2" "$rc"

    rc=0; out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid2" --verdict high --signals "" --target outline 2>&1) || rc=$?
    assert_eq "FO-15 --verdict is rejected by the wrapper too (exit 2)" "2" "$rc"

    # `--signals ""` is a legitimate value and must reach the delegate as one,
    # producing the auto-skip branch (0-signal low).
    rc=0; out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid2" --signals "" --target outline 2>/dev/null) || rc=$?
    assert_eq "FO-16 --signals \"\" forwards as zero signals and resolves the auto branch" "auto" "$out"
    assert_eq "FO-17 ... on a clean exit" "0" "$rc"

    local sid3
    sid3=$(new_session wrapper3)
    rc=0; out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid3" --signals "S2-architecture" --target outline 2>/dev/null) || rc=$?
    assert_eq "FO-18 a signal-bearing evaluation still needs human judgment" "judgment" "$out"
}

d2099_isolation_barrel
d2099_consumer_fail_open
d2099_backcompat_mode_fail_open
d2099_wrapper_contract
