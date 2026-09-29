#!/usr/bin/env bash
# tests/hooks/feature-2403-readonly-classes.sh
# Tests: hooks/lib/readonly-command-classes.js, hooks/lib/readonly-syntax-adapters.js, hooks/lib/bash-write-patterns/git-read-ir.js, hooks/lib/bash-write-patterns/gh-read.js, hooks/lib/gh-api-argv.js, hooks/bash-guard/readonly-class.js, install/readonly-command-classes.json, hooks/confirm-forge-target-ownership/gh-api-argv.js
# Tags: hook, bash-guard, readonly-allow, classifier, fail-closed, git, gh, security, scope:issue-specific, pwsh-not-required, TL2
# #2403 unit layer for the N3/N4/N5 read-only allow classes; judge-level rows live in
# tests/hooks/feature-2403-readonly-judge.sh.

# TL3 gap: this TL2 run calls the classifier modules in-process, so it cannot catch whether
# Claude Code actually invokes hooks/bash-guard.js on a real Bash tool call, how settings.json
# and the host permission layer interact with the resulting allow, or real transcript behavior.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

# Every predicate here is an ALLOW decision, so each is fail-closed: a missing data file, a
# malformed entry, an unknown flag or an ambiguous gh api scan must answer "not read-only".
# Each section is one node process printing `name<TAB>want<TAB>got` rows; ro_section asserts
# every row and the exact row count, so a crashed or truncated section cannot report green.

RO_AGENTS="$(np "$AGENTS_DIR")"
RO_T="$(np "$T")"
export RO_AGENTS RO_T

check() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then pass "$name"; else fail "$name" "want=[$want] got=[$got]"; fi
}

RO_PRELUDE='
const A = process.env.RO_AGENTS, T = process.env.RO_T;
const out = [];
const row = (n, w, g) => out.push([n, String(w), String(g)].join("\t"));
const load = (p) => { try { return require(A + "/" + p); } catch (e) { return null; } };
const call = (m, mp, fn, ...a) => {
  if (!m || typeof m[fn] !== "function") return "<MISSING:" + mp + "#" + fn + ">";
  try { return m[fn](...a); } catch (e) { return "<THREW:" + e.message + ">"; }
};
const J = (v) => JSON.stringify(v);
process.on("exit", () => process.stdout.write(out.join("\n") + "\n"));
'

# ro_section <label> <expected-row-count> <js-body>
ro_section() {
    local label="$1" want_n="$2" body="$3" out line name rest want got n=0
    out="$(run_with_timeout 60 node -e "$RO_PRELUDE$body" 2>&1)" || true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            *$'\t'*$'\t'*) ;;
            *) fail "$label: unparsed output line" "$line"; continue ;;
        esac
        name="${line%%$'\t'*}"; rest="${line#*$'\t'}"
        want="${rest%%$'\t'*}"; got="${rest#*$'\t'}"
        n=$((n + 1))
        check "$label/$name" "$want" "$got"
    done <<< "$out"
    check "$label: executed row count" "$want_n" "$n"
}

# Fixture roots for the loader: each carries install/readonly-command-classes.json (or not).
mkroot() { mkdir -p "$T/$1/install"; printf '%s' "$2" > "$T/$1/install/readonly-command-classes.json"; }
mkdir -p "$T/root-missing"
mkroot root-badjson '{"version":1, "generic": {'
mkroot root-array '[]'
mkroot root-wrongtypes '{"version":1,"delegate":"git","generic":5}'
mkroot root-mixed '{"version":1,"delegate":{"git":"git-pure-read","gh":"gh-read","svn":"svn-read","hg":5},"generic":{"ls":{"syntax":"getopt"},"find":{"syntax":"find"},"tree":{"syntax":"getopt","denyFlags":["-o"]},"weird":{"syntax":"regex"},"nosyntax":{},"nullentry":null,"strflags":{"syntax":"getopt","denyFlags":"-C"},"bareflag":{"syntax":"getopt","denyFlags":["C"]}}}'
mkroot root-noversion '{"delegate":{"git":"git-pure-read"},"generic":{"ls":{"syntax":"getopt"}}}'
mkroot root-v2 '{"version":2,"delegate":{"git":"git-pure-read"},"generic":{"ls":{"syntax":"getopt"}}}'
mkroot root-vstr '{"version":"1","delegate":{"git":"git-pure-read"},"generic":{"ls":{"syntax":"getopt"}}}'
mkroot root-emptyobj '{}'
# Unreadable: the data path exists but is a directory, so the read itself throws.
mkdir -p "$T/root-unreadable/install/readonly-command-classes.json"
mkroot root-ghonly '{"version":1,"delegate":{"gh":"gh-read"},"generic":{}}'
mkroot root-lsonly '{"version":1,"delegate":{},"generic":{"ls":{"syntax":"getopt"}}}'

