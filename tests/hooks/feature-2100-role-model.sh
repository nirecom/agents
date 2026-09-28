#!/usr/bin/env bash
# tests/hooks/feature-2100-role-model.sh
# Tests: hooks/lib/role-model.js, bin/resolve-role-model, .env.example
# Tags: hook, bin, env, model-routing, resolver, unit, scope:issue-specific
# RM-1..9 (#2100 Step 8b): role -> model alias resolution and its CLI.
# RED until hooks/lib/role-model.js and bin/resolve-role-model exist and
# .env.example carries the "Subagent model routing" keys.
# TL3 gap: whether the Agent tool honours the passed model is not observable here.

set -u
# Anchor to THIS checkout: an inherited AGENTS_DIR would otherwise win in harness.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

AGENTS_NODE="$(np "$AGENTS_DIR")"
ROLE_MODEL="$AGENTS_DIR/hooks/lib/role-model.js"
ROLE_MODEL_NODE="$AGENTS_NODE/hooks/lib/role-model.js"
RRM="$AGENTS_DIR/bin/resolve-role-model"
ENV_EXAMPLE="$AGENTS_DIR/.env.example"

WORK="$(make_tmp)"
trap 'rm -rf "$WORK"' EXIT
harness_isolate "$WORK/iso"
NEUTRAL="$WORK/neutral"; mkdir -p "$NEUTRAL"

