// Helper for tests/enforce-off-clearance-lifecycle.sh.
//
// In a FILE rather than a `node -e` body on purpose: every string this touches
// spells an OFF-clearance name, and hooks/block-off-clearance-write.js blocks any
// interpreter body that does. Suffixes are taken from the SSOT
// (hooks/lib/protected-basenames.js) at runtime, never hardcoded.
//
// Modes (argv[2]); AGENTS_DIR comes from argv[3] in every mode:
//   contract  <agents> <dir>                  deterministic consumeExactFile table
//   mktoken   <agents> <dir> <sid> <target> <category>   mint a valid bare token
//   mkmarker  <agents> <dir> <sid> [ageMs]    write an EMERGENCY provenance marker
//   race-consume <agents> <file> <rawFile> <outFile>     one consumeExactFile racer
//   race-prov <agents> <dir> <sid> <target> <outFile>    one provenance racer
//   prov-once <agents> <dir> <sid> <target>   print the provenance value once
//   tokenpath <agents> <dir> <sid> [.suffix-index]       print a protected path
"use strict";

const fs = require("fs");
const path = require("path");

const mode = process.argv[2];
const agentsDir = process.argv[3];
const H = (...p) => path.join(agentsDir, "hooks", ...p);
const rest = process.argv.slice(4);

const { consumeExactFile } = require(H("lib", "consume-exact-file.js"));
const pb = require(H("lib", "protected-basenames.js"));

const TOKEN_SUF = pb.OFF_CLEARANCE_TOKEN_SUFFIXES[0];
const CLAIMED_SUF = TOKEN_SUF + ".claimed";
const MARKER_KIND = pb.EMERGENCY_PROVENANCE_MARKER_KIND;

function claimPathOf(filePath, raw) {
  const crypto = require("crypto");
  const id = crypto.createHash("sha256").update(String(raw)).digest("hex").slice(0, 16);
  return `${filePath}.consuming-${id}.tmp`;
}

function contract(dir) {
  const out = [];
  const emit = (k, v) => out.push(k + "=" + v);
  const f = (name) => path.join(dir, name);
  const exists = (p) => fs.existsSync(p);

  // consumed: the exact bytes inspected are the bytes removed.
  fs.writeFileSync(f("a"), "AAA");
  emit("consumed", consumeExactFile(f("a"), "AAA"));
  emit("consumed_gone", !exists(f("a")));
  emit("consumed_no_claim_left", fs.readdirSync(dir).filter((n) => n.indexOf(".consuming-") !== -1).length === 0);

  // lost: the pathname now holds DIFFERENT bytes — the caller inspected a record
  // that is no longer there, so nothing may be removed on its behalf.
  fs.writeFileSync(f("b"), "NEW");
  emit("lost_changed", consumeExactFile(f("b"), "OLD"));
  emit("lost_changed_preserved", fs.readFileSync(f("b"), "utf8") === "NEW");

  // lost: already gone. ENOENT is NOT success — someone else consumed it.
  emit("lost_absent", consumeExactFile(f("c"), "ANY"));

  // lost: another consumer holds the claim for these exact bytes.
  fs.writeFileSync(f("d"), "DDD");
  const held = claimPathOf(f("d"), "DDD");
  fs.writeFileSync(held, "");
  emit("lost_contended", consumeExactFile(f("d"), "DDD"));
  emit("lost_contended_preserved", exists(f("d")));

  // ...and the claim is keyed to the CONTENT, so a claim left over from an older
  // record at the same pathname does not block a genuinely new record.
  fs.writeFileSync(f("d"), "EEE");
  emit("content_keyed", consumeExactFile(f("d"), "EEE"));
  try { fs.unlinkSync(held); } catch (_e) {}

  // failed: a non-string expectation cannot identify anything.
  fs.writeFileSync(f("e"), "EEE");
  emit("failed_nonstring", consumeExactFile(f("e"), null));
  emit("failed_nonstring_preserved", exists(f("e")));
  emit("failed_undefined", consumeExactFile(f("e"), undefined));
  emit("failed_object", consumeExactFile(f("e"), { toString: () => "EEE" }));
  emit("failed_preserved_after_all", exists(f("e")));

  // empty string is a legitimate expectation, not a falsy no-op.
  fs.writeFileSync(f("g"), "");
  emit("consumed_empty", consumeExactFile(f("g"), ""));
  emit("consumed_empty_gone", !exists(f("g")));

  process.stdout.write(out.join("\n") + "\n");
}

function mktoken(dir, sid, target, category) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, sid + TOKEN_SUF), JSON.stringify({
    target,
    category,
    urgency: "normal",
    minted_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + 15 * 60000).toISOString(),
    verdict_reason: "examiner ALLOW",
    detail: "stub",
  }));
}

function mkmarker(dir, sid, ageMs) {
  const { buildProvenanceMarker } = require(H("lib", "off-emergency-provenance.js"));
  fs.mkdirSync(dir, { recursive: true });
  const age = Number(ageMs || 0);
  fs.writeFileSync(path.join(dir, `${sid}.${MARKER_KIND}`), JSON.stringify(buildProvenanceMarker(Date.now() - age)));
}

function raceConsume(file, rawFile, outFile) {
  const expected = fs.readFileSync(rawFile, "utf8");
  fs.writeFileSync(outFile, consumeExactFile(file, expected));
}

function provOnce(dir, sid, target) {
  process.env.CLAUDE_WORKFLOW_DIR = dir;
  process.env.WORKFLOW_PLANS_DIR = dir;
  const { resolveEmergencyProvenance } = require(
    H("workflow-mark", "enforce-override-handlers", "off-clearance.js"));
  return resolveEmergencyProvenance(sid, target);
}

switch (mode) {
  case "contract": contract(rest[0]); break;
  case "mktoken": mktoken(rest[0], rest[1], rest[2], rest[3]); break;
  case "mkmarker": mkmarker(rest[0], rest[1], rest[2]); break;
  case "race-consume": raceConsume(rest[0], rest[1], rest[2]); break;
  case "race-prov": fs.writeFileSync(rest[3], provOnce(rest[0], rest[1], rest[2])); break;
  case "prov-once": process.stdout.write(provOnce(rest[0], rest[1], rest[2]) + "\n"); break;
  case "suffixes": process.stdout.write(TOKEN_SUF + " " + CLAIMED_SUF + " ." + MARKER_KIND + "\n"); break;
  default:
    process.stderr.write("unknown mode: " + String(mode) + "\n");
    process.exit(3);
}
