#!/usr/bin/env bash
# Tests: hooks/lib/jev/pending.js, hooks/lib/jev/broker.js, hooks/jev-shadow-post.js
# Tags: TL2, hooks, jev, pending, scope:issue-specific, pwsh-not-required, pending-version, version-mismatch, takeover-claim, mode-freeze, recording-owner

# A pending hand is a versioned file that freezes the policy it was written under: the pre hook
# stamps PENDING_VERSION, the mode and the recording owner, and the post hook records with those
# frozen values even when the registry changes in between. A hand of another version is treated
# as absent. takeOverClaim lets a re-run take over a stopped claim, never a live and fresh one.

# TL3 gap (what this test does NOT catch): a registry edit landing between a real host's pre and
# post hooks; the swap here overrides registryEntry inside one probe process.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
harness_isolate "$TMPROOT/iso"   # the guard reads a fragment's own top-level pin, not _lib's
mock_start

PENDING_JS="$REPO_N/hooks/lib/jev/pending.js"
BROKER_JS="$REPO_N/hooks/lib/jev/broker.js"
# hand_fields <sid> <tid>: version|mode|recording_owner of the live pending hand (JSON-encoded).
hand_fields() {
  local f
  f="$(np "$JEVDIR/$1/pending/$2.json")"
  echo "hand:$(hq json-get "$f" version)|$(hq json-get "$f" mode)|$(hq json-get "$f" recording_owner)"
}

echo "=== the pre hook's hand carries the version and the frozen policy ==="
case_begin "m-hand-carries-version-mode-owner" "hooks/lib/jev/pending.js"
fx_new m-hand
SID="jev2460-m-hand"
mock_mode '{}'
mkpayload "$FX/io/pre.json" pre "$SID" toolu_m_hand
run_hook pre "$FX/io/pre.json"
check "pre exits 0 and leaves exactly one hand" "0|1" "$HOOK_RC|$(pending_count)"
check "the hand has version 2, mode shadow and recording owner hook" 'hand:2|"shadow"|"hook"' \
  "$(hand_fields "$SID" toolu_m_hand)"
case_end

echo "=== a hand of another version is treated as absent ==="
case_begin "m-version-mismatch-hand-absent" "hooks/lib/jev/pending.js"
for ver in 1 null '"2"'; do
  tag="$(printf '%s' "$ver" | tr -dc 'a-z0-9')"
  fx_new "m-ver-$tag"
  SID="jev2460-m-ver-$tag"
  mock_mode '{}'
  mkpayload "$FX/io/pre.json" pre "$SID" "toolu_m_ver_$tag"
  mkpayload "$FX/io/post.json" post "$SID" "toolu_m_ver_$tag"
  run_hook pre "$FX/io/pre.json"
  check "fixture: pre wrote one hand" "1" "$(pending_count)"
  hq json-set "$(np "$JEVDIR/$SID/pending/toolu_m_ver_$tag.json")" version "$ver"
  run_hook post "$FX/io/post.json"
  check "version $ver: post exits 0; one record with jev not-run and the llm side kept" "0|1|not-run|ok" \
    "$HOOK_RC|$(rq "toolu_m_ver_$tag" 'recs.length + "|" + (r && [r.jev.status, r.llm.status].join("|"))')"
done
case_end

echo "=== takeOverClaim takes a stopped claim, never a live and fresh one ==="
# takeover <tid> <dead|live|stale>: pending-probe.js seeds <tid>.claimed-<owner> and calls takeOverClaim.
takeover() {
  run_with_timeout 30 node "$(np "$LIBDIR/pending-probe.js")" "$PENDING_JS" takeover "$SID" "$1" "$2" 2>> "$ERR_ALL"
}
case_begin "m-takeover-claim-dead-live-stale" "hooks/lib/jev/pending.js"
for kind in dead live stale; do
  fx_new "m-take-$kind"
  SID="jev2460-m-take-$kind"
  out="$(takeover "toolu_m_take_$kind" "$kind")"
  case "$out" in
    EXPORT_MISSING*) fail "takeOverClaim ($kind owner)" "$out" ;;
    *)
      if [ "$kind" = live ]; then
        check "a live owner with a fresh claim: null, the claim keeps its owner's name" \
          "null|toolu_m_take_live.claimed-OWNER" "$out"
      else
        check "a $kind owner's claim is renamed to this process and its contents returned" \
          "M|toolu_m_take_$kind.claimed-SELF" "$out"
      fi ;;
  esac
done
case_end

echo "=== a registry change between pre and post does not reach the record ==="
case_begin "m-registry-swap-mode-frozen" "hooks/lib/jev/broker.js"
fx_new m-swap
SID="jev2460-m-swap"
mock_mode '{}'
mkpayload "$FX/io/pre.json" pre "$SID" toolu_m_swap
run_hook pre "$FX/io/pre.json"
check "the hand froze mode shadow and recording owner hook" 'hand:2|"shadow"|"hook"' \
  "$(hand_fields "$SID" toolu_m_swap)"
SWAP_JS="$TMPROOT/registry-swap.js"
cat > "$SWAP_JS" <<'JS'
// Override registryEntry before broker loads it, so complexity-judge reads as production.
const [regPath, brokerPath, sid, tid] = process.argv.slice(2);
try {
  const reg = require(regPath);
  const orig = reg.registryEntry;
  reg.registryEntry = (p) => {
    const e = orig(p);
    return e && p === "complexity-judge" ? Object.freeze(Object.assign({}, e, { mode: "production" })) : e;
  };
  const broker = require(brokerPath);
  const rec = broker.recordShadow({
    point: "complexity-judge", sessionId: sid, toolUseId: tid, llmText: "SIGNALS: S2-architecture",
    toolInput: { subagent_type: "complexity-judge" }, step: "outline",
  });
  process.stdout.write("swapped:" + reg.registryEntry("complexity-judge").mode + "|" + (rec ? "rec" : "null"));
} catch (e) { process.stdout.write("THREW:" + (e && (e.code || e.message))); }
JS
SWAP_OUT="$(cd "$FX/cwd" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE JEV=on \
  bash "$RWT" 60 node "$(np "$SWAP_JS")" "$REGISTRY_JS" "$BROKER_JS" "$SID" toolu_m_swap 2>> "$ERR_ALL")"
check "fixture: the probe saw the swapped registry and recorded" "swapped:production|rec" "$SWAP_OUT"
check "one record, mode shadow from the hand (not production from the registry), adopted llm" "1|shadow|llm" \
  "$(rq toolu_m_swap 'recs.length + "|" + (r && [r.mode, r.adopted].join("|"))')"
check "the hand was consumed" "0" "$(pending_count)"
case_end

finish
