# shellcheck shell=bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, instructions-loaded, security, injection, traversal, secret-redaction, table-driven, TL2, scope:common

# Every payload field arrives from the host, not this repo. session_id and file_path both flow
# into a filesystem path (<workflowDir>/<sid>.instructions-loaded/<sha1(file_path)>.json), so a
# naive join lets a hostile value escape the pinned directory — and the payload as a whole may
# carry credentials that must never be persisted. CONTRACT NOTE (asserted here): every artifact
# the hook writes stays under CLAUDE_WORKFLOW_DIR — no traversal, absolute path, separator, or
# control character in session_id/file_path may produce a path outside it. No payload VALUE other
# than file_path/load_reason is persisted; key NAMES survive in payload_keys. Shell metacharacters
# are inert: the hook must never hand a payload value to a shell.

echo ""
echo "=== security: untrusted session_id / file_path ==="

OUTSIDE="$BASE/outside"
mkdir -p "$OUTSIDE"

# Snapshot of everything in the fixture base that is NOT under the pinned dirs.
snap_outside() {
    find "$BASE" -mindepth 1 \
        -not -path "$WFDIR" -not -path "$WFDIR/*" \
        -not -path "$PLANS" -not -path "$PLANS/*" \
        2>/dev/null | LC_ALL=C sort
}
SNAP_BEFORE="$(snap_outside)"

# sec_fire <session_id> <file_path> -> prints "<rc>|<stdout>|<stderr>"
sec_fire() {
    local payload
    payload="$(node -e 'console.log(JSON.stringify({session_id:process.argv[1],file_path:process.argv[2],hook_event_name:"InstructionsLoaded"}))' "$1" "$2")"
    fire_raw "$payload"
}

SAFE_FP="$(node_path "$REPO/rules/missing.md")"
SAFE_SID="secbaseline"

# --- table: name | field(sid|fp) | hostile value ---
SEC_N=0
while IFS='|' read -r name field value; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')"
    field="$(printf '%s' "$field" | sed 's/^ *//; s/ *$//')"
    value="$(printf '%s' "$value" | sed 's/^ *//; s/ *$//')"
    # Escapes keep each row on one line; @OUT@ is the canary directory, resolved
    # here because the table heredoc is quoted (nothing in it may expand early).
    value="$(printf '%b' "$value")"
    value="${value//@OUT@/$OUTSIDE}"
    SEC_N=$((SEC_N + 1))
    if [ "$field" = "sid" ]; then
        res="$(sec_fire "$value" "$SAFE_FP")"
    else
        res="$(sec_fire "$SAFE_SID$SEC_N" "$value")"
    fi
    rc="${res%%|*}"; rest="${res#*|}"; sout="${rest%%|*}"
    if [ "$rc" != "0" ]; then
        fail "$name: hook must fail open on hostile input, exited $rc"
    elif [ -n "$sout" ]; then
        fail "$name: stdout must stay empty, got '$sout'"
    else
        pass "$name (exit 0, stdout empty)"
    fi
done <<'TABLE'
sec-sid-dotdot           | sid | ../escape
sec-sid-dotdot-deep      | sid | ../../../escape
sec-sid-abs-posix        | sid | /etc/passwd
sec-sid-abs-win          | sid | C:\\Windows\\Temp\\pwned
sec-sid-fwd-separator    | sid | nested/child
sec-sid-back-separator   | sid | nested\\child
sec-sid-dot-only         | sid | ..
sec-sid-newline          | sid | sid\nsecond-line
sec-sid-tab              | sid | sid\ttab
sec-sid-metachars        | sid | sid;touch @OUT@/pwned-sid
sec-sid-subshell         | sid | sid$(touch @OUT@/pwned-sub)
sec-sid-backtick         | sid | sid`touch @OUT@/pwned-tick`
sec-sid-glob             | sid | *
sec-sid-empty            | sid |
sec-fp-dotdot            | fp  | ../../../../etc/passwd
sec-fp-abs-win           | fp  | C:\\Windows\\win.ini
sec-fp-metachars         | fp  | rules/x.md;touch @OUT@/pwned-fp
sec-fp-newline           | fp  | rules/a.md\nrules/b.md
sec-fp-empty             | fp  |
TABLE

