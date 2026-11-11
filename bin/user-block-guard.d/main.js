"use strict";
// lang-check: ignore -- deny messages are user-facing Japanese text pinned by tests.
// bin/user-block-guard — judges one GitHub issue write against its `<user>` blocks (#2940).
// --op create|edit|comment-create|comment-edit|comment-delete|issue-delete
// target (at most one): --issue N [--repo O/R] | --node-id ID | --comment-id DBID --repo O/R
//   | --issue N --last-own-comment [--create-if-none]; create takes none, comment-create no fetch.
// title: --new-title T | --title-unreadable; body: --new-body-file PATH|- | --body-unreadable
// (absent = unchanged). --deadline-ms MS (default 8000) bounds every gh read.
// Exit 0 allow / 1 deny / 2 ask / 3 usage; callers treat anything but 0 and 2 as deny.
// stdout: exactly one `user-block-guard: <reason>` line. Any failed read of the old state denies.

const fs = require("node:fs");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");
const { judge } = require("./judge");
const { FetchError, fetchIssueByNumber, fetchNode, fetchRestComment } = require("./fetch");

const OPS = new Set(["create", "edit", "comment-create", "comment-edit", "comment-delete", "issue-delete"]);
const VALUE_FLAGS = {
  "--op": "op", "--issue": "issue", "--repo": "repo", "--node-id": "nodeId", "--comment-id": "commentId",
  "--new-title": "title", "--new-body-file": "bodyFile", "--deadline-ms": "deadlineMs",
};
const BOOL_FLAGS = {
  "--last-own-comment": "lastOwn", "--create-if-none": "createIfNone",
  "--title-unreadable": "titleUnreadable", "--body-unreadable": "bodyUnreadable",
};
const EXIT = { allow: 0, deny: 1, ask: 2 };
const NUM_RE = /^[1-9][0-9]*$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

class UsageError extends Error {}

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const key = VALUE_FLAGS[a] || BOOL_FLAGS[a];
    if (!key) throw new UsageError(`未知の引数: ${a}`);
    if (key in o) throw new UsageError(`${a} が重複している`);
    if (BOOL_FLAGS[a]) { o[key] = true; continue; }
    if (i + 1 >= argv.length) throw new UsageError(`${a} に値がない`);
    o[key] = argv[++i];
  }
  return o;
}

function need(cond, msg) { if (!cond) throw new UsageError(msg); }

function validate(o) {
  need(OPS.has(o.op), `--op が不正: ${o.op === undefined ? "(なし)" : o.op}`);
  need(o.issue === undefined || NUM_RE.test(o.issue), "--issue は正の整数");
  need(o.commentId === undefined || NUM_RE.test(o.commentId), "--comment-id は正の整数");
  need(o.repo === undefined || REPO_RE.test(o.repo), "--repo は OWNER/REPO");
  need(o.deadlineMs === undefined || NUM_RE.test(o.deadlineMs), "--deadline-ms は正の整数");
  need(!(o.title !== undefined && o.titleUnreadable), "--new-title と --title-unreadable は同時に使えない");
  need(!(o.bodyFile !== undefined && o.bodyUnreadable), "--new-body-file と --body-unreadable は同時に使えない");
  const targets = ["issue", "nodeId", "commentId"].filter((k) => o[k] !== undefined);
  need(targets.length <= 1, "対象は --issue / --node-id / --comment-id のどれか 1 つ");
  need(!o.lastOwn || o.issue !== undefined, "--last-own-comment には --issue が要る");
  need(!o.createIfNone || o.lastOwn, "--create-if-none には --last-own-comment が要る");
  need(o.commentId === undefined || o.repo !== undefined, "--comment-id には --repo が要る");
  need(!(o.title !== undefined || o.titleUnreadable) || o.op === "create" || o.op === "edit", "title は create / edit だけ");
  const byIssueOrNode = (o.issue !== undefined && !o.lastOwn) || o.nodeId !== undefined;
  const commentTarget = o.commentId !== undefined || o.nodeId !== undefined || o.lastOwn;
  const ok = {
    create: targets.length === 0 && !o.lastOwn,
    "comment-create": o.commentId === undefined && !o.lastOwn,
    edit: byIssueOrNode,
    "issue-delete": byIssueOrNode,
    "comment-edit": commentTarget,
    "comment-delete": commentTarget,
  }[o.op];
  need(ok, `--op ${o.op} に合う対象の指定がない`);
}