# rm_run <env-file-content> <node|cli> <script-or-args...> [--env VAR=val...]
# Sets RM_OUT / RM_ERR / RM_RC. Fresh cfg dir per call; ambient MODEL_* and
# project-overlay variables are stripped so the developer's .env never leaks in.
RM_OUT=""; RM_ERR=""; RM_RC=0
rm_run() {
    local content="$1" mode="$2"; shift 2
    local cfg; cfg="$(mktemp -d "$WORK/cfg.XXXX")"
    printf '%b' "$content" > "$cfg/.env"
    local -a args=() envs=()
    while [ $# -gt 0 ]; do
        if [ "$1" = "--env" ]; then
            envs+=("$2"); shift 2
        else
            args+=("$1"); shift
        fi
    done
    local -a cmd
    if [ "$mode" = "node" ]; then
        cmd=(node -e "${args[0]}")
    else
        cmd=(node "$(np "$RRM")" "${args[@]}")
    fi
    (cd "$NEUTRAL" && env -u MODEL_REVIEWER -u MODEL_ALERT -u MODEL_PRODUCER_HIGH -u MODEL_PRODUCER_LOW \
        -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_SUBAGENT_MODEL AGENTS_CONFIG_DIR="$(np "$cfg")" "${envs[@]}" \
        bash "$RWT" 10 "${cmd[@]}" >"$WORK/out" 2>"$WORK/err")
    RM_RC=$?
    RM_OUT="$(cat "$WORK/out")"; RM_ERR="$(cat "$WORK/err")"
}

have_impl() {
    [ -f "$ROLE_MODEL" ] && return 0
    fail "$1" "hooks/lib/role-model.js not implemented yet"; return 1
}
have_cli() {
    [ -f "$RRM" ] && return 0
    fail "$1" "bin/resolve-role-model not implemented yet"; return 1
}

ROLES_JS="const rm = require('$ROLE_MODEL_NODE');
const roles = ['reviewer', 'producer-high', 'producer-low', 'alert'];"

# --- RM-1: empty .env -> defaults (opus/opus/sonnet/sonnet), lib and CLI ------
case_begin "RM-1 defaults" "hooks/lib/role-model.js"
if have_impl "RM-1 lib defaults"; then
    rm_run "" node "$ROLES_JS
process.stdout.write(roles.map((r) => { const x = rm.resolveRoleModel(r); return r + '=' + x.model + ':' + x.key + ':' + x.invalid; }).join(','));"
    assert_eq "$RM_OUT" "reviewer=opus:MODEL_REVIEWER:false,producer-high=opus:MODEL_PRODUCER_HIGH:false,producer-low=sonnet:MODEL_PRODUCER_LOW:false,alert=sonnet:MODEL_ALERT:false"
fi
case_end
case_begin "RM-1 CLI defaults" "bin/resolve-role-model"
if have_cli "RM-1 CLI defaults"; then
    got=""
    for r in reviewer producer-high producer-low alert; do
        rm_run "" cli --role "$r"
        got="$got$r:$RM_RC:$RM_OUT;"
    done
    assert_eq "$got" "reviewer:0:model=opus;producer-high:0:model=opus;producer-low:0:model=sonnet;alert:0:model=sonnet;"
fi
case_end

# --- RM-1b: fail-open — role-model.js copied WITHOUT load-env.js -> defaults ---
case_begin "RM-1b fail-open without load-env" "hooks/lib/role-model.js"
if have_impl "RM-1b fail-open"; then
    iso="$WORK/lonely/hooks/lib"; mkdir -p "$iso"; cp "$ROLE_MODEL" "$iso/"
    rm_run "MODEL_REVIEWER=haiku\n" node "const rm = require('$(np "$iso")/role-model.js');
process.stdout.write(rm.resolveRoleModel('reviewer').model + ',' + rm.resolveRoleModel('alert').model);"
    assert_eq "$RM_RC:$RM_OUT" "0:opus,sonnet"
fi
case_end

# --- RM-2: .env value reaches the resolver; exported env beats .env ----------
case_begin "RM-2 .env and env precedence" "hooks/lib/role-model.js"
if have_impl "RM-2"; then
    rm_run "MODEL_REVIEWER=haiku\nMODEL_ALERT=opus\n" node "$ROLES_JS
process.stdout.write(rm.resolveRoleModel('reviewer').model + ',' + rm.resolveRoleModel('alert').model);" --env MODEL_ALERT=haiku
    assert_eq "$RM_OUT" "haiku,haiku"
fi
case_end
case_begin "RM-2 CLI reads .env" "bin/resolve-role-model"
if have_cli "RM-2 CLI"; then
    rm_run "MODEL_PRODUCER_LOW=haiku\n" cli --role producer-low
    assert_eq "$RM_RC:$RM_OUT" "0:model=haiku"
fi
case_end

# --- RM-3: case and surrounding whitespace are normalized --------------------
case_begin "RM-3 normalization" "hooks/lib/role-model.js"
if have_impl "RM-3"; then
    # Non-default targets, so a silent fallback cannot pass for normalization.
    rm_run 'MODEL_REVIEWER=" Haiku "\nMODEL_ALERT=OPUS\nMODEL_PRODUCER_HIGH=" Sonnet"\n' node "$ROLES_JS
const a = rm.resolveRoleModel('reviewer'), b = rm.resolveRoleModel('alert'), c = rm.resolveRoleModel('producer-high');
process.stdout.write([a.model, a.invalid, b.model, b.invalid, c.model, c.invalid].join(','));"
    assert_eq "$RM_OUT" "haiku,false,opus,false,sonnet,false"
fi
case_end

# --- RM-4: disallowed values fall back; CLI names the key, withholds the value
RM4_VALUES=(gpt inherit fable claude-opus-5-5)
case_begin "RM-4 invalid -> default (lib)" "hooks/lib/role-model.js"
if have_impl "RM-4 lib"; then
    got=""
    for v in "${RM4_VALUES[@]}"; do
        rm_run "MODEL_REVIEWER=$v\nMODEL_ALERT=$v\nMODEL_PRODUCER_HIGH=$v\nMODEL_PRODUCER_LOW=$v\n" node "$ROLES_JS
process.stdout.write(roles.map((r) => { const x = rm.resolveRoleModel(r); return x.model + ':' + x.invalid; }).join('/'));"
        got="$got$v=$RM_OUT;"
    done
    want=""
    for v in "${RM4_VALUES[@]}"; do want="${want}$v=opus:true/opus:true/sonnet:true/sonnet:true;"; done
    assert_eq "$got" "$want"
    rm_run 'MODEL_REVIEWER="haiku\nrm4leakmarker"\n' node "$ROLES_JS
const a = rm.resolveRoleModel('reviewer'); process.stdout.write(a.model + ':' + a.invalid);"
    assert_eq "$RM_OUT" "opus:true"
fi
case_end
case_begin "RM-4 invalid -> default (CLI, value withheld)" "bin/resolve-role-model"
if have_cli "RM-4 CLI"; then
    for v in "${RM4_VALUES[@]}" 'haiku\nrm4leakmarker'; do
        rm_run "MODEL_REVIEWER=\"$v\"\n" cli --role reviewer
        shown="${v%%\\n*}"; [ "$shown" = "haiku" ] && shown="rm4leakmarker"
        if [ "$RM_RC" != 0 ] || [ "$RM_OUT" != "model=opus" ]; then
            fail "RM-4 CLI $v" "rc=$RM_RC out=$RM_OUT (want rc=0 model=opus)"
        elif ! printf '%s' "$RM_ERR" | grep -q 'MODEL_REVIEWER'; then
            fail "RM-4 CLI $v" "stderr does not name the key: $RM_ERR"
        elif printf '%s' "$RM_ERR$RM_OUT" | grep -qF -- "$shown"; then
            fail "RM-4 CLI $v" "value leaked: err=$RM_ERR"
        else
            pass "RM-4 CLI $v -> default, key named, value withheld"
        fi
    done
    # CPR-ORTH: the other three roles fall back to their own default and name their own key.
    for row in "producer-high|MODEL_PRODUCER_HIGH|opus" "producer-low|MODEL_PRODUCER_LOW|sonnet" "alert|MODEL_ALERT|sonnet"; do
        IFS='|' read -r role key dflt <<<"$row"
        rm_run "$key=gpt-rm4leak\n" cli --role "$role"
        if [ "$RM_RC" != 0 ] || [ "$RM_OUT" != "model=$dflt" ]; then
            fail "RM-4 CLI $role" "rc=$RM_RC out=$RM_OUT (want rc=0 model=$dflt)"
        elif ! printf '%s' "$RM_ERR" | grep -qF "$key"; then
            fail "RM-4 CLI $role" "stderr does not name $key: $RM_ERR"
        elif printf '%s' "$RM_ERR$RM_OUT" | grep -qF 'rm4leak'; then
            fail "RM-4 CLI $role" "value leaked: err=$RM_ERR"
        else
            pass "RM-4 CLI $role invalid -> $dflt, $key named, value withheld"
        fi
    done
    # Negative control: a valid value produces no warning at all.
    rm_run "MODEL_REVIEWER=haiku\n" cli --role reviewer
    assert_eq "$RM_RC:$RM_OUT:$RM_ERR" "0:model=haiku:"
fi
case_end

# --- RM-5: usage errors -> exit 1, empty stdout ------------------------------
case_begin "RM-5 usage errors" "bin/resolve-role-model"
if have_cli "RM-5"; then
    got=""
    for spec in "" "--role" "--role unknown" "--role reviewer --bogus" "--level high"; do
        # shellcheck disable=SC2086  # word-split the spec on purpose
        rm_run "" cli $spec
        got="$got[$spec]$RM_RC:$RM_OUT;"
    done
    assert_eq "$got" "[]1:;[--role]1:;[--role unknown]1:;[--role reviewer --bogus]1:;[--level high]1:;"
fi
case_end

# --- RM-6: modelForLevel maps via producer-high / producer-low ---------------
case_begin "RM-6 modelForLevel" "hooks/lib/role-model.js"
if have_impl "RM-6"; then
    ML_JS="$ROLES_JS
process.stdout.write(['high', 'low', 'medium', undefined, 'NONE'].map((l) => rm.modelForLevel(l)).join(','));"
    rm_run "" node "$ML_JS"
    assert_eq "$RM_OUT" "opus,sonnet,opus,opus,opus"
    # Distinct non-default values prove which role each level reads.
    rm_run "MODEL_PRODUCER_HIGH=haiku\nMODEL_PRODUCER_LOW=opus\n" node "$ML_JS"
    assert_eq "$RM_OUT" "haiku,opus,haiku,haiku,haiku"
fi
case_end

# --- RM-7: ROLE_TABLE keys/defaults == the MODEL_* lines of .env.example ------
case_begin "RM-7 .env.example parity" ".env.example"
if have_impl "RM-7"; then
    rm_run "" node "$ROLES_JS
process.stdout.write(Object.keys(rm.ROLE_TABLE).map((r) => { const x = rm.resolveRoleModel(r); return x.key + '=' + x.model; }).sort().join(','));"
    table="$RM_OUT"
    example="$(grep -E '^MODEL_[A-Z0-9_]+=' "$ENV_EXAMPLE" | tr -d '\r' | sort | paste -sd, -)"
    if [ -z "$table" ]; then
        fail "RM-7" "ROLE_TABLE produced nothing (rc=$RM_RC err=$RM_ERR)"
    elif [ -z "$example" ]; then
        fail "RM-7" ".env.example has no MODEL_* lines yet (want $table)"
    else
        assert_eq "$example" "$table"
    fi
    assert_eq "$table" "MODEL_ALERT=sonnet,MODEL_PRODUCER_HIGH=opus,MODEL_PRODUCER_LOW=sonnet,MODEL_REVIEWER=opus"
fi
case_end

# --- RM-8: unknown role is a programming error (TypeError), not fail-open -----
case_begin "RM-8 unknown role throws" "hooks/lib/role-model.js"
if have_impl "RM-8"; then
    rm_run "MODEL_REVIEWER=haiku\n" node "$ROLES_JS
const t = (f) => { try { f(); return 'none'; } catch (e) { return e instanceof TypeError ? 'TypeError' : 'other'; } };
process.stdout.write([t(() => rm.formatAgentModelLine('nope')), t(() => rm.resolveRoleModel('nope')), rm.formatAgentModelLine('reviewer')].join('|'));"
    assert_eq "$RM_OUT" 'TypeError|TypeError|Subagent model: pass model: "haiku" to the Agent tool.'
fi
case_end

# --- RM-9: the project .env.local overlay reaches the CLI (via resolveConfigVar)
case_begin "RM-9 .env.local overlay through the CLI" "bin/resolve-role-model"
if have_cli "RM-9"; then
    proj="$WORK/rm9-proj"; mkdir -p "$proj"
    printf 'MODEL_REVIEWER=haiku\n' > "$proj/.env.local"
    rm_run "MODEL_REVIEWER=sonnet\n" cli --role reviewer --env CLAUDE_PROJECT_DIR="$(np "$proj")"
    with_local="$RM_RC:$RM_OUT"
    # Negative control: same global .env, no project root -> the global value.
    rm_run "MODEL_REVIEWER=sonnet\n" cli --role reviewer
    assert_eq "$with_local|$RM_RC:$RM_OUT" "0:model=haiku|0:model=sonnet"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
