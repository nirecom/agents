"use strict";
// Part of tests/hooks/feature-2768-plan-sync-turn-force.js: the learned remote state is dropped by
// re-provisioning (I1) and ignored for another push URL (I2); the record helpers keep it per URL.

const OTHER = "ssh://git@github.com/test-owner/other-plans.git";

function seed(F, dir, url, force, until) {
  F.git(dir, ["config", "--local", "plansync.remoteStateUrl", url]);
  if (force) F.git(dir, ["config", "--local", "plansync.forceRejected", "true"]);
  if (until) F.git(dir, ["config", "--local", "plansync.authBackoffUntil", String(until)]);
}

function run(F) {
  const RS = F.mod("hooks/lib/plan-sync/remote-state.js");
  F.guard("I1 provisionRepo clears the learned state and keeps the version", () => {
    const repo = F.makeRepo("i1");
    const version = F.config(repo.dir, "plansync.version");
    seed(F, repo.dir, F.config(repo.dir, "remote.origin.url"), true, Date.now() + 600000);
    F.provision(repo);
    for (const k of ["plansync.remoteStateUrl", "plansync.forceRejected", "plansync.authBackoffUntil"]) {
      F.check(`I1 ${k} cleared`, F.config(repo.dir, k) === null, F.config(repo.dir, k));
    }
    F.check("I1 plansync.version kept", version !== null && F.config(repo.dir, "plansync.version") === version, F.config(repo.dir, "plansync.version"));
  });
  F.guard("I2 state recorded for another URL is ignored", () => {
    const repo = F.makeRepo("i2");
    const pushUrl = F.config(repo.dir, "remote.origin.url");
    const until = Date.now() + 600000;
    seed(F, repo.dir, OTHER, true, until);
    if (RS) {
      const st = RS.readRemoteState(repo.dir, pushUrl);
      F.check("I2 mismatched URL reads as nothing learned", st && st.forceRejected === false && st.authBackoffUntil === 0, JSON.stringify(st));
      const own = RS.readRemoteState(repo.dir, OTHER);
      F.check("I2 matching URL reads the stored facts", own && own.forceRejected === true && own.authBackoffUntil === until, JSON.stringify(own));
    }
    const sid = F.newSid("i2");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    const r1 = F.writeSync(repo, a, "a1\n", { turn });
    const r2 = F.writeSync(repo, a, "a2\n", { turn });
    F.check("I2 the stale backoff does not block", r1.status === "pushed" && r2.status === "pushed", JSON.stringify([r1, r2]));
    F.check("I2 the stale forceRejected does not stop replacement", F.bareCount(repo) === n0 + 1, F.bareCount(repo));
  });
  F.guard("I3 record helpers align the URL and drop the other stale key", () => {
    if (!RS) return;
    const repo = F.makeRepo("i3");
    const pushUrl = F.config(repo.dir, "remote.origin.url");
    seed(F, repo.dir, OTHER, false, 12345);
    RS.recordForceRejected(repo.dir, pushUrl);
    F.check("I3 recordForceRejected sets URL + flag", F.config(repo.dir, "plansync.remoteStateUrl") === pushUrl &&
      F.config(repo.dir, "plansync.forceRejected") === "true", `${F.config(repo.dir, "plansync.remoteStateUrl")} ${F.config(repo.dir, "plansync.forceRejected")}`);
    F.check("I3 stale backoff of the old URL dropped", F.config(repo.dir, "plansync.authBackoffUntil") === null, F.config(repo.dir, "plansync.authBackoffUntil"));
    RS.recordAuthBackoff(repo.dir, pushUrl, 777);
    F.check("I3 same URL: backoff added, flag kept", F.config(repo.dir, "plansync.authBackoffUntil") === "777" &&
      F.config(repo.dir, "plansync.forceRejected") === "true", `${F.config(repo.dir, "plansync.authBackoffUntil")} ${F.config(repo.dir, "plansync.forceRejected")}`);
    RS.recordAuthBackoff(repo.dir, OTHER, 888);
    F.check("I3 URL change: flag of the old URL dropped", F.config(repo.dir, "plansync.remoteStateUrl") === OTHER &&
      F.config(repo.dir, "plansync.forceRejected") === null && F.config(repo.dir, "plansync.authBackoffUntil") === "888", F.config(repo.dir, "plansync.forceRejected"));
    const version = F.config(repo.dir, "plansync.version");
    RS.clearRemoteState(repo.dir);
    RS.clearRemoteState(repo.dir);
    F.check("I3 clearRemoteState (twice) clears and keeps the version", F.config(repo.dir, "plansync.remoteStateUrl") === null &&
      F.config(repo.dir, "plansync.authBackoffUntil") === null && F.config(repo.dir, "plansync.version") === version, version);
    F.check("I3 AUTH_BACKOFF_MS is 15 min", RS.AUTH_BACKOFF_MS === 900000, RS.AUTH_BACKOFF_MS);
    const none = RS.readRemoteState(repo.dir, pushUrl);
    F.check("I3 nothing stored reads as defaults", none && none.forceRejected === false && none.authBackoffUntil === 0, JSON.stringify(none));
  });
  F.guard("I4 a stored authBackoffUntil that is not a positive finite number reads as the default 0", () => {
    if (!RS) return;
    const repo = F.makeRepo("i4");
    const pushUrl = F.config(repo.dir, "remote.origin.url");
    for (const { name, stored, want } of UNTIL_CASES) {
      seed(F, repo.dir, pushUrl, true, 0);
      F.git(repo.dir, ["config", "--local", "plansync.authBackoffUntil", stored]);
      const st = RS.readRemoteState(repo.dir, pushUrl);
      F.check(`I4 ${name}: stored ${JSON.stringify(stored)} -> ${want}`, F.config(repo.dir, "plansync.authBackoffUntil") === stored &&
        st && st.authBackoffUntil === want && st.forceRejected === true, `${F.config(repo.dir, "plansync.authBackoffUntil")} ${JSON.stringify(st)}`);
    }
  });
  // A malformed stored backoff reads as 0, so a real plan write must still push (never auth-backoff).
  for (const { name, stored, want } of UNTIL_CASES) {
    if (want !== 0) continue;
    F.guard(`I5 ${name}: stored ${JSON.stringify(stored)} never suppresses a real push`, () => {
      const repo = F.makeRepo(`i5-${name}`);
      const pushUrl = F.config(repo.dir, "remote.origin.url");
      const sid = F.newSid(`i5-${name}`);
      const rel = F.planName(sid, "intent");
      const r0 = F.writeSync(repo, rel, "v1\n");
      F.check(`I5 ${name}: precondition first write pushed`, r0.status === "pushed", JSON.stringify(r0));
      seed(F, repo.dir, pushUrl, false, 0);
      F.git(repo.dir, ["config", "--local", "plansync.authBackoffUntil", stored]);
      const n0 = F.bareCount(repo);
      const r1 = F.writeSync(repo, rel, "v2\n");
      F.check(`I5 ${name}: changed content pushed despite stored ${JSON.stringify(stored)}`,
        r1.status === "pushed" && r1.reason !== "auth-backoff", JSON.stringify(r1));
      F.check(`I5 ${name}: the push reached the bare remote`, F.bareCount(repo) > n0 && F.showAt(repo, "refs/heads/main", rel) === "v2",
        `${F.bareCount(repo)} vs ${n0}`);
    });
  }
  F.guard("I5 positive-control: a valid future authBackoffUntil does suppress the push", () => {
    const repo = F.makeRepo("i5-control");
    const pushUrl = F.config(repo.dir, "remote.origin.url");
    const rel = F.planName(F.newSid("i5-control"), "intent");
    const r0 = F.writeSync(repo, rel, "v1\n");
    F.check("I5 positive-control: precondition first write pushed", r0.status === "pushed", JSON.stringify(r0));
    seed(F, repo.dir, pushUrl, false, Date.now() + 600000);
    const n0 = F.bareCount(repo);
    const r1 = F.writeSync(repo, rel, "v2\n");
    F.check("I5 positive-control: changed content failed with auth-backoff", r1.status === "failed" && r1.reason === "auth-backoff", JSON.stringify(r1));
    F.check("I5 positive-control: the bare remote gained no commit", F.bareCount(repo) === n0, `${F.bareCount(repo)} vs ${n0}`);
  });
}

// readRemoteState keeps only a positive finite epoch ms; anything else is DEFAULTS.authBackoffUntil (0).
const UNTIL_CASES = [
  { name: "negative", stored: "-5", want: 0 },
  { name: "zero", stored: "0", want: 0 },
  { name: "non-numeric", stored: "soon", want: 0 },
  { name: "empty", stored: "", want: 0 },
  { name: "infinity", stored: "Infinity", want: 0 },
  { name: "positive-control", stored: "4102444800000", want: 4102444800000 },
];

module.exports = { run };
