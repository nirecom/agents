# tests/bin/feature-2501-launch-classify/_lib.sh
# Tests: bin/lib/run-all-launch.sh
# Tags: TL2, bin, run-all, launch, scope:issue-specific
# Shared helpers for tests/bin/feature-2501-launch-classify.sh. Sourced by the dispatcher.
# shellcheck shell=bash
# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"

RAC_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-classify.sh"

# The bodies below run in a fresh bash so the libraries under test never touch this shell.
cat >"$TMPBASE/cls.sh" <<'EOF'
# cls.sh <agents> <rc> <launched> <resultdir> — prints STATE|RC|MISSING.
. "$1/bin/lib/run-all-classify.sh" || exit 95
shift
unset RUN_ALL_EXEC_STATE RUN_ALL_EXEC_RC RUN_ALL_EXEC_MISSING
rac_classify "$@"
printf '%s|%s|%s' "${RUN_ALL_EXEC_STATE-<unset>}" "${RUN_ALL_EXEC_RC-<unset>}" "${RUN_ALL_EXEC_MISSING-}"
EOF

cat >"$TMPBASE/eto.sh" <<'EOF'
# eto.sh <agents> <entry-timeout> <env-or-empty> <env-set:0|1> — RAC_EFFECTIVE_TIMEOUT, or <unset>.
. "$1/bin/lib/run-all-classify.sh" || exit 95
if [ "$4" = 1 ]; then export RUN_ALL_TIMEOUT_SECONDS="$3"; else unset RUN_ALL_TIMEOUT_SECONDS; fi
unset RAC_EFFECTIVE_TIMEOUT
rac_effective_timeout "$2" || exit 94
printf '%s' "${RAC_EFFECTIVE_TIMEOUT-<unset>}"
EOF

cat >"$TMPBASE/rae.sh" <<'EOF'
# rae.sh <checkout> <script> <out> <err> [<resultdir>] — run_all_exec of <checkout>; key=value lines.
co="$1" script="$2" out="$3" err="$4" res="${5-}"
unset RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER RUN_ALL_EXEC_STATE RUN_ALL_EXEC_MISSING RUN_ALL_EXEC_LAUNCHED RUN_ALL_EXEC_RC
. "$co/bin/lib/run-all-launch.sh" || exit 95
t0=$SECONDS
if [ -n "$res" ]; then
  run_all_exec "$script" "$out" "$err" "$res"
else
  run_all_exec "$script" "$out" "$err"
fi
rc=$?
printf 'rc=%s\n' "$rc"
printf 'launched=%s\n' "${RUN_ALL_EXEC_LAUNCHED-<unset>}"
printf 'state=%s\n' "${RUN_ALL_EXEC_STATE-<unset>}"
printf 'missing=%s\n' "${RUN_ALL_EXEC_MISSING-}"
printf 'el=%s\n' "$((SECONDS - t0))"
printf 'rd=%s\n' "${RUN_ALL_RESULT_DIR-<unset>}"
printf 'ro=%s\n' "${RUN_ALL_RESULT_OWNER-<unset>}"
printf 'execrc=%s\n' "${RUN_ALL_EXEC_RC-<unset>}"
EOF

