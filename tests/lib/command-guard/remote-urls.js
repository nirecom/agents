"use strict";
// tests/lib/command-guard/remote-urls.js — the URLs a push / fetch / clone really reaches (#2590).
// Every URL is taken after git's own url.<base>.insteadOf / pushInsteadOf rewriting, read from the
// real git with the caller's globals (-c included), so the guard judges the URL git will use.
// A remote configured in the repo resolves through `git remote get-url [--push] --all`. A raw URL,
// and a remote git cannot resolve (one set only by -c), go through `git ls-remote --get-url`
// (insteadOf); a push also keeps the URL itself and its pushInsteadOf form, which no git command
// prints, applied here by git's longest-prefix rule. A failed lookup keeps the unrewritten URL.

// The raw url / pushurl config values, unrewritten.
function rawConfigUrls(git, operand, push) {
  if (operand === null) {
    return git(["config", "--get-regexp", "^remote\\..*\\.(url|pushurl)$"]).lines.map((l) => l.replace(/^\S+\s+/, ""));
  }
  if (!/^[A-Za-z0-9._-]+$/.test(operand)) return [operand];
  const urls = git(["config", "--get-all", `remote.${operand}.url`]).lines;
  if (push) urls.push(...git(["config", "--get-all", `remote.${operand}.pushurl`]).lines);
  return urls.length > 0 ? urls : [operand];
}

const answered = (r) => (r.status === 0 && r.lines.length > 0 ? r.lines : null);

// pushRewrite(git, url) — url after the longest matching url.<base>.pushInsteadOf, or null.
function pushRewrite(git, url) {
  const r = git(["config", "-z", "--get-regexp", "^url\\..*\\.pushinsteadof$"]);
  let best = null;
  for (const entry of r.status === 0 ? r.out.split("\0") : []) {
    const nl = entry.indexOf("\n");
    if (nl < 0) continue;
    const base = entry.slice(4, nl - ".pushinsteadof".length);
    const prefix = entry.slice(nl + 1);
    if (prefix !== "" && url.startsWith(prefix) && (!best || prefix.length > best.prefix.length)) best = { base, prefix };
  }
  return best ? best.base + url.slice(best.prefix.length) : null;
}

// rawUrlTargets(git, url, push, pre) — a URL after rewriting; pre is extra -c globals.
function rawUrlTargets(git, url, push, pre = []) {
  const fetchSide = answered(git([...pre, "ls-remote", "--get-url", "--", url]));
  if (!push) return fetchSide || [url];
  const pushSide = pushRewrite(git, url);
  return [url, ...(fetchSide || []), ...(pushSide === null ? [] : [pushSide])];
}

function namedRemoteUrls(git, name, push) {
  const args = push ? ["remote", "get-url", "--push", "--all", name] : ["remote", "get-url", "--all", name];
  return answered(git(args)) || rawConfigUrls(git, name, push).flatMap((u) => rawUrlTargets(git, u, push));
}

// remoteUrls(git, operand, push) — the URLs a remote operand stands for; no operand means every
// configured remote, a conservative over-approximation of the one git picks.
function remoteUrls(git, operand, push) {
  const listed = git(["remote"]);
  if (listed.status !== 0) return rawConfigUrls(git, operand, push).flatMap((u) => rawUrlTargets(git, u, push));
  if (operand === null) return listed.lines.flatMap((n) => namedRemoteUrls(git, n, push));
  if (listed.lines.includes(operand)) return namedRemoteUrls(git, operand, push);
  return rawUrlTargets(git, operand, push);
}

// configGlobals(rest) — clone's -c / --config values as -c globals: clone applies them before it fetches.
function configGlobals(rest) {
  const out = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--") break;
    if ((a === "-c" || a === "--config") && i + 1 < rest.length) out.push("-c", rest[++i]);
    else if (a.startsWith("--config=")) out.push("-c", a.slice("--config=".length));
    else if (/^-c./.test(a)) out.push("-c", a.slice(2));
  }
  return out;
}

module.exports = { remoteUrls, rawUrlTargets, configGlobals };
