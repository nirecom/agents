#!/bin/bash
# tests/fix-1899-parse-remote-url/detect-forge-type.sh
# Tests: hooks/lib/parse-remote-url.js
# Tags: parse-remote-url, forge, detect-forge-type, gitlab, scope:issue-specific, TL1
#
# Group B of #2307: detectForgeType() is a NEW export on parse-remote-url.js that
# classifies a remote URL's forge from its host. PRE-IMPLEMENTATION: the export
# does NOT exist yet, so every case reports ERR:not-a-function and FAILS.
# NOTE: these turn green once detectForgeType() is added to parse-remote-url.js.
# Contract: detectForgeType(url) -> { type: "github"|"gitlab"|"unknown", host };
# JIRA and other trackers carry no URL, so an empty input classifies as "unknown".

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# call_detect <input> -> detectForgeType(input).type, or ERR:<what> when the
# export is absent / throws. __EMPTY__ carries the empty string (the table cannot).
call_detect() {
    run_with_timeout 20 node -e '
const p = process.argv[1];
let arg = process.argv[2];
if (arg === "__EMPTY__") arg = "";
else if (arg === "__NULL__") arg = null;
else if (arg === "__UNDEFINED__") arg = undefined;
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require-failed"); process.exit(0); }
if (!m || typeof m.detectForgeType !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m.detectForgeType(arg); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
if (r === null || r === undefined || typeof r !== "object") { process.stdout.write("ERR:not-an-object"); process.exit(0); }
process.stdout.write(String(r.type));
' "$PRU_JS" "$1" 2>/dev/null
}

# is_detect_exported -> "yes" | "no" (module contract, B1).
is_detect_exported() {
    run_with_timeout 20 node -e '
const p = process.argv[1];
let m;
try { m = require(p); } catch (e) { process.stdout.write("no"); process.exit(0); }
process.stdout.write(m && typeof m.detectForgeType === "function" ? "yes" : "no");
' "$PRU_JS" 2>/dev/null
}

echo "=== B: detectForgeType() forge classification ==="
assert_eq "B1/detectForgeType is exported" "yes" "$(is_detect_exported)"
assert_eq "B2/github.com -> github" "github" "$(call_detect 'https://github.com/owner/repo.git')"
assert_eq "B3/gitlab.com -> gitlab" "gitlab" "$(call_detect 'https://gitlab.com/owner/repo.git')"
assert_eq "B4/bitbucket.org -> unknown" "unknown" "$(call_detect 'https://bitbucket.org/owner/repo.git')"
assert_eq "B5/empty (JIRA has no URL) -> unknown" "unknown" "$(call_detect '__EMPTY__')"

# B6-B11: URL-shape and lookalike coverage. Host is matched case-insensitively
# against the exact registered hosts, so uppercase resolves and any host that
# merely contains "github.com" (prefix or suffix) must NOT be treated as github.
assert_eq "B6/gitlab SCP form -> gitlab" "gitlab" "$(call_detect 'git@gitlab.com:owner/repo.git')"
assert_eq "B7/uppercase host GitHub.COM -> github" "github" "$(call_detect 'https://GitHub.COM/owner/repo.git')"
assert_eq "B8/lookalike prefix notgithub.com -> unknown" "unknown" "$(call_detect 'https://notgithub.com/owner/repo.git')"
assert_eq "B9/lookalike suffix github.com.evil.com -> unknown" "unknown" "$(call_detect 'https://github.com.evil.com/owner/repo.git')"
assert_eq "B10/null arg -> unknown, no throw" "unknown" "$(call_detect '__NULL__')"
assert_eq "B11/undefined arg -> unknown, no throw" "unknown" "$(call_detect '__UNDEFINED__')"

# B12-B14: case-folding symmetry and hostile-host coverage. The uppercase path
# must resolve for gitlab exactly as B7 proves it does for github (CPR-ORTH), and
# a host that only borrows "gitlab.com"/"github.com" as a suffix or as URL userinfo
# is a different host and must classify "unknown".
assert_eq "B12/uppercase host GITLAB.COM -> gitlab" "gitlab" "$(call_detect 'https://GITLAB.COM/owner/repo.git')"
assert_eq "B13/lookalike suffix gitlab.com.evil.com -> unknown" "unknown" "$(call_detect 'https://gitlab.com.evil.com/owner/repo.git')"
assert_eq "B14/userinfo host github.com@evil.example -> unknown" "unknown" "$(call_detect 'https://github.com@evil.example/owner/repo.git')"

finish