cat >"$TMPBASE/fx-table.js" <<'EOF'
// fx-table.js <table.json> <mode> — adds fixture-only entries in front of the real ones.
const fs = require("fs");
const [file, mode] = process.argv.slice(2);
const t = JSON.parse(fs.readFileSync(file, "utf8"));
const base = (id, ext, launch) => ({
  id, status: "supported", patterns: ["*" + ext], selfIdentifying: true,
  nameStrip: { prefix: "", suffix: ext }, siblingSuiteDir: false, header: { commentPrefix: "#" },
  launch: Object.assign({ unit: "file", prepare: null, timeoutSeconds: 60, suiteRootMarker: null }, launch),
  caseMarkerReader: null, tableDrivenDetector: null, helperLibrary: null,
  diagnostics: { nameLabel: ext }, note: "fixture-only entry (#2501)",
});
if (mode === "missing") {
  t.entries.unshift(base("fx-missing", ".fxmiss", { requires: "no-such-tool-2501", command: ["bash", "{path}"] }));
} else if (mode === "wrap") {
  t.entries.unshift(base("fx-wrap", ".fxwrap", {
    requires: "bash",
    command: ["bash", "{wrapper}", "{nativePath}", "{minVersion}"],
    wrapper: "bin/lib/test-wrappers/fx-echo-2501.sh",
    minVersion: { runtime: "fxrt", version: "1.2" },
  }));
  // A suite reaches the same wrapper: {wrapper} is the launcher's file, not a test path.
  t.entries.unshift(base("fx-suitewrap", ".fxsuitewrap", {
    unit: "suite", suiteRootMarker: "fxsuite.marker", requires: "bash",
    command: ["bash", "{wrapper}", "{minVersion}"],
    wrapper: "bin/lib/test-wrappers/fx-echo-2501.sh",
    minVersion: { runtime: "fxrt", version: "1.2" },
  }));
} else if (mode === "exe") {
  // launch.requires is on PATH or not; so is what prepare / command start with.
  const suite = { unit: "suite", suiteRootMarker: "fxsuite.marker", requires: "bash" };
  t.entries.unshift(
    base("fx-nocmd", ".fxnocmd", { requires: "bash", command: ["no-such-cmd-2501", "{path}"] }),
    base("fx-noprep", ".fxnoprep", Object.assign({}, suite, {
      prepare: ["no-such-prep-2501", "prep-arg-2501"], command: ["bash", "-c", "echo suite-cmd-ran-2501"],
    })),
    base("fx-both", ".fxboth", { requires: "no-such-req-2501", command: ["no-such-cmd-2501", "{path}"] }),
    base("fx-suiteok", ".fxsuiteok", Object.assign({}, suite, {
      prepare: ["bash", "-c", "echo suite-prep-ran-2501"], command: ["bash", "-c", "echo suite-cmd-ran-2501"],
    })),
    // An executable that exists only relative to the suite root.
    base("fx-suitelocal", ".fxsuitelocal", Object.assign({}, suite, { command: ["./runner-2501"] })),
    base("fx-suiteslow", ".fxsuiteslow", Object.assign({}, suite, {
      prepare: ["bash", "-c", "sleep 2"], command: ["bash", "-c", "sleep 4; echo suite-slow-cmd-done-2501"],
    })),
    // The same prepare contract on a file unit.
    base("fx-fileprep", ".fxfileprep", {
      requires: "bash", prepare: ["bash", "-c", "echo file-prep-ran-2501 \"$0\"", "{path}"], command: ["bash", "{path}"],
    }),
    base("fx-fileprepfail", ".fxfileprepfail", {
      requires: "bash", prepare: ["bash", "-c", "echo file-prep-failed-2501; exit 7"], command: ["bash", "{path}"],
    }),
    base("fx-fileprep77", ".fxfileprep77", {
      requires: "bash", prepare: ["bash", "-c", "echo file-prep-skipped-2501; exit 77"], command: ["bash", "{path}"],
    }),
    base("fx-suiteprepfail", ".fxsuiteprepfail", Object.assign({}, suite, {
      prepare: ["bash", "-c", "echo suite-prep-failed-2501; exit 7"], command: ["bash", "-c", "echo should-not-run"],
    })),
    base("fx-filenoprep", ".fxfilenoprep", {
      requires: "bash", prepare: ["no-such-prep-2501", "prep-arg-2501"], command: ["bash", "{path}"],
    }),
    base("fx-fileslow", ".fxfileslow", {
      requires: "bash", prepare: ["bash", "-c", "sleep 2"], command: ["bash", "{path}"],
    }),
  );
}
fs.writeFileSync(file, JSON.stringify(t, null, 1));
EOF

# cls <rc> <launched> <resultdir> — "STATE|RC|MISSING" from rac_classify (no elapsed: #2501 D3-1).
cls() {
  run_with_timeout 60 bash "$TMPBASE/cls.sh" "$SCRIPT_CHECKOUT_ROOT" "$@" 2>>"$TMPBASE/cls.err" || printf '<rc=%s>' "$?"
}
# cls_state <rc> <launched> <resultdir> — the STATE field only.
cls_state() {
  local got
  got="$(cls "$@")"
  printf '%s' "${got%%|*}"
}

# eto <entry-timeout> [env] — rac_effective_timeout of the worktree; env is exported only when given.
eto() {
  local set=0
  if [ "$#" -ge 2 ]; then set=1; fi
  run_with_timeout 60 bash "$TMPBASE/eto.sh" "$SCRIPT_CHECKOUT_ROOT" "$1" "${2-}" "$set" \
    2>>"$TMPBASE/eto.err" || printf '<rc=%s>' "$?"
}

