#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-schema.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/payload.js, bin/worker-dispatch/registry.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, dispatcher, payload, schema, argv, free-text, TL1, scope:issue-specific
#
# Issue #1643 — argv arity / worker-name enum / payload schema of the worker
# dispatcher, plus the hard requirement that free-text worker input (history
# background/changes bodies) reaches the worker module BYTE-IDENTICAL. Payload
# is passed as a PLANS_DIR file (not inline argv JSON) so free text never
# traverses the guard's UNSAFE_ARG_VALUE_RE reject set — Group C fences that.
#
# TL3 gap (what this TL1 test does NOT catch):
#   - A real skill (run-tests RNT-7 / update-docs UD-9) actually writing the
#     payload file with the Write tool and invoking the CLI in one turn.
#   - Real PLANS_DIR resolution through bin/workflow-plans-dir on the operator's
#     machine (this test pins WORKFLOW_PLANS_DIR explicitly).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PAYLOAD_JS="$AGENTS_DIR/bin/worker-dispatch/payload.js"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-schema-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

nodepath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# ---------------------------------------------------------------------------
# Fixtures: a temp main worktree + a PLANS_DIR
# ---------------------------------------------------------------------------
MAIN_ROOT_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_ROOT_RAW"
git -C "$MAIN_ROOT_RAW" init -q -b main
git -C "$MAIN_ROOT_RAW" config user.email "test@example.com"
git -C "$MAIN_ROOT_RAW" config user.name "Test"
git -C "$MAIN_ROOT_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_ROOT_RAW/README.md"
git -C "$MAIN_ROOT_RAW" add README.md 2>/dev/null
git -C "$MAIN_ROOT_RAW" commit -q --no-verify -m initial 2>/dev/null
MAIN_ROOT="$(nodepath "$MAIN_ROOT_RAW")"

PLANS_RAW="$TMPD/plans"
mkdir -p "$PLANS_RAW"
PLANS="$(nodepath "$PLANS_RAW")"

# write_payload <file-basename> <json-literal>
write_payload() {
    printf '%s' "$2" > "$PLANS_RAW/$1"
    nodepath "$PLANS_RAW/$1"
}

VALID_TR_PAYLOAD="{\"cwd\":\"$MAIN_ROOT\",\"test_args\":[],\"timeout_seconds\":30}"

# run_dispatch <args...> → sets DOUT / DRC
DOUT=""
DRC=0
run_dispatch() {
    DRC=0
    DOUT="$(run_with_timeout 60 env \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$DISPATCH_JS" "$@" 2>&1)" || DRC=$?
}

impl_missing() {
    # $1 = case name, $2 = required file, $3 = repo-relative label
    if [ -f "$2" ]; then return 1; fi
    fail "$1 — implementation missing: $3"
    return 0
}

# ===========================================================================
# Group A — argv arity and worker-name enum (exit 2, fail-closed)
# ===========================================================================
group_a() {
    while IFS='|' read -r name argstr want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        want="$(echo "$want" | xargs)"
        argstr="$(echo "$argstr" | xargs)"
        impl_missing "argv/$name" "$DISPATCH_JS" "bin/worker-dispatch.js" && continue

        # shellcheck disable=SC2086
        case "$argstr" in
            NONE)   run_dispatch ;;
            *)      run_dispatch $argstr ;;
        esac
        assert_eq "argv/$name" "$want" "$DRC"
    done <<TABLE
arity-0            | NONE                                                        | 2
arity-1            | test-runner                                                 | 2
arity-2            | test-runner $MAIN_ROOT                                      | 2
arity-4            | test-runner $MAIN_ROOT $PLANS/p.json extra                  | 2
unknown-worker     | not-a-worker $MAIN_ROOT $PLANS/p.json                       | 2
unknown-worker-mix | Test-Runner $MAIN_ROOT $PLANS/p.json                        | 2
unknown-worker-path | ../../etc/passwd $MAIN_ROOT $PLANS/p.json                  | 2
TABLE
}

# Group B — payload structure / type validation -> rejection status (exit 0).
# Every row dispatches `test-runner` (renderer test-runner-yaml), whose status
# vocabulary is pass|fail|timeout|runner-error — skills/run-tests/SKILL.md
# RNT-9 branches on exactly those four, so a validation rejection must arrive
# as `runner-error`, not `failed` (which matches no branch and hides a
# rejected payload behind "a run it never heard about").
status_of() {
    printf '%s\n' "$DOUT" | sed -n 's/^status: *//p' | head -1
}

