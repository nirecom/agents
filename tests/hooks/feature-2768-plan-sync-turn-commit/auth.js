"use strict";
// Part of tests/hooks/feature-2768-plan-sync-turn-auth.js: the auth backoff (A1-A11). The ssh stub
// refuses auth while GIT_SSH_STUB_FAIL=auth (F.useSsh); every network attempt is counted in the ssh log.
// A8: a secret in the ssh URL's userinfo never shows in an auth failure. A9: offline. A10: two hook runs.
// A11: auth refused on the lease (replacement) push.

const BACKOFF = 15 * 60 * 1000;
const net = (F) => F.sshCalls("auth-refused") + F.sshCalls("git-receive-pack") + F.sshCalls("git-upload-pack");

function run(F) {
  const repo = F.makeRepo("auth");
  const sid = F.newSid("auth");
  const a = F.planName(sid, "intent");
  const b = F.planName(sid, "outline");
  const N = Date.now();
  const at = (ms) => ({ now: () => ms });
  const until = () => Number(F.config(repo.dir, "plansync.authBackoffUntil"));
  F.writeSync(repo, a, "a1\n");
  F.writeSync(repo, b, "b1\n");
  try {
    F.useSsh(true);
    F.guard("A6 auth failure right after the write keeps the URL of published content", () => {
      const r = F.sync(repo, a, at(N));
      F.check("A6 pushed with blob URL", r.status === "pushed" && r.url === F.blobUrl(a), JSON.stringify(r));
      F.check("A6 backoff recorded", until() === N + BACKOFF, F.config(repo.dir, "plansync.authBackoffUntil"));
      F.git(repo.dir, ["config", "--local", "--unset", "plansync.authBackoffUntil"], true);
    });
    F.guard("A1 changed content under an auth failure fails and records the backoff", () => {
      const before = F.sshCalls("auth-refused");
      const r = F.writeSync(repo, a, "a2\n", at(N));
      F.check("A1 failed auth", r.status === "failed" && r.reason === "auth", JSON.stringify(r));
      F.check("A1 network was tried", F.sshCalls("auth-refused") > before, "no attempt");
      F.check("A1 backoff until now + 15 min", until() === N + BACKOFF, F.config(repo.dir, "plansync.authBackoffUntil"));
      F.check("A1 remoteStateUrl set", F.config(repo.dir, "plansync.remoteStateUrl") === F.config(repo.dir, "remote.origin.url"),
        F.config(repo.dir, "plansync.remoteStateUrl"));
    });
    F.guard("A2 inside the backoff nothing touches the network", () => {
      const before = net(F);
      const r = F.writeSync(repo, a, "a3\n", at(N + 60000));
      F.check("A2 failed auth-backoff", r.status === "failed" && r.reason === "auth-backoff", JSON.stringify(r));
      F.check("A2 no ssh call", net(F) === before, net(F) - before);
    });
    F.guard("A5 published content keeps its URL during the backoff", () => {
      const before = net(F);
      const r = F.sync(repo, b, at(N + 120000));
      F.check("A5 pushed with blob URL", r.status === "pushed" && r.url === F.blobUrl(b), JSON.stringify(r));
      F.check("A5 no ssh call", net(F) === before, net(F) - before);
    });
    F.guard("A3 after the backoff the push is tried again", () => {
      const before = F.sshCalls("auth-refused");
      const later = N + 16 * 60 * 1000;
      const r = F.sync(repo, a, at(later));
      F.check("A3 tried again", F.sshCalls("auth-refused") > before, "no attempt");
      F.check("A3 failed auth again", r.status === "failed" && r.reason === "auth", JSON.stringify(r));
      F.check("A3 backoff renewed", until() === later + BACKOFF, F.config(repo.dir, "plansync.authBackoffUntil"));
    });
  } finally {
    F.useSsh(false);
  }
  F.guard("A7 unknown forge under the backoff", () => {
    const plain = F.makeRepo("a7", { url: F.ORIGIN_PLAIN });
    const rel = F.planName(F.newSid("a7"), "intent");
    const r0 = F.writeSync(plain, rel, "c1\n");
    F.check("A7 precondition pushed unknown-forge", r0.status === "pushed" && r0.reason === "unknown-forge", JSON.stringify(r0));
    F.git(plain.dir, ["config", "--local", "plansync.remoteStateUrl", F.config(plain.dir, "remote.origin.url")]);
    F.git(plain.dir, ["config", "--local", "plansync.authBackoffUntil", String(Date.now() + 600000)]);
    const before = net(F);
    const same = F.sync(plain, rel);
    F.check("A7 unchanged -> pushed unknown-forge", same.status === "pushed" && same.reason === "unknown-forge" && !same.url, JSON.stringify(same));
    const changed = F.writeSync(plain, rel, "c2\n");
    F.check("A7 changed -> auth-backoff", changed.status === "failed" && changed.reason === "auth-backoff", JSON.stringify(changed));
    F.check("A7 no ssh call", net(F) === before, net(F) - before);
  });
  F.guard("A4/A5 hook: breadcrumb for unpublished, URL for published", () => {
    const hsid = F.newSid("a4");
    F.startTurn(hsid);
    const p = F.planName(hsid, "intent");
    const q = F.planName(hsid, "outline");
    for (const k of ["plansync.authBackoffUntil", "plansync.remoteStateUrl"]) F.git(repo.dir, ["config", "--local", "--unset", k], true);
    F.writeSync(repo, q, "published\n");
    F.git(repo.dir, ["config", "--local", "plansync.remoteStateUrl", F.config(repo.dir, "remote.origin.url")]);
    F.git(repo.dir, ["config", "--local", "plansync.authBackoffUntil", String(Date.now() + 600000)]);
    F.writePlan(repo, p, "never published\n");
    const before = net(F);
    const h4 = F.hookWrite(repo, p, { sid: hsid });
    F.check("A4 exit 0", h4.code === 0, h4.err);
    F.check("A4 breadcrumb names auth-backoff", h4.msg.includes("[plan-sync] auth-backoff — run node"), h4.msg || h4.out);
    F.check("A4 model context says not published", h4.ctx.includes("(no URL: not-published)"), h4.ctx);
    const h5 = F.hookWrite(repo, q, { sid: hsid });
    F.check("A5 hook context has the blob URL", h5.ctx.includes(F.blobUrl(q)), h5.ctx || h5.out);
    F.check("A5 hook shows no systemMessage", h5.msg === "", h5.msg);
    F.check("A4/A5 hook touched no network", net(F) === before, net(F) - before);
  });
  F.guard("A11 auth refused on the lease (replacement) push of a same-turn second write", () => leaseAuth(F));
  F.guard("A8 ssh push URL with credentials: auth failure never shows the secret", () => credentials(F));
  F.guard("A9 an offline push failure records no backoff and the next write retries", () => offline(F));
  F.guard("A10 two real hook runs: the first hits auth, the second stays off the network", () => twoRuns(F));
}

