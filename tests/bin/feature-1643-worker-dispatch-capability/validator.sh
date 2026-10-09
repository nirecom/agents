#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-capability/validator.sh
# Tests: bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, capability, fsguard, spawn, security, attack-matrix, TL1, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-capability.sh after matrix.sh — defines group_validator_rows.
# Group V: table-driven validator rows (skills/_shared/test-design/parser-regex-tests.md).
# One node process evaluates the whole table; values travel as JSON string bodies.
CAP_PROBE="$TMPD/cap-probe.js"
cat > "$CAP_PROBE" <<'CAPJS'
const fs = require("fs");
const path = require("path");
const [scriptCheckoutRoot, targetMainRoot, rowsFile, outFile] = process.argv.slice(2);
const capMod = require(path.join(scriptCheckoutRoot, "bin/worker-dispatch/capability.js"));
const anchorMod = require(path.join(scriptCheckoutRoot, "bin/worker-dispatch/anchor.js"));

const anchors = anchorMod.resolveAnchors(targetMainRoot);
if (anchors.error) {
  fs.writeFileSync(outFile, "ANCHORS_ERROR\tANCHORS_ERROR\t" + anchors.error + "\n");
  process.exit(9);
}
const backupRoot = path.join(anchors.targetMainRoot, capMod.BACKUP_DIR_NAME);

// The row's value column is a JSON string BODY: the shell hands over bytes it
// can carry, node reconstitutes the ones it cannot (control chars, backslashes).
const decode = (enc) => JSON.parse('"' + enc + '"');

const rows = [];
for (const raw of fs.readFileSync(rowsFile, "utf8").split(/\r?\n/)) {
  if (raw === "") continue;
  const [name, kind, enc] = raw.split("\t");
  const value = decode(enc === undefined ? "" : enc);
  let verdict = "UNKNOWN_KIND";
  let extra = "-";
  if (kind === "branch") {
    const r = capMod.checkField(value, { type: "branch" }, anchors, { branch: value });
    verdict = r.error ? "reject" : "accept";
  } else if (kind === "backup") {
    // The field is DERIVED: absent from the payload, computed from `branch`.
    const r = capMod.checkField(undefined, { type: "derived-backup-dir" }, anchors, { branch: value });
    verdict = r.error ? "reject" : "accept";
    if (!r.error) {
      extra = anchorMod.isUnder(r.value, backupRoot, false) ? "inside" : "OUTSIDE:" + r.value;
    }
  } else if (kind === "relarg") {
    const r = capMod.checkField([value], { type: "rel-path-arg[]", maxItems: 64 }, anchors, {});
    verdict = r.error ? "reject" : "accept";
  } else if (kind === "relarg-n") {
    const n = Number(value);
    const arr = [];
    for (let i = 0; i < n; i += 1) arr.push("tests/case-" + i + ".sh");
    const r = capMod.checkField(arr, { type: "rel-path-arg[]", maxItems: 64 }, anchors, {});
    verdict = r.error ? "reject" : "accept";
  }
  rows.push([name, verdict, extra].join("\t"));
}
fs.writeFileSync(outFile, rows.join("\n") + "\n");
CAPJS

CAP_ROWS="$TMPD/cap-rows.tsv"
CAP_OUT="$TMPD/cap-out.tsv"

# The probe's verdict table is read once into memory. Looking each row up with
# `awk ... "$CAP_OUT"` instead costs two process starts per assertion.
declare -A CAP_VERDICT CAP_EXTRA
cap_load() {
    local rname rverdict rextra
    while IFS=$'\t' read -r rname rverdict rextra; do
        [ -z "$rname" ] && continue
        CAP_VERDICT["$rname"]="$rverdict"
        CAP_EXTRA["$rname"]="$rextra"
    done < "$CAP_OUT"
}
# Lookups below read the arrays directly rather than through an accessor: a
# `$(fn)` call is a fork per assertion even when the function itself is builtin.

