"use strict";
// lang-check: ignore -- deny messages are user-facing Japanese text pinned by tests.
// Old-state reads over `gh api` (GraphQL, REST for a numeric comment id). Every failure throws;
// the caller turns a throw into deny (fail-closed).

const { spawnSync } = require("node:child_process");

const COMMENTS = "comments(first:100, after:$cursor){pageInfo{hasNextPage endCursor} nodes{id databaseId body viewerDidAuthor}}";
const issueFields = (withComments) => `id title body${withComments ? ` ${COMMENTS}` : ""}`;
// GraphQL rejects a declared-but-unused variable, so $cursor is declared only when COMMENTS uses it.
const cursorDecl = (withComments) => (withComments ? ",$cursor:String" : "");

class FetchError extends Error {}

function gh(args, deadlineAt) {
  const remaining = deadlineAt - Date.now();
  if (remaining <= 0) throw new FetchError("deadline を超えた");
  const r = spawnSync("gh", args, {
    env: { ...process.env, MSYS_NO_PATHCONV: "1" },
    encoding: "utf8",
    timeout: remaining,
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  if (r.error) throw new FetchError(r.error.code === "ETIMEDOUT" ? "deadline を超えた" : `gh を起動できない (${r.error.code || r.error.message})`);
  if (r.status !== 0) {
    const err = String(r.stderr || "").trim().split("\n")[0];
    throw new FetchError(`gh が rc=${r.status} で失敗した${err ? ` (${err})` : ""}`);
  }
  try { return JSON.parse(r.stdout); } catch { throw new FetchError("gh の出力が JSON ではない"); }
}

function repoFields(repo) {
  if (!repo) return ["-F", "owner={owner}", "-F", "name={repo}"];
  const [owner, name] = repo.split("/");
  return ["-f", `owner=${owner}`, "-f", `name=${name}`];
}

function graphql(query, fields, deadlineAt, cursor) {
  const args = ["api", "graphql", ...fields, "-f", `query=${query}`];
  if (cursor) args.push("-f", `cursor=${cursor}`);
  const data = gh(args, deadlineAt);
  if (!data || typeof data !== "object" || !data.data) throw new FetchError("GraphQL の応答に data がない");
  return data.data;
}

// Follows hasNextPage; fetchPage(cursor) returns the issue (or node) object of the next reply.
function collectComments(first, fetchPage) {
  const comments = [...first.comments.nodes];
  let info = first.comments.pageInfo || {};
  while (info.hasNextPage) {
    if (!info.endCursor) throw new FetchError("次の comment page の cursor がない");
    const page = fetchPage(info.endCursor);
    if (!page || !page.comments || !Array.isArray(page.comments.nodes)) throw new FetchError("comment page を読めない");
    comments.push(...page.comments.nodes);
    info = page.comments.pageInfo || {};
  }
  return comments;
}

function toIssue(obj, withComments, fetchPage) {
  if (!obj || typeof obj.body !== "string" || typeof obj.title !== "string") throw new FetchError("issue を取得できない");
  const issue = { title: obj.title, body: obj.body, comments: [] };
  if (withComments) {
    if (!obj.comments || !Array.isArray(obj.comments.nodes)) throw new FetchError("comment を取得できない");
    issue.comments = collectComments(obj, fetchPage);
  }
  return issue;
}

function fetchIssueByNumber({ repo, number, withComments, deadlineAt }) {
  const query = `query($owner:String!,$name:String!,$number:Int!${cursorDecl(withComments)}){repository(owner:$owner,name:$name){issue(number:$number){${issueFields(withComments)}}}}`;
  const fields = [...repoFields(repo), "-F", `number=${number}`];
  const pick = (d) => (d.repository ? d.repository.issue : null);
  const first = pick(graphql(query, fields, deadlineAt));
  return toIssue(first, withComments, (cursor) => pick(graphql(query, fields, deadlineAt, cursor)));
}

// -> { type: "Issue", issue } | { type: "IssueComment", comment: { body } }
function fetchNode({ id, withComments, deadlineAt }) {
  const query = `query($id:ID!${cursorDecl(withComments)}){node(id:$id){__typename ... on Issue{${issueFields(withComments)}} ... on IssueComment{id databaseId body}}}`;
  const fields = ["-f", `id=${id}`];
  const first = graphql(query, fields, deadlineAt).node;
  if (!first) throw new FetchError("node を取得できない");
  if (first.__typename === "IssueComment") {
    if (typeof first.body !== "string") throw new FetchError("comment を取得できない");
    return { type: "IssueComment", comment: { body: first.body } };
  }
  if (first.__typename !== "Issue") throw new FetchError(`node の型が Issue / IssueComment ではない (${first.__typename})`);
  const issue = toIssue(first, withComments, (cursor) => graphql(query, fields, deadlineAt, cursor).node);
  return { type: "Issue", issue };
}

function fetchRestComment({ repo, commentId, deadlineAt }) {
  const data = gh(["api", `repos/${repo}/issues/comments/${commentId}`], deadlineAt);
  if (!data || typeof data.body !== "string") throw new FetchError("comment を取得できない");
  return { body: data.body };
}

module.exports = { FetchError, fetchIssueByNumber, fetchNode, fetchRestComment };