# --- S-CONTAINMENT: nothing was written outside the pinned directories ---
SNAP_AFTER="$(snap_outside)"
NEW_OUTSIDE="$(comm -13 <(printf '%s\n' "$SNAP_BEFORE") <(printf '%s\n' "$SNAP_AFTER") \
    | grep -v '/\.raw-\(out\|err\)\.' || true)"
if [ -z "$NEW_OUTSIDE" ]; then
    pass "S-CONTAINMENT: no hostile session_id/file_path produced an artifact outside the pinned dirs"
else
    fail "S-CONTAINMENT: artifacts escaped the pinned dirs — $(printf '%s' "$NEW_OUTSIDE" | tr '\n' ' ')"
fi

# --- S-SIDDIR: every receipt directory name is a single path segment ending in
# .instructions-loaded, i.e. the session id was sanitized rather than joined raw. ---
BAD_DIRS="$(find "$WFDIR" -mindepth 2 -maxdepth 2 -type d -name '*.instructions-loaded' 2>/dev/null | tr '\n' ' ')"
if [ -z "${BAD_DIRS// /}" ]; then
    pass "S-SIDDIR: no receipt directory was created below the first level of the workflow dir"
else
    fail "S-SIDDIR: nested receipt directories exist (session id joined raw) — $BAD_DIRS"
fi

echo ""
echo "=== security: payload secret must not be persisted ==="

# --- S-LEAKAGE (C8): a payload carrying a credential-shaped sentinel must leave no
# trace of the VALUE anywhere, while the key NAME survives in payload_keys. ---
CANARY='sk-ant-api03-CANARY-DO-NOT-PERSIST-9f2b7c1e'
LEAK_SID="secleak"
LEAK_FP="$(node_path "$REPO/rules/missing.md")"
LEAK_PAYLOAD="$(node -e '
console.log(JSON.stringify({
  session_id: process.argv[1],
  file_path: process.argv[2],
  hook_event_name: "InstructionsLoaded",
  api_key: process.argv[3],
  content: "preamble " + process.argv[3] + " postamble",
  nested: { deeper: { token: process.argv[3] } }
}));' "$LEAK_SID" "$LEAK_FP" "$CANARY")"
leak_res="$(fire_raw "$LEAK_PAYLOAD")"
leak_rc="${leak_res%%|*}"; leak_rest="${leak_res#*|}"
leak_out="${leak_rest%%|*}"; leak_err="${leak_rest##*|}"

leak_hits="$(grep -rl "$CANARY" "$WFDIR" "$PLANS" "$BASE/outside" 2>/dev/null | tr '\n' ' ')"
leak_tmp="$(find "$WFDIR" -type f ! -name '*.json' 2>/dev/null | tr '\n' ' ')"
leak_keys="$(read_field "$LEAK_SID" "$LEAK_FP" payload_keys)"

if [ "$leak_rc" != "0" ]; then
    fail "S-LEAKAGE: want exit 0, got $leak_rc"
elif printf '%s' "$leak_out" | grep -q "$CANARY"; then
    fail "S-LEAKAGE: the sentinel credential appeared on stdout"
elif printf '%s' "$leak_err" | grep -q "$CANARY"; then
    fail "S-LEAKAGE: the sentinel credential appeared on stderr"
elif [ -n "${leak_hits// /}" ]; then
    fail "S-LEAKAGE: the sentinel credential was persisted in — $leak_hits"
elif [ -n "${leak_tmp// /}" ]; then
    fail "S-LEAKAGE: non-.json leftovers under the receipt dir may hold payload bytes — $leak_tmp"
else
    pass "S-LEAKAGE: no sentinel credential on stdout/stderr, in receipts, in temp files, or in supervisor state"
fi

# The key NAMES are the diagnostic the plan keeps; assert they survived, so the
# assertion above cannot be satisfied by a hook that simply writes nothing.
if printf '%s' "$leak_keys" | grep -q 'api_key' && printf '%s' "$leak_keys" | grep -q 'content'; then
    pass "S-KEYNAMES: payload_keys retains the key names (api_key, content) without their values"
else
    fail "S-KEYNAMES: want payload_keys to list api_key and content, got '$leak_keys'"
fi

echo ""
echo "=== security: the two fields that ARE written to disk ==="

