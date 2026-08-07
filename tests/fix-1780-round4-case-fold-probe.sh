#!/usr/bin/env bash
# tests/fix-1780-round4-case-fold-probe.sh
# Tests: hooks/enforce-worktree/bash-write-scope/target-normalize.js
# Tags: worktree, enforce-worktree, case-sensitivity, filesystem-probe, containment, fail-closed, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The cross-volume matrix. Every case here runs on ONE volume (the temp dir's)
#   plus that volume's root. A case-sensitive APFS volume, a WSL/DrvFs mount, an
#   SMB share, or a Windows directory with case-sensitivity enabled would each
#   exercise a different probe outcome, and no single CI host has all of them.
#   What IS asserted platform-independently is the INVARIANT (folding follows the
#   probe result, whatever it is) rather than a hard-coded per-platform verdict.
# Closest-to-action mitigation: the invariant form below fails on any host where
# folding and the probe disagree, so a regression to a platform constant is
# caught wherever the suite runs (see case D3).
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780 round-4 H-3)
#
# Containment used to be decided by a platform constant:
#
#     const CASE_INSENSITIVE_FS = process.platform === "win32" || process.platform === "darwin";
#
# Case-sensitivity is a property of the VOLUME, not of the OS. On a case-
# sensitive APFS volume /repo/State and /repo/state are different directories,
# so folding reported containment for targets that are NOT inside the
# containment root. Every caller of isContainedUnder() uses containment to grant
# an ALLOW (areAllBashTargetsUnderWorkflowDir, the plans-dir check, ...), so a
# false containment is a false allow — the guard fails OPEN.
#
# The replacement asks the filesystem: flip the case of the deepest existing
# ancestor's basename and compare realpaths. Anything inconclusive — no
# probeable ancestor, an unflippable name, ENOENT, EACCES, any throw — resolves
# to CASE-SENSITIVE, i.e. no folding, i.e. stricter containment, i.e. fail
# CLOSED toward blocking.
#
# The two properties pinned here are therefore:
#   (1) the PROBE RESULT drives folding — not the platform, not a constant;
#   (2) when the probe cannot run, NO folding is applied.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
MOD_REL="hooks/enforce-worktree/bash-write-scope/target-normalize.js"
MOD="$_AGENTS_DIR_NODE/$MOD_REL"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

if [ ! -f "$AGENTS_DIR/$MOD_REL" ]; then
    fail "H0 $MOD_REL missing - every case below is vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H0 target-normalize.js present"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t 'casefold')
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -r -f "$TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

# A probe root whose basename definitely contains cased letters, so flipCase()
# has something to work with regardless of what mktemp produced.
PROBE_DIR="$TMP/CaseProbeRoot"
mkdir -p "$PROBE_DIR/Inner"
PROBE_N=$(node_path "$PROBE_DIR")
INNER_N=$(node_path "$PROBE_DIR/Inner")

DRV="$TMP/probe-driver.js"
cat > "$DRV" <<'DRV_EOF'
"use strict";
const nodePath = require("path");
const fs = require("fs");
const [, , modPath, query, a1, a2, a3] = process.argv;
const m = require(modPath);
const out = (v) => process.stdout.write(String(v));

switch (query) {
  // ---- unit-level ----
  case "flip":
    out(m._flipCase(a1) === null ? "null" : m._flipCase(a1));
    break;
  case "probe":
    out(m._probeCaseInsensitive(a1));
    break;
  case "isci":
    out(m.isCaseInsensitiveFsAt(a1));
    break;
  // Cached repeat: same answer twice, and the cached answer equals the probe.
  case "cache":
    out([m.isCaseInsensitiveFsAt(a1), m.isCaseInsensitiveFsAt(a1), m._probeCaseInsensitive(a1)].join("|"));
    break;
  // Independent ground truth: does the case-flipped spelling of an existing
  // directory resolve at all? Derived from existsSync, NOT from realpath
  // comparison, so it is not the probe restating itself.
  case "groundtruth": {
    const flipped = m._flipCase(nodePath.basename(a1));
    if (!flipped) { out("unflippable"); break; }
    out(fs.existsSync(nodePath.join(nodePath.dirname(a1), flipped)));
    break;
  }
  // THE INVARIANT: build a child whose PARENT PORTION differs only in case, so
  // exact containment cannot fire and the probe alone decides. Prints
  // "<probe>|<contained>" — the two halves must be equal on every filesystem.
  case "foldparity": {
    const parent = nodePath.resolve(a1);
    const flippedParent = m._flipCase(parent);
    if (!flippedParent) { out("unflippable"); break; }
    const child = flippedParent + nodePath.sep + "sub";
    out(m.isCaseInsensitiveFsAt(parent) + "|" + m.isContainedUnder(child, parent));
    break;
  }
  case "contain":
    out(m.isContainedUnder(a1, a2, { allowEqual: a3 === "true" }));
    break;
  // Case-flipped SELF under allowEqual:false must never be contained: that is
  // what keeps `rm -rf <workflowDir>` itself blocked on a folding volume.
  case "selfflip": {
    const parent = nodePath.resolve(a1);
    const flipped = m._flipCase(parent);
    if (!flipped) { out("unflippable"); break; }
    out(m.isContainedUnder(flipped, parent, { allowEqual: false }) + "|" +
        m.isContainedUnder(parent, parent, { allowEqual: false }) + "|" +
        m.isContainedUnder(parent, parent, { allowEqual: true }));
    break;
  }
  case "containtypes":
    out([
      m.isContainedUnder(null, a1),
      m.isContainedUnder(a1, null),
      m.isContainedUnder(a1, ""),
      m.isContainedUnder(12345, a1),
      m.isContainedUnder(a1, {}),
    ].join(","));
    break;
  // The volume root: dirname(root) === root, so there is no ancestor to probe
  // and the answer is forced to the fail-closed side on EVERY platform.
  case "rootprobe": {
    const root = nodePath.parse(nodePath.resolve(a1)).root;
    out(m.isCaseInsensitiveFsAt(root) + "|" + m._probeCaseInsensitive(root));
    break;
  }
  case "platform":
    out(process.platform);
    break;
  case "normalize": {
    const inputs = [null, undefined, "bare/string", {}, { path: 7 }, { resolveVia: "cwd", path: "x" }];
    out(inputs.map((t) => {
      const r = m.normalizeTarget(t);
      return [!!r.malformed, r.resolveVia, r.path].join(":");
    }).join(" "));
    break;
  }
  default:
    out("BAD-QUERY");
}
DRV_EOF