RO_REAL='const REAL = "ag,cat,command,df,du,file,find,grep,head,ls,pwd,rg,stat,tail,tree,type,uname,wc,which";'
# The 32 PURE_READ_SUBCOMMANDS (SSOT pin: fix-enforce-worktree-rtk-fail-open.sh RS_PURE).
RO_PURE='const PURE = "annotate,blame,cat-file,check-attr,check-ignore,check-ref-format,cherry,count-objects,describe,diff,diff-files,diff-index,diff-tree,for-each-ref,grep,log,ls-files,ls-tree,merge-base,name-rev,range-diff,rev-list,rev-parse,shortlog,show,show-branch,show-ref,status,var,verify-pack,version,whatchanged";
// A minimal, valid argv tail per generic entry (command needs -v; find needs a start path).
const GEN_ARGS = { command: "-v node", find: ". -name x", pwd: "", uname: "-a", df: "-h", which: "node", type: "node" };'

case_begin "loader-fail-closed" "hooks/lib/readonly-command-classes.js"
ro_section LOADER 14 "$RO_REAL"'
const L = load("hooks/lib/readonly-command-classes.js");
const keys = (m) => (m instanceof Map ? [...m.keys()].sort().join(",") : "<NOT-MAP>");
const shape = (root) => {
  const r = call(L, "hooks/lib/readonly-command-classes.js", "loadReadOnlyClasses", root);
  if (typeof r === "string") return r;
  return r ? "d=" + keys(r.delegate) + ";g=" + keys(r.generic) : "<NULL>";
};
row("L1 missing data file -> both maps empty", "d=;g=", shape(T + "/root-missing"));
row("L2 malformed JSON -> both maps empty", "d=;g=", shape(T + "/root-badjson"));
row("L3 top-level array -> both maps empty", "d=;g=", shape(T + "/root-array"));
row("L4 non-object delegate/generic -> both maps empty", "d=;g=", shape(T + "/root-wrongtypes"));
row("L4b missing version -> both maps empty", "d=;g=", shape(T + "/root-noversion"));
row("L4c version 2 -> both maps empty", "d=;g=", shape(T + "/root-v2"));
row("L4d version \"1\" (string) -> both maps empty", "d=;g=", shape(T + "/root-vstr"));
row("L4e empty object -> both maps empty", "d=;g=", shape(T + "/root-emptyobj"));
row("L4f unreadable data path -> both maps empty", "d=;g=", shape(T + "/root-unreadable"));
row("L5 invalid entries and unknown delegates dropped, valid kept", "d=gh,git;g=find,ls,tree", shape(T + "/root-mixed"));
const a = call(L, "L", "loadReadOnlyClasses", T + "/root-mixed");
const b = call(L, "L", "loadReadOnlyClasses", T + "/root-mixed");
row("L6 same root is served from the cache", "true", typeof a === "string" ? a : a === b);
row("L7 cache is per root", "d=gh;g=", shape(T + "/root-ghonly"));
row("L8 default root carries the shipped class list", "d=gh,git;g=" + REAL, shape(undefined));
row("L9 a non-string root falls back to the default", "d=gh,git;g=" + REAL, shape(null));
'
case_end

case_begin "data-file-contents" "install/readonly-command-classes.json"
ro_section DATA 10 "$RO_REAL"'
let D = null;
try { D = JSON.parse(require("fs").readFileSync(A + "/install/readonly-command-classes.json", "utf8")); } catch (e) { D = null; }
const M = "<MISSING:install/readonly-command-classes.json>";
const G = (D && D.generic) || {};
const f = (n, k) => (D ? (G[n] && Array.isArray(G[n][k]) ? [...G[n][k]].sort().join(",") : "<none>") : M);
row("D1 version", "1", D ? D.version : M);
row("D2 delegate registry keys", J({ gh: "gh-read", git: "git-pure-read" }), D ? J(Object.fromEntries(Object.entries(D.delegate || {}).sort())) : M);
row("D3 generic names (less deliberately excluded)", REAL, D ? Object.keys(G).sort().join(",") : M);
row("D4 file denyFlags", "--compile,--no-sandbox,--preserve-date,--uncompress,--uncompress-noreport,-C,-S,-Z,-m,-p,-z", f("file", "denyFlags"));
row("D5 tree denyFlags", "-R,-o", f("tree", "denyFlags"));
row("D6 rg denyFlags", "--hostname-bin,--pre,--search-zip,-z", f("rg", "denyFlags"));
row("D7 ag denyFlags", "--pager", f("ag", "denyFlags"));
row("D8 command requireLeading", "-V,-v", f("command", "requireLeading"));
row("D9 find uses the find syntax, every other entry getopt",
    "", D ? Object.keys(G).filter((n) => G[n].syntax !== (n === "find" ? "find" : "getopt")).join(",") : M);
const plain = ["ls", "cat", "head", "tail", "wc", "stat", "pwd", "uname", "which", "type", "du", "grep"];
row("D10 plain entries carry no deny flags", "", D ? plain.filter((n) => !G[n] || (G[n].denyFlags || []).length).join(",") : M);
'
case_end

