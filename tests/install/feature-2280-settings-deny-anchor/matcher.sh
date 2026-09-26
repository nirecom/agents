# tests/install/feature-2280-settings-deny-anchor/matcher.sh
# Tests: settings.json, hooks/lib/settings-allow-match.js
# Tags: settings, permissions, deny, ssot, scope:issue-specific, pwsh-not-required, TL2
# Deny-side mirror of hooks/lib/settings-allow-match.js:62-83 (patternToRegExp); an
# approximation itself (allow-side origin), so regression-cases.sh cross-checks this
# mirror against the real module rather than trusting it standalone.
# DIVERGENCE (intentional): isAllowRuleMatch fails OPEN on unreadable/malformed
# settings; this deny-side mirror fails LOUD instead (ERROR:unreadable-settings,
# E1/E1b below) so a broken config never masks a #2280-class bug as an allow-all.

DENY_MATCH_JS='
const fs = require("fs");
// `node -e` shifts extra args down one slot vs a script file; slice from the end instead.
const [settingsPath, commandText] = process.argv.slice(-2);
const WORD = "A-Za-z0-9_";
function wildcardFor(precedingChar) {
  const guard = new RegExp("[" + WORD + "]").test(precedingChar || "") ? "(?![" + WORD + "])" : "";
  return guard + ".*";
}
function patternToRegExp(pattern) {
  let source = "";
  let i = 0;
  while (i < pattern.length) {
    if (pattern[i] === "*") {
      const preceding = i > 0 ? pattern[i - 1] : "";
      while (pattern[i] === "*") i++;
      source += wildcardFor(preceding);
      continue;
    }
    source += pattern[i].replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    i++;
  }
  return new RegExp("^" + source + "$", "s");
}
const BASH_RULE_RE = /^Bash\((.*)\)$/;
let parsed;
try {
  parsed = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
} catch (e) {
  console.log("ERROR:unreadable-settings");
  process.exit(0);
}
// Array.isArray mirrors readAllowPatterns(): a non-array `deny` (string, object, number)
// degrades to "no rules", never to an iteration crash.
const rawDeny = parsed && parsed.permissions && parsed.permissions.deny;
const deny = Array.isArray(rawDeny) ? rawDeny : [];
const hits = [];
for (const entry of deny) {
  if (typeof entry !== "string") continue;
  const m = BASH_RULE_RE.exec(entry.trim());
  if (!m) continue;
  if (patternToRegExp(m[1]).test(String(commandText).trim())) hits.push(m[1]);
}
console.log(hits.length ? "MATCHED" : "NO-MATCH");
for (const h of hits) console.log(h);
'

matcher_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# deny_probe <settings-path> <command>
# Sets DENY_VERDICT (MATCHED / NO-MATCH / ERROR:*) and DENY_HITS (newline-separated
# matching deny patterns, empty when none).
deny_probe() {
    local settings="$1" cmd="$2" out npath
    npath="$(matcher_node_path "$settings")"
    out="$(node -e "$DENY_MATCH_JS" "$npath" "$cmd" 2>&1)" || {
        DENY_VERDICT="ERROR:node-failed"; DENY_HITS="$out"; return 0
    }
    DENY_VERDICT="$(printf '%s\n' "$out" | sed -n '1p')"
    DENY_HITS="$(printf '%s\n' "$out" | sed -n '2,$p')"
}

# deny_hits_contain <bare-pattern> — is <bare-pattern> among the patterns DENY_HITS holds?
deny_hits_contain() {
    printf '%s\n' "$DENY_HITS" | grep -Fqx -- "$1"
}

# row_is_well_formed <row> <expected-field-count> — a `@@`-delimited table row is usable
# only when it splits into exactly the schema's field count and no field is empty. A
# dropped or doubled separator otherwise reshapes a row into a different, still-runnable
# assertion, which would pass silently without moving ROWS_EXPECTED.
row_is_well_formed() {
    local row="$1" want="$2" n=0 field
    while :; do
        field="${row%%@@*}"
        [ -n "$field" ] || return 1
        n=$((n + 1))
        case "$row" in *@@*) row="${row#*@@}" ;; *) break ;; esac
    done
    [ "$n" = "$want" ]
}

DENY_HAS_JS='
const fs = require("fs");
const [settingsPath, literal] = process.argv.slice(-2);
let parsed;
try { parsed = JSON.parse(fs.readFileSync(settingsPath, "utf8")); }
catch (e) { console.log("no"); process.exit(0); }
const rawDeny = parsed && parsed.permissions && parsed.permissions.deny;
const deny = Array.isArray(rawDeny) ? rawDeny : [];
console.log(deny.includes(literal) ? "yes" : "no");
'

# deny_list_has <settings-path> <bare-pattern> — does permissions.deny (ONLY that array,
# never permissions.allow or any other key) carry the literal rule `Bash(<bare-pattern>)`?
# A whole-file grep would false-positive on an identical literal living under
# permissions.allow; parsing JSON and checking membership in the deny array specifically
# is what the assertion actually claims. Lets a row name its target pattern before
# write-code lands without fabricating a match against a rule that does not exist yet.
deny_list_has() {
    local out
    out="$(node -e "$DENY_HAS_JS" "$(matcher_node_path "$1")" "Bash($2)" 2>&1)"
    [ "$out" = "yes" ]
}