function readNext(o) {
  const next = {};
  if (o.title !== undefined) next.title = o.title;
  if (o.titleUnreadable) next.titleUnreadable = true;
  if (o.bodyUnreadable) next.bodyUnreadable = true;
  if (o.bodyFile !== undefined) {
    try {
      next.body = fs.readFileSync(o.bodyFile === "-" ? 0 : toWindowsPath(o.bodyFile), "utf8");
    } catch (e) {
      throw new UsageError(`--new-body-file を読めない: ${e.code || e.message}`);
    }
  }
  return next;
}

const deny = (reason) => ({ verdict: "deny", reason });
const changesSomething = (n) => n.title !== undefined || n.titleUnreadable || n.body !== undefined || n.bodyUnreadable;

function issueOf(o, withComments, deadlineAt) {
  if (o.nodeId === undefined) return fetchIssueByNumber({ repo: o.repo, number: o.issue, withComments, deadlineAt });
  const r = fetchNode({ id: o.nodeId, withComments, deadlineAt });
  return r.type === "Issue" ? r.issue : null;
}

function decideComment(o, next, deadlineAt) {
  let old;
  if (o.commentId !== undefined) {
    old = fetchRestComment({ repo: o.repo, commentId: o.commentId, deadlineAt });
  } else if (o.nodeId !== undefined) {
    const r = fetchNode({ id: o.nodeId, withComments: false, deadlineAt });
    if (r.type !== "IssueComment") return deny("--node-id が IssueComment ではない");
    old = r.comment;
  } else {
    const issue = fetchIssueByNumber({ repo: o.repo, number: o.issue, withComments: true, deadlineAt });
    const own = issue.comments.filter((c) => c.viewerDidAuthor === true).pop();
    if (!own) {
      if (o.createIfNone && o.op === "comment-edit") return judge({ op: "comment-create", old: null, next });
      return { verdict: "allow", reason: "自分の comment がない(gh 自身が失敗する)" };
    }
    old = { body: own.body };
  }
  return judge({ op: o.op, old, next });
}

function decide(o, next, deadlineAt) {
  switch (o.op) {
    case "create":
    case "comment-create":
      return judge({ op: o.op, old: null, next });
    case "edit": {
      if (!changesSomething(next)) return { verdict: "allow", reason: "title も本文も変わらない" };
      const withComments = next.title !== undefined || next.titleUnreadable === true;
      const old = issueOf(o, withComments, deadlineAt);
      return old ? judge({ op: "edit", old, next }) : deny("--node-id が Issue ではない");
    }
    case "issue-delete": {
      const old = issueOf(o, true, deadlineAt);
      return old ? judge({ op: "issue-delete", old, next }) : deny("--node-id が Issue ではない");
    }
    default:
      return decideComment(o, next, deadlineAt);
  }
}

function run(argv) {
  const started = Date.now();
  try {
    const o = parseArgs(argv);
    validate(o);
    const next = readNext(o);
    const deadlineAt = started + Number(o.deadlineMs || 8000);
    const r = decide(o, next, deadlineAt);
    return { code: EXIT[r.verdict], reason: r.reason };
  } catch (e) {
    if (e instanceof UsageError) return { code: 3, reason: `使い方の誤り: ${e.message}` };
    if (e instanceof FetchError) return { code: 1, reason: `旧状態を取得できないので拒否する (fail-closed): ${e.message}` };
    return { code: 1, reason: `内部エラーなので拒否する (fail-closed): ${e && e.message}` };
  }
}

function cli() {
  const { code, reason } = run(process.argv.slice(2));
  process.stdout.write(`user-block-guard: ${String(reason).replace(/\s*[\r\n]+\s*/g, " ")}\n`);
  process.exitCode = code;
}

module.exports = { cli, run };
