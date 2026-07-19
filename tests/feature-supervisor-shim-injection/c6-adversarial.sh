assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "C6/$name"
    else fail "C6/$name — want=$want got=$got"; fi
}

eval_case() {
    local cmd="$1"
    local tmp tmp_node hook_input out rc
    tmp=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi
    hook_input=$(node -e "
process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'c6-test-$$',tool_input:{command:process.argv[1]}}))" -- "$cmd" 2>/dev/null)
    if [ -z "$hook_input" ]; then
        fail "C6/build-json: failed for cmd=${cmd:0:40}"
        rm -rf "$tmp"; echo "error"; return
    fi
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if echo "$out" | node -e "try{const d=JSON.parse(require('fs').readFileSync(0,'utf8'));process.exit(d.decision==='block'?0:1);}catch(e){process.exit(1);}" 2>/dev/null || [ $rc -eq 2 ]; then
        echo "block"
    else
        echo "pass"
    fi
}

while IFS='|' read -r name cmd want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"
    got=$(eval_case "$cmd")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
# Genuine emit commands — shim must block
actual-workflow-off    | echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>"    | block
worktree-off-actual    | echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: reason>>"    | block
# Look-alike patterns — shim must pass through
in-grep                | grep "WORKFLOW_ENFORCE_WORKFLOW_OFF" logfile         | pass
in-echo-single-quoted  | echo 'text <<WORKFLOW_ENFORCE_WORKFLOW_OFF: x>>'    | pass
chained-cmd            | echo hello && cat notes.txt                          | pass
malformed-sentinel     | echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF>>"             | pass
TABLE

_hd_cmd=$(printf 'cat <<'"'"'EOF'"'"'\nThis <<WORKFLOW_ENFORCE_WORKFLOW_OFF: x>> is documented\nEOF')
assert_eq "in-heredoc-docs" "pass" "$(eval_case "$_hd_cmd")"

_long_cmd="$(python3 -c "print('x'*5000)" 2>/dev/null || node -e "process.stdout.write('x'.repeat(5000))" 2>/dev/null || printf '%5000s' | tr ' ' 'x')"
assert_eq "long-command" "pass" "$(eval_case "$_long_cmd")"

run_t6_mutation() {
    local tmp sid tmp_node hook_input state_before state_after
    tmp=$(make_tmp)
    sid="c6-mut-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert.cumulative_severity='warning';
st.alert.findings=[{categories:['code'],severity:'warning',detail:'test',reporter:'test',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('$sid'),JSON.stringify(st));
" >/dev/null 2>&1

    state_before=$(cat "$tmp/${sid}-supervisor-state.json" 2>/dev/null || echo "{}")

    hook_input=$(node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'$sid',tool_input:{command:'echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\"'}}))" 2>/dev/null)

    WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" >/dev/null 2>&1

    state_after=$(cat "$tmp/${sid}-supervisor-state.json" 2>/dev/null || echo "{}")
    rm -rf "$tmp"

    if [ "$state_before" = "$state_after" ]; then
        pass "T6-mutation: blocked OFF proposal left supervisor state unchanged"
    else
        fail "T6-mutation: supervisor state was mutated by blocked OFF proposal (unexpected)"
    fi
}
run_t6_mutation
