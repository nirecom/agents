"use strict";
// Part of tests/hooks/feature-2768-plan-sync-turn-force.js: a remote that refuses the replacement
// (receive.denyNonFastForwards) is learned once (F1-F2), the lease push is classified (F3), turn-diff
// links follow the range (F4), and the compare/commit URL builders (urls).

const porcelain = (flag, summary) => `To ssh://x\n${flag}\trefs/heads/main:refs/heads/main\t${summary}\nDone\n`;

function run(F) {
  const RS = F.mod("hooks/lib/plan-sync/remote-state.js");
  const repo = F.makeRepo("f1", { deny: true });
  const pushUrl = F.config(repo.dir, "remote.origin.url");
  const sid = F.newSid("f1");
  const turn = F.newTurn(sid);
  const a = F.planName(sid, "intent");
  const P = F.bareTip(repo);

  F.guard("F1 refused replacement falls back to an append and is learned", () => {
    const r1 = F.writeSync(repo, a, "a1\n", { turn });
    const X1 = F.bareTip(repo);
    F.check("F1 first write pushed, no turnLinks yet", r1.status === "pushed" && r1.turnLinks === undefined, JSON.stringify(r1));
    const r2 = F.writeSync(repo, a, "a2\n", { turn });
    const X2 = F.bareTip(repo);
    F.check("F1 second write pushed with URL", r2.status === "pushed" && r2.url === F.blobUrl(a), JSON.stringify(r2));
    F.check("F1 appended on X1", F.parentsOf(repo, X2)[0] === X1 && X2 !== X1, F.parentsOf(repo, X2));
    F.check("F1 forceRejected recorded", F.config(repo.dir, "plansync.forceRejected") === "true", F.config(repo.dir, "plansync.forceRejected"));
    F.check("F1 remoteStateUrl recorded", F.config(repo.dir, "plansync.remoteStateUrl") === pushUrl, F.config(repo.dir, "plansync.remoteStateUrl"));
    F.check("F1 turnLinks compare P...X2", r2.turnLinks && r2.turnLinks.kind === "compare" &&
      JSON.stringify(r2.turnLinks.urls) === JSON.stringify([F.compareUrl(P, X2)]), JSON.stringify(r2.turnLinks));
  });
  F.guard("F2 a learned remote gets one push per write", () => {
    const before = F.sshCalls("git-receive-pack");
    const r = F.writeSync(repo, a, "a3\n", { turn });
    F.check("F2 pushed", r.status === "pushed", JSON.stringify(r));
    F.check("F2 exactly one receive-pack", F.sshCalls("git-receive-pack") - before === 1, F.sshCalls("git-receive-pack") - before);
    F.check("F2 compare still spans the whole turn", r.turnLinks && r.turnLinks.kind === "compare" &&
      r.turnLinks.urls[0] === F.compareUrl(P, F.bareTip(repo)), JSON.stringify(r.turnLinks));
    if (RS) {
      const st = RS.readRemoteState(repo.dir, pushUrl);
      F.check("F2 readRemoteState learned", st && st.forceRejected === true && st.authBackoffUntil === 0, JSON.stringify(st));
    }
  });
  F.guard("F3 classifyLeasePush verdicts", () => {
    const LP = F.mod("hooks/lib/plan-sync/lease-push.js");
    if (!LP) return;
    const c = (r) => LP.classifyLeasePush(Object.assign({ status: 1, stdout: "", stderr: "", timedOut: false }, r));
    const table = [
      ["ok", { status: 0, stdout: porcelain("+", "abc...def (forced update)") }],
      ["timeout", { status: null, timedOut: true }],
      ["lease-miss", { stdout: porcelain("!", "[rejected] (stale info)") }],
      ["remote-rejected", { stdout: porcelain("!", "[remote rejected] (protected branch hook declined)") }],
      ["remote-rejected", { stdout: porcelain("!", "[remote rejected] (pre-receive hook declined)") }],
      ["remote-rejected", { stdout: porcelain("!", "[remote rejected] (non-fast-forward)") }],
      ["other", { stdout: porcelain("!", "[remote rejected] (failed to lock)") }],
      ["other", { stdout: porcelain("!", "[remote rejected] (cannot lock ref 'refs/heads/main')") }],
      ["other", { stdout: porcelain("!", "[remote rejected] (stale info)") }],
      ["other", { stdout: porcelain("!", "[rejected] (fetch first)") }],
      ["remote-rejected", { stderr: " ! [remote rejected] main -> main (protected branch hook declined)\n" }],
      ["lease-miss", { stderr: " ! [rejected]        main -> main (stale info)\n" }],
      ["other", { status: 128, stderr: "Permission denied (publickey).\nfatal: Could not read from remote repository.\n" }],
    ];
    table.forEach(([want, r], i) => F.check(`F3 #${i} -> ${want}`, c(r) === want, `${c(r)} for ${JSON.stringify(r)}`));
  });
  F.guard("F3 a real porcelain refusal is remote-rejected", () => {
    const LP = F.mod("hooks/lib/plan-sync/lease-push.js");
    if (!LP) return;
    const tip = F.bareTip(repo);
    F.git(repo.dir, ["fetch", "-q", "origin", "+refs/heads/main:refs/remotes/origin/main"]);
    const parent = F.git(repo.dir, ["rev-parse", `${tip}^`]);
    const tree = F.git(repo.dir, ["rev-parse", `${tip}^{tree}`]);
    const side = F.git(repo.dir, ["commit-tree", tree, "-p", parent, "-m", "side"]);
    F.git(repo.dir, ["update-ref", "refs/heads/main", side]);
    try {
      const r = LP.pushMainWithLease(repo.dir, tip, { deadline: Date.now() + 20000 });
      F.check("F3 real refusal classified remote-rejected", LP.classifyLeasePush(r) === "remote-rejected", JSON.stringify(r));
      F.check("F3 bare tip unchanged", F.bareTip(repo) === tip, F.bareTip(repo));
    } finally {
      F.git(repo.dir, ["update-ref", "refs/heads/main", tip]);
    }
  });
  F.guard("F4 interleaved commits switch to per-commit links", () => {
    const t2 = F.newTurn(sid);
    const r1 = F.writeSync(repo, a, "t2-1\n", { turn: t2 });
    const Z1 = F.bareTip(repo);
    F.check("F4 first commit of the turn: compare", r1.turnLinks && r1.turnLinks.kind === "compare" &&
      r1.turnLinks.urls[0] === F.compareUrl(F.parentsOf(repo, Z1)[0], Z1), JSON.stringify(r1.turnLinks));
    const B = F.cloneRepo(repo, "f4b");
    F.writeSync(B, F.planName(F.newSid("f4b"), "intent"), "B\n");
    const Y = F.bareTip(repo);
    const r2 = F.writeSync(repo, a, "t2-2\n", { turn: t2 });
    const Z2 = F.bareTip(repo);
    F.check("F4 Z2 appended on Y", F.parentsOf(repo, Z2)[0] === Y, F.parentsOf(repo, Z2));
    const tl = r2.turnLinks || {};
    F.check("F4 kind commits", tl.kind === "commits", JSON.stringify(tl));
    F.check("F4 urls are this turn's commits, oldest first", JSON.stringify(tl.urls) === JSON.stringify([F.commitUrl(Z1), F.commitUrl(Z2)]),
      JSON.stringify(tl.urls));
    F.check("F4 no link to Y and no compare", tl.kind === "commits" && !JSON.stringify(tl).includes(Y) && !JSON.stringify(tl).includes("/compare/"),
      JSON.stringify(tl));
    F.check("F4 more is 0", tl.kind === "commits" && (tl.more || 0) === 0, JSON.stringify(tl));
    let last = null;
    for (let i = 3; i <= 6; i++) last = F.writeSync(repo, a, `t2-${i}\n`, { turn: t2 });
    const ll = (last && last.turnLinks) || {};
    const own = F.firstParentLog(repo, 20).filter((h) => F.trailersOf(F.bodyOf(repo, h)).turn[0] === t2.turnId).reverse();
    F.check("F4 six turn commits on the remote", own.length === 6, own.length);
    F.check("F4 capped at 5 links + more 1", ll.kind === "commits" && Array.isArray(ll.urls) && ll.urls.length === 5 && ll.more === 1, JSON.stringify(ll));
    const order = (ll.urls || []).map((u) => own.findIndex((h) => F.commitUrl(h) === u));
    F.check("F4 links are turn commits in oldest-first order", order.length > 0 && order.every((v, i) => v >= 0 && (i === 0 || v > order[i - 1])), JSON.stringify(order));
    const TC = F.mod("hooks/lib/plan-sync/turn-commit.js");
    if (!TC) return;
    const tr = TC.turnRange(repo.dir, F.bareTip(repo), t2);
    F.check("F4 turnRange newest first + interleaved", tr && JSON.stringify(tr.turnCommits) === JSON.stringify(own.slice().reverse()) &&
      tr.interleaved === true && tr.base === F.parentsOf(repo, Z1)[0], JSON.stringify(tr));
    F.check("F4 turnRange of an unknown turn is null", TC.turnRange(repo.dir, F.bareTip(repo), F.newTurn(sid)) === null, "non-null");
    const t1 = TC.turnRange(repo.dir, Z1, turn);
    F.check("F4 turnRange of the first turn: base P, not interleaved", t1 && t1.base === P && t1.interleaved === false, JSON.stringify(t1));
  });
}

