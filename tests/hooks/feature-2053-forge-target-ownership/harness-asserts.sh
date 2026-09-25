#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# The assertion vocabulary and the unit-probe seam, shared by every case block.

# Sourced by the dispatcher after the fixtures exist — it reads BASE, RWT,
# AGENTS_DIR, GH_LOG, DECISION and REASON from there.
# --- assertions ---------------------------------------------------------------
# `ask` and `silent` are the two observable hook decisions. passThrough is also
# `silent`, so wherever the plan distinguishes "silent allow" from "not my
# business" the case must additionally assert the probe counters.
assert_decision() { # <id> <want ask|silent> [reason-substring]
    local id="$1" want="$2" needle="${3:-}"
    if [ "$DECISION" != "$want" ]; then
        fail "$id" "want decision=$want got=$DECISION reason=$REASON"
        return
    fi
    if [ -n "$needle" ] && ! printf '%s' "$REASON" | grep -qF -- "$needle"; then
        fail "$id" "decision=$want ok but reason lacks '$needle': $REASON"
        return
    fi
    pass "$id"
}
assert_reason_lacks() { # <id> <substring that must NOT appear>
    if printf '%s' "$REASON" | grep -qF -- "$1"; then
        fail "$2" "reason must not resolve/name '$1': $REASON"
    else
        pass "$2"
    fi
}
assert_probes() { # <id> <pattern> <want-count>
    local got; got="$(probe_count "$2")"
    if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "probe '$2' ran $got times, want $3"; fi
}
assert_eq() { # <id> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}

# --- unit probes into the guard's own modules ---------------------------------
cat > "$BASE/unit.js" <<'UNIT'
"use strict";
const path = require("path");
let mod;
try { mod = require(process.argv[2]); }
catch (e) {
    const why = e && e.code === "MODULE_NOT_FOUND" ? "" : ":" + (e && e.message);
    process.stdout.write("MODULE-MISSING:" + path.basename(process.argv[2]) + why);
    process.exit(0);
}
let v;
try { v = new Function("m", "require", "return (" + process.argv[3] + ");")(mod, require); }
catch (e) { process.stdout.write("THREW:" + (e && e.message ? e.message : String(e))); process.exit(0); }
process.stdout.write(v === undefined ? "undefined" : JSON.stringify(v));
UNIT

GUARD_DIR="$AGENTS_DIR/hooks/confirm-forge-target-ownership"
unit_expr() { # <id> <want-json> <module-file.js> <expression over m>
    local got
    got="$("$RWT" 15 node "$BASE/unit.js" "$(npath "$GUARD_DIR/$3")" "$4" 2>&1)"
    assert_eq "$1" "$2" "$got"
}
# Pins that a module REUSES a shared primitive instead of copying its rules.
assert_source_has() { # <id> <module-file.js> <needle>
    if [ ! -f "$GUARD_DIR/$2" ]; then fail "$1" "module not created yet: $2"; return; fi
    if grep -qF -- "$3" "$GUARD_DIR/$2"; then pass "$1"; else fail "$1" "$2 does not reference '$3'"; fi
}
