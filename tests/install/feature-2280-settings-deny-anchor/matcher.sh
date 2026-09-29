# tests/install/feature-2280-settings-deny-anchor/matcher.sh
# Tests: settings.json
# Tags: settings, permissions, deny, ssot, scope:issue-specific, pwsh-not-required, TL2
# Deny-side approximation of the host's Bash(...) glob matching (patternToRegExp, ported
# from the retired hooks/lib/settings-allow-match.js). regression-cases.sh pins its
# semantics row by row (C1-C14) rather than trusting it standalone.
# Fails LOUD on unreadable/malformed settings (ERROR:unreadable-settings, E1/E1b) so a
# broken config never masks a #2280-class bug as an allow-all.

DENY_MATCH_JS='
const fs = require("fs");
// BATCHED (see dp_run): request file = NUL-delimited `settings\0command\0` pairs; reply =
// NUL-delimited `verdict\0hits\0` per request. A file, not argv, so MSYS never path-converts
// a command such as G7 `/usr/bin/git ...`. `node -e` shifts args, so take the last one.
const fields = fs.readFileSync(process.argv[process.argv.length - 1], "utf8").split("\0");
fields.pop();
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
function probe(settingsPath, commandText) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch (e) {
    return ["ERROR:unreadable-settings", ""];
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
  return [hits.length ? "MATCHED" : "NO-MATCH", hits.join("\n")];
}
const out = [];
for (let i = 0; i + 1 < fields.length; i += 2) {
  let r;
  try { r = probe(fields[i], fields[i + 1]); }
  catch (e) { r = ["ERROR:node-failed", String(e && e.message)]; }
  out.push(r[0] + "\0" + r[1] + "\0");
}
process.stdout.write(out.join(""));
'

matcher_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# Memoized path conversion: one cygpath per distinct path, not one per row. A path already
# in mixed `X:/...` form is what `cygpath -m` would return unchanged, so it skips the spawn.
declare -A DP_NPATH=()
dp_node_path() {
    if [[ "$1" =~ ^[A-Za-z]:/ ]]; then DP_NODE_PATH="$1"; return 0; fi
    if [[ -z "${DP_NPATH[$1]+x}" ]]; then DP_NPATH[$1]="$(matcher_node_path "$1")"; fi
    DP_NODE_PATH="${DP_NPATH[$1]}"
}

declare -A DP_V=() DP_H=() DP_QUEUED=()
DP_KEYS=(); DP_SETTINGS=(); DP_CMDS=(); DP_SEQ=0

# dp_req <key> <settings-path> <command> -- queue one probe for the next dp_run.
dp_req() {
    if [[ -n "${DP_V[$1]+x}" || -n "${DP_QUEUED[$1]+x}" ]]; then
        echo "FAIL: harness -- duplicate batched deny-probe key [$1]"; exit 1
    fi
    dp_node_path "$2"
    DP_QUEUED[$1]=1; DP_KEYS+=("$1"); DP_SETTINGS+=("$DP_NODE_PATH"); DP_CMDS+=("$3")
}

# dp_run <label> -- evaluate every queued probe in ONE node process. Fewer reply records
# than requests (node crash, truncated output) is a loud harness FAIL, never a short table.
dp_run() {
    local label="$1" n="${#DP_KEYS[@]}" i req out recs=()
    if (( n == 0 )); then echo "FAIL: harness -- $label: empty deny-probe batch"; exit 1; fi
    DP_SEQ=$((DP_SEQ + 1))
    dp_node_path "$TMPROOT"
    req="$DP_NODE_PATH/dp-req-$DP_SEQ.bin"; out="$DP_NODE_PATH/dp-out-$DP_SEQ.bin"
    for ((i = 0; i < n; i++)); do
        printf '%s\0%s\0' "${DP_SETTINGS[$i]}" "${DP_CMDS[$i]}"
    done > "$req"
    node -e "$DENY_MATCH_JS" "$req" > "$out" 2> "$out.err"
    mapfile -d '' -t recs < "$out"
    if (( ${#recs[@]} != 2 * n )); then
        echo "FAIL: harness -- $label: deny batch returned ${#recs[@]} records for $n requests (want $((2 * n)))"
        echo "    stderr: $(head -c 2000 "$out.err")"
        exit 1
    fi
    for ((i = 0; i < n; i++)); do
        DP_V[${DP_KEYS[$i]}]="${recs[2 * i]}"; DP_H[${DP_KEYS[$i]}]="${recs[2 * i + 1]}"
    done
    DP_KEYS=(); DP_SETTINGS=(); DP_CMDS=(); DP_QUEUED=()
}

# dp_get <key> -- sets DENY_VERDICT (MATCHED / NO-MATCH / ERROR:*) and DENY_HITS
# (newline-separated matching deny patterns, empty when none) for a batched probe.
dp_get() {
    if [[ -z "${DP_V[$1]+x}" ]]; then
        echo "FAIL: harness -- no batched deny verdict for key [$1]"; exit 1
    fi
    DENY_VERDICT="${DP_V[$1]}"; DENY_HITS="${DP_H[$1]}"
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

# Emits `<count>\0<entry>\0...` -- the string entries of permissions.deny. Unreadable or
# non-array deny emits count 0, so every lookup answers "no" exactly as before.
DENY_HAS_JS='
const fs = require("fs");
let deny = [];
try {
  const parsed = JSON.parse(fs.readFileSync(process.argv[process.argv.length - 1], "utf8"));
  const rawDeny = parsed && parsed.permissions && parsed.permissions.deny;
  deny = Array.isArray(rawDeny) ? rawDeny.filter((e) => typeof e === "string") : [];
} catch (e) { deny = []; }
process.stdout.write([String(deny.length), ...deny].map((s) => s + "\0").join(""));
'
declare -A DLH_LOADED=() DLH_SET=()
deny_list_load() {
    local settings="$1" recs=() i n
    dp_node_path "$settings"
    mapfile -d '' -t recs < <(node -e "$DENY_HAS_JS" "$DP_NODE_PATH")
    n="${recs[0]:-}"
    if [[ ! "$n" =~ ^[0-9]+$ ]] || (( ${#recs[@]} != n + 1 )); then
        echo "FAIL: harness -- deny_list_has: permissions.deny load returned ${#recs[@]} records, header [$n]"
        exit 1
    fi
    for ((i = 1; i <= n; i++)); do DLH_SET["$settings"$'\x1f'"${recs[$i]}"]=1; done
    DLH_LOADED[$settings]=1
}

# deny_list_has <settings-path> <bare-pattern> — does permissions.deny (ONLY that array,
# never permissions.allow or any other key) carry the literal rule `Bash(<bare-pattern>)`?
# A whole-file grep would false-positive on an identical literal living under
# permissions.allow; parsing JSON and checking membership in the deny array specifically
# is what the assertion actually claims. Lets a row name its target pattern before
# write-code lands without fabricating a match against a rule that does not exist yet.
# The deny array is loaded once per settings path (the file is never rewritten mid-run).
deny_list_has() {
    [[ -n "${DLH_LOADED[$1]+x}" ]] || deny_list_load "$1"
    [[ -n "${DLH_SET["$1"$'\x1f'"Bash($2)"]+x}" ]]
}
