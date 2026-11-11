"use strict";
// lang-check: ignore -- deny messages are user-facing Japanese text pinned by tests.
// judge({ op, old, next }) -> { verdict: "allow"|"deny"|"ask", reason } per the #2940 op table.
//   old  = { title, body, comments: [{ body }] }; comment ops: { body } of the comment
//   next = { title?, titleUnreadable?, body?, bodyUnreadable? } (an absent field is unchanged)

const { extractBlocks, compareBlocks, hasBlock } = require("./blocks");

const GUARANTEE = "承認すると、`<user>` block を追加・改変しないことをユーザーが保証したことになる";
const RANK = { allow: 0, ask: 1, deny: 2 };

const allow = (reason) => ({ verdict: "allow", reason });
const deny = (reason) => ({ verdict: "deny", reason });
const ask = (reason) => ({ verdict: "ask", reason: `${reason}。${GUARANTEE}` });
const NEW_BLOCK = "新しい `<user>` block は LLM が書かない(承認しても通らない)";

function compose(results) {
  return results.reduce((a, b) => (RANK[b.verdict] > RANK[a.verdict] ? b : a), allow("`<user>` block の差分はない"));
}

function judgeCreate(next) {
  const out = [];
  if (next.title !== undefined && hasBlock(next.title)) out.push(deny(`title に ${NEW_BLOCK}`));
  if (next.titleUnreadable) out.push(ask("title を読めないので `<user>` block の有無を判定できない"));
  if (next.bodyUnreadable) out.push(ask("本文を読めないので `<user>` block の有無を判定できない"));
  else if (next.body !== undefined && hasBlock(next.body)) out.push(deny(`本文に ${NEW_BLOCK}`));
  return compose(out);
}

function judgeBody(oldBody, next) {
  if (next.bodyUnreadable) return ask("新しい本文を読めないので `<user>` block の差分を判定できない");
  if (next.body === undefined) return allow("本文は変わらない");
  const diff = compareBlocks(extractBlocks(oldBody), extractBlocks(next.body));
  if (diff === "added") return deny(`本文に ${NEW_BLOCK}`);
  if (diff === "changed") return ask("既存の `<user>` block が改変・削除される");
  return allow("`<user>` block は変わらない");
}

const issueHasBlock = (old) => hasBlock(old.body) || (old.comments || []).some((c) => hasBlock(c.body));

function judgeTitle(old, next) {
  const changes = next.titleUnreadable || (next.title !== undefined && next.title !== old.title);
  if (!changes) return allow("title は変わらない");
  if (issueHasBlock(old)) return deny("`<user>` block がある issue の title は LLM が変えない");
  if (next.title !== undefined && hasBlock(next.title)) return deny(`title に ${NEW_BLOCK}`);
  return allow("`<user>` block のない issue の title 変更");
}

function judge({ op, old, next }) {
  const n = next || {};
  switch (op) {
    case "create":
    case "comment-create":
      return judgeCreate(n);
    case "edit":
      return compose([judgeTitle(old, n), judgeBody(old.body, n)]);
    case "comment-edit":
      return compose([judgeBody(old.body, n)]);
    case "comment-delete":
      return hasBlock(old.body) ? ask("`<user>` block を含む comment を削除する") : allow("削除する comment に `<user>` block はない");
    case "issue-delete":
      return issueHasBlock(old) ? ask("`<user>` block を含む issue を削除する") : allow("削除する issue に `<user>` block はない");
    default:
      return deny(`未知の op: ${op}`);
  }
}

module.exports = { judge, GUARANTEE };