# mkcases <dir> "<seq> <STATE> <case>"... — a result dir whose cases.tsv holds those records.
mkcases() {
  local d="$1" r s st c
  shift
  mkdir -p "$d"
  : >"$d/cases.tsv"
  for r in "$@"; do
    read -r s st c <<<"$r"
    printf '%s\t%s\t%s\t%s\n' "$s" "$st" "$c" "bin/lib/run-all-classify.sh" >>"$d/cases.tsv"
  done
}

# fx_co <dir> [missing|wrap|exe] — a minimal agents checkout (bin/lib, run-with-timeout.sh, the
# registry, harness.sh) whose table optionally gains a fixture-only entry. Copies the pattern
# of tests/bin/test-language-registry/_lib.sh fx_checkout.
fx_co() {
  local d="$1" mode="${2:-}"
  mkdir -p "$d/bin" "$d/hooks/lib" "$d/tests/lib" "$d/tests/bin"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$d/bin/lib"
  cp "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$d/bin/run-with-timeout.sh"
  install_test_language_registry "$d" "$SCRIPT_CHECKOUT_ROOT" || return 1
  cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh" "$d/tests/lib/harness.sh"
  if [ -f "$SCRIPT_CHECKOUT_ROOT/tests/lib/xfail.sh" ]; then cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/xfail.sh" "$d/tests/lib/xfail.sh"; fi
  if [ "$mode" = wrap ]; then
    mkdir -p "$d/bin/lib/test-wrappers"
    cat >"$d/bin/lib/test-wrappers/fx-echo-2501.sh" <<'EOF'
# Fixture wrapper: prints its argv and the result-dir env it received.
printf 'wrapper=%s\n' "$0"
i=0
for a in "$@"; do
  i=$((i + 1))
  printf 'arg%s=%s\n' "$i" "$a"
done
printf 'argc=%s\n' "$#"
printf 'rdir=%s\n' "${RUN_ALL_RESULT_DIR-<unset>}"
printf 'rowner=%s\n' "${RUN_ALL_RESULT_OWNER-<unset>}"
EOF
  fi
  if [ -n "$mode" ]; then
    node "$(np "$TMPBASE/fx-table.js")" "$(np "$d/hooks/lib/test-language-registry.json")" "$mode" || return 1
  fi
  harness_git_init "$d"
}

# rae <tag> <checkout> <script> [resultdir] — run_all_exec; key=value lines in $TMPBASE/rae-<tag>.kv,
# the child's stdout in $TMPBASE/rae-<tag>.out.
rae() {
  local tag="$1"
  shift
  run_with_timeout 90 bash "$TMPBASE/rae.sh" "$1" "$2" "$TMPBASE/rae-$tag.out" "$TMPBASE/rae-$tag.err" "${3-}" \
    >"$TMPBASE/rae-$tag.kv" 2>"$TMPBASE/rae-$tag.err2" || true
}

# kv <key> <file> — the value of the first <key>= line, or <absent>.
kv() {
  local line
  if [ -f "$2" ]; then
    while IFS= read -r line; do
      case "$line" in "$1="*) printf '%s' "${line#"$1="}"; return 0 ;; esac
    done <"$2"
  fi
  printf '<absent>'
}

# rae_sum <tag> — "rc=N state=S" of an rae run.
rae_sum() {
  printf 'rc=%s state=%s' "$(kv rc "$TMPBASE/rae-$1.kv")" "$(kv state "$TMPBASE/rae-$1.kv")"
}

# rae_full <tag> — rae_sum plus the RUN_ALL_EXEC_RC and RUN_ALL_EXEC_LAUNCHED the caller was left with.
rae_full() {
  printf '%s execrc=%s launched=%s' "$(rae_sum "$1")" "$(kv execrc "$TMPBASE/rae-$1.kv")" "$(kv launched "$TMPBASE/rae-$1.kv")"
}

# res_of <cases.tsv> — "seq=STATE:case " per seq in first-seen order, the last line of a seq winning.
res_of() {
  if [ ! -f "$1" ]; then
    printf '<no cases.tsv>'
    return 0
  fi
  awk -F'\t' '{ if (!($1 in st)) ord[++n] = $1; st[$1] = $2; nm[$1] = $3 } END { for (i = 1; i <= n; i++) printf "%s=%s:%s ", ord[i], st[ord[i]], nm[ord[i]] }' "$1"
}

# file_text <file> — its lines joined by spaces, or <absent>.
file_text() { if [ -f "$1" ]; then tr '\n' ' ' <"$1"; else printf '<absent>'; fi; }
