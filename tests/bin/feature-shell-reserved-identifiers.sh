#!/usr/bin/env bash
# Tests: bin/, hooks/, skills/, install.sh
# Tags: TL1, lint, shell, reserved-identifiers, scope:common, pwsh-not-required
# Lint (#2475): never assign to an OS/shell-exported name; RESERVED in detect.js is the SSOT list.
# Forms: (a) [export|local|declare|readonly] NAME=/+=, (b) read operands incl. -a NAME,
#   (c) printf -v NAME, (d) for NAME in. Named exception: PATH whose RHS references $PATH.
# Out of scope: mapfile/readarray, getopts, (( NAME = ... )) — no such usage in the repo.
# tests/ is excluded: fixtures assign HOME=/PATH=/PROMPT= on purpose for isolation.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

SRI_TMP="$(make_tmp)"
trap 'rm -rf "$SRI_TMP"' EXIT
DETECT_JS="$SRI_TMP/detect.js"

cat > "$DETECT_JS" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const RESERVED = ['PROMPT', 'TMP', 'TEMP', 'TMPDIR', 'HOME', 'OS', 'COMSPEC',
  'SHELL', 'PWD', 'USER', 'USERNAME', 'USERPROFILE', 'APPDATA', 'SYSTEMROOT',
  'WINDIR', 'PATHEXT', 'HOSTNAME', 'PATH'];
const RES = new Set(RESERVED);
const READ_VALUE_OPTS = new Set(['d', 'i', 'n', 'N', 'p', 't', 'u']);

function tokenize(s) {
  const out = [];
  let i = 0;
  while (i < s.length) {
    while (i < s.length && /\s/.test(s[i])) i++;
    if (i >= s.length) break;
    if (/[<>;|&)]/.test(s[i])) break;
    let tok = '';
    while (i < s.length && !/[\s<>;|&)]/.test(s[i])) {
      const c = s[i];
      if (c === "'" || c === '"') {
        const end = s.indexOf(c, i + 1);
        const stop = end < 0 ? s.length : end;
        tok += s.slice(i + 1, stop);
        i = stop + 1;
      } else {
        tok += c;
        i++;
      }
    }
    out.push(tok);
  }
  return out;
}

function readNames(rest) {
  const toks = tokenize(rest);
  const names = [];
  for (let k = 0; k < toks.length; k++) {
    const t = toks[k];
    if (t.startsWith('-') && t.length > 1) {
      const last = t[t.length - 1];
      if (last === 'a') { if (k + 1 < toks.length) names.push(toks[++k]); continue; }
      if (READ_VALUE_OPTS.has(last)) k++;
      continue;
    }
    names.push(t);
  }
  return names;
}

