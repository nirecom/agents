#!/usr/bin/env bash
# Tests: hooks/lib/commit-targets.js, hooks/lib/commit-detect.js
# Tags: workflow, gate, hook, commit-detect, table-driven, scope:issue-specific
# fix-1633 (TL1): enumerateCommitTargets decides, per commit, which repo the
# commit lands in (explicit dir / the payload default / ambiguous). The gate's
# cross-repo bypass trusts only explicit and default targets, so every shape the
# enumerator cannot pin down must come back ambiguous. isWipCommitText and
# allCommitsAreWip judge WIP per commit, so a later non-WIP commit cannot ride a
# leading WIP commit. The commit-detect cases pin the existing contract.
# No TL3 gap block: pure in-process module logic, no Windows-only or claude -p surface (rules/test.md).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"

AGENTS_NODE="$(np "$SCRIPT_CHECKOUT_ROOT")"
HELPER="$TMP_ROOT/commit-targets-helper.js"

# One table per group. Each row prints "OK <name>" or "NG <name> <detail>".
# A missing module turns every row of the group into NG (the expected TDD red).
cat >"$HELPER" <<'JS'
"use strict";
const [agents, group] = process.argv.slice(2);
const rows = [];
function load(rel) {
  try { return require(agents + "/" + rel); } catch (e) { return { __loadError: String(e.message).split("\n")[0] }; }
}
function show(t) {
  if (!t || !t.target) return "malformed";
  const k = t.target.kind;
  if (k === "explicit") return "explicit:" + t.target.dir;
  if (k === "ambiguous") return "ambiguous:" + (t.target.reason || "");
  return k;
}
// want: comma list; "ambiguous" alone accepts any reason, "none" means 0 targets.
function matches(got, want) {
  const w = want === "none" ? [] : want.split(",");
  if (got.length !== w.length) return false;
  return w.every((x, i) => (x === "ambiguous" ? got[i].startsWith("ambiguous:") : got[i] === x));
}
const ct = load("hooks/lib/commit-targets");
if (group === "enum") {
  const table = [
    ["dash-c-absolute", ["git -C /a commit -m x"], "explicit:/a"],
    ["plain-commit-default", ["git commit -m x"], "default"],
    ["cd-and-commit", ["cd /a && git commit -m x"], "explicit:/a"],
    ["cd-semicolon-commit", ["cd /a; git commit -m x"], "explicit:/a"],
    ["cd-or-commit", ["cd /a || git commit -m x"], "ambiguous"],
    ["cd-pipe-commit", ["cd /a | git commit -m x"], "ambiguous"],
    ["subshell-cd-commit", ["(cd /a && git commit -m x)"], "ambiguous"],
    ["cd-relative", ["cd rel && git commit -m x"], "ambiguous"],
    ["cd-variable", ["cd $X && git commit -m x"], "ambiguous"],
    ["cd-tilde", ["cd ~/a && git commit -m x"], "ambiguous"],
    ["pushd-commit", ["pushd /a && git commit -m x"], "ambiguous"],
    ["double-dash-c", ["git -C /a -C /b commit -m x"], "ambiguous"],
    ["git-dir-flag", ["git --git-dir=/x commit -m x"], "ambiguous"],
    ["git-dir-env-prefix", ["GIT_DIR=/x git commit -m x"], "ambiguous"],
    ["dash-c-quoted-home-var", ["git -C '$HOME' commit -m x"], "ambiguous"],
    ["dash-c-relative", ["git -C rel commit -m x"], "ambiguous"],
    ["two-explicit-commits", ["git -C /a commit -m x; git -C /b commit -m y"], "explicit:/a,explicit:/b"],
    ["status-is-not-commit", ["git -C /a status && git commit -m x"], "default"],
    ["dash-c-overrides-cd", ["cd /a && git -C /b commit -m x"], "explicit:/b"],
    ["multiline-cd-then-commit", ["cd /a\ngit commit -m x"], "explicit:/a"],
    ["multiline-status-then-commit", ["git -C /o status\ngit commit -m x"], "default"],
    ["array-status-then-commit", ["git -C /o status", "git commit -m x"], "default"],
    ["array-cross-element-cd", ["cd /a", "git commit -m x"], "ambiguous:cross-element-cd"],
    ["array-cross-element-cd-with-dash-c", ["cd /a", "git -C /b commit -m x"], "explicit:/b"],
    ["rtk-wrapper", ["rtk git -C /a commit -m x"], "explicit:/a"],
    ["env-wrapper", ["env FOO=1 git -C /a commit -m x"], "explicit:/a"],
    ["bash-c-inline-body", ["bash -c 'cd /a && git commit -m x'"], "explicit:/a"],
    ["heredoc-body-is-not-commit", ["cat <<'EOF'\ngit commit -m x\nEOF"], "none"],
    ["echo-text-is-not-commit", ['echo "git commit"'], "none"],
    ["non-commit-git", ["git status"], "none"],
    ["windows-drive-path", ["git -C C:/a commit -m x"], "explicit:C:/a"],
    ["posix-drive-path", ["git -C /c/a commit -m x"], "explicit:/c/a"],
    ["dash-c-single-quoted-space", ["git -C '/a b' commit -m x"], "explicit:/a b"],
    ["dash-c-double-quoted-space", ['git -C "/a b" commit -m x'], "explicit:/a b"],
    ["cd-single-quoted-space", ["cd '/a b' && git commit -m x"], "explicit:/a b"],
    ["cd-double-quoted-space", ['cd "/a b" && git commit -m x'], "explicit:/a b"],
    // Attached -C forms are not a separate path token, so they never prove a target.
    ["attached-c-slash", ["git -C/x commit -m a"], "ambiguous:attached-C"],
    ["attached-c-quoted", ['git -C"/x" commit -m a'], "ambiguous:attached-C"],
    ["attached-c-equals", ["git -C=/x commit -m a"], "ambiguous:attached-C"],
    ["separate-c-contrast", ["git -C /x commit -m a"], "explicit:/x"],
    // A value-taking flag (-c k=v) consumes its value, so a later -C still names the target.
    ["dash-lower-c-then-dash-c", ["git -c user.name=x -C /a commit -m x"], "explicit:/a"],
    ["dash-lower-c-default", ["git -c user.name=x commit -m x"], "default"],
    // eval / PowerShell / shell-without--c bodies are not walked: commit text there is unprovable.
    ["eval-commit", ['eval "git commit -m y"'], "ambiguous:wrapped-commit"],
    ["eval-mixed-with-foreign", ['git -C /foreign commit -m x; eval "git commit -m y"'], "explicit:/foreign,ambiguous:wrapped-commit"],
    ["eval-echo-not-commit", ["eval echo hi"], "none"],
    ["pwsh-command-commit", ['pwsh -Command "git commit -m x"'], "ambiguous:wrapped-commit"],
    ["powershell-command-commit", ['powershell -Command "git -C /a commit -m x"'], "ambiguous:wrapped-commit"],
    ["bash-without-c-commit", ['bash -s "git commit -m x"'], "ambiguous:wrapped-commit"],
    ["bash-c-recursion-contrast", ["bash -c 'cd /a && git commit -m x'"], "explicit:/a"],
    ["sh-c-recursion-contrast", ["sh -c 'git -C /b commit -m x'"], "explicit:/b"],
    // A cd behind && / || may or may not run, so the following commit's cwd is unknown.
    ["and-conditional-cd", ["false && cd /foreign; git commit -m x"], "ambiguous:conditional-cd"],
    ["or-conditional-cd", ["true || cd /foreign; git commit -m x"], "ambiguous:conditional-cd"],
    ["unconditional-cd-contrast", ["cd /a && git commit -m x"], "explicit:/a"],
    // A commit inside $( ) / backticks runs in a repo the outer -C does not govern.
    ["dollar-paren-substituted-commit", ['git -C /foreign commit -m "$(git -C /work commit -m inner)"'], "explicit:/foreign,ambiguous:substituted-commit"],
    ["backtick-substituted-commit", ['git -C /foreign commit -m "`git -C /work commit -m inner`"'], "explicit:/foreign,ambiguous:substituted-commit"],
    ["substitution-without-commit-contrast", ['git -C /foreign commit -m "$(date)"'], "explicit:/foreign"],
    // GIT_DIR / GIT_WORK_TREE set earlier in the shell override any later -C.
    ["exported-git-env", ["export GIT_DIR=/work/.git GIT_WORK_TREE=/work; git -C /foreign commit -m x"], "ambiguous:exported-git-env"],
    ["bare-assigned-git-env", ["GIT_DIR=/w/.git; git -C /f commit -m x"], "ambiguous:exported-git-env"],
    ["exported-unrelated-env-contrast", ["export FOO=1; git -C /foreign commit -m x"], "explicit:/foreign"],
    // Shell compound syntax at command position + commit text: the whole line is unprovable.
    ["compound-if-mixed", ["git -C /foreign commit -m x; if true; then git -C /work commit -m y; fi"], "ambiguous:compound-shell"],
    ["compound-brace-group", ["{ git -C /w commit -m y; }"], "ambiguous:compound-shell"],
    ["compound-for", ["for i in 1; do git commit -m y; done"], "ambiguous:compound-shell"],
    ["compound-while", ["while false; do git commit; done"], "ambiguous:compound-shell"],
    ["compound-until", ["until true; do git -C /w commit -m y; done"], "ambiguous:compound-shell"],
    ["compound-subshell", ["(git -C /w commit -m y)"], "ambiguous:compound-shell"],
    ["compound-case", ["case x in x) git -C /w commit -m y;; esac"], "ambiguous:compound-shell"],
    ["compound-select", ["select a in b; do git -C /w commit -m y; done"], "ambiguous:compound-shell"],
    ["compound-function-keyword", ["function f { git -C /w commit -m y; }; f"], "ambiguous:compound-shell"],
    ["compound-name-paren-function", ["f() { git -C /w commit -m y; }; f"], "ambiguous:compound-shell"],
    ["compound-double-bracket", ["[[ -d /w ]] && git -C /w commit -m y"], "ambiguous:compound-shell"],
    ["compound-coproc", ["coproc git -C /w commit -m y"], "ambiguous:compound-shell"],
    ["quoted-reserved-words-contrast", ['git -C /foreign commit -m "if done fi"'], "explicit:/foreign"],
    ["compound-without-commit-contrast", ["if true; then echo hi; fi"], "none"],
    // A segment whose own text looks like a commit but is not enumerated as one is unprovable.
    ["xargs-sh-c-unenumerated", ["git -C /f commit -m a; printf x | xargs -n1 sh -c 'git -C /w commit -m b'"], "explicit:/f,ambiguous:unenumerated-commit"],
    ["find-exec-unenumerated", ["find . -exec git -C /w commit -m b \\;"], "ambiguous:unenumerated-commit"],
    ["env-prefixed-commit", ["env git -C /w commit -m b"], "explicit:/w"],
    ["nohup-prefixed-commit", ["nohup git commit -m b"], "default"],
    ["timeout-prefixed-commit", ["timeout 5 git commit -m b"], "ambiguous:unenumerated-commit"],
    ["commit-words-in-message-contrast", ['git -C /f commit -m "fix git commit typo"'], "explicit:/f"],
    // --work-tree / --git-dir flags make the target ambiguous regardless of -C.
    ["work-tree-flag-attached", ["git --work-tree=/x commit -m x"], "ambiguous:git-dir-flag"],
    ["work-tree-flag-separated", ["git --work-tree /x commit -m x"], "ambiguous:git-dir-flag"],
    // GIT_WORK_TREE as an inline env prefix is the same reason as GIT_DIR.
    ["git-work-tree-env-prefix", ["GIT_WORK_TREE=/x git commit -m x"], "ambiguous:git-env-redirect"],
    // export in a prior element propagates gitEnv across the element boundary.
    ["cross-element-exported-git-env", ["export GIT_DIR=/w/.git", "git -C /f commit -m x"], "ambiguous:exported-git-env"],
    // A heredoc spans multiple logical lines; an explicit -C target survives the join.
    ["heredoc-with-dash-c-explicit", ["git -C /a commit -F - <<EOF\nmsg\nEOF"], "explicit:/a"],
  ];
  for (const [name, list, want] of table) {
    if (ct.__loadError) { rows.push("NG " + name + " module-missing:" + ct.__loadError); continue; }
    try {
      const got = ct.enumerateCommitTargets(list).map(show);
      rows.push((matches(got, want) ? "OK " : "NG ") + name + " want=" + want + " got=" + (got.join(",") || "none"));
    } catch (e) { rows.push("NG " + name + " threw:" + e.message); }
  }
  // inline-body-limit: a bash -c chain 4 levels deep triggers MAX_DEPTH=3 on the innermost body.
  if (!ct.__loadError) {
    try {
      const l1 = "git commit -m depth";
      const l2 = "bash -c '" + l1 + "'";
      const l3 = "bash -c \"" + l2 + "\"";
      const esc = (s) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
      const l4 = 'bash -c "' + esc(l3) + '"';
      const l5 = 'bash -c "' + esc(l4) + '"';
      const r = ct.enumerateCommitTargets([l5]);
      const ok = r.length === 1 && r[0].target.kind === "ambiguous" && r[0].target.reason === "inline-body-limit";
      rows.push((ok ? "OK " : "NG ") + "inline-body-limit-depth got=" + JSON.stringify(r));
    } catch (e) { rows.push("NG inline-body-limit-depth threw:" + e.message); }
  }
  // Parse failure: one ambiguous target whose commitText is null (WIP can never ride it).
  if (ct.__loadError) rows.push("NG parse-failure-null-text module-missing:" + ct.__loadError);
  else {
    try {
      const r = ct.enumerateCommitTargets(['git commit -m "unterminated']);
      const ok = r.length === 1 && r[0].target.kind === "ambiguous" && r[0].target.reason === "parse-failure" && r[0].commitText === null;
      rows.push((ok ? "OK " : "NG ") + "parse-failure-null-text got=" + JSON.stringify(r));
    } catch (e) { rows.push("NG parse-failure-null-text threw:" + e.message); }
    // A wrapped commit carries no commitText, so a WIP flag inside eval cannot exempt it.
    try {
      const r = ct.enumerateCommitTargets(['eval "git -c workflow.wip=1 commit -m y"']);
      const ok = r.length === 1 && r[0].target.reason === "wrapped-commit" && r[0].commitText === null &&
        ct.allCommitsAreWip(r) === false;
      rows.push((ok ? "OK " : "NG ") + "wrapped-commit-null-text got=" + JSON.stringify(r));
    } catch (e) { rows.push("NG wrapped-commit-null-text threw:" + e.message); }
    try {
      const r = ct.enumerateCommitTargets(["if true; then git -c workflow.wip=1 commit -m y; fi"]);
      const ok = r.length === 1 && r[0].target.reason === "compound-shell" && r[0].commitText === null &&
        ct.allCommitsAreWip(r) === false;
      rows.push((ok ? "OK " : "NG ") + "compound-shell-null-text got=" + JSON.stringify(r));
    } catch (e) { rows.push("NG compound-shell-null-text threw:" + e.message); }
  }
} else if (group === "commit-text") {
  const cases = [
    ["later-element-wip-text", ["git -C /o status", "git -c workflow.wip=1 commit -m x"],
      (r) => r.length === 1 && typeof r[0].commitText === "string" && r[0].commitText.includes("workflow.wip=1")],
    ["per-commit-text-split", ["git -c workflow.wip=1 commit -m a; git commit -m b"],
      (r) => r.length === 2 && String(r[0].commitText).includes("workflow.wip=1") &&
        typeof r[1].commitText === "string" && !r[1].commitText.includes("workflow.wip")],
    ["multiline-later-line-wip-text", ["git -C /o status\ngit -c workflow.wip=1 commit -m x"],
      (r) => r.length === 1 && String(r[0].commitText).includes("workflow.wip=1")],
  ];
  for (const [name, list, pred] of cases) {
    if (ct.__loadError) { rows.push("NG " + name + " module-missing:" + ct.__loadError); continue; }
    try {
      const r = ct.enumerateCommitTargets(list);
      rows.push((pred(r) ? "OK " : "NG ") + name + " got=" + JSON.stringify(r));
    } catch (e) { rows.push("NG " + name + " threw:" + e.message); }
  }
} else if (group === "wip-text") {
  const table = [
    ["wip-1", "git -c workflow.wip=1 commit -m x", true],
    ["wip-true-uppercase", "git -c workflow.wip=TRUE commit -m x", true],
    ["wip-0", "git -c workflow.wip=0 commit -m x", false],
    ["no-wip", "git commit -m x", false],
    ["null-text", null, false],
  ];
  for (const [name, text, want] of table) {
    if (ct.__loadError) { rows.push("NG " + name + " module-missing:" + ct.__loadError); continue; }
    try {
      const got = ct.isWipCommitText(text);
      rows.push((got === want ? "OK " : "NG ") + name + " want=" + want + " got=" + got);
    } catch (e) { rows.push("NG " + name + " threw:" + e.message); }
  }
} else if (group === "all-wip") {
  const W = { target: { kind: "default" }, commitText: "git -c workflow.wip=1 commit -m x" };
  const N = { target: { kind: "default" }, commitText: "git commit -m x" };
  const P = { target: { kind: "ambiguous", reason: "parse-failure" }, commitText: null };
  const table = [
    ["all-wip-true", [W, W], true],
    ["one-non-wip-false", [W, N], false],
    ["null-text-false", [W, P], false],
    ["empty-false", [], false],
  ];
  for (const [name, arr, want] of table) {
    if (ct.__loadError) { rows.push("NG " + name + " module-missing:" + ct.__loadError); continue; }
    try {
      const got = ct.allCommitsAreWip(arr);
      rows.push((got === want ? "OK " : "NG ") + name + " want=" + want + " got=" + got);
    } catch (e) { rows.push("NG " + name + " threw:" + e.message); }
  }
} else if (group === "detect") {
  const cd = load("hooks/lib/commit-detect");
  const { parse } = require(agents + "/hooks/lib/command-ir");
  const table = [
    ["rtk-commit-detected", () => cd.isCommitCommand(parse("rtk git commit -m x")), true],
    ["echo-text-not-commit", () => cd.isCommitCommand(parse('echo "git commit"')), false],
    ["heredoc-body-not-commit", () => cd.isCommitCommand(parse("cat <<'EOF'\ngit commit -m x\nEOF")), false],
    ["segment-text-keeps-wip", () => cd.extractCommitSegmentText(parse("git -c workflow.wip=1 commit -m x")), "git -c workflow.wip=1 commit -m x"],
    ["segment-text-skips-status", () => cd.extractCommitSegmentText(parse("git -C /a status && git commit -m x")), "git commit -m x"],
    ["parse-failure-raw-text", () => cd.extractCommitSegmentText(parse('git commit -m "unterminated')), 'git commit -m "unterminated'],
    ["is-commit-argv-exported", () => typeof cd.isCommitArgv, "function"],
    ["is-commit-argv-with-dash-c", () => cd.isCommitArgv && cd.isCommitArgv(["-C", "/a", "commit", "-m", "x"]), true],
    ["is-commit-argv-status", () => cd.isCommitArgv && cd.isCommitArgv(["status"]), false],
  ];
  for (const [name, fn, want] of table) {
    try {
      const got = fn();
      rows.push((got === want ? "OK " : "NG ") + name + " want=" + JSON.stringify(want) + " got=" + JSON.stringify(got));
    } catch (e) { rows.push("NG " + name + " threw:" + e.message); }
  }
} else {
  rows.push("NG unknown-group " + group);
}
process.stdout.write(rows.join("\n") + "\n");
JS

# run_group <group> — map each helper row onto the harness counters.
run_group() {
  local group="$1" out verdict name rest
  if ! out="$(run_with_timeout 60 node "$(np "$HELPER")" "$AGENTS_NODE" "$group" 2>&1)"; then
    fail "$group: helper exited non-zero" "$out"
    return 0
  fi
  [ -n "$out" ] || { fail "$group: helper printed nothing"; return 0; }
  while IFS=' ' read -r verdict name rest; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" = "OK" ]; then pass "$group/$name"; else fail "$group/$name" "$rest"; fi
  done <<<"$out"
}

echo "=== fix-1633: commit targets ==="

case_begin "enumerate-commit-targets-table" "hooks/lib/commit-targets.js"
run_group enum
case_end

case_begin "commit-text-per-commit" "hooks/lib/commit-targets.js"
run_group commit-text
case_end

case_begin "is-wip-commit-text" "hooks/lib/commit-targets.js"
run_group wip-text
case_end

case_begin "all-commits-are-wip" "hooks/lib/commit-targets.js"
run_group all-wip
case_end

case_begin "commit-detect-contract-regression" "hooks/lib/commit-detect.js"
run_group detect
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
