"use strict";
// Tests: bin/scan-outbound.sh, bin/scan-outbound.d/cli.js, hooks/lib/ere/translate.js, hooks/lib/ere/longest.js, hooks/lib/outbound-scan/glob.js, hooks/lib/outbound-scan/hard-secret-patterns.js, hooks/lib/outbound-scan/scan-text.js, hooks/pre-commit.d/checks/outbound-scan.js, hooks/pre-commit.d/checks/outbound-scan/binary.js, hooks/workflow-state/complexity-routing/secret-shape.js
// Tags: TL1, TL2, scan-outbound, pre-commit, ere-translation, leftmost-longest, golden, binary-detection, hard-secret-patterns, fail-closed, test-lang-exception:e2e, scope:issue-specific
// #2507 D5/D6: the Node port of scan-outbound must reproduce the bash scanner recorded in golden/
// (made by generate-golden.js from synthetic lists only). The assumed module contracts are listed
// beside the module paths in feature-2507-scan-outbound-node/common.js; every case loads its module
// inside the test, so a missing module or export fails that case alone.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const { after, before, test } = require("node:test");
const SB = require("./feature-2507-scan-outbound-node/sandbox");
const ere = require("./feature-2507-scan-outbound-node/ere");
const gb = require("./feature-2507-scan-outbound-node/glob-binary");
const ssot = require("./feature-2507-scan-outbound-node/ssot-skip");
const st = require("./feature-2507-scan-outbound-node/scan-text");
const cli = require("./feature-2507-scan-outbound-node/cli-golden");
const mf = require("./feature-2507-scan-outbound-node/manifest-cases");

const restore = isolate();
let root = null;
before(() => {
  root = SB.createSandbox();
});
after(() => {
  restore();
  if (root) SB.removeSandbox(root);
});

caseBegin("ere-translation-table", "hooks/lib/ere/translate.js");
test("1 ERE translation matches bash: valid / invalid / untranslatable, u flag, no i flag", () => ere.runTranslate());
caseEnd();

caseBegin("ere-leftmost-longest", "hooks/lib/ere/longest.js");
test("2 leftmost-longest returns BASH_REMATCH[0] for every golden match", () => ere.runLongest());
caseEnd();

caseBegin("ere-word-shorthand-gnu", "hooks/lib/ere/translate.js");
test("2b \\w is GNU [_[:alnum:]], \\W its complement, both agree with \\b \\< \\>", () => ere.runWordShorthand());
caseEnd();

caseBegin("ere-word-shorthand-scanner-lists", "bin/scan-outbound.sh");
test("2c \\w / \\W in blocklist and allowlist files: the CLI detects and allows _ words as GNU does", () => ere.runWordShorthandScanner(root));
caseEnd();

caseBegin("allowlist-file-glob", "hooks/lib/outbound-scan/glob.js");
test("3 file:value glob equals bash [[ f == g ]]", () => gb.runGlob());
caseEnd();

caseBegin("binary-skip-golden", "hooks/pre-commit.d/checks/outbound-scan/binary.js");
test("4 isBinary equals git show | file --mime - | grep binary (empty, gitlink, symlink target, window)", () => gb.runBinary());
caseEnd();

caseBegin("skip-patterns-and-self-scan", "hooks/pre-commit.d/checks/outbound-scan.js");
test("5 SKIP_PATTERNS unchanged and the new modules scan clean", () => ssot.runSkipAndSelfScan(root));
caseEnd();

caseBegin("hard-secret-patterns-ssot", "hooks/lib/outbound-scan/hard-secret-patterns.js");
test("6a the pattern SSOT equals the bash block", () => ssot.runHardSecretTable());
caseEnd();

caseBegin("secret-shape-reads-ssot", "hooks/workflow-state/complexity-routing/secret-shape.js");
test("6b secret-shape and scanText share the SSOT; empty or unreadable throws", () => ssot.runHardSecretShared());
caseEnd();

caseBegin("hard-secret-shape-table", "bin/scan-outbound.sh");
test("6c each of the 11 patterns has a hit and a near miss whose labels equal the bash golden", () => ssot.runHardSecretShapeTable());
caseEnd();

caseBegin("hard-secret-shape-scan", "hooks/lib/outbound-scan/scan-text.js");
test("6d scanText reports each hit and no near miss, as bash did", () => ssot.runHardSecretShapeScan());
caseEnd();

caseBegin("scan-text-line-handling", "hooks/lib/outbound-scan/scan-text.js");
test("7 \\n split keeps \\r, last line without newline, UTF-8, zero-width / bidi ranges", () => st.runLines());
caseEnd();

caseBegin("untranslatable-ere-fail-closed-cli", "bin/scan-outbound.d/cli.js");
test("8a an untranslatable valid ERE gives rc 4 with a reason and scans no line", () => st.runFailClosedCli(root));
caseEnd();

caseBegin("untranslatable-ere-fail-closed-precommit", "hooks/pre-commit.d/checks/outbound-scan.js");
test("8b the pre-commit outbound-scan check stops with today's rc 4 wording", () => st.runFailClosedPrecommit());
caseEnd();

caseBegin("d5-result-shape", "hooks/lib/outbound-scan/scan-text.js");
test("9a scanText returns the D5 shape: verdict, messages, findings, incomplete", () => st.runResultShape());
caseEnd();

caseBegin("cli-rc-mapping", "bin/scan-outbound.d/cli.js");
test("9b the in-process CLI maps clean/hard/warn/usage/no-blocklist to rc 0-4", () => st.runRcMapping(root));
caseEnd();

caseBegin("cli-golden-corpus", "bin/scan-outbound.sh");
test("10 bin/scan-outbound.sh reproduces the golden in --stdin, --manifest and file mode", () => cli.runGolden(root));
caseEnd();

caseBegin("manifest-sane-frames-golden", "bin/scan-outbound.sh");
test("12a empty body, truncated last body, missing leading RS: equal the bash golden", () => mf.runManifestGolden(root));
caseEnd();

caseBegin("manifest-broken-frame-fail-closed", "bin/scan-outbound.sh");
test("12b a broken --manifest frame, followed or alone, stops the scan with rc 4", () => mf.runManifestFailClosed(root));
caseEnd();

caseBegin("adapter-without-node", "bin/scan-outbound.sh");
test("11 with no node on PATH the adapter exits rc 4 and scans nothing", () => cli.runNoNode(root));
caseEnd();