// The first turn commit is published over the working ssh; the replacement of it (same turn id) is
// the lease push, and only that push meets the auth refusal.
function leaseAuth(F) {
  const repo = F.makeRepo("a11");
  const sid = F.newSid("a11");
  const turn = F.newTurn(sid);
  const rel = F.planName(sid, "intent");
  const N = Date.now();
  const at = (ms) => ({ now: () => ms, turn });
  const cfg = (k) => F.config(repo.dir, k);
  try {
    const r1 = F.writeSync(repo, rel, "t1\n", at(N));
    const first = F.bareTip(repo);
    const n1 = F.bareCount(repo);
    F.check("A11 precondition: the first turn commit is published", r1.status === "pushed" && r1.url === F.blobUrl(rel) && Boolean(first), JSON.stringify(r1));
    F.check("A11 precondition: no backoff yet", cfg("plansync.authBackoffUntil") === null, cfg("plansync.authBackoffUntil"));
    F.useSsh(true);
    const refused = F.sshCalls("auth-refused");
    const r2 = F.writeSync(repo, rel, "t2\n", at(N + 1000));
    F.check("A11 the replacement push met the refusal", F.sshCalls("auth-refused") > refused, "no attempt");
    F.check("A11 failed with reason auth", r2.status === "failed" && r2.reason === "auth", JSON.stringify(r2));
    F.check("A11 backoff recorded in the future", Number(cfg("plansync.authBackoffUntil")) === N + 1000 + BACKOFF, cfg("plansync.authBackoffUntil"));
    F.check("A11 remoteStateUrl set", cfg("plansync.remoteStateUrl") === cfg("remote.origin.url"), cfg("plansync.remoteStateUrl"));
    const before = net(F);
    const r3 = F.writeSync(repo, rel, "t3\n", at(N + 60000));
    F.check("A11 third write: failed auth-backoff", r3.status === "failed" && r3.reason === "auth-backoff", JSON.stringify(r3));
    F.check("A11 third write touched no network", net(F) === before, net(F) - before);
    F.check("A11 the first turn commit is still the bare tip", F.bareTip(repo) === first && F.bareCount(repo) === n1, `${F.bareTip(repo)} count=${F.bareCount(repo)}`);
    F.check("A11 the published content is the first version", F.showAt(repo, "refs/heads/main", rel) === "t1", F.showAt(repo, "refs/heads/main", rel));
  } finally {
    F.useSsh(false);
    for (const k of ["plansync.authBackoffUntil", "plansync.remoteStateUrl"]) F.git(repo.dir, ["config", "--local", "--unset", k], true);
  }
}