# The cases above prove unrecognized payload fields are dropped — trivially safe. The dangerous
# half is the two fields the receipt is REQUIRED to keep: file_path and load_reason are persisted
# verbatim by design, so a credential-shaped value in either lands on disk under CLAUDE_WORKFLOW_DIR
# and survives the session. Both are host-supplied. CONTRACT NOTE (asserted here): a persisted
# field is not exempt from redaction — a credential-shaped substring in file_path or load_reason
# must be masked, and the receipt must still be written (redaction must not degrade into dropping
# the entry, which would silently shrink the TL3 EXPECTED_SET).

# receipt_text <sid> <fp> -> raw bytes of the receipt file, or the empty string
receipt_text() {
    local rf="$WFDIR/$1.instructions-loaded/$(sha1_of "$2").json"
    [ -f "$rf" ] && cat "$rf" 2>/dev/null
}

# --- S-LEAK-FP: the canary lives in the file NAME, which the receipt must record. ---
CANARY_FP='sk-ant-api03-CANARYFP-DO-NOT-PERSIST-4d81ac02'
FP_RULE="$REPO/rules/$CANARY_FP.md"
printf '# a rule whose own name is credential-shaped\n' > "$FP_RULE"
FPLEAK_SID="secleakfp"
FPLEAK_FP="$(node_path "$FP_RULE")"
fire "$FPLEAK_SID" "$FPLEAK_FP" OMIT >/dev/null
fp_hits="$(grep -rl "$CANARY_FP" "$WFDIR" "$PLANS" 2>/dev/null | tr '\n' ' ')"
fp_dirs="$(find "$WFDIR" -maxdepth 2 -name "*$CANARY_FP*" 2>/dev/null | tr '\n' ' ')"
fp_written="$(find "$WFDIR/$FPLEAK_SID.instructions-loaded" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$fp_written" = "0" ]; then
    fail "S-LEAK-FP: no receipt was written at all — redaction must not drop the entry"
elif [ -n "${fp_hits// /}" ]; then
    fail "S-LEAK-FP: the credential-shaped file name was persisted verbatim in — $fp_hits"
elif [ -n "${fp_dirs// /}" ]; then
    fail "S-LEAK-FP: the credential-shaped file name became part of a path on disk — $fp_dirs"
else
    pass "S-LEAK-FP: a credential-shaped file_path is masked in the receipt and in the path on disk"
fi

# --- S-LEAK-LR: load_reason is host-supplied and persisted verbatim. Both the string
# form and the object form must be redacted; an object-only implementation would leak
# the string form and vice versa. ---
CANARY_LR='sk-ant-api03-CANARYLR-DO-NOT-PERSIST-7e30bb14'
LR_RULE="$REPO/rules/lrleak.md"
printf '# load_reason carrier\n' > "$LR_RULE"
LR_FP="$(node_path "$LR_RULE")"

lr_case() {
    local label="$1" sid="$2" lr_json="$3" body
    fire "$sid" "$LR_FP" "$lr_json" >/dev/null
    body="$(receipt_text "$sid" "$LR_FP")"
    if [ -z "$body" ]; then
        fail "$label: no receipt was written — redaction must not drop the entry"
    elif printf '%s' "$body" | grep -q "$CANARY_LR"; then
        fail "$label: the credential in load_reason was persisted verbatim"
    elif ! printf '%s' "$body" | grep -q '"verdict"'; then
        fail "$label: the receipt lost its verdict field while redacting"
    else
        pass "$label"
    fi
}
lr_case "S-LEAK-LR-string: a credential inside a string load_reason is masked" \
    "secleaklrs" "$(node -e 'console.log(JSON.stringify(JSON.stringify(process.argv[1])))' "carrier $CANARY_LR")"
lr_case "S-LEAK-LR-object: a credential nested in an object load_reason is masked" \
    "secleaklro" "$(node -e 'console.log(JSON.stringify(JSON.stringify({kind:"path_glob_match",detail:process.argv[1]})))' "$CANARY_LR")"