// Returns the reserved names a single line assigns to.
function detect(line) {
  const hits = [];
  if (/^\s*#/.test(line)) return hits;
  const a = line.match(/^\s*(?:(?:export|local|readonly|declare(?:\s+-[A-Za-z]+)*)\s+)?([A-Za-z_][A-Za-z0-9_]*)\+?=(.*)$/);
  if (a && RES.has(a[1])) {
    const selfRef = /\$PATH\b|\$\{PATH\}/.test(a[2]);
    if (!(a[1] === 'PATH' && selfRef)) hits.push(a[1]);
  }
  const readRe = /(?:^|[;&|(]|\b(?:while|until|if|do|then)\s|!\s)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*read\s+(.*)$/;
  const r = line.match(readRe);
  if (r) for (const n of readNames(r[1])) if (RES.has(n)) hits.push(n);
  const p = line.match(/(?:^|[;&|(]|\s)printf\s+-v\s+([A-Za-z_][A-Za-z0-9_]*)/);
  if (p && RES.has(p[1])) hits.push(p[1]);
  const f = line.match(/(?:^|[;&|(]|\s)for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b/);
  if (f && RES.has(f[1])) hits.push(f[1]);
  return hits;
}

function isShellFile(root, rel) {
  if (rel.endsWith('.sh')) return true;
  if (path.basename(rel).includes('.')) return false;
  try {
    const head = fs.readFileSync(path.join(root, rel), 'utf8').split('\n', 1)[0];
    return /^#!.*\b(?:bash|sh)\b/.test(head);
  } catch (_) { return false; }
}

const [mode, arg1, arg2] = process.argv.slice(2);
if (mode === 'line') {
  const hits = detect(fs.readFileSync(arg1, 'utf8').replace(/\n$/, ''));
  process.stdout.write(hits.length ? 'violation ' + hits.join(',') : 'ok');
} else if (mode === 'files' || mode === 'scan') {
  const root = arg1;
  const prefix = arg2;
  const files = execFileSync('git', ['-C', root, 'ls-files'], { encoding: 'utf8' })
    .split('\n').filter(Boolean)
    .filter((f) => !f.startsWith('tests/'))
    .filter((f) => (prefix.endsWith('/') ? f.startsWith(prefix) : f === prefix))
    .filter((f) => isShellFile(root, f));
  if (mode === 'files') { for (const f of files) console.log(`FILE ${f}`); process.exit(0); }
  let n = 0;
  for (const rel of files) {
    let text;
    try { text = fs.readFileSync(path.join(root, rel), 'utf8'); } catch (_) { continue; }
    text.split('\n').forEach((ln, idx) => {
      const hits = detect(ln);
      if (hits.length) { n++; console.log(`${rel}:${idx + 1}: ${hits.join(',')}`); }
    });
  }
  console.log(`SCANNED ${files.length}`);
  process.exitCode = n ? 1 : 0;
}
JS

LINE_FILE="$SRI_TMP/line.txt"

# check_line <label> <line> <want: violation|ok>
check_line() {
  local label="$1" line="$2" want="$3" got got_kind
  printf '%s\n' "$line" > "$LINE_FILE"
  got="$(run_with_timeout 20 node "$(np "$DETECT_JS")" line "$(np "$LINE_FILE")" 2>&1)"
  case "$got" in
    violation*) got_kind=violation ;;
    ok) got_kind=ok ;;
    *) fail "$label" "detector error: $got"; return ;;
  esac
  if [ "$got_kind" = "$want" ]; then
    pass "$label"
  else
    fail "$label" "want=$want got=$got line=$line"
  fi
}

# scan_dir <label> <prefix>
scan_dir() {
  local label="$1" prefix="$2" out rc
  out="$(run_with_timeout 60 node "$(np "$DETECT_JS")" scan "$(np "$AGENTS_DIR")" "$prefix" 2>&1)"
  rc=$?
  if ! printf '%s\n' "$out" | grep -q '^SCANNED [1-9]'; then
    fail "$label" "scan did not complete or matched no file (rc=$rc): $out"
    return
  fi
  if [ "$rc" -eq 0 ]; then
    pass "$label ($(printf '%s\n' "$out" | tail -n 1))"
  else
    fail "$label" "reserved-identifier assignments:
$(printf '%s\n' "$out" | grep -v '^SCANNED ')"
  fi
}

echo "=== shell reserved identifiers lint ==="

case_begin "selftest-violations" "bin/"
check_line "V1 PROMPT= plain" 'PROMPT="x"' violation
check_line "V2 export TMP= indented" '  export TMP=/tmp/a' violation
check_line "V3 local HOME=" 'local HOME="$d"' violation
check_line "V4 PROMPT+= append" "PROMPT+=\$'\\n'" violation
check_line "V5 PATH= without self-reference" 'PATH=/usr/bin' violation
check_line "V6 read -r PROMPT" 'read -r PROMPT' violation
check_line "V7 IFS= read -d '' TMP" "IFS= read -r -d '' TMP < f" violation
check_line "V8 printf -v PROMPT" "printf -v PROMPT '%s' x" violation
check_line "V9 for PATH in" 'for PATH in a b; do' violation
check_line "V10 read -a HOME array" 'read -r -a HOME <<< "$x"' violation
check_line "V11 declare -g PROMPT=" 'declare -g PROMPT=x' violation
check_line "V12 PATHEXT reference is not a PATH self-reference" 'PATH="$PATHEXT"' violation
case_end

case_begin "selftest-allowed" "bin/"
check_line "A1 PATH append via \${PATH}" 'export PATH="${PATH}:${SCRIPT_DIR}"' ok
check_line "A2 PATH prepend via \$PATH" 'export PATH="$HOME/.local/bin:$PATH"' ok
check_line "A3 prefixed CODEX_PROMPT=" 'CODEX_PROMPT="x"' ok
check_line "A4 IFS= read -r line" 'IFS= read -r line' ok
check_line "A5 read -p value is not a name" 'read -r -p "PROMPT? " ans' ok
check_line "A6 printf -v CODEX_PROMPT" "printf -v CODEX_PROMPT '%s' x" ok
check_line "A7 comment" '# PROMPT= in comment' ok
check_line "A8 echo string" 'echo "PROMPT=x"' ok
check_line "A9 lowercase tmp=" 'tmp="$(mktemp)"' ok
case_end

case_begin "scan-coverage-extensionless" "bin/"
# False-green guard: the scan must reach extensionless shebang scripts, not only *.sh.
SRI_FILES="$(run_with_timeout 60 node "$(np "$DETECT_JS")" files "$(np "$AGENTS_DIR")" bin/ 2>&1)"
for f in bin/review-plan-codex bin/supervisor-findings-codex bin/lib/codex-core.sh; do
  if printf '%s\n' "$SRI_FILES" | grep -qx "FILE $f"; then pass "scan set includes $f"; else fail "scan set includes $f" "not listed"; fi
done
SRI_FX="$SRI_TMP/fixture-repo"
mkdir -p "$SRI_FX/bin"
git -C "$SRI_FX" init -q
git -C "$SRI_FX" config core.hooksPath /dev/null
printf '%s\n' '#!/usr/bin/env bash' 'PROMPT="planted"' > "$SRI_FX/bin/extless-tool"
printf '%s\n' '#!/usr/bin/env node' 'PROMPT="not shell"' > "$SRI_FX/bin/node-tool"
printf '%s\n' 'PROMPT="data file"' > "$SRI_FX/bin/notes.txt"
git -C "$SRI_FX" add -A
SRI_FX_OUT="$(run_with_timeout 60 node "$(np "$DETECT_JS")" scan "$(np "$SRI_FX")" bin/ 2>&1)"
SRI_FX_RC=$?
if [ "$SRI_FX_RC" -eq 1 ]; then pass "planted fixture: scan exits 1"; else fail "planted fixture: scan exits 1" "rc=$SRI_FX_RC out=$SRI_FX_OUT"; fi
if printf '%s\n' "$SRI_FX_OUT" | grep -qx 'bin/extless-tool:2: PROMPT'; then pass "planted fixture: extensionless bash script violation detected"; else fail "planted fixture: extensionless bash script violation detected" "out=$SRI_FX_OUT"; fi
if printf '%s\n' "$SRI_FX_OUT" | grep -q 'node-tool\|notes.txt'; then fail "planted fixture: non-shell files not scanned" "out=$SRI_FX_OUT"; else pass "planted fixture: non-shell files not scanned"; fi
if printf '%s\n' "$SRI_FX_OUT" | grep -qx 'SCANNED 1'; then pass "planted fixture: exactly one shell file scanned"; else fail "planted fixture: exactly one shell file scanned" "out=$SRI_FX_OUT"; fi
case_end

case_begin "repo-scan-bin" "bin/"
scan_dir "scan bin/ has no reserved-identifier assignment" bin/
case_end

case_begin "repo-scan-hooks" "hooks/"
scan_dir "scan hooks/ has no reserved-identifier assignment" hooks/
case_end

case_begin "repo-scan-skills" "skills/"
scan_dir "scan skills/ has no reserved-identifier assignment" skills/
case_end

case_begin "repo-scan-install" "install.sh"
scan_dir "scan install.sh has no reserved-identifier assignment" install.sh
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
