"use strict";
// Redaction, truncation and read-cap rows of adapter-probe.js (#2460). The body runs inside one
// function so it can take the probe's shared context (A, safe, plansDir, sid, prompt, redacted).
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

module.exports = function redactionRows(ctx) {
const { A, safe, plansDir, sid, prompt, redacted } = ctx;

// Redaction rows. Secret-shaped fixtures are built at runtime: the outbound scan matches
// these shapes in any committed file. NO_ART is a session with no plan artifacts.
const GHP = "gh" + "p_" + "A".repeat(36);
const AKIA = "AK" + "IA" + "B".repeat(16);
const SKT = "s" + "k-" + "C".repeat(40);
const PH = "[REDACTED]";
const NO_ART = sid + "-noart";
const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");
const req = (p, s, stage) => A.buildRequest({ toolInput: { prompt: p }, sessionId: s, stage: stage || "outline" });
function withArtifacts(texts, fn) {
  const saved = {};
  for (const n of Object.keys(texts)) {
    const f = path.join(plansDir, sid + "-" + n + ".md");
    saved[n] = fs.existsSync(f) ? fs.readFileSync(f, "utf8") : null;
    fs.writeFileSync(f, texts[n]);
  }
  try { return fn(); } finally {
    for (const n of Object.keys(saved)) {
      const f = path.join(plansDir, sid + "-" + n + ".md");
      if (saved[n] === null) fs.rmSync(f, { force: true }); else fs.writeFileSync(f, saved[n]);
    }
  }
}
safe("request-redacts-prompt", () => {
  const state = String(req("see " + GHP + " and " + AKIA + " end", NO_ART).state);
  return [state.includes(GHP), state.includes(AKIA), state.includes("see " + PH + " and " + PH + " end")].join("|");
});
safe("request-redacts-artifacts", () => withArtifacts(
  { intent: "INTENT-SEC " + GHP + "\n", outline: "OUTLINE-SEC " + AKIA + "\n", detail: "DETAIL-SEC " + SKT + "\n" }, () => {
    const r = req(prompt, sid, "detail");
    const state = String(r.state);
    return [[GHP, AKIA, SKT].some((t) => state.includes(t)),
      ["INTENT-SEC ", "OUTLINE-SEC ", "DETAIL-SEC "].every((m) => state.includes(m + PH)),
      r.input.sources.join(",")].join("|");
  }));
// The token starts 10 chars before the cap: cut first and redacted second, the state would
// end in a 10-char fragment of the key that no pattern matches any more.
safe("request-secret-straddles-cap", () => {
  const prefix = String(req("", NO_ART).state).length - 1;
  const r = req("F".repeat(A.MAX_STATE_CHARS - prefix - 1 - PH.length) + " " + SKT, NO_ART);
  const state = String(r.state);
  return [state.length, r.input.truncated, state.includes(SKT.slice(0, 4)), state.endsWith(" " + PH),
    r.input.sha256 === sha(state), r.input.bytes === Buffer.byteLength(state)].join("|");
});
safe("request-filler-then-secret", () => {
  const r = req("F".repeat(15990) + " " + SKT, NO_ART);
  return [String(r.state).length, r.input.truncated, String(r.state).includes(SKT.slice(0, 4))].join("|");
});
// Surrogate-safe cut: the state must be valid UTF-16 so bytes/sha256 describe what is sent.
const EMOJI = "\u{1F600}";
const LONE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;
function cutShape(r) {
  const state = String(r.state);
  const last = state.charCodeAt(state.length - 1);
  return [state.length, last >= 0xd800 && last <= 0xdbff, LONE.test(state), r.input.bytes === Buffer.byteLength(state),
    Buffer.from(state, "utf8").toString("utf8") === state, r.input.sha256 === sha(state), r.input.truncated].join("|");
}
const promptAt = () => String(req("", NO_ART).state).length;
safe("request-surrogate-at-prompt-cut", () => cutShape(req("z".repeat(A.MAX_STATE_CHARS - promptAt()) + EMOJI.repeat(10), NO_ART)));
safe("request-surrogate-pair-fits-prompt-cut", () => cutShape(req("z".repeat(A.MAX_STATE_CHARS - promptAt() - 1) + EMOJI.repeat(10), NO_ART)));
safe("request-surrogate-at-artifact-cut", () => {
  const marker = "\n## intent.md\n";
  const at = withArtifacts({ intent: "Z\n" }, () => {
    const s = String(req(prompt, sid, "detail").state);
    return s.indexOf(marker) + marker.length;
  });
  return withArtifacts({ intent: "z".repeat(A.MAX_STATE_CHARS - at - 1) + EMOJI.repeat(10) + "\n" }, () => {
    const r = req(prompt, sid, "detail");
    return [cutShape(r), String(r.state).indexOf(marker) + marker.length === at, r.input.sources.join(",")].join("|");
  });
});
// A ghp_ token starting 10 chars before the cap: cut first, the state would keep "ghp_" + 6 body chars.
safe("request-ghp-straddles-cap", () => {
  const body = "Q7x".repeat(12);
  const tok = "gh" + "p_" + body;
  const r = req("F".repeat(A.MAX_STATE_CHARS - (promptAt() - 1) - 10) + tok + " tail", NO_ART);
  const state = String(r.state);
  return [state.length <= A.MAX_STATE_CHARS, /ghp_[A-Za-z0-9]/.test(state), state.includes(body.slice(0, 6)),
    state.endsWith(PH), r.input.truncated, r.input.bytes === Buffer.byteLength(state)].join("|");
});
safe("request-input-is-of-redacted-state", () => {
  const p = "multi-byte 日本語 " + GHP;
  const r = req(p, NO_ART);
  const state = String(r.state);
  return [Object.keys(r.input).join(","), r.input.sha256 === sha(state), r.input.bytes === Buffer.byteLength(state),
    r.input.bytes > state.length, r.input.sha256 === sha(state.replace(PH, GHP)), JSON.stringify(r.input).includes(GHP)].join("|");
});
safe("request-clean-prompt-identical", () => {
  const p = "Judge the task_complexity_signals_file_name for S1-multi-file.\n  line two\t(tab) = \"quoted\"";
  const a = req(p, NO_ART);
  const b = req(p, NO_ART);
  return [String(a.state).endsWith("\n## dispatch prompt\n" + p + "\n"), a.input.truncated, a.input.sha256 === b.input.sha256,
    a.input.sources.length].join("|");
});
safe("request-non-string-prompt", () => [undefined, null, 42, { prompt: GHP }].map((p) => {
  const r = A.buildRequest({ toolInput: { prompt: p }, sessionId: NO_ART, stage: "outline" });
  return String(r.state).endsWith("\n## dispatch prompt\n\n") && !JSON.stringify(r).includes(GHP);
}).join("|"));

// output-sanitize.js redactSecrets shapes, each in the prompt and in all three artifacts:
// [name, text, fragments that must never be sent, fragments that must survive].
const SAN = "<redacted>";
const SAN_SHAPES = [
  ["github-pat", "github" + "_pat_" + "11ABCDEFG0a1B2c3D4e5F6g7H8i9J0", ["11ABCDEFG0a1B2c3D4e5"], []],
  ["url-userinfo", "https://" + "alice" + ":" + "S3cretPassw0rdX" + "@host.example.com/repo", ["alice", "S3cretPassw0rdX"],
    ["https://", "@host.example.com/repo"]],
  ["auth-bearer", "Authorization: Bearer " + "eyJhbGciOi.QmVhcmVyVG9r.c2ln", ["eyJhbGciOi", "QmVhcmVyVG9r"], ["Authorization"]],
  ["auth-basic", "Authorization: Basic " + "dXNlcjpzM2NyZXQtcHc9OTk=", ["dXNlcjpzM2NyZXQtcHc9OTk"], ["Authorization"]],
  ["password-assign", "pass" + "word=" + "Hunter2SecretVal", ["Hunter2SecretVal"], ["password="]],
  ["token-colon", "tok" + "en: " + "TokValue9xyzQ", ["TokValue9xyzQ"], ["token:"]],
  ["api-key-assign", "api" + "_key=" + "ApiKeyVal7qrsT", ["ApiKeyVal7qrsT"], ["api_key="]],
  ["encrypted-pem", "-----BEGIN " + "ENCRYPTED PRIVATE KEY" + "-----\nMIIFHDBOBgkqhkiG9w0BBQ0wQTApBgkq\n" +
    "-----END " + "ENCRYPTED PRIVATE KEY" + "-----", ["MIIFHDBOBgkqhkiG9w0BBQ0wQTApBgkq", "ENCRYPTED PRIVATE"], []],
  ["sk-with-assign", SKT + " and pass" + "word=" + "Hunter3SecretVal", [SKT.slice(0, 12), "Hunter3SecretVal"], ["and"]],
];
// leak in prompt|prose kept|marker|leak in artifacts|prose kept|marker|bytes+sha256 of the state (both requests).
function sanShape([, text, leaks, keeps]) {
  const judge = (r, pre, post) => {
    const state = String(r.state);
    const body = JSON.stringify(r);
    return [leaks.some((f) => state.includes(f) || body.includes(f)),
      keeps.every((k) => state.includes(k)) && pre.every((p) => state.includes(p + " ")) && post.every((p) => state.includes(" " + p)),
      state.includes(SAN) || state.includes(PH), r.input.bytes === Buffer.byteLength(state) && r.input.sha256 === sha(state)];
  };
  const p = judge(req("BEFORE-P " + text + " AFTER-P", NO_ART), ["BEFORE-P"], ["AFTER-P"]);
  const a = withArtifacts({ intent: "INT-P " + text + " INT-Q\n", outline: "OUT-P " + text + " OUT-Q\n",
    detail: "DET-P " + text + " DET-Q\n" }, () => judge(req(prompt, sid, "detail"), ["INT-P", "OUT-P", "DET-P"],
    ["INT-Q", "OUT-Q", "DET-Q"]));
  return [p[0], p[1], p[2], a[0], a[1], a[2], p[3] && a[3]].join("|");
}
for (const shape of SAN_SHAPES) safe("sanitize-shape-" + shape[0], () => sanShape(shape));
// Redaction equals the scanner: prose glued to a 20+ "sk-" run is redacted (accepted over-redaction),
// prose without one survives. Per word: kept in prompt, kept in artifact, marker in prompt, in artifact.
const proseRow = (w) => {
  const s = String(req("see " + w + " here", NO_ART).state);
  const a = withArtifacts({ intent: "INT " + w + " END\n" }, () => String(req(prompt, sid, "detail").state));
  return [s.includes("see " + w + " here"), a.includes("INT " + w + " END"), s.includes(PH), a.includes(PH)].join(",");
};
safe("sanitize-prose-sk-glued-redacted", () => ["tas" + "k-complexity-signals-file-name", "ri" + "sk-assessment_threshold_v2",
  "di" + "sk-usage_report_2024_final"].map(proseRow).join("|"));
safe("sanitize-prose-non-sk-kept", () => ["di" + "sk-usage", "task_complexity_signals_file_name", "tasks-complexity-signals"].map(proseRow).join("|"));
// Straddling the cap: cut first, the state would keep "github_pat_" + 4 body chars, or
// "https://alice:" + 5 password chars with no "@" left for the userinfo pattern to anchor on.
const PAT_BODY = "Z9y8X7w6V5u4T3s2R1q0";
const PAT = "github" + "_pat_" + PAT_BODY;
function straddle(r, leaks, mark) {
  const state = String(r.state);
  return [state.length <= A.MAX_STATE_CHARS, leaks.some((f) => state.includes(f)), state.includes(mark), r.input.truncated,
    r.input.bytes === Buffer.byteLength(state) && r.input.sha256 === sha(state)].join("|");
}
safe("request-github-pat-straddles-cap", () => straddle(
  req("F".repeat(A.MAX_STATE_CHARS - (promptAt() - 1) - 15) + PAT + " tail", NO_ART), ["github_pat_", PAT_BODY.slice(0, 4)], SAN));
safe("request-url-userinfo-straddles-cap", () => straddle(
  req("F".repeat(A.MAX_STATE_CHARS - (promptAt() - 1) - 19) + "https://alice:Pw0rdStraddle99@host.example.com/x tail", NO_ART),
  ["alice", "Pw0rd"], "https://" + SAN));
safe("request-github-pat-straddles-artifact-cap", () => {
  const marker = "\n## intent.md\n";
  const at = withArtifacts({ intent: "Z\n" }, () => {
    const s = String(req(prompt, sid, "detail").state);
    return s.indexOf(marker) + marker.length;
  });
  return withArtifacts({ intent: "z".repeat(A.MAX_STATE_CHARS - at - 15) + PAT + " tail\n" }, () => {
    const r = req(prompt, sid, "detail");
    return [straddle(r, ["github_pat_", PAT_BODY.slice(0, 4)], SAN), r.input.sources.join(",")].join("|");
  });
});

// Read-cap rows: one intent artifact under its own session; read = the text as read from disk.
const CAP = A.MAX_ARTIFACT_READ_BYTES;
const CAP_SID = sid + "-cap";
function capRead(text) {
  const f = path.join(plansDir, CAP_SID + "-intent.md");
  fs.writeFileSync(f, text);
  try {
    redacted.length = 0;
    const r = req(prompt, CAP_SID, "outline");
    const state = String(r.state);
    const m = /intent\+outline lines: (\d+)/.exec(state);
    return { read: redacted[1], state, lines: m ? Number(m[1]) : null, r };
  } finally { fs.rmSync(f, { force: true }); }
}
safe("request-artifact-read-cap", () => {
  const c = capRead("a\n".repeat(CAP / 2 + 1000));
  return [CAP, c.read.length, c.lines, c.state.length <= A.MAX_STATE_CHARS, c.r.input.truncated, c.r.input.sources.join(",")].join("|");
});
safe("request-artifact-cap-splits-multibyte", () => [[1, "日"], [2, "日"], [3, EMOJI]].map(([inside, ch]) => {
  const c = capRead("x".repeat(CAP - inside) + ch + "tail\n");
  return [c.read.length === CAP - inside, c.read.endsWith("x"), c.read.includes("�"), c.lines].join(",");
}).join("|"));
safe("request-artifact-at-cap-not-trimmed", () => {
  const exact = capRead("x".repeat(CAP - 3) + "�");
  const small = capRead("small �");
  return [exact.read.length, exact.read.endsWith("�"), small.read === "small �"].join("|");
});
// Over the cap, a complete U+FFFD (EF BF BD) ending exactly at the cap is genuine text, not a split char.
safe("request-artifact-cap-keeps-genuine-fffd", () => {
  const c = capRead("x".repeat(CAP - 3) + "�" + "tail\n");
  return [c.read.length, c.read.endsWith("�"), c.lines].join("|");
});
};
