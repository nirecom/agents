#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-capability.sh
# Tests: bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, capability, fsguard, spawn, security, attack-matrix, TL1, scope:issue-specific
#
# Issue #1643 — capability attack matrix. The guard never inspects the payload,
# so capability.js / fsguard.js / spawn.js are the ONLY barrier between an
# untrusted PLANS_DIR file and arbitrary write/exec. Every row below drives one
# hostile payload field type from the detail plan's capability table and asserts
# all three protection properties (protection-fix Pattern 1 — negative assertion
# on the protected resource, not merely on the exit status):
#   1. a rejection status in the worker's own renderer vocabulary
#      (`failed` for the status-triple workers, `runner-error` for the
#      test-runner YAML renderer — see expected_reject_status below)
#   2. no effectful child process (nothing but the read-only anchor git probes)
#   3. no filesystem write anywhere in the fixture tree
#
# Group V adds the complementary axis. A whole-dispatch row answers "did a
# hostile payload reach a side effect", which is too coarse to enumerate the
# accept/reject boundary of a charset-and-segment rule. So the two path-shaped
# SCALAR types — `branch` (via isSafeBranch, which `derived-backup-dir` also
# depends on) and `rel-path-arg[]` — are additionally driven table-row by
# table-row straight through capability.checkField.
#
# TL3 gap (what this TL1 test does NOT catch):
#   - A real linked-worktree family with NTFS junctions / bind mounts, where
#     realpath resolution behaves differently from the temp fixtures here.
#   - Real PLANS_DIR shared between concurrent sessions.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

# Wall-clock guard, re-exec form. This MUST come before the fixture block below:
# with the guard at the bottom of the file, the outer shell built the entire
# fixture tree (two git repos, two linked worktrees, the PATH shims) and only
# then re-exec'd an inner shell that built all of it a second time — roughly
# doubling the runtime of the suite, against a budget the suite was already
# close to exhausting. Matches the placement in
# tests/feature-1643-worker-dispatch-backup-secrets.sh.
#
# 180s is deliberately above the 120s default of rules/test.md but well under
# the old 420s: the run is dominated by 18 real dispatches, and a guard that
# fires only after several minutes turns a hang into a lost summary line (the
# tail of a killed run's buffered stdout never reaches the log) instead of a
# visible failure.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_CAP_INNER:-}" ]; then
    _WD1643_CAP_INNER=1 timeout 180 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"

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

# Whitespace trim, in-process. The `$(echo "$x" | xargs)` idiom this replaces
# costs a fork + two process starts per column; at ~70 table rows x 3-4 columns
# that alone was over a minute of the suite's wall-clock budget on Windows.
# It is also safer for this table: xargs applies quote and backslash processing,
# and several rows here are *about* backslashes.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    TRIMMED="$s"
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-cap-$$")"
mkdir -p "$TMPD"
# An inherited EXIT trap runs when a ( ) subshell or a "$( )" substitution exits
# on some bash builds (it does not on others — the behaviour is not portable).
# This suite is full of both: snapshot_all cds into each fixture directory, and
# run_dispatch cds into the main worktree. Unguarded, the first such subshell
# deletes the whole fixture tree MID-RUN, and every later row fails to cd — the
# suite then ends with no summary line at all, which reads as a pass to anything
# that only checks the exit status.
#
# $$ cannot express the guard: it stays the PID of the *invoking* shell inside a
# subshell. $BASHPID is the one that changes, so it is what the comparison uses.
TMPD_OWNER_PID="${BASHPID:-$$}"
cleanup_tmpd() {
    [ "${BASHPID:-$$}" = "$TMPD_OWNER_PID" ] || return 0
    rm -rf "$TMPD"
}
trap cleanup_tmpd EXIT

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

mk_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config core.hooksPath /dev/null
    echo init > "$d/README.md"
    git -C "$d" add README.md 2>/dev/null
    git -C "$d" commit -q --no-verify -m initial 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fixtures — every protected surface gets a file whose bytes we watch.