function runUrls(F) {
  F.guard("urls compare/commit builders and re-exports", () => {
    const RU = F.mod("hooks/lib/plan-sync/remote-url.js");
    const none = { gitlabHost: "", gitlabSshHost: "" };
    const gh = RU.resolveRemoteTarget(F.ORIGIN_GH, none);
    F.check("urls github compare", RU.compareUrlFor && RU.compareUrlFor(gh, "b1", "h2") === `${F.GH_WEB}/compare/b1...h2`,
      RU.compareUrlFor && RU.compareUrlFor(gh, "b1", "h2"));
    F.check("urls github commit", RU.commitUrlFor && RU.commitUrlFor(gh, "c3") === `${F.GH_WEB}/commit/c3`, RU.commitUrlFor && RU.commitUrlFor(gh, "c3"));
    const gls = { gitlabHost: "gitlab.example.com", gitlabSshHost: "" };
    const gl = RU.resolveRemoteTarget("ssh://git@gitlab.example.com/grp/sub/plans.git", gls);
    F.check("urls gitlab uses /-/", RU.compareUrlFor && RU.compareUrlFor(gl, "b", "h") === "https://gitlab.example.com/grp/sub/plans/-/compare/b...h" &&
      RU.commitUrlFor(gl, "c") === "https://gitlab.example.com/grp/sub/plans/-/commit/c", RU.compareUrlFor && RU.compareUrlFor(gl, "b", "h"));
    const plain = RU.resolveRemoteTarget(F.ORIGIN_PLAIN, none);
    F.check("urls unknown forge -> null", RU.compareUrlFor && RU.compareUrlFor(plain, "b", "h") === null && RU.commitUrlFor(plain, "c") === null, "non-null");
    // AT keeps the credential URLs from reading as email addresses to the outbound scan.
    const AT = "@";
    const table = [
      ["https plain", "https://github.com/o/r.git", none, "https://github.com/o/r"],
      ["http plain keeps http", "http://github.com/o/r", none, "http://github.com/o/r"],
      ["https default port 443 dropped", "https://github.com:443/o/r.git", none, "https://github.com/o/r"],
      ["http default port 80 dropped", "http://github.com:80/o/r.git", none, "http://github.com/o/r"],
      ["https non-standard port kept", "https://github.com:8443/o/r.git", none, "https://github.com:8443/o/r"],
      ["https user:token credential stripped", `https://user:tok3n${AT}github.com/o/r.git`, none, "https://github.com/o/r"],
      ["https token-only credential stripped", `https://tok3n${AT}github.com/o/r.git`, none, "https://github.com/o/r"],
      ["ssh non-standard port is not a web port", "ssh://git@github.com:2222/o/r.git", none, "https://github.com/o/r"],
      ["gitlab ssh port 2222 dropped", "ssh://git@gitlab.example.com:2222/g/s/p.git", gls, "https://gitlab.example.com/g/s/p", "/-/"],
      ["gitlab https port 8443 kept", "https://gitlab.example.com:8443/g/s/p.git", gls, "https://gitlab.example.com:8443/g/s/p", "/-/"],
      ["gitlab http port 8080 kept", "http://gitlab.example.com:8080/g/p", gls, "http://gitlab.example.com:8080/g/p", "/-/"],
      ["gitlab https credential stripped", `https://u:tok3n${AT}gitlab.example.com/g/s/p.git`, gls, "https://gitlab.example.com/g/s/p", "/-/"],
    ];
    for (const [label, url, st, project, sep = "/"] of table) {
      const t = RU.resolveRemoteTarget(url, st);
      const cmp = RU.compareUrlFor(t, "b", "h");
      const cmt = RU.commitUrlFor(t, "c");
      F.check(`urls ${label}: compare`, cmp === `${project}${sep}compare/b...h`, cmp);
      F.check(`urls ${label}: commit`, cmt === `${project}${sep}commit/c`, cmt);
      F.check(`urls ${label}: no credential or ssh user in the links`, !/tok3n|user:|u:|git@/.test(`${cmp} ${cmt}`), `${cmp} ${cmt}`);
    }
    for (const [label, url, st] of [
      ["https unknown host with port", "https://plans.example.com:8443/o/r.git", none],
      ["github with a nested project path", "https://github.com:8443/o/r/extra.git", none],
      ["local path", "/srv/plans.git", none],
      ["empty url", "", none],
    ]) {
      const t = RU.resolveRemoteTarget(url, st);
      F.check(`urls ${label} -> null`, RU.compareUrlFor(t, "b", "h") === null && RU.commitUrlFor(t, "c") === null,
        `${RU.compareUrlFor(t, "b", "h")} ${RU.commitUrlFor(t, "c")}`);
    }
    const PS = F.ps();
    for (const [name, src] of [["compareUrlFor", RU], ["commitUrlFor", RU], ["formatTurnMessage", "turn-trailer"],
      ["parseTurnMessage", "turn-trailer"], ["readRemoteState", "remote-state"], ["clearRemoteState", "remote-state"]]) {
      const owner = typeof src === "string" ? F.mod(`hooks/lib/plan-sync/${src}.js`) : src;
      F.check(`urls plan-sync re-exports ${name}`, owner && typeof owner[name] === "function" && PS[name] === owner[name], typeof PS[name]);
    }
  });
}

module.exports = { run, runUrls };
