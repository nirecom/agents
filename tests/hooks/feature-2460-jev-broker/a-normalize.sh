#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js, hooks/lib/jev/registry.js
# Tags: TL2, hooks, jev, broker, registry, prototype-pollution, temp-dir, hook-timeout-budget, scope:issue-specific, pwsh-not-required
# Fragment of tests/hooks/feature-2460-jev-broker.sh, sourced by it after _lib.sh (not
# standalone): registry own-key lookup, the hook timeout budget, and the parser's temp dir.

echo "=== a point is a registry key only when it is an own key ==="
case_begin "b-registry-entry-own-keys-only" "hooks/lib/jev/registry.js"
fx_new b-entry
check "registryEntry(complexity-judge) is the REGISTRY entry itself" "same-ref" "$(bp entry "$POINT")"
check "inherited names and non-strings are not entries" "null|null|null|null|null|null|null|null|null|null" \
  "$(bp entry '"constructor"' '"__proto__"' '"toString"' '"hasOwnProperty"' 'null' 'undefined' '5' '{}' '""' '["complexity-judge"]')"
check "an unregistered name and a near-miss spelling are not entries" "null|null|null" \
  "$(bp entry '"no-such-point"' '"Complexity-Judge"' '"complexity-judge "')"
case_end

echo "=== probe + query + parser end inside the registered hook timeout ==="
case_begin "b-hook-timeout-budget" "hooks/lib/jev/broker.js"
fx_new b-budget
BUDGET="$(bp budget "$REPO_N/settings.json")"
check "fixture: settings.json registers exactly one pre and one post jev-shadow hook" "1|1" "$(echo "$BUDGET" | cut -d'|' -f1,2)"
check "probe, query and parser timeouts in ms" "2000|6000|4000" "$(echo "$BUDGET" | cut -d'|' -f3-5)"
check "their sum is strictly below each hook's timeout from settings.json" "true|true" "$(echo "$BUDGET" | cut -d'|' -f6,7)"
case_end

echo "=== the parser's temp dir sits under the session's state dir ==="
case_begin "b-normalize-session-scoped-dir" "hooks/lib/jev/broker.js"
fx_new b-norm-sid
check "valid session id: parsed CSV, raw file under <state>/jev/sid-1/norm-*, parser timeout applied" \
  '"S1-multi-file"|sid-1/norm-XXXXXX|true|"SIGNALS: S1-multi-file"' "$(bp norm "$POINT" "$RAW" '"sid-1"')"
check "afterwards the session dir exists and is empty; no norm dir anywhere" "jev|sid-1||0" \
  "$(names "$FX/state")|$(names "$JEVDIR")|$(names "$JEVDIR/sid-1")|$(norm_left)"
check "two calls in one process: both parse, each in its own dir, none left" '"S1-multi-file"|"S1-multi-file"|2|2|0' \
  "$(bp norm-twice "$POINT" "$RAW" '"sid-1"')|$(norm_left)"
case_end

case_begin "b-normalize-invalid-session-falls-back-to-state-root" "hooks/lib/jev/broker.js"
fx_new b-norm-root
FX_BEFORE="$(names "$FX")"
check "two-argument call: parsed CSV, raw file under <state>/jev/norm-*" \
  '"S1-multi-file"|norm-XXXXXX|true|"SIGNALS: S1-multi-file"' "$(bp norm2 "$POINT" "$RAW")"
for _sid in '"../x"' '""' '"."' '"a/b"' 'null' '"..\\x"'; do
  check "session id $_sid: parsed CSV, raw file under <state>/jev/norm-*" \
    '"S1-multi-file"|norm-XXXXXX|true|"SIGNALS: S1-multi-file"' "$(bp norm "$POINT" "$RAW" "$_sid")"
done
check "nothing was created outside <state>/jev, and <state>/jev is empty again" "true|jev||0" \
  "$([ "$(names "$FX")" = "$FX_BEFORE" ] && echo true || echo "false: $(names "$FX")")|$(names "$FX/state")|$(names "$JEVDIR")|$(norm_left)"
case_end

case_begin "b-normalize-ignores-os-tmpdir" "hooks/lib/jev/broker.js"
fx_new b-norm-ostmp
check "os.tmpdir() points at a missing dir (false) and the parse still succeeds under the state dir" \
  'false|"S1-multi-file"|sid-1/norm-XXXXXX|true|"SIGNALS: S1-multi-file"' \
  "$(bp norm-no-os-tmp "$(np "$FX/no-such-os-tmp")" "$POINT" "$RAW" '"sid-1"')"
check "the missing dir was not created" "absent" "$([ -e "$FX/no-such-os-tmp" ] && echo present || echo absent)"
case_end

echo "=== an unregistered point never reaches the parser ==="
case_begin "b-normalize-unregistered-point" "hooks/lib/jev/broker.js"
fx_new b-norm-unreg
for _pt in '"constructor"' '"__proto__"' '"toString"' '"no-such-point"' 'null' 'undefined'; do
  check "normalizeViaParser($_pt, ...): null, no parser run" "null|no-spawn|-|-" "$(bp norm "$_pt" "$RAW" '"sid-1"')"
done
check "no state dir entry was created" "" "$(names "$FX/state")"
case_end

echo "=== raw text that is empty or absent ==="
case_begin "b-normalize-empty-raw-text" "hooks/lib/jev/broker.js"
fx_new b-norm-empty
for _raw in '""' 'null' 'undefined'; do
  check "raw text $_raw: no throw, an empty raw file, the parser's S0-undecidable" \
    '"S0-undecidable"|sid-1/norm-XXXXXX|true|""' "$(bp norm "$POINT" "$_raw" '"sid-1"')"
done
check "raw text 'SIGNALS: none' is the empty CSV, not a failure" '""|sid-1/norm-XXXXXX|true|"SIGNALS: none"' \
  "$(bp norm "$POINT" '"SIGNALS: none"' '"sid-1"')"
check "a non-string raw value is written as its string form" '"S0-undecidable"|sid-1/norm-XXXXXX|true|"5"' \
  "$(bp norm "$POINT" '5' '"sid-1"')"
check "no norm dir left" "0" "$(norm_left)"
case_end

case_begin "b-normalize-unusable-state-dir" "hooks/lib/jev/broker.js"
fx_new b-norm-blocked
printf 'not-a-dir' > "$JEVDIR"
check "<state>/jev is a regular file: null with a session id and without, no parser run" "null|no-spawn|-|-#null|no-spawn|-|-" \
  "$(bp norm "$POINT" "$RAW" '"sid-1"')#$(bp norm2 "$POINT" "$RAW")"
check "the file is untouched" "not-a-dir" "$(cat "$JEVDIR")"
case_end