# ---------------------------------------------------------------------------
MAIN_RAW="$TMPD/mainrepo"; mk_repo "$MAIN_RAW"
ALT_RAW="$TMPD/altrepo";   mk_repo "$ALT_RAW"
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/cap-probe "$LINKED_RAW" >/dev/null 2>&1
ALT_LINKED_RAW="$TMPD/alt-linked-wt"
git -C "$ALT_RAW" worktree add -q -b feature/alt-probe "$ALT_LINKED_RAW" >/dev/null 2>&1

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
EVIL_RAW="$TMPD/plans-evil"; mkdir -p "$EVIL_RAW"   # sibling-prefix bypass target
OUTSIDE_RAW="$TMPD/outside"; mkdir -p "$OUTSIDE_RAW"
FAKE_ACD_RAW="$TMPD/fake-acd"; mkdir -p "$FAKE_ACD_RAW/hooks" "$FAKE_ACD_RAW/bin"
touch "$FAKE_ACD_RAW/hooks/enforce-worktree.js" "$FAKE_ACD_RAW/bin/worker-dispatch.js"
NONGIT_RAW="$TMPD/plain-dir"; mkdir -p "$NONGIT_RAW"

echo "canary" > "$EVIL_RAW/WORKTREE_NOTES.md"
echo "canary" > "$OUTSIDE_RAW/history.md"
echo "canary" > "$NONGIT_RAW/canary.txt"

MAIN="$(nodepath "$MAIN_RAW")"
ALT="$(nodepath "$ALT_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
ALT_LINKED="$(nodepath "$ALT_LINKED_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
EVIL="$(nodepath "$EVIL_RAW")"
OUTSIDE="$(nodepath "$OUTSIDE_RAW")"
FAKE_ACD="$(nodepath "$FAKE_ACD_RAW")"
NONGIT="$(nodepath "$NONGIT_RAW")"

# Symlink inside the family that escapes it (env-dependent on Windows).
SYMLINK_OK=0
SYMLINK_RAW="$LINKED_RAW/escape-link"
if ln -s "$OUTSIDE_RAW" "$SYMLINK_RAW" 2>/dev/null; then SYMLINK_OK=1; fi
SYMLINK="$(nodepath "$SYMLINK_RAW")"

# ---------------------------------------------------------------------------
# Observability: PATH shims record every external child process.
# Read-only anchor probes are the only permitted invocations.
# ---------------------------------------------------------------------------
SHIM_DIR="$TMPD/shims"; mkdir -p "$SHIM_DIR"
SPAWN_LOG="$TMPD/spawn.log"; : > "$SPAWN_LOG"
for real_bin in git gh uv docker bash; do
    real_path="$(command -v "$real_bin" 2>/dev/null || true)"
    [ -z "$real_path" ] && continue
    cat > "$SHIM_DIR/$real_bin" <<SHIM
#!/usr/bin/env bash
printf '%s %s\n' "$real_bin" "\$*" >> "$SPAWN_LOG"
exec "$real_path" "\$@"
SHIM
    chmod +x "$SHIM_DIR/$real_bin"
done