q() { "$RWT" 15 node "$DRV" "$MOD" "$@" 2>/dev/null; }

# ── harness self-check: the driver must be able to reach the module at all ──
selfcheck=$(q flip "Users")
if [ "$selfcheck" != "uSERS" ]; then
    fail "H1 driver cannot exercise target-normalize.js (got $(printf '%q' "$selfcheck")) - all cases vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 driver reaches target-normalize.js"

# ===========================================================================
# Section F - flipCase: the probe's raw material. A name it cannot flip yields
# no usable probe, which is one of the routes into the fail-closed branch.
# ===========================================================================
assert_eq "F1 flipCase inverts each cased letter"        "uSERS"  "$(q flip 'Users')"
assert_eq "F2 flipCase handles an all-lowercase name"    "ABC"    "$(q flip 'abc')"
assert_eq "F3 flipCase handles an all-uppercase name"    "abc"    "$(q flip 'ABC')"
assert_eq "F4 flipCase leaves uncased chars alone"       "A1_b-2" "$(q flip 'a1_B-2')"
assert_eq "F5 flipCase returns null for a digits-only name (unprobeable)" "null" "$(q flip '12345')"
assert_eq "F6 flipCase returns null for punctuation only (unprobeable)"   "null" "$(q flip '._-')"
assert_eq "F7 flipCase returns null for the empty name"  "null"   "$(q flip '')"

# ===========================================================================
# Section D - the probe DRIVES the decision.
# ===========================================================================
GT=$(q groundtruth "$PROBE_N")
PROBE=$(q probe "$PROBE_N")
case "$GT" in
    true|false)
        assert_eq "D1 probe agrees with independent existsSync ground truth on this volume" "$GT" "$PROBE" ;;
    *)  skip "D1 ground truth unavailable on this volume (flipCase said: $GT)" ;;
esac

# D2 is the load-bearing one: for a child that differs from its parent ONLY in
# case, containment must equal the probe result - true on a folding volume,
# false on a case-sensitive one. Written as an equality so it holds everywhere.
assert_eq "D2 case-only-differing containment follows the probe verdict" \
    "$PROBE|$PROBE" "$(q foldparity "$PROBE_N")"

# D3 pins the REMOVED constant. `process.platform === "win32" || "darwin"` would
# have returned true here on Windows and macOS; the probe returns false because
# the volume root has no ancestor to compare against. On Linux the old constant
# was false too, so this case only contradicts the old code on win32/darwin -
# stated explicitly rather than silently platform-skipped.
PLAT=$(q platform)
assert_eq "D3 volume root is reported case-SENSITIVE (fail-closed), platform=$PLAT" \
    "false|false" "$(q rootprobe "$PROBE_N")"

# D4 a nonexistent path does not force a verdict of its own: the probe walks up
# to the nearest real ancestor and reports THAT volume's answer. Pinned so the
# walk-up is not "simplified" into an ENOENT->false shortcut, which would make
# containment silently stricter for every not-yet-created target.
assert_eq "D4 nonexistent path inherits its nearest real ancestor's verdict" \
    "$PROBE" "$(q probe "$PROBE_N/no-such-dir-xyz/deeper")"

# D5 caching must not change the answer.
assert_eq "D5 repeated lookups are cached without changing the verdict" \
    "$PROBE|$PROBE|$PROBE" "$(q cache "$PROBE_N")"

# ===========================================================================
# Section C - containment semantics that must hold on ANY volume.
# ===========================================================================
assert_eq "C1 exact-case child is contained regardless of the probe" \
    "true" "$(q contain "$INNER_N" "$PROBE_N" true)"
assert_eq "C2 a sibling directory is never contained" \
    "false" "$(q contain "$PROBE_N-other/x" "$PROBE_N" true)"
assert_eq "C3 a prefix-sharing sibling is not contained (separator required)" \
    "false" "$(q contain "${PROBE_N}Extra/x" "$PROBE_N" true)"
# allowEqual:false is what keeps the containment root ITSELF outside the allow -
# both spellings of it, otherwise a folding volume would readmit it.
assert_eq "C4 allowEqual:false excludes the root itself and its case-flipped spelling" \
    "false|false|true" "$(q selfflip "$PROBE_N")"
assert_eq "C5 non-string / empty arguments are never contained (fail-closed)" \
    "false,false,false,false,false" "$(q containtypes "$INNER_N")"

# ===========================================================================
# Section N - normalizeTarget: the other fail-closed direction in this module.
# A malformed target must be marked, never coerced into a clean "outside scope".
# ===========================================================================
assert_eq "N1 normalizeTarget marks malformed targets and preserves valid ones" \
    "true:ancestor: true:ancestor: false:ancestor:bare/string true:ancestor: true:ancestor: false:cwd:x" \
    "$(q normalize)"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