// The backoff must survive between hook processes: nothing is seeded, the first spawn records it.
function twoRuns(F) {
  const repo = F.makeRepo("a10");
  const sid = F.newSid("a10");
  F.startTurn(sid);
  const p = F.planName(sid, "intent");
  F.check("A10 precondition: no backoff before the first run", F.config(repo.dir, "plansync.authBackoffUntil") === null,
    F.config(repo.dir, "plansync.authBackoffUntil"));
  try {
    F.useSsh(true);
    const refused = F.sshCalls("auth-refused");
    F.writePlan(repo, p, "first\n");
    const h1 = F.hookWrite(repo, p, { sid });
    F.check("A10 run 1 exit 0", h1.code === 0, h1.err);
    F.check("A10 run 1 tried the network and was refused", F.sshCalls("auth-refused") > refused, "no attempt");
    F.check("A10 run 1 breadcrumb names the auth failure", h1.msg.includes("[plan-sync] auth — run node"), h1.msg || h1.out);
    const until = Number(F.config(repo.dir, "plansync.authBackoffUntil"));
    F.check("A10 run 1 recorded a future backoff", until > Date.now(), F.config(repo.dir, "plansync.authBackoffUntil"));
    const before = net(F);
    const tip = F.bareTip(repo);
    F.writePlan(repo, p, "second\n");
    const h2 = F.hookWrite(repo, p, { sid });
    F.check("A10 run 2 exit 0", h2.code === 0, h2.err);
    F.check("A10 run 2 touched no network", net(F) === before, net(F) - before);
    F.check("A10 run 2 pushed nothing", F.bareTip(repo) === tip, F.bareTip(repo));
    F.check("A10 run 2 breadcrumb names auth-backoff", h2.msg.includes("[plan-sync] auth-backoff — run node"), h2.msg || h2.out);
    F.check("A10 run 2 model context says not published", h2.ctx.includes("(no URL: not-published)") && !h2.ctx.includes(F.blobUrl(p)), h2.ctx);
    // The backoff belongs to the plans repository, not the session: another session's write waits too.
    const sid2 = F.newSid("a10b");
    F.startTurn(sid2);
    const q = F.planName(sid2, "intent");
    F.writePlan(repo, q, "other session\n");
    const h3 = F.hookWrite(repo, q, { sid: sid2 });
    F.check("A10 run 3 (another session) exit 0", h3.code === 0, h3.err);
    F.check("A10 run 3 (another session) touched no network", net(F) === before, net(F) - before);
    F.check("A10 run 3 (another session) breadcrumb names auth-backoff", h3.msg.includes("[plan-sync] auth-backoff — run node"), h3.msg || h3.out);
  } finally {
    F.useSsh(false);
  }
}