# An invocation is "read-only anchor probe" when it is git rev-parse / git
# worktree list. Anything else counts as an effectful spawn.
# Same pattern the `grep -v … | grep -c .` form used, evaluated in-process: two
# more process starts saved per matrix row. The log is normally empty, so the
# loop body rarely runs at all.
SPAWN_PROBE_RE='^git (-C [^ ]+ )?(rev-parse|worktree list)'
count_effectful_spawns() {
    local line
    EFFECTFUL_SPAWNS=0
    [ -f "$SPAWN_LOG" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [[ $line =~ $SPAWN_PROBE_RE ]]; then continue; fi
        EFFECTFUL_SPAWNS=$((EFFECTFUL_SPAWNS + 1))
    done < "$SPAWN_LOG"
    return 0
}

# Byte snapshot of every protected surface (payload files excluded — the test
# itself writes those, and PLANS_DIR is the one sanctioned write scope).
#
# One node process walks all eight roots. The obvious shell form — find | while
# read | node -e per file — costs a process start per file per call, and this is
# called twice per matrix row; on Windows (~100-150ms per node start) that alone
# outran the suite's wall-clock guard before the matrix finished. The output
# format is byte-identical to that form: `<root>|<./relpath> <sha256>` lines,
# roots in the listed order, paths LC_ALL=C-sorted (byte order, hence the
# Buffer.compare), regular files only, and only a top-level `.git/` pruned — a
# linked worktree's `.git` *file* is a protected surface and stays in.
#
# Roots arrive on stdin as `label<TAB>path` pairs, not as argv: MSYS rewrites
# path-shaped argv on the way into a native node.exe, so an argv form would
# print the rewritten spelling (C:/... ) instead of the bash-side one and the
# snapshot would no longer be byte-identical. The label is the raw bash path the
# old form printed; the path is the cygpath -m form node can actually open.
SNAP_JS="$TMPD/snapshot-all.js"
cat > "$SNAP_JS" <<'SNAPJS'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const roots = fs.readFileSync(0, "utf8").split("\n")
  .filter((l) => l !== "")
  .map((l) => { const i = l.indexOf("\t"); return { label: l.slice(0, i), dir: l.slice(i + 1) }; });

const out = [];
for (const { label, dir: root } of roots) {
  let st;
  try { st = fs.statSync(root); } catch { continue; }   // cd failed => no output
  if (!st.isDirectory()) continue;

  const files = [];
  const walk = (dir, rel) => {
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const r = rel ? rel + "/" + e.name : e.name;
      if (r === ".git" && e.isDirectory()) continue;    // matches -not -path './.git/*'
      if (e.isDirectory()) walk(path.join(dir, e.name), r);
      else if (e.isFile()) files.push(r);               // isFile() is lstat-based: symlinks excluded, as -type f
    }
  };
  walk(root, "");

  files.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  for (const r of files) {
    let hash;
    try {
      hash = crypto.createHash("sha256").update(fs.readFileSync(path.join(root, r))).digest("hex");
    } catch { hash = "ERR"; }
    out.push(label + "|./" + r + " " + hash);
  }
}
process.stdout.write(out.length ? out.join("\n") + "\n" : "");
SNAPJS
SNAP_JS_N="$(nodepath "$SNAP_JS")"

snapshot_all() {
    printf '%s\t%s\n' \
        "$MAIN_RAW"       "$MAIN" \
        "$ALT_RAW"        "$ALT" \
        "$LINKED_RAW"     "$LINKED" \
        "$ALT_LINKED_RAW" "$ALT_LINKED" \
        "$EVIL_RAW"       "$EVIL" \
        "$OUTSIDE_RAW"    "$OUTSIDE" \
        "$NONGIT_RAW"     "$NONGIT" \
        "$FAKE_ACD_RAW"   "$FAKE_ACD" \
        | node "$SNAP_JS_N" 2>/dev/null
}

DOUT=""
DRC=0
run_dispatch() {
    DRC=0
    DOUT="$(cd "$MAIN_RAW" && run_with_timeout 60 env \
        "PATH=$SHIM_DIR:$PATH" \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$DISPATCH_JS" "$@" 2>&1)" || DRC=$?
}

# First `status: <value>` line of the dispatcher output, matched in-process for
# the same reason as trim(): the pipe-to-sed form is three process starts, and
# this runs once per matrix row.
status_of() {
    local line
    STATUS_LINE=""
    while IFS= read -r line; do
        case "$line" in
            status:*)
                line="${line#status:}"
                trim "$line"
                STATUS_LINE="$TRIMMED"
                return 0
                ;;
        esac
    done <<< "$DOUT"
}

# The rejection status is renderer-dependent, and the renderer is a property of
# the worker (hooks/lib/worker-dispatch-registry.js). The status-triple families
# say `failed`; the test-runner YAML renderer has its own four-value vocabulary
# — pass | fail | timeout | runner-error — which skills/run-tests/SKILL.md RNT-9
# branches on, and `failed` is in none of those branches. Kept as an explicit
# test-owned table rather than read back out of the registry, so a registry that
# silently re-rendered a worker would fail here instead of agreeing with itself.
expected_reject_status() {
    case "$1" in
        test-runner) echo "runner-error" ;;
        *)           echo "failed" ;;
    esac
}

