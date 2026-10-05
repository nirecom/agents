#!/usr/bin/env bash
# tests/hooks/fix-524-confirm-plan-guard/layer1-url-cases.sh
# Tests: hooks/stop-confirm-plan-guard.js
# Tags: plan, hook, workflow, plans, plan-sync, TL2, scope:common, table-driven
# Sourced by ../fix-524-confirm-plan-guard.sh — reuses PLANS_DIR, WORKFLOW_DIR,
# TRANSCRIPT_DIR, NODE_TMPDIR, write_marker, write_transcript, run_stop_hook, pass/fail.
# #2513 Layer 1 as a named allow/block table: GitHub blob URLs may be repeated; every
# local PLANS_DIR form (native, forward-slash, ~, percent-encoded file:/// URI) blocks.
L1_TABLE_N=0

# TL3 gap (what this test does NOT catch):
# - real Claude Code Stop-event dispatch (the hook runs on a synthetic stdin payload)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
L1_BLOB="https://github.com/test-owner/test-repo/blob/main"
SPACE_PLANS="${NODE_TMPDIR}/fix-524 plans sp-$$"
mkdir -p "$SPACE_PLANS"
NATIVE_PLANS="$(run_with_timeout node -e '
  const p = process.argv[1];
  process.stdout.write(process.platform === "win32" ? p.replace(/\//g, "\\") : p);' "$PLANS_DIR")"

# l1_text_line <template> <plansDir> — one assistant JSONL line; the template tokens
# {BLOB} {P} {F} {U} expand to the blob base, native, forward-slash and encoded-URI forms.
l1_text_line() {
  run_with_timeout node -e '
    const [tpl, dir, blob] = process.argv.slice(1);
    const fwd = dir.replace(/\\/g, "/");
    const nat = process.platform === "win32" ? fwd.replace(/\//g, "\\") : fwd;
    const enc = (s) => s.split("/").map(encodeURIComponent).join("/");
    const m = fwd.match(/^([A-Za-z]:)\/(.*)/);
    const uri = m ? "file:///" + m[1] + "/" + enc(m[2]) : "file:///" + enc(fwd.replace(/^\//, ""));
    const text = tpl.split("{BLOB}").join(blob).split("{P}").join(nat).split("{F}").join(fwd).split("{U}").join(uri);
    process.stdout.write(JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text }] } }));' \
    "$1" "$2" "$L1_BLOB"
}

# l1_verdict <sid> <plansDir> — prints "allow", "block" or "other(rc=..)"; full stdout goes to $TRANSCRIPT_DIR/<sid>.out.
l1_verdict() {
  (
    export WORKFLOW_PLANS_DIR="$2"
    run_stop_hook "{\"session_id\":\"$1\",\"transcript_path\":\"$TRANSCRIPT_DIR/$1.jsonl\"}"
    printf '%s' "$STOP_STDOUT" > "$TRANSCRIPT_DIR/$1.out"
    if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_STDOUT" ]; then printf 'allow'
    elif [ "$STOP_RC" -eq 2 ] && printf '%s' "$STOP_STDOUT" | grep -q '"decision":"block"'; then printf 'block'
    else printf 'other(rc=%s)' "$STOP_RC"; fi
  )
}

echo "=== T-L1-URL table: blob URLs allowed, local PLANS_DIR forms blocked ==="
while IFS='|' read -r name tpl dirkind want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; dirkind="${dirkind//[[:space:]]/}"; want="${want//[[:space:]]/}"
  tpl="${tpl#"${tpl%%[![:space:]]*}"}"; tpl="${tpl%"${tpl##*[![:space:]]}"}"
  case "$dirkind" in
    native) dir="$NATIVE_PLANS" ;;
    space) dir="$SPACE_PLANS" ;;
    *) fail "T-L1-URL $name — unknown dir kind '$dirkind'"; continue ;;
  esac
  L1_TABLE_N=$((L1_TABLE_N + 1))
  sid="sid-l1-$name-$$"
  write_marker "$sid" detail >/dev/null
  write_transcript "$TRANSCRIPT_DIR/$sid.jsonl" "$(l1_text_line "$tpl" "$dir")"
  got="$(l1_verdict "$sid" "$dir")"
  if [ "$got" = "$want" ]; then pass "T-L1-URL $name — $want"
  else fail "T-L1-URL $name — want=$want got=$got stdout='$(cat "$TRANSCRIPT_DIR/$sid.out" 2>/dev/null)'"; fi
  rm -f "$WORKFLOW_DIR/${sid}".confirm-plan-turn-*.json 2>/dev/null || true
done <<'TABLE'
# name               | assistant text template                        | plans dir | want
blob-url-only        | Plan: {BLOB}/abc-detail.md                     | native    | allow
blob-url-md-link     | [abc-detail.md]({BLOB}/abc-detail.md)          | native    | allow
blob-urls-two-stages | {BLOB}/abc-intent.md then {BLOB}/abc-detail.md | native    | allow
blob-url-space-dir   | Plan: {BLOB}/abc-detail.md                     | space     | allow
native-path          | see {P}/abc-detail.md                          | native    | block
forward-slash-path   | see {F}/abc-detail.md                          | native    | block
tilde-path           | see ~/.workflow-plans/abc-detail.md            | native    | block
encoded-file-uri     | open {U}/abc-detail.md please                  | space     | block
blob-url-plus-path   | {BLOB}/abc-detail.md or {F}/abc-detail.md      | native    | block
TABLE
if [ "$L1_TABLE_N" -eq 9 ]; then pass "T-L1-URL table ran all 9 rows"
else fail "T-L1-URL table ran $L1_TABLE_N of 9 rows"; fi

# #2513 reason wording (separate from the verdict table): blob URLs may be repeated.
L1_REASON="$(cat "$TRANSCRIPT_DIR/sid-l1-encoded-file-uri-$$.out" 2>/dev/null)"
if printf '%s' "$L1_REASON" | grep -qF "blob URL"; then
  pass "T-L1-URL block reason says the blob URL may be repeated"
else
  fail "T-L1-URL block reason lacks the 'blob URL' allowance (new #2513 wording not implemented) — got '$L1_REASON'"
fi
rm -rf "$SPACE_PLANS"
rm -f "$TRANSCRIPT_DIR"/sid-l1-*-"$$".out 2>/dev/null || true