case_begin "syntax-adapters" "hooks/lib/readonly-syntax-adapters.js"
ro_section ADAPT 31 '
const S = load("hooks/lib/readonly-syntax-adapters.js"), SP = "hooks/lib/readonly-syntax-adapters.js";
const FILE = { syntax: "getopt", denyFlags: ["-C", "--compile"] };
const RG = { syntax: "getopt", denyFlags: ["--pre", "--hostname-bin"] };
const TREE = { syntax: "getopt", denyFlags: ["-o"] };
const CMD = { syntax: "getopt", requireLeading: ["-v", "-V"] };
const PLAIN = { syntax: "getopt" };
for (const [n, e, args, want] of [
  ["plain flags", PLAIN, ["-la", "/tmp"], true], ["no args", PLAIN, [], true],
  ["long deny exact", FILE, ["--compile", "x"], false], ["long deny abbreviation", FILE, ["--comp", "x"], false],
  ["long deny shortest abbreviation", FILE, ["--c", "x"], false], ["long deny = form", FILE, ["--compile=x"], false],
  ["long deny abbreviation = form", FILE, ["--comp=x"], false], ["short deny alone", FILE, ["-C", "x"], false],
  ["short deny inside a cluster", FILE, ["-zC", "x"], false], ["cluster without a deny letter", FILE, ["-zb", "x"], true],
  ["deny flag after -- is an operand", FILE, ["--", "-C"], true], ["longer name than any deny flag", RG, ["--pretty", "foo"], true],
  ["rg --pre", RG, ["--pre", "x", "foo"], false], ["rg --hostname-bin= form", RG, ["--hostname-bin=x", "foo"], false],
  ["tree -o in a cluster", TREE, ["-ao", "out"], false], ["tree -L", TREE, ["-L", "2"], true],
  ["requireLeading met (-v)", CMD, ["-v", "node"], true], ["requireLeading met (-V)", CMD, ["-V", "node"], true],
  ["requireLeading unmet", CMD, ["ls"], false], ["requireLeading with no args", CMD, [], false],
]) row("getopt " + n + " " + J(args), want, call(S, SP, "getopt", args, e));
row("find plain predicates", true, call(S, SP, "find", [".", "-name", "*.js"]));
row("find -type/-newer", true, call(S, SP, "find", [".", "-type", "f", "-newer", "x"]));
for (const tok of ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fls", "-fprint", "-fprint0", "-fprintf"])
  row("find rejects " + tok, false, call(S, SP, "find", [".", "-name", "x", tok, "y"]));
'
case_end

case_begin "git-pure-read" "hooks/lib/bash-write-patterns/git-read-ir.js"
ro_section GIT 181 '
const R = load("hooks/lib/bash-write-patterns/git-read-ir.js"), RP = "git-read-ir.js";
const W = load("hooks/lib/bash-write-patterns/git-write-ir.js");
const POS = [
  ["status"], ["-C", "/x", "status"], ["--git-dir=/x/.git", "log"], ["--git-dir", "/x/.git", "log"],
  ["--work-tree=/x", "status"], ["--no-pager", "diff"], ["-P", "log"], ["--no-optional-locks", "status"],
  ["--literal-pathspecs", "log"], ["--no-replace-objects", "log"], ["diff", "--no-textconv"], ["diff", "--no-ext-diff"],
  ["diff", "-O", "order.txt"], ["diff", "--no-index", "a", "b"], ["log", "--format=%h %s"], ["log", "--", "--output=f"],
  ["branch"], ["branch", "-a"], ["branch", "--list", "feat*"], ["branch", "--contains", "HEAD"], ["tag"], ["tag", "-l", "v*"],
  ["remote"], ["remote", "-v"], ["remote", "--verbose"], ["remote", "get-url", "origin"], ["remote", "show"],
  ["remote", "show", "-n", "origin"], ["stash", "list"], ["stash", "show"], ["worktree", "list"],
  ["worktree", "list", "--porcelain"], ["rev-parse", "--git-path", "x"], ["var", "GIT_EDITOR"],
  ["--glob-pathspecs", "log"], ["--noglob-pathspecs", "log"], ["--icase-pathspecs", "log"],
  ["worktree", "list", "--verbose"], ["branch", "--merged", "HEAD"],
  // tag -n: the spaced form (TAG_LIST_FLAGS) and the attached -n<num> form (TAG_N_NUM_RE).
  ["tag", "-n", "5"], ["tag", "-n", "0"], ["tag", "-l", "-n5"], ["tag", "-n5", "-l", "v*"], ["tag", "-l", "-n1", "v*"],
  // Every GLOBAL_VALUE_FLAGS / BRANCH_READ_FLAGS / BRANCH_LIST_FLAGS / TAG_READ_FLAGS /
  // TAG_LIST_FLAGS / WORKTREE_LIST_FLAGS member not exercised above.
  ["--work-tree", "/x", "status"], ["branch", "-r"], ["branch", "-v"], ["branch", "-vv"], ["branch", "--show-current"],
  ["branch", "-l"], ["branch", "--no-merged", "HEAD"], ["branch", "--points-at", "HEAD"],
  ["branch", "-l", "--format=%(refname:short)"], ["branch", "--format", "%(refname)", "--list"],
  ["tag", "--list", "v*"], ["tag", "--contains", "HEAD"], ["tag", "--merged", "HEAD"], ["tag", "--no-merged", "HEAD"],
  ["tag", "--points-at", "HEAD"], ["tag", "--sort=-creatordate", "-l"], ["tag", "--sort=-creatordate"],
  ["tag", "--sort", "refname", "-l"], ["tag", "--format=%(refname)", "-l", "v*"], ["tag", "--format", "%(refname)", "-l"],
  ["tag", "-n"], ["worktree", "list", "-v"], ["worktree", "list", "-z"], ["worktree", "list", "--porcelain", "-z"],
  ["remote", "show", "-n"],
  // -h prints usage only; --help after -- is a pathspec; --histogram is no prefix of --help.
  ["log", "-h"], ["status", "-h"], ["log", "--", "--help"], ["diff", "--histogram"],
];
const NEG = [
  [], ["-c", "a=b", "log"], ["--config-env=a=B", "log"], ["--exec-path=/x", "status"], ["-p", "log"], ["--paginate", "log"],
  ["--bare", "log"], ["--namespace=x", "log"], ["commit", "-m", "x"], ["fetch"], ["difftool"], ["help", "log"],
  ["archive", "HEAD"], ["ls-remote", "origin"], ["merge-tree", "a", "b"], ["verify-commit", "HEAD"], ["verify-tag", "v1"],
  ["config", "--get", "a"], ["config", "--list"], ["notes", "list"], ["reflog"], ["symbolic-ref", "HEAD"],
  ["hash-object", "f"], ["frobnicate"], ["branch", "newb"], ["branch", "--delete", "-r", "x"], ["branch", "-d", "x"],
  ["branch", "--cont", "HEAD"], ["tag", "v2"], ["tag", "-d", "v1"], ["tag", "--sort=x", "--delete", "v1"],
  ["tag", "-v", "v1"], ["tag", "--verify", "v1"], ["remote", "show", "origin"], ["remote", "-v", "add", "a", "b"],
  ["remote", "add", "a", "b"], ["remote", "set-url", "a", "b"], ["stash"], ["stash", "drop"], ["stash", "pop"],
  ["worktree", "remove", "x"], ["worktree", "add", "x"], ["worktree", "list", "--expire", "x"],
  ["diff", "--text"], ["rev-list", "--filter=blob:none", "HEAD"],
  // Fail-closed today: git-write-ir sees no TAG_READ_FLAGS token in a lone -n<num>, so calls it a write.
  ["tag", "-n5"], ["tag", "-n1", "v*"],
  // Globals: a short value flag with =, a value flag with no value, no subcommand, a bool with =.
  ["-C=/x", "status"], ["--git-dir"], ["-C", "/x"], ["--no-pager=1", "log"],
  // The SIDE_EFFECT_READ_SUBCOMMANDS not listed above.
  ["instaweb"], ["gui"], ["gitk"],
  // git-write-ir matches BRANCH_READ_FLAGS by exact token, so their = forms read as a write.
  ["branch", "--format=%(refname)"], ["branch", "--merged=HEAD"],
  // An operand with no list flag is a create/pattern form; a spaced --sort value is an operand
  // (or, when it starts with -, an unknown flag).
  ["branch", "--show-current", "x"], ["branch", "-r", "x"], ["tag", "--sort", "refname"],
  ["tag", "--sort", "-creatordate", "-l"], ["tag", "--sort=-creatordate", "v1"],
  // worktree list takes only whole WORKTREE_LIST_FLAGS tokens; remote get-url takes one bare name.
  ["worktree", "list", "--porcelain", "x"], ["worktree", "list", "-vz"],
  ["remote", "get-url", "--push", "origin"], ["remote", "get-url"],
];
// EXEC_CAPABLE_OPTIONS: full, unique-prefix and = forms of every option that launches a program.
const EXEC = [
  ["diff", "--ext-diff"], ["diff", "--ext-d"], ["diff", "--ext-diff=x"],
  ["show", "--textconv"], ["show", "--textc"], ["show", "--textconv=x"], ["blame", "--textconv", "f"],
  ["cat-file", "--filters", "HEAD:f"], ["cat-file", "--filt", "HEAD:f"], ["cat-file", "--filters=x"],
  ["log", "--output", "f"], ["log", "--outp", "f"], ["log", "--output=f"],
  ["grep", "-O", "x"], ["grep", "-Oless", "x"], ["grep", "--open-files-in-pager", "x"], ["grep", "--open", "x"],
  ["grep", "--open-files-in-pager=less", "x"],
  ["log", "--show-signature"], ["log", "--show-sig"], ["log", "--show-signature=x"],
  ["log", "--format=%G?"], ["log", "--pretty=format:%GS"], ["show", "--format=%GK"], ["log", "--format", "%GG"],
  ["for-each-ref", "--format=%(signature)"],
  ["tag", "-l", "--format=%(signature)"], ["branch", "-l", "--format=%GS"], ["stash", "list", "--format=%GS"],
  ["grep", "-nO", "x"],
  // --help dispatches to `git help <cmd>` (may open a browser); unique prefixes count too.
  // branch/tag/remote/worktree --help were already rejected by isConditionalRead; stash list was not.
  ["log", "--help"], ["status", "--help"], ["diff", "--hel"], ["show", "--he"], ["log", "--h"],
  ["branch", "--help"], ["tag", "--help"], ["worktree", "list", "--help"], ["remote", "--help"],
  ["stash", "list", "--help"],
  // Fail-closed: git rewrites only a leading exact --help, but any spelling is rejected.
  ["log", "--help=x"], ["log", "--oneline", "--help"],
];
for (const a of POS) row("pure-read " + J(a), true, call(R, RP, "isGitPureReadArgv", a));
for (const a of NEG) row("not pure-read " + J(a), false, call(R, RP, "isGitPureReadArgv", a));
for (const a of EXEC) row("exec-capable " + J(a), false, call(R, RP, "isGitPureReadArgv", a));
row("invariant: no positive is a git write", "", W ? POS.filter((a) => W.isGitWriteArgv(a)).map(J).join(" ") : "<MISSING:git-write-ir>");
'
case_end

case_begin "gh-read" "hooks/lib/bash-write-patterns/gh-read.js"
ro_section GH 153 '
const R = load("hooks/lib/bash-write-patterns/gh-read.js"), RP = "gh-read.js";
const P = load("hooks/lib/bash-write-patterns/patterns.js");
const POS = [
  ["pr", "view", "12"], ["pr", "list"], ["pr", "status"], ["pr", "diff", "1"], ["pr", "checks", "1"],
  ["issue", "list"], ["issue", "view", "1"], ["issue", "status"], ["repo", "view"], ["run", "list"], ["run", "view", "1"],
  ["release", "list"], ["release", "view", "v1"], ["label", "list"],
  ["-R", "o/r", "pr", "view", "1"], ["--repo", "o/r", "issue", "list"], ["--repo=o/r", "issue", "list"],
  ["pr", "view", "1", "-R", "o/r"], ["pr", "view", "1", "--repo=o/r"],
  ["api", "repos/o/r/issues"], ["api", "repos/o/r/pulls", "--jq", ".[].number"], ["api", "-X", "GET", "x"],
  ["api", "--paginate", "x"], ["api", "-H", "Accept: application/json", "x"],
  // API_READ_METHOD_RE (forge-write-extract.js) treats GET and HEAD as reads, in every spelling.
  ["api", "--method", "GET", "repos/o/r/issues"], ["api", "--method=GET", "repos/o/r/issues"],
  ["api", "-X", "HEAD", "repos/o/r/issues"],
  // repo view selector boundary: a host-less OWNER/REPO (one slash) stays a read, at any position;
  // a one-slash flag value is not host-qualified; the 2+-slash screen is scoped to repo view only.
  ["repo", "view", "owner/repo"], ["-R", "o/r", "repo", "view"], ["repo", "view", "-R", "o/r"],
  ["repo", "view", "-b", "feature/x"], ["repo", "view", "o/r", "-b", "main"],
  ["pr", "view", "feature/x"], ["pr", "view", "a/b/c"], ["issue", "view", "12"],
  // A short bool flag with no R in its letter run stays a read (SHORT_REPO_CLUSTER_RE boundary).
  ["pr", "view", "1", "-c"],
  // Lowercase r is not R: the cluster check is case-sensitive (-cr is no real gh flag; boundary only).
  ["pr", "view", "1", "-cr"],
];
const NEG = [
  [], ["pr", "create"], ["pr", "checkout", "1"], ["pr", "merge", "1"], ["issue", "close", "1"], ["issue", "create"],
  ["auth", "status"], ["auth", "token"], ["release", "download"], ["repo", "clone", "o/r"], ["label", "create", "x"],
  ["workflow", "run", "x"], ["pr", "view", "1", "-w"], ["pr", "view", "1", "--web"], ["pr", "view", "1", "-cw"],
  ["pr", "view", "1", "-w=true"],
  // --hostname at every position and spelling (codex C2): pre, post, = form; api and pr view.
  ["--hostname", "h", "api", "x"], ["--hostname=h", "api", "x"], ["api", "--hostname", "h", "x"], ["api", "x", "--hostname=h"],
  ["--hostname", "h", "pr", "view", "1"], ["--hostname=h", "pr", "view", "1"],
  ["pr", "view", "1", "--hostname", "h"], ["pr", "view", "1", "--hostname=h"],
  // -R / --repo value shape: exactly OWNER/REPO, before or after; none before api.
  ["-R", "h/o/r", "pr", "view", "1"], ["pr", "view", "1", "-R", "h/o/r"], ["--repo=h/o/r", "pr", "view", "1"],
  ["pr", "view", "1", "--repo", "h/o/r"], ["-R", "o", "pr", "view", "1"], ["-R", "o/r", "api", "x"],
  ["--repo", "o/r", "api", "x"], ["--unknown", "pr", "view", "1"],
  // Attached -R<value> is refused at any position, host-less value included: the spelling itself.
  // ["-Ro/r", ...] is refused by skipGlobals (pre-subcommand), not by repoValuesOk.
  ["pr", "view", "1", "-Rh.example/o/r"], ["-Ro/r", "issue", "list"], ["issue", "list", "-Ro/r"],
  // Clustered -R: pflag splits -cR<value> into -c + -R <value>, so any letter run holding R is
  // refused, attached or spaced value, host-less value included.
  ["pr", "view", "1", "-cRh.example/o/r"], ["pr", "view", "1", "-cR", "h.example/o/r"], ["run", "view", "1", "-vRo/r"],
  ["-cR", "o/r", "pr", "list"], ["issue", "list", "-cRo/r"],
  ["pr", "view", "1", "-cvRo/r"], ["pr", "view", "1", "-cR", "o/r"],
  ["api", "-X", "POST", "x"], ["api", "--method", "DELETE", "x"], ["api", "x", "-f", "a=b"], ["api", "x", "-F", "a=b"],
  ["api", "x", "--field", "a=b"], ["api", "x", "--raw-field", "a=b"], ["api", "x", "--input", "f"],
  ["api", "-H", "X-HTTP-Method-Override: DELETE", "x"], ["api", "--header", "x-http-method-override: PATCH", "x"],
  ["api", "--unknown", "x"], ["api"],
  // Method spellings gh accepts: attached, = form, long with a space, every non-GET verb.
  ["api", "-XPOST", "x"], ["api", "-X=POST", "x"], ["api", "--method=POST", "x"], ["api", "--method", "POST", "x"],
  ["api", "-X", "PATCH", "x"], ["api", "-X", "DELETE", "x"], ["api", "-X", "PUT", "x"],
  // An explicit GET does not excuse a payload: gh sends the body regardless.
  ["api", "-X", "GET", "x", "-f", "a=b"], ["api", "-X", "GET", "x", "-F", "a=b"],
  ["api", "-X", "GET", "x", "--field", "a=b"], ["api", "-X", "GET", "x", "--raw-field", "a=b"],
  ["api", "-X", "GET", "x", "--input", "f"],
  // Attached and = spellings of payload / override flags are the same write (C1).
  ["api", "x", "-fa=b"], ["api", "x", "-Fa=b"], ["api", "x", "--field=a=b"], ["api", "x", "--raw-field=a=b"],
  ["api", "x", "--input=f"], ["api", "-HX-HTTP-Method-Override: DELETE", "x"],
  ["api", "--header=X-HTTP-Method-Override: DELETE", "x"],
  ["api", "--cache", "1h", "repos/o/r"],
  ["api", "https://attacker.invalid/path"],
  ["pr", "view", "https://attacker.invalid/o/r/pull/1"],
  // repo view [HOST/]OWNER/REPO: any 2+-slash token after `repo view` names a foreign host, even
  // behind a valid -R; flag values are refused too (fail-closed), in spaced and = spellings.
  ["repo", "view", "attacker.invalid/o/r"], ["repo", "view", "github.com/o/r"], ["repo", "view", "o/r/extra"],
  ["-R", "o/r", "repo", "view", "h/o/r"], ["repo", "view", "h/o/r", "-R", "o/r"], ["repo", "view", "a//b"],
  ["repo", "view", "-b", "a/b/c"], ["repo", "view", "--branch=a/b/c"],
];
// Method matrix: every spelling scanGhApiFlags accepts x GET/HEAD (API_READ_METHOD_RE is /i) is a
// read, and x every write verb is not; a spelling already listed above is not repeated.
const SPELL = [(m) => ["-X", m], (m) => ["-X" + m], (m) => ["--method", m], (m) => ["--method=" + m]];
const seen = new Set([...POS, ...NEG].map((a) => J(a.slice(0, -1))));
const add = (list, a) => { const k = J(a.slice(0, -1)); if (!seen.has(k)) { seen.add(k); list.push(a); } };
for (const m of ["GET", "HEAD", "get", "head"]) for (const s of SPELL) add(POS, ["api", ...s(m), "x"]);
for (const m of ["POST", "PUT", "PATCH", "DELETE", "post"])
  for (const s of [...SPELL, (v) => ["-X=" + v]]) add(NEG, ["api", ...s(m), "x"]);
// -X=GET: pflag would read GET, but the scan keeps "=GET" as the method, so it fails closed.
for (const m of ["GET", "HEAD", "get", "head"]) add(NEG, ["api", "-X=" + m, "x"]);
for (const a of POS) row("gh read " + J(a), true, call(R, RP, "isGhReadArgv", a, a));
for (const a of NEG) row("not gh read " + J(a), false, call(R, RP, "isGhReadArgv", a, a));
row("invariant: no positive is a gh write", "", P ? POS.filter((a) => P.isGhWriteArgv(a)).map(J).join(" ") : "<MISSING:patterns>");
'
case_end

case_begin "gh-api-argv-lib" "hooks/lib/gh-api-argv.js"
ro_section GHAPI 8 '
const L = load("hooks/lib/gh-api-argv.js");
const LP = "hooks/lib/gh-api-argv.js";
row("G1 lib exports scanGhApiFlags / hasInputFlag / PAYLOAD_FIELD_FLAGS",
    "function,function,true", L ? [typeof L.scanGhApiFlags, typeof L.hasInputFlag, L.PAYLOAD_FIELD_FLAGS instanceof Set].join(",") : "<MISSING:" + LP + ">");
row("G5 PAYLOAD_FIELD_FLAGS unchanged", "--field,--raw-field,-F,-f", L && L.PAYLOAD_FIELD_FLAGS instanceof Set ? [...L.PAYLOAD_FIELD_FLAGS].sort().join(",") : "<MISSING>");
const s = call(L, LP, "scanGhApiFlags", ["-X", "POST", "x"]);
row("G6 scan: -X POST x", J({ flags: [["-X", "POST"]], endpoint: "x", ambiguous: false }),
    typeof s === "string" ? s : J({ flags: s.flags.map((f) => [f.flag, f.value]), endpoint: s.endpoint, ambiguous: s.ambiguous }));
const u = call(L, LP, "scanGhApiFlags", ["--unknown", "x"]);
row("G7 scan: unknown flag is ambiguous", "true", typeof u === "string" ? u : u.ambiguous);
const i = call(L, LP, "scanGhApiFlags", ["x", "--input", "f"]);
row("G8 hasInputFlag sees --input", "true", typeof i === "string" ? i : call(L, LP, "hasInputFlag", i.flags));
const fl = (a) => { const r = call(L, LP, "scanGhApiFlags", a); return typeof r === "string" ? r : J(r.flags.map((f) => [f.flag, f.value])); };
row("G10 scan: attached -XPOST is a method flag", J([["-X", "POST"]]), fl(["-XPOST", "x"]));
row("G11 scan: --method=POST is a method flag", J([["--method", "POST"]]), fl(["--method=POST", "x"]));
row("G12 scan: payload flag after an explicit GET is still recorded", J([["-X", "GET"], ["-f", "a=b"]]), fl(["-X", "GET", "x", "-f", "a=b"]));
'
case_end

case_begin "gh-api-argv-confirm-forge-shim" "hooks/confirm-forge-target-ownership/gh-api-argv.js"
ro_section GHAPI-SHIM 4 '
const L = load("hooks/lib/gh-api-argv.js"), C = load("hooks/confirm-forge-target-ownership/gh-api-argv.js");
row("G2 the old module re-exports the same objects (one SSOT)", "true,true,true",
    L && C ? [C.scanGhApiFlags === L.scanGhApiFlags, C.hasInputFlag === L.hasInputFlag, C.PAYLOAD_FIELD_FLAGS === L.PAYLOAD_FIELD_FLAGS].join(",") : "<MISSING>");
row("G3 the old module keeps isGhApiWriteArgv", "function", C ? typeof C.isGhApiWriteArgv : "<MISSING>");
let src = ""; try { src = require("fs").readFileSync(A + "/hooks/confirm-forge-target-ownership/gh-api-argv.js", "utf8"); } catch (e) {}
row("G4 the old module still references isGhApiWriteFromFlags", "true", src.includes("isGhApiWriteFromFlags"));
row("G9 isGhApiWriteArgv verdicts unchanged", "true,false", C ? [C.isGhApiWriteArgv(["-X", "POST", "x"]), C.isGhApiWriteArgv(["x"])].join(",") : "<MISSING>");
'
case_end

case_begin "readonly-class-segment" "hooks/bash-guard/readonly-class.js"
ro_section CLASS 120 "$RO_REAL$RO_PURE"'
const RC = load("hooks/bash-guard/readonly-class.js"), RCP = "readonly-class.js";
const AL = load("hooks/bash-guard/allow.js");
const { parse } = require(A + "/hooks/lib/command-ir");
const seg = (c) => (parse(c).segments || [])[0];
const cls = (c, root) => String(call(RC, RCP, "classifyReadOnlySegment", seg(c), root ? { root: T + "/" + root } : undefined));
const whole = (c, root) => String(call(RC, RCP, "matchReadOnlyCommand", parse(c), { cwd: null }, root ? { root: T + "/" + root } : undefined));
const GEN = "BG-ALLOW-READONLY-GENERIC", GIT = "BG-ALLOW-READONLY-GIT", GH = "BG-ALLOW-READONLY-GH";
for (const [c, want] of [
  ["ls -la", GEN], ["cat .env.example", GEN], ["git status", GIT], ["gh pr view 1", GH], ["make build", "null"],
  ["/usr/bin/ls", "null"], ["./ls", "null"], ["ls.exe", "null"], ["command ls", "null"], ["git.exe status", "null"],
  ["/usr/bin/git status", "null"], ["cat .env", "null"], ["grep x .env.local", "null"], ["cat ~/.ssh/id_rsa", "null"],
  ["git add .", "null"], ["gh pr create", "null"],
  // Segment scope only (#2404 contract): the caller owns compound/newline judgement.
  ["git status && rm -rf x", GIT],
  // Nested dotenv / credential paths: the sensitive-path check reads every operand, at any depth.
  ["cat config/.env", "null"], ["grep x config/.env.production", "null"],
  ["cat $HOME/.ssh/id_rsa", "null"], ["tail sub/dir/.env.local", "null"],
  // Git revision-qualified and pathspec-magic operands must not bypass sensitive-path check (C6/C8).
  // Magic pathspec is quoted (\x27 = single quote): unquoted parens split the command into 3 segments.
  ["git show HEAD:.env", "null"], ["git show \x27:(top).env\x27", "null"], ["git grep secret \x27:(top).env\x27", "null"],
  // TEXT_FLAGS bypass: -m consumes .env as flag value in checkBashCommand; direct-token check must catch it.
  ["git log -p -m .env", "null"],
  // Attached short option bypass: -f.env / -f/path — attached value must also be screened (C27).
  ["grep -f.env secret haystack", "null"], ["grep -f/home/user/.ssh/id_rsa pattern f", "null"],
  // Absolute home paths name the same credentials as ~/ and $HOME, so they must be screened alike.
  ["cat /home/user/.ssh/id_rsa", "null"], ["head C:/Users/u/.ssh/id_rsa", "null"],
  ["tail /Users/u/.aws/credentials", "null"], ["grep key /root/.ssh/id_ed25519", "null"],
  // Any spelling that still names a credential directory is screened, whatever root precedes it.
  ["cat /c//Users/u/.ssh/id_rsa", "null"], ["cat /c/Windows/../Users/u/.ssh/id_rsa", "null"],
  ["cat /home//u/.aws/credentials", "null"], ["cat ~u/.ssh/id_rsa", "null"],
  ["cat ../../../../Users/u/.ssh/id_rsa", "null"], ["git diff --no-index /c//Users/u/.ssh/id_rsa /dev/null", "null"],
  ["wc --files0-from=/c/Users/u/.ssh/id_rsa", "null"], ["grep --file=/mnt/c/Users/u/.ssh/id_rsa x", "null"],
  ["cat \x27\\\\?\\C:\\Users\\u\\.ssh\\id_rsa\x27", "null"],
  // Bundled short options: the attached value may start after any option letter.
  ["file -bf.env", "null"], ["file -bf~/.ssh/id_rsa", "null"], ["grep -hf.env x", "null"], ["git grep -hf.env x", "null"],
  // Over-block control: a non-credential absolute path stays read-only.
  ["cat /home/user/notes.txt", GEN], ["cat src/sshutil.js", GEN], ["grep -hi x f", GEN],
  // file -m reads a magic-file path (C18); that path must be screened like any other operand.
  ["file -m .env f", "null"],
  // file -S/-z enables external decompressor execution (C20); -p writes atime metadata (C21).
  ["file -S archive.gz", "null"], ["file -z archive.gz", "null"], ["file -p f", "null"],
  // tree -R recursive deny (C22); rg -z decompressor exec (C23); df --sync global writeback (C24).
  ["tree -R .", "null"], ["rg -z pattern", "null"], ["df --sync /", "null"],
]) row("segment [" + c + "]", want, cls(c));
// C2: every shipped N3 entry and every PURE_READ subcommand classifies positively.
for (const n of REAL.split(",")) {
  const c = (n + " " + (n in GEN_ARGS ? GEN_ARGS[n] : "f")).trim();
  row("generic entry [" + c + "]", GEN, cls(c));
}
for (const s of PURE.split(",")) row("pure-read subcommand [git " + s + "]", GIT, cls("git " + s));
row("segment null never throws", "null", String(call(RC, RCP, "classifyReadOnlySegment", null)));
row("segment {cmd0: 5} never throws", "null", String(call(RC, RCP, "classifyReadOnlySegment", { cmd0: 5 })));
for (const [c, want] of [
  ["ls -la", GEN], ["git status && ls", "null"], ["ls > f", "null"], ["ls 2>&1", "null"], ["ls \"unterminated", "null"],
]) row("command [" + c + "]", want, whole(c));
// Fail-closed on broken or partial data: a class absent from the data never allows.
for (const [c, root, want] of [
  ["ls -la", "root-missing", "null"], ["git status", "root-missing", "null"], ["ls -la", "root-badjson", "null"],
  ["ls -la", "root-lsonly", GEN], ["cat f", "root-lsonly", "null"], ["git status", "root-lsonly", "null"],
  ["gh pr view 1", "root-ghonly", GH], ["git status", "root-ghonly", "null"],
]) row("root " + root + " [" + c + "]", want, cls(c, root));
'
case_end

case_begin "is-plain-single-command-export" "hooks/bash-guard/readonly-class.js"
ro_section PLAIN 3 '
const AL = load("hooks/bash-guard/allow.js");
const { parse } = require(A + "/hooks/lib/command-ir");
const f = AL && AL.isPlainSingleCommand;
row("P1 allow.js exports isPlainSingleCommand", "function", typeof f);
row("P2 a plain command returns its segment", "ls", typeof f === "function" ? (f(parse("ls -la")) || {}).cmd0 : "<MISSING>");
row("P3 a pipeline returns null", "null", typeof f === "function" ? String(f(parse("ls | head"))) : "<MISSING>");
'
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