# ===========================================================================
# Attack matrix
# ===========================================================================
run_matrix() {
    local name worker payload pfile before after spawns got_status
    local i=0
    while IFS='|' read -r name worker payload; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        trim "$name";   name="$TRIMMED"
        trim "$worker"; worker="$TRIMMED"
        i=$((i + 1))

        if [ ! -f "$DISPATCH_JS" ]; then
            fail "cap/$name/status — implementation missing: bin/worker-dispatch.js"
            fail "cap/$name/no-spawn — implementation missing: bin/worker-dispatch.js"
            fail "cap/$name/no-write — implementation missing: bin/worker-dispatch.js"
            continue
        fi
        if [ "$name" = "worktree-via-symlink" ] && [ "$SYMLINK_OK" -eq 0 ]; then
            # SKIPPED: symlink-escape containment case
            # Because: this host refuses unprivileged symlink creation (Windows
            #          without Developer Mode); the fixture cannot be built.
            # L3 gap: only a real NTFS/POSIX host with symlink support proves
            #          that realpath-based containment defeats the escape.
            echo "SKIP: cap/$name (symlink creation unsupported on this host)"
            continue
        fi

        pfile="$PLANS_RAW/attack-$i.json"
        printf '%s' "$payload" > "$pfile"

        before="$(snapshot_all)"
        : > "$SPAWN_LOG"
        # $PLANS is already the cygpath -m form of $PLANS_RAW, so the payload
        # path is composed rather than converted — one less cygpath per row.
        run_dispatch "$worker" "$MAIN" "$PLANS/attack-$i.json"
        after="$(snapshot_all)"
        count_effectful_spawns; spawns="$EFFECTFUL_SPAWNS"
        status_of; got_status="$STATUS_LINE"

        assert_eq "cap/$name/status"   "$(expected_reject_status "$worker")" "$got_status"
        assert_eq "cap/$name/no-spawn" "0"      "$spawns"
        assert_eq "cap/$name/no-write" "$before" "$after"
    done <<TABLE
acd-other-dir          | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","agents_config_dir":"$FAKE_ACD","artifact_dir":"$PLANS"}
main-root-mismatch     | worktree-copy    | {"main_root":"$ALT","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-unregistered  | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$NONGIT","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-dotdot        | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$LINKED/../../outside","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-via-symlink   | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$SYMLINK","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-other-repo    | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$ALT_LINKED","branch":"feature/alt-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-relative      | worktree-copy    | {"main_root":"$MAIN","worktree_path":"linked-wt","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
backup-dir-arbitrary   | worktree-backup  | {"mode":"execute","worktree_path":"$LINKED","branch":"feature/cap-probe","backup_dir":"$OUTSIDE","docker_check":false,"artifact_dir":"$PLANS"}
backup-dir-sibling     | worktree-backup  | {"mode":"execute","worktree_path":"$LINKED","branch":"feature/cap-probe","backup_dir":"$EVIL","docker_check":false,"artifact_dir":"$PLANS"}
cwd-outside-family     | doc-append       | {"mode":"history","cwd":"$ALT","category":"FEATURE","subject":"x","commits":"abcdef1","background":"b","changes":"c","artifact_dir":"$PLANS"}
notes-sibling-prefix   | doc-append       | {"mode":"compose","cwd":"$LINKED","notes_path":"$EVIL/WORKTREE_NOTES.md","branch":"feature/cap-probe","pr_number":"1","merge_commit":"abcdef1","pr_title":"t","closes_issues_count":1,"artifact_dir":"$PLANS"}
history-outside-repo   | issue-reconcile  | {"owner_repo":"nirecom/agents","history_md_path":"$OUTSIDE/history.md","history_dir_path":"$OUTSIDE","limit":10,"artifact_dir":"$PLANS"}
artifact-outside-plans | issue-reconcile  | {"owner_repo":"nirecom/agents","history_md_path":"$MAIN/docs/history.md","history_dir_path":"$MAIN/docs/history","limit":10,"artifact_dir":"$OUTSIDE"}
payload-binary-key     | test-runner      | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"binary":"/bin/sh"}
payload-env-keys       | test-runner      | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"env":{"PATH":"$EVIL"}}
cwd-outside-family-tr  | test-runner      | {"cwd":"$ALT","test_args":[],"timeout_seconds":15}
owner-repo-injection   | issue-reconcile  | {"owner_repo":"nirecom/agents --json body","history_md_path":"$MAIN/docs/history.md","history_dir_path":"$MAIN/docs/history","limit":10,"artifact_dir":"$PLANS"}
plans-dir-sibling      | session-close-gate | {"session_id":"s1","plans_dir":"$EVIL","artifact_dir":"$EVIL","outcome_json_path":"$EVIL/o.json"}
TABLE
}