group_b() {
    local name json p first
    while IFS='|' read -r name json; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        impl_missing "payload/$name" "$DISPATCH_JS" "bin/worker-dispatch.js" && continue

        p="$(write_payload "$name.json" "$json")"
        run_dispatch test-runner "$MAIN_ROOT" "$p"
        first="$(status_of)"
        assert_eq "payload/$name/status" "runner-error" "$first"
        assert_eq "payload/$name/exit0" "0" "$DRC"
    done <<TABLE
missing-required-key  | {"test_args":[]}
type-mismatch-int     | {"cwd":"$MAIN_ROOT","test_args":[],"timeout_seconds":"abc"}
type-mismatch-array   | {"cwd":"$MAIN_ROOT","test_args":"not-an-array"}
unknown-key           | {"cwd":"$MAIN_ROOT","test_args":[],"bogus_key":1}
malformed-json        | {"cwd": not json
not-an-object         | ["cwd"]
empty-file            |
TABLE
}

# Group C — free-text passthrough must be BYTE-IDENTICAL. Asserts that
# bin/worker-dispatch/payload.js exports a loader (loadPayload|parsePayload|
# readPayload) returning the parsed object (directly, or as `.payload`) for a
# PLANS_DIR-resident JSON file — the loader is the only layer between the file
# bytes and the worker module, so a byte-compare of the round-tripped field is
# the tightest available TL1 probe.
ECHOBACK="$TMPD/echoback.js"
cat > "$ECHOBACK" <<'ECHOJS'
// Echo-back harness: prints the requested payload field raw on stdout.
const mod = require(process.argv[2]);
const file = process.argv[3];
const field = process.argv[4];
const fn = mod.loadPayload || mod.parsePayload || mod.readPayload;
if (typeof fn !== "function") {
  process.stderr.write("NO_LOADER_EXPORT");
  process.exit(3);
}
let r;
try { r = fn(file); } catch (e) { process.stderr.write("THREW:" + e.message); process.exit(4); }
const obj = (r && typeof r === "object" && r.payload) ? r.payload : r;
if (!obj || typeof obj !== "object") { process.stderr.write("NO_OBJECT"); process.exit(5); }
const v = obj[field];
if (typeof v !== "string") { process.stderr.write("NOT_STRING"); process.exit(6); }
process.stdout.write(v);
ECHOJS

sha_of_file() {
    node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$1"
}

group_c() {
    local name gen valfile pfile got_sha want_sha out rc
    while IFS='|' read -r name gen; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        gen="$(echo "$gen" | xargs)"
        impl_missing "freetext/$name" "$PAYLOAD_JS" "bin/worker-dispatch/payload.js" && continue

        valfile="$TMPD/val-$name.txt"
        pfile="$PLANS_RAW/freetext-$name.json"
        # Build the raw value + payload JSON in Node so the shell never touches the bytes.
        node -e '
          const fs = require("fs");
          const kind = process.argv[1], valFile = process.argv[2], payFile = process.argv[3];
          let v;
          switch (kind) {
            case "spaces-quotes": v = "a b  c \x27single\x27 \"double\" tail"; break;
            case "cmd-subst":     v = "before $(rm -rf /) `id` after"; break;
            case "shell-chain":   v = "one; two && three | four > five"; break;
            case "newlines":      v = "line1\nline2\r\nline3"; break;
            case "japanese":      v = "\u65E5\u672C\u8A9E\u306E\u80CC\u666F\u8AAC\u660E\u3067\u3059\u3002"; break;
            case "over-4kb":      v = "\u3042X".repeat(2600); break;
            default: throw new Error("unknown kind " + kind);
          }
          fs.writeFileSync(valFile, v);
          fs.writeFileSync(payFile, JSON.stringify({ background: v, changes: v }));
        ' "$gen" "$valfile" "$pfile"

        rc=0
        out="$(run_with_timeout 60 node "$ECHOBACK" "$PAYLOAD_JS" "$(nodepath "$pfile")" background 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            fail "freetext/$name — echo-back harness failed (rc=$rc): $out"
            continue
        fi
        printf '%s' "$out" > "$TMPD/got-$name.txt"
        want_sha="$(sha_of_file "$valfile")"
        got_sha="$(sha_of_file "$TMPD/got-$name.txt")"
        assert_eq "freetext/$name/byte-identical" "$want_sha" "$got_sha"
    done <<'TABLE'
spaces-quotes | spaces-quotes
cmd-subst     | cmd-subst
shell-chain   | shell-chain
newlines      | newlines
japanese      | japanese
over-4kb      | over-4kb
TABLE
}

# Group D — the SSOT registry must require nothing outside node builtins
# (commit-ordering invariant: commit 1 must be requireable without bin/).
group_d() {
    if impl_missing "registry/builtins-only" "$REGISTRY_JS" "hooks/lib/worker-dispatch-registry.js"; then
        return
    fi
    local nonbuiltin
    nonbuiltin="$(node -e '
      const fs = require("fs");
      const src = fs.readFileSync(process.argv[1], "utf8");
      const re = /require\(\s*["\x27]([^"\x27]+)["\x27]\s*\)/g;
      const bad = [];
      let m;
      while ((m = re.exec(src)) !== null) {
        const id = m[1];
        const bare = id.replace(/^node:/, "");
        if (id.startsWith(".") || id.startsWith("/")) { bad.push(id); continue; }
        if (!require("module").builtinModules.includes(bare)) bad.push(id);
      }
      process.stdout.write(bad.join(","));
    ' "$REGISTRY_JS")"
    assert_eq "registry/builtins-only" "" "$nonbuiltin"

    # Enum must actually carry the 6 workers this issue converts.
    local missing
    missing="$(node -e '
      const reg = require(process.argv[1]);
      const names = Array.isArray(reg) ? reg.map(e => e && e.name)
        : (reg.WORKERS ? Object.keys(reg.WORKERS)
        : (reg.workers ? Object.keys(reg.workers) : Object.keys(reg)));
      const want = ["test-runner","worktree-copy","worktree-backup","doc-append","issue-reconcile","session-close-gate"];
      process.stdout.write(want.filter(w => !names.includes(w)).join(","));
    ' "$REGISTRY_JS" 2>/dev/null)" || missing="REQUIRE_FAILED"
    assert_eq "registry/worker-enum-complete" "" "$missing"
}

# Group E — credential scope and the typed `test_args` field, asserted on the
# SSOT registry (behavioural counterpart: the buildEnv group in
# tests/feature-1643-worker-dispatch-script-anchor.sh).
# CHILD_ENV_ALLOWLIST applies to EVERY worker's children, including the
# family-worktree-anchored tests/run-all.sh — i.e. unreviewed branch code —
# so a credential there would leak; tokens belong only in `issue-reconcile`'s
# envPassthrough. The allowlist also carries a POSITIVE contract this group
# fences: a config-location var missing from it lands a child in a different
# config dir than its parent and fails exactly like a missing credential
# would (#1719). Admission-rule SSOT for that set is the comment block above
# CHILD_ENV_ALLOWLIST in hooks/lib/worker-dispatch-registry.js — not restated
# here. `test_args` is asserted here for the same reason it's typed: as
# `text[]` it was free text that became argv for a script runner.
group_e() {
    if impl_missing "credentials/tokens-not-global" "$REGISTRY_JS" "hooks/lib/worker-dispatch-registry.js"; then
        return
    fi
    local out
    out="$(node -e '
      const reg = require(process.argv[1]);
      const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
      const TOKENS = ["GH_TOKEN", "GITHUB_TOKEN"];
      const allow = Array.isArray(reg.CHILD_ENV_ALLOWLIST) ? reg.CHILD_ENV_ALLOWLIST : null;
      out("allowlist_is_array", allow ? 1 : 0);
      out("allowlist_tokens", allow ? TOKENS.filter((t) => allow.includes(t)).join(",") : "NOT_ARRAY");
      // Non-vacuity: "no tokens in it" must not hold merely because the list is empty.
      out("allowlist_has_path", allow && allow.includes("PATH") ? 1 : 0);
      const workers = reg.workers || {};
      const ir = (workers["issue-reconcile"] || {}).envPassthrough || [];
      out("reconcile_tokens", TOKENS.filter((t) => ir.includes(t)).sort().join(","));
      // Workers legitimately authenticating against GitHub, closed on purpose —
      // a token reaching any OTHER workers children is the leak this catches.
      // (No apostrophes here: this whole script is a single-quoted shell word.)
      const SANCTIONED = ["issue-reconcile", "commit-push", "issue-close-stage", "issue-close-finalize"];
      const declarers = [];
      const others = [];
      for (const name of Object.keys(workers)) {
        const pass = workers[name].envPassthrough || [];
        const held = TOKENS.filter((t) => pass.includes(t));
        if (held.length === 0) continue;
        declarers.push(name);
        if (!SANCTIONED.includes(name)) for (const t of held) others.push(name + ":" + t);
      }
      out("other_workers_with_tokens", others.join(","));
      // Both directions: a sanctioned worker silently DROPPING tokens breaks
      // `gh` auth just as surely as an extra one leaking them.
      out("token_declarers", declarers.slice().sort().join(","));
      out("sanctioned_expected", SANCTIONED.slice().sort().join(","));
      // Each sanctioned worker must declare BOTH tokens, not just one.
      out("sanctioned_partial", SANCTIONED.filter((n) => {
        const pass = (workers[n] || {}).envPassthrough || [];
        return TOKENS.filter((t) => pass.includes(t)).length !== TOKENS.length;
      }).sort().join(","));
      const spec = (workers["test-runner"] || {}).payloadSpec || {};
      out("test_args_type", spec.test_args ? spec.test_args.type : "(absent)");
      out("test_args_max_items", spec.test_args ? spec.test_args.maxItems : "(absent)");
      // Config-location vars; SSOT for the admission rule is the comment block
      // above CHILD_ENV_ALLOWLIST in the registry.
      const CONFIG_PATH_VARS = ["APPDATA", "ProgramData", "PROGRAMDATA", "XDG_CONFIG_HOME", "GH_CONFIG_DIR"];
      out("config_path_count", CONFIG_PATH_VARS.length);
      out("config_path_missing", allow ? CONFIG_PATH_VARS.filter((v) => !allow.includes(v)).join(",") : "NOT_ARRAY");
      // Data integrity, not security: a member listed twice means two people
      // added it independently and neither noticed.
      out("allowlist_dupes", allow ? allow.filter((v, i) => allow.indexOf(v) !== i).join(",") : "NOT_ARRAY");
      // CHANGE DETECTOR ON PURPOSE: exact sorted membership + cardinality, so an
      // unanticipated credential (AWS_SECRET_ACCESS_KEY, NPM_TOKEN, ...) quietly
      // appended, or an existing member silently dropped, always turns this row
      // red — the list may only move by a deliberate human edit to the expected
      // value below. Cardinality guards against a dupe-driven length change
      // hiding behind an identical sorted join.
      out("allowlist_sorted", allow ? allow.slice().sort().join(",") : "NOT_ARRAY");
      out("allowlist_count", allow ? allow.length : -1);
    ' "$REGISTRY_JS" 2>&1)" || out="REQUIRE_FAILED"
    ev() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

    assert_eq "credentials/allowlist-is-array" "1" "$(ev allowlist_is_array)"
    assert_eq "credentials/allowlist-still-carries-path" "1" "$(ev allowlist_has_path)"
    assert_eq "credentials/tokens-not-global" "" "$(ev allowlist_tokens)"        # the fix
    assert_eq "credentials/reconcile-declares-both" "GH_TOKEN,GITHUB_TOKEN" "$(ev reconcile_tokens)"  # …but can still authenticate
    assert_eq "credentials/no-unsanctioned-worker-declares-a-token" "" "$(ev other_workers_with_tokens)"
    assert_eq "credentials/token-declarers-are-exactly-the-sanctioned-set" \
        "$(ev sanctioned_expected)" "$(ev token_declarers)"
    assert_eq "credentials/sanctioned-workers-declare-both-tokens" "" "$(ev sanctioned_partial)"

    assert_eq "payload/test-args-is-rel-path-arg" "rel-path-arg[]" "$(ev test_args_type)"
    assert_eq "payload/test-args-max-items-64" "64" "$(ev test_args_max_items)"

    # Whole config-location-variable class, not just gh-related vars — the
    # allowlist is a "class" contract applied unconditionally to every worker.
    assert_eq "config-paths/set-non-vacuous" "5" "$(ev config_path_count)"
    assert_eq "config-paths/all-present-in-allowlist" "" "$(ev config_path_missing)"
    assert_eq "allowlist/no-duplicate-entries" "" "$(ev allowlist_dupes)"

    # Change-detection assert (intentional): pins the allowlist set itself so
    # any unexpected add/remove turns red. Expected-value order follows JS's
    # default sort (UTF-16 code units): uppercase before lowercase.
    assert_eq "allowlist/exact-sorted-membership" \
        "APPDATA,COMSPEC,ComSpec,GH_CONFIG_DIR,HOME,PATH,PATHEXT,PROGRAMDATA,Path,ProgramData,SYSTEMROOT,SystemRoot,TEMP,TMP,USERPROFILE,XDG_CONFIG_HOME" \
        "$(ev allowlist_sorted)"
    assert_eq "allowlist/exact-cardinality" "16" "$(ev allowlist_count)"
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_WD1643_SCHEMA_INNER:-}" ]; then
        _WD1643_SCHEMA_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

group_a
group_b
group_c
group_d
group_e

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