# Row classes, as the original Group V header described them:
#   branch       — `isSafeBranch`. `../../../pwned` passes a charset test, and
#                  path.join normalizes `..`, so derived-backup-dir resolved OUTSIDE
#                  <target-main-root>/.worktree-backup and became an fsguard write scope for
#                  the worker that copies .env aside. Both layers are asserted.
#   rel-path-arg — test-runner's `test_args` (argv for tests/run-all.sh); an absolute
#                  path or `..` climb selected a script outside the family worktree.
group_validator_rows() {
    if [ ! -f "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/capability.js" ]; then
        fail "cap-row/probe — implementation missing: bin/worker-dispatch/capability.js"
        return
    fi

    local name kind enc want
    local -a NAMES KINDS WANTS
    : > "$CAP_ROWS"
    while IFS='|' read -r name kind enc want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        trim "$name"; name="$TRIMMED"
        trim "$kind"; kind="$TRIMMED"
        trim "$want"; want="$TRIMMED"
        # The value column is trimmed, never word-split: backslashes are data.
        trim "$enc";  enc="$TRIMMED"
        printf '%s\t%s\t%s\n' "$name" "$kind" "$enc" >> "$CAP_ROWS"
        NAMES+=("$name"); KINDS+=("$kind"); WANTS+=("$want")
    done <<'TABLE'
# --- branch: the accept set (ordinary git refs must keep working) ------------
br-simple                | branch   | main                                     | accept
br-feature-slash         | branch   | feature/worker-dispatch                  | accept
br-underscore-dot        | branch   | fix/a_b-c.d                              | accept
br-release-semver        | branch   | release/1.2.3                            | accept
br-plus-sign             | branch   | feature/a+b                              | accept
br-inner-dots-not-a-seg  | branch   | feature/a..b                             | accept
br-deep-path             | branch   | user/topic/sub/leaf                      | accept
# --- branch: the traversal set (the regression this rule exists for) --------
br-traversal-classic     | branch   | ../../../pwned                           | reject
br-traversal-mid         | branch   | feature/../../x                          | reject
br-dotdot-only           | branch   | ..                                       | reject
br-dot-only              | branch   | .                                        | reject
br-dot-segment           | branch   | feature/./x                              | reject
br-trailing-dotdot       | branch   | feature/..                               | reject
# --- branch: separator abuse -----------------------------------------------
br-leading-slash         | branch   | /feature/x                               | reject
br-trailing-slash        | branch   | feature/x/                               | reject
br-double-slash          | branch   | feature//x                               | reject
br-slash-only            | branch   | /                                        | reject
# --- branch: option-looking segments ---------------------------------------
br-leading-dash          | branch   | -rf                                      | reject
br-dash-segment          | branch   | feature/-x                               | reject
br-double-dash           | branch   | --upload-pack=x                          | reject
# --- branch: charset floor still holds -------------------------------------
br-empty                 | branch   |                                          | reject
br-space                 | branch   | feature/a b                              | reject
br-semicolon             | branch   | feature/a;id                             | reject
br-backslash             | branch   | feature\\x                               | reject
br-newline               | branch   | feature\nx                               | reject
# --- derived-backup-dir: same input set, asserted on the DERIVED path -------
bk-simple                | backup   | main                                     | accept
bk-feature-slash         | backup   | feature/worker-dispatch                  | accept
bk-release-semver        | backup   | release/1.2.3                            | accept
bk-inner-dots-not-a-seg  | backup   | feature/a..b                             | accept
bk-traversal-classic     | backup   | ../../../pwned                           | reject
bk-traversal-mid         | backup   | feature/../../x                          | reject
bk-dotdot-only           | backup   | ..                                       | reject
bk-dot-only              | backup   | .                                        | reject
bk-leading-slash         | backup   | /feature/x                               | reject
bk-trailing-slash        | backup   | feature/x/                               | reject
bk-double-slash          | backup   | feature//x                               | reject
bk-leading-dash          | backup   | -rf                                      | reject
bk-backslash             | backup   | ..\\..\\pwned                            | reject
bk-empty                 | backup   |                                          | reject
# --- rel-path-arg[]: the accept set (what /run-tests actually passes) -------
ra-plain-file            | relarg   | tests/run-all.sh                         | accept
ra-glob                  | relarg   | tests/feature-1643-worker-dispatch-*.sh  | accept
ra-dotted-name           | relarg   | tests/.hidden-case.sh                    | accept
ra-inner-dots-not-a-seg  | relarg   | tests/a..b.sh                            | accept
ra-space-inside          | relarg   | tests/a b.sh                             | accept
ra-backslash-relative    | relarg   | tests\\sub\\case.sh                      | accept
ra-bare-name             | relarg   | run-all.sh                               | accept
# --- rel-path-arg[]: roots ---------------------------------------------------
ra-abs-posix             | relarg   | /etc/passwd                              | reject
ra-abs-windows-back      | relarg   | C:\\Windows\\System32\\x.sh              | reject
ra-abs-windows-fwd       | relarg   | C:/Windows/System32/x.sh                 | reject
ra-leading-backslash     | relarg   | \\\\server\\share\\x.sh                  | reject
ra-single-backslash      | relarg   | \\x.sh                                   | reject
# --- rel-path-arg[]: climbs, both separators --------------------------------
ra-climb-fwd             | relarg   | ../outside/x.sh                          | reject
ra-climb-mid-fwd         | relarg   | tests/../../outside/x.sh                 | reject
ra-climb-back            | relarg   | ..\\outside\\x.sh                        | reject
ra-climb-mid-back        | relarg   | tests\\..\\..\\outside\\x.sh             | reject
ra-dotdot-only           | relarg   | ..                                       | reject
# --- rel-path-arg[]: option smuggling and degenerate values -----------------
ra-leading-dash          | relarg   | -rf                                      | reject
ra-long-option           | relarg   | --exec=/bin/sh                           | reject
ra-flagless-word         | relarg   | --all                                    | reject
ra-empty                 | relarg   |                                          | reject
ra-control-char          | relarg   | tests/a\u0001b.sh                        | reject
ra-newline               | relarg   | tests/a\nb.sh                            | reject
ra-tab                   | relarg   | tests/a\tb.sh                            | reject
# --- rel-path-arg[]: maxItems 64 still bounds the array ---------------------
ra-count-64              | relarg-n | 64                                       | accept
ra-count-65              | relarg-n | 65                                       | reject
TABLE

    if ! run_with_timeout 90 node "$CAP_PROBE" "$(nodepath "$SCRIPT_CHECKOUT_ROOT")" "$MAIN" \
            "$(nodepath "$CAP_ROWS")" "$(nodepath "$CAP_OUT")" >/dev/null 2>"$TMPD/cap-probe.err"; then
        fail "cap-row/probe — validator probe failed: $(cat "$TMPD/cap-probe.err" 2>/dev/null)"
        return
    fi

    cap_load

    local i got
    for i in "${!NAMES[@]}"; do
        got="${CAP_VERDICT[${NAMES[$i]}]-}"
        assert_eq "cap-row/${NAMES[$i]}" "${WANTS[$i]}" "$got"
        # Second layer for the derived field: an ACCEPTED derivation must still
        # land inside <target-main-root>/.worktree-backup. This is the assertion that
        # would have caught `../../../pwned` even if the branch rule had missed
        # it, because it measures the joined result rather than the input.
        if [ "${KINDS[$i]}" = "backup" ] && [ "$got" = "accept" ]; then
            assert_eq "cap-row/${NAMES[$i]}/containment" "inside" "${CAP_EXTRA[${NAMES[$i]}]-}"
        fi
    done
}