# ===========================================================================
# Group V — validator rows for the two path-shaped SCALAR types
#
# The attack matrix above drives whole dispatches, which is the right shape for
# "does a hostile payload reach a side effect" but far too coarse to enumerate a
# charset/segment rule. These two types are ordinary parsers, so they get the
# table-driven treatment from skills/_shared/test-design/parser-regex-tests.md:
# one row per input class, accept/reject asserted per row.
#
#   branch      — `isSafeBranch`. The charset regex alone used to be the whole
#                 test, and `../../../pwned` passes a charset test. Because
#                 `derived-backup-dir` path.join()s the branch onto the backup
#                 root, and path.join NORMALIZES `..` away, that value resolved
#                 to a directory OUTSIDE <main-root>/.worktree-backup — and that
#                 directory then became an authorized fsguard write scope for
#                 worktree-backup, the worker that copies gitignored files
#                 (including .env) aside. Both layers are asserted: the `branch`
#                 field rejects the input, AND no accepted derivation lands
#                 outside the backup root.
#   rel-path-arg— test-runner's `test_args`, which becomes argv for
#                 tests/run-all.sh. As `text[]` an absolute path or a `..` climb
#                 selected a script outside the validated family worktree.
#
# One node process evaluates the whole table so the per-row cost is a function
# call, not a process start; values travel as JSON string bodies so a Windows
# path or a control character survives the shell untouched.
# ===========================================================================
CAP_PROBE="$TMPD/cap-probe.js"
cat > "$CAP_PROBE" <<'CAPJS'
const fs = require("fs");
const path = require("path");
const [agentsDir, mainRoot, rowsFile, outFile] = process.argv.slice(2);
const capMod = require(path.join(agentsDir, "bin/worker-dispatch/capability.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));

const anchors = anchorMod.resolveAnchors(mainRoot);
if (anchors.error) {
  fs.writeFileSync(outFile, "ANCHORS_ERROR\tANCHORS_ERROR\t" + anchors.error + "\n");
  process.exit(9);
}
const backupRoot = path.join(anchors.mainRoot, capMod.BACKUP_DIR_NAME);

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

group_validator_rows() {
    if [ ! -f "$AGENTS_DIR/bin/worker-dispatch/capability.js" ]; then
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

    if ! run_with_timeout 90 node "$CAP_PROBE" "$(nodepath "$AGENTS_DIR")" "$MAIN" \
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
        # land inside <main-root>/.worktree-backup. This is the assertion that
        # would have caught `../../../pwned` even if the branch rule had missed
        # it, because it measures the joined result rather than the input.
        if [ "${KINDS[$i]}" = "backup" ] && [ "$got" = "accept" ]; then
            assert_eq "cap-row/${NAMES[$i]}/containment" "inside" "${CAP_EXTRA[${NAMES[$i]}]-}"
        fi
    done
}

# Group V runs FIRST: it is seconds of in-process function calls, while the
# matrix below is a dispatch (and a full fixture-tree hash) per row. Ordering the
# cheap deterministic rows ahead of the expensive ones means a run that is cut
# short by the wall-clock guard still reports the validator verdicts.
group_validator_rows
run_matrix

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