function offline(F) {
  const repo = F.makeRepo("a9");
  const rel = F.planName(F.newSid("a9"), "intent");
  F.writeSync(repo, rel, "o1\n");
  const before = F.sshCalls("offline");
  try {
    F.useSsh("offline");
    const r = F.writeSync(repo, rel, "o2\n");
    F.check("A9 precondition: the offline stub was called", F.sshCalls("offline") > before, "no attempt");
    F.check("A9 failed, not an auth reason", r.status === "failed" && r.reason !== "auth" && r.reason !== "auth-backoff", JSON.stringify(r));
    F.check("A9 no backoff recorded", F.config(repo.dir, "plansync.authBackoffUntil") === null, F.config(repo.dir, "plansync.authBackoffUntil"));
  } finally {
    F.useSsh(false);
  }
  const pushes = F.sshCalls("git-receive-pack");
  const r2 = F.writeSync(repo, rel, "o3\n");
  F.check("A9 the next write tries the network again", F.sshCalls("git-receive-pack") > pushes, "no push attempt");
  F.check("A9 the next write pushes", r2.status === "pushed" && r2.url === F.blobUrl(rel), JSON.stringify(r2));
}

const SECRET = "s3cr3t-token-2768";

// The secret rides in the ssh URL's userinfo; git hands "user:<secret>@github.com" to the ssh stub as
// the destination, and the stub's auth refusal names it the way OpenSSH does.
function credentials(F) {
  const base = F.makeRepo("a8");
  const url = `ssh://user:${SECRET}@github.com/test-owner/test-repo.git`;
  const repo = Object.assign({}, base, { url });
  const sid = F.newSid("a8");
  const rel = F.planName(sid, "intent");
  F.writeSync(base, rel, "v1\n");
  F.git(repo.dir, ["config", "--local", "remote.origin.url", url]);
  try {
    F.useSsh("auth");
    const refused = F.sshCalls("auth-refused");
    const r = F.writeSync(repo, rel, "v2\n");
    const shown = JSON.stringify(r);
    F.check("A8 precondition: the push reached the refusing ssh stub", F.sshCalls("auth-refused") > refused, "no attempt");
    F.check("A8 changed content fails auth", r.status === "failed" && r.reason === "auth", shown);
    F.check("A8 the sync result and its detail carry no secret", !shown.includes(SECRET), shown);
    F.git(repo.dir, ["config", "--local", "--unset", "plansync.authBackoffUntil"], true);
    F.startTurn(sid);
    F.writePlan(repo, rel, "v3\n");
    const before = F.sshCalls("auth-refused");
    const h = F.hookWrite(repo, rel, { sid, env: { PLAN_SYNC_REMOTE_URL: url } });
    F.check("A8 precondition: the hook's push reached the refusing ssh stub", F.sshCalls("auth-refused") > before, "no attempt");
    F.check("A8 hook exit 0", h.code === 0, h.err);
    F.check("A8 hook out/err/systemMessage/additionalContext carry no secret", ![h.out, h.err, h.msg, h.ctx].join("\n").includes(SECRET),
      h.out + h.err);
  } finally {
    F.useSsh(false);
  }
}

// A8b: redactText alone masks the scp-form userinfo OpenSSH prints in its Permission denied line.
function redact(F) {
  const { redactText } = require(`${F.ROOT}/hooks/lib/plan-sync/remote-url.js`);
  for (const text of [`git:${SECRET}@github.com: Permission denied (publickey).`, `ssh://git:${SECRET}@h/x`,
    `fatal: Could not read from remote repository.\ngit:${SECRET}@github.com: Permission denied (publickey).`]) {
    const out = redactText(text);
    F.check(`A8b secret masked in ${JSON.stringify(text.split("\n").pop())}`, !out.includes(SECRET) && out.length > 0, out);
  }
  const plain = "git@github.com:o/r.git";
  F.check("A8b scp form without a secret is unchanged", redactText(plain) === plain, redactText(plain));
}

module.exports = { run, redact };
