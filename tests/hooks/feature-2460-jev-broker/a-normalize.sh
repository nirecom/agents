#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js, hooks/lib/jev/registry.js
# Tags: TL2, hooks, jev, broker, registry, prototype-pollution, temp-dir, hook-timeout-budget, scope:issue-specific, pwsh-not-required, in-process-normalize, no-file-write, normalizer-failure
# Fragment of tests/hooks/feature-2460-jev-broker.sh, sourced by it after _lib.sh (not
# standalone): registry own-key lookup, the hook timeout budget, and the in-process normalizer
# (no child process, no file written anywhere, null on every normalizer failure).

echo "=== a point is a registry key only when it is an own key ==="
case_begin "b-registry-entry-own-keys-only" "hooks/lib/jev/registry.js"
fx_new b-entry
check "registryEntry(complexity-judge) is the REGISTRY entry itself" "same-ref" "$(bp entry "$POINT")"
check "inherited names and non-strings are not entries" "null|null|null|null|null|null|null|null|null|null" \
  "$(bp entry '"constructor"' '"__proto__"' '"toString"' '"hasOwnProperty"' 'null' 'undefined' '5' '{}' '""' '["complexity-judge"]')"
check "an unregistered name and a near-miss spelling are not entries" "null|null|null" \
  "$(bp entry '"no-such-point"' '"Complexity-Judge"' '"complexity-judge "')"
case_end

echo "=== probe + query end inside the registered hook timeout; no parser timeout remains ==="
case_begin "b-hook-timeout-budget" "hooks/lib/jev/broker.js"
fx_new b-budget
BUDGET="$(bp budget "$REPO_N/settings.json")"
check "fixture: settings.json registers exactly one pre and one post jev-shadow hook" "1|1" "$(echo "$BUDGET" | cut -d'|' -f1,2)"
check "probe and query timeouts in ms" "2000|6000" "$(echo "$BUDGET" | cut -d'|' -f3,4)"
check "the broker no longer exports PARSER_TIMEOUT_MS or NORM_DIR_PREFIX" "false|false" "$(echo "$BUDGET" | cut -d'|' -f5,6)"
check "their sum is strictly below each hook's timeout from settings.json" "true|true" "$(echo "$BUDGET" | cut -d'|' -f7,8)"
case_end

echo "=== the normalizer runs in-process ==="
case_begin "b-normalize-in-process" "hooks/lib/jev/broker.js"
fx_new b-norm-inproc
check "valid raw text: the parsed CSV, no child process" '"S1-multi-file"|0' "$(bp norm "$POINT" "$RAW")"
check "several signals with spacing: the trimmed CSV, no child process" '"S1-multi-file,S3-security"|0' \
  "$(bp norm "$POINT" '"SIGNALS: S1-multi-file , S3-security"')"
check "a retired third (session id) argument changes nothing" '"S1-multi-file"|0' "$(bp norm "$POINT" "$RAW" '"sid-1"')"
case_end

echo "=== normalizing writes no file anywhere ==="
case_begin "b-normalize-writes-no-file" "hooks/lib/jev/broker.js"
fx_new b-norm-files
mkdir -p "$FX/ostmp"
OSTMP_N="$(np "$FX/ostmp")"
FX_BEFORE="$(fx_tree)"
check "valid raw text with os.tmpdir() at the fixture: parsed, no child process" '"S1-multi-file"|0' \
  "$(bp norm-ostmp "$OSTMP_N" "$POINT" "$RAW")"
check "a retired session id argument: parsed, no child process" '"S1-multi-file"|0' \
  "$(bp norm-ostmp "$OSTMP_N" "$POINT" "$RAW" '"sid-1"')"
check "'SIGNALS: none' and garbage: parsed, no child process" '""|0#"S0-undecidable"|0' \
  "$(bp norm-ostmp "$OSTMP_N" "$POINT" '"SIGNALS: none"')#$(bp norm-ostmp "$OSTMP_N" "$POINT" '"garbage"')"
check "the fixture tree (Jev state dir, workflow control dir, plans dir, OS temp dir) is unchanged" "same" \
  "$([ "$(fx_tree)" = "$FX_BEFORE" ] && echo same || echo "changed: $(fx_tree | tr '\n' ',')")"
check "the OS temp dir is empty; no norm-*, *-signals.txt or *.control entry exists" "|0" \
  "$(names "$FX/ostmp")|$(stray_files)"
case_end

echo "=== an unregistered point never reaches the normalizer ==="
case_begin "b-normalize-unregistered-point" "hooks/lib/jev/broker.js"
fx_new b-norm-unreg
for _pt in '"constructor"' '"__proto__"' '"toString"' '"hasOwnProperty"' '"no-such-point"' 'null' 'undefined'; do
  check "normalizeViaParser($_pt, ...): null, no child process, normalizer not reached" "null|0|false" \
    "$(bp norm-stub real "$_pt" "$RAW")"
done
check "no state dir entry was created" "" "$(names "$FX/state")"
case_end

echo "=== raw text that is empty, absent or not a string ==="
case_begin "b-normalize-empty-raw-text" "hooks/lib/jev/broker.js"
fx_new b-norm-empty
for _raw in '""' 'null' 'undefined' '"garbage only"'; do
  check "raw text $_raw: no throw, the parser's S0-undecidable" '"S0-undecidable"|0' "$(bp norm "$POINT" "$_raw")"
done
check "raw text 'SIGNALS: none' is the empty CSV, not a failure" '""|0' "$(bp norm "$POINT" '"SIGNALS: none"')"
check "a non-string raw value is normalized in its string form: 5 is S0-undecidable" '"S0-undecidable"|0' \
  "$(bp norm "$POINT" '5')"
check "a non-string raw value is normalized in its string form: [\"SIGNALS: S1-multi-file\"] parses" '"S1-multi-file"|0' \
  "$(bp norm "$POINT" '["SIGNALS: S1-multi-file"]')"
check "no stray file left" "0" "$(stray_files)"
case_end

echo "=== a normalizer that throws, cannot load or returns a non-string yields null ==="
case_begin "b-normalize-normalizer-failure" "hooks/lib/jev/broker.js"
fx_new b-norm-fail
for _mode in throw missing nonstring null undefined object; do
  check "normalizer $_mode: null, no child process, the normalizer was reached" "null|0|true" \
    "$(bp norm-stub "$_mode" "$POINT" "$RAW")"
done
check "control: the real normalizer through the same stub path parses" '"S1-multi-file"|0|true' \
  "$(bp norm-stub real "$POINT" "$RAW")"
check "no stray file left" "0" "$(stray_files)"
case_end

case_begin "b-normalize-unusable-state-dir" "hooks/lib/jev/broker.js"
fx_new b-norm-blocked
printf 'not-a-dir' > "$JEVDIR"
check "<state>/jev is a regular file: the normalizer does not need it and still parses" '"S1-multi-file"|0' \
  "$(bp norm "$POINT" "$RAW")"
check "the file is untouched" "not-a-dir" "$(cat "$JEVDIR")"
case_end