# --- S-LEAK-SWEEP: the final backstop. Neither canary may exist anywhere the hook can
# write, including file NAMES, not just file contents. ---
sweep_content="$(grep -rl -e "$CANARY_FP" -e "$CANARY_LR" "$WFDIR" "$PLANS" 2>/dev/null | tr '\n' ' ')"
sweep_names="$(find "$WFDIR" "$PLANS" \( -name "*$CANARY_FP*" -o -name "*$CANARY_LR*" \) 2>/dev/null | tr '\n' ' ')"
if [ -z "${sweep_content// /}" ] && [ -z "${sweep_names// /}" ]; then
    pass "S-LEAK-SWEEP: neither persisted-field canary appears in any content or file name under the pinned dirs"
else
    fail "S-LEAK-SWEEP: canary found — content: ${sweep_content:-none} names: ${sweep_names:-none}"
fi

# --- S-LINK: the receipt directory is a NAME the hook derives from session_id, not a handle it
# owns. Anything already there is attacker-controllable in the one scenario that matters: a stale
# worktree or shared /tmp where another process left a link pointing elsewhere first. `mkdir -p`
# on an existing link succeeds silently, so a hook trusting the name writes receipt content —
# which S-LEAK-FP/S-LEAK-LR established may carry redacted-but-sensitive material — through the
# link's TARGET, outside both pinned dirs and unmonitored. The contract asserted here is narrow
# and behavioural: after firing on a link-occupied name, NO receipt artifact exists at the link
# target. Mechanism (lstat-and-refuse, O_NOFOLLOW, realpath containment, or writing nothing)
# is not constrained. ---
LINK_SID="linkleak"
LINK_OUT="$BASE/outside-receipts"
LINK_AT="$WFDIR/$LINK_SID.instructions-loaded"
mkdir -p "$LINK_OUT"

# Try a junction first (Windows: no elevation required), then a POSIX symlink. Neither
# is assumed to have worked: MSYS silently degrades `ln -s` to a copy, which would make
# this case pass for the wrong reason. The probe below is the real gate.
link_made=0
if command -v cmd >/dev/null 2>&1; then
    cmd //c mklink //J "$(cygpath -w "$LINK_AT" 2>/dev/null || echo "$LINK_AT")" \
        "$(cygpath -w "$LINK_OUT" 2>/dev/null || echo "$LINK_OUT")" >/dev/null 2>&1 && link_made=1
fi
if [ "$link_made" = "0" ]; then
    ln -s "$LINK_OUT" "$LINK_AT" >/dev/null 2>&1 && link_made=1
fi

# Probe: write THROUGH the name and see whether it surfaces at the target. Only a real
# link redirects; a copied directory or a failed creation does not.
link_real=0
if [ "$link_made" = "1" ]; then
    : > "$LINK_AT/.probe" 2>/dev/null || true
    [ -f "$LINK_OUT/.probe" ] && link_real=1
    rm -f "$LINK_AT/.probe" "$LINK_OUT/.probe" 2>/dev/null || true
fi

if [ "$link_real" != "1" ]; then
    echo "SKIP: S-LINK: Skipped-Because: this host could not create a directory link at the receipt path (mklink /J and ln -s both declined or degraded to a copy — on Windows a symlink needs Developer Mode or elevation). Receipt-directory link redirection is UNVERIFIED here; nothing below substitutes for it."
    rm -rf "$LINK_AT" 2>/dev/null || true
else
    LINK_RULE="$REPO/rules/link-target.md"
    printf '# plain rule, no paths: -> a receipt is definitely written\n' > "$LINK_RULE"
    LINK_FP="$(node_path "$LINK_RULE")"
    link_rc="$(fire "$LINK_SID" "$LINK_FP" OMIT)"
    link_rc="${link_rc%%|*}"
    escaped="$(find "$LINK_OUT" -type f 2>/dev/null | tr '\n' ' ')"

    if [ "$link_rc" != "0" ]; then
        fail "S-LINK: the hook exited $link_rc on a link-occupied receipt path — a hostile directory name must be refused quietly, never turned into a failing hook"
    elif [ -n "${escaped// /}" ]; then
        fail "S-LINK: receipt artifacts were written THROUGH the link, outside both pinned directories — $escaped"
    else
        pass "S-LINK: a receipt-directory name occupied by a link produced no artifact at the link target (hook exit $link_rc)"
    fi
    rm -rf "$LINK_AT" 2>/dev/null || true
fi
