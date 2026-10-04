# ── side-effect helpers (C1/C2) ────────────────────────────────────
# A PreToolUse hook only returns a verdict; the harness runs the tool when the
# verdict is not a block. These helpers do the same, so "unchanged" assertions
# fail when the guard lets a destructive command through.
dir_fp() {
    local d="$1" f out=""
    [ -d "$d" ] || { printf 'missing'; return; }
    for f in "$d"/* "$d"/.[!.]*; do
        [ -e "$f" ] || continue
        out+="$(basename "$f")=$(sum_of "$f");"
    done
    printf 'dir:%s' "$out"
}
attempt_bash() {
    local label="$1" cmd="$2" verdict
    verdict="$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "$cmd")")")"
    expect_block "$label" "$verdict"
    if [ "$verdict" != "block" ] && [ "$verdict" != "hook-absent" ]; then
        "$RWT" 10 bash -c "$cmd" >/dev/null 2>&1 || true
    fi
}
attempt_file() {
    local label="$1" tool="$2" target="$3" verdict
    verdict="$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in "$tool" "$target")")")"
    expect_block "$label" "$verdict"
    if [ "$verdict" != "block" ] && [ "$verdict" != "hook-absent" ]; then
        if [ "$tool" = "Edit" ]; then printf 'edited\n' >> "$target"; else printf 'written\n' > "$target"; fi
    fi
}

# ════════════════════════════════════════════════════════════════════
case_begin "control-dir-destructive-side-effects" "hooks/block-clearance-token-write/placement-guard.js"

# C1: directory-level delete and outside-to-control mv/cp against a preseeded
# terminal. Each attempt is judged on the real directory and terminal bytes.
CTL_RAW="$WORKFLOW_STATE_DIR/$SID.control"
CTL="$WFN/$SID.control"
OUT_DIR="$(make_tmp)"; OUT_N="$(np "$OUT_DIR")"
c1_seed() {
    rm -rf "$CTL_RAW"; mkdir -p "$CTL_RAW"
    printf 'exit=8 round=3\n' > "$CTL_RAW/detail-plan-terminal.txt"
    printf '3\n' > "$CTL_RAW/detail-plan-round-number.txt"
    printf 'forged\n' > "$OUT_DIR/fake.txt"
}
while IFS='|' read -r name cmd; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name// /}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
    cmd="${cmd//__CTL__/$CTL}"; cmd="${cmd//__OUT__/$OUT_N}"
    c1_seed
    DIR_BEFORE="$(dir_fp "$CTL_RAW")"
    TERM_BEFORE="$(sum_of "$CTL_RAW/detail-plan-terminal.txt")"
    OUT_BEFORE="$(sum_of "$OUT_DIR/fake.txt")"
    attempt_bash "$name" "$cmd"
    now_dir="$(dir_fp "$CTL_RAW")"
    if [ "$now_dir" = "$DIR_BEFORE" ]; then pass "$name control dir listing+bytes unchanged"
    else fail "$name control dir listing+bytes unchanged" "before=$DIR_BEFORE now=$now_dir"; fi
    expect_unchanged "$name terminal bytes unchanged" "$CTL_RAW/detail-plan-terminal.txt" "$TERM_BEFORE"
    expect_unchanged "$name outside source unchanged" "$OUT_DIR/fake.txt" "$OUT_BEFORE"
done <<'TABLE'
c1-rm-rf-dir          | rm -rf __CTL__
c1-rm-rf-dir-slash    | rm -rf __CTL__/
c1-rm-r-glob          | rm -r __CTL__/*
c1-remove-item-rec    | Remove-Item -Recurse -Force __CTL__
c1-mv-over-terminal   | mv __OUT__/fake.txt __CTL__/detail-plan-terminal.txt
c1-mv-into-dir        | mv __OUT__/fake.txt __CTL__/
c1-mv-target-dir      | mv -t __CTL__ __OUT__/fake.txt
c1-cp-over-terminal   | cp __OUT__/fake.txt __CTL__/detail-plan-terminal.txt
c1-cp-f-over-terminal | cp -f __OUT__/fake.txt __CTL__/detail-plan-terminal.txt
c1-cp-into-dir        | cp __OUT__/fake.txt __CTL__/
c1-copy-item-over     | Copy-Item __OUT__/fake.txt __CTL__/detail-plan-terminal.txt
TABLE
c1_seed
rm -rf "$OUT_DIR" 2>/dev/null || true

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "plans-rule-c-edit-rm-rename" "hooks/block-clearance-token-write/placement-guard.js"

# C2: rule (c) with WORKFLOW=on against a legacy terminal (registered control
# kind) and an unregistered session file. Edit, rm and rename in both
# directions are blocked; source and destination bytes stay unchanged.
rm -f "$WORKFLOW_STATE_DIR/$SID.workflow-off"
PL_RAW="$WORKFLOW_PLANS_DIR"
LEG="$SID-detail-plan-terminal.txt"
UNR="$SID-scratch-state.json"
BAK="$SID-detail-plan-terminal.txt.old-cycle-round3-exit8"
NOTE="$SID-note-stash.md"
c2_seed() {
    printf 'exit=8 round=3\n' > "$PL_RAW/$LEG"
    printf '{ "round": 3 }\n' > "$PL_RAW/$UNR"
    printf 'exit=6 round=1\n' > "$PL_RAW/$BAK"
    printf 'note body\n' > "$PL_RAW/$NOTE"
    rm -f "$PL_RAW/$SID-renamed.txt" "$PL_RAW/$SID-note-renamed.md"
}
c2_snapshot() {
    printf '%s/%s/%s/%s/%s/%s' "$(sum_of "$PL_RAW/$LEG")" "$(sum_of "$PL_RAW/$UNR")" \
        "$(sum_of "$PL_RAW/$BAK")" "$(sum_of "$PL_RAW/$NOTE")" \
        "$(sum_of "$PL_RAW/$SID-renamed.txt")" "$(sum_of "$PL_RAW/$SID-note-renamed.md")"
}
c2_check() {
    local label="$1" before="$2" now
    now="$(c2_snapshot)"
    if [ "$now" = "$before" ]; then pass "$label source+destination unchanged"
    else fail "$label source+destination unchanged" "before=$before now=$now"; fi
}

for tgt in "$LEG" "$UNR"; do
    c2_seed; B="$(c2_snapshot)"
    attempt_file "c2-Edit $tgt" Edit "$PLDN/$tgt"
    c2_check "c2-Edit $tgt" "$B"
done
while IFS='|' read -r name cmd; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name// /}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
    cmd="${cmd//__P__/$PLDN}"; cmd="${cmd//__LEG__/$LEG}"; cmd="${cmd//__UNR__/$UNR}"
    cmd="${cmd//__BAK__/$BAK}"; cmd="${cmd//__NOTE__/$NOTE}"; cmd="${cmd//__SID__/$SID}"
    c2_seed; B="$(c2_snapshot)"
    attempt_bash "$name" "$cmd"
    c2_check "$name" "$B"
done <<'TABLE'
c2-rm-legacy            | rm -f __P__/__LEG__
c2-rm-unregistered      | rm -f __P__/__UNR__
c2-remove-item-legacy   | Remove-Item __P__/__LEG__
c2-mv-legacy-away       | mv __P__/__LEG__ __P__/__SID__-renamed.txt
c2-mv-legacy-to-note    | mv __P__/__LEG__ __P__/__SID__-note-renamed.md
c2-mv-bak-onto-legacy   | mv __P__/__BAK__ __P__/__LEG__
c2-mv-note-onto-legacy  | mv __P__/__NOTE__ __P__/__LEG__
c2-mv-unreg-away        | mv __P__/__UNR__ __P__/__SID__-note-renamed.md
c2-mv-note-onto-unreg   | mv __P__/__NOTE__ __P__/__UNR__
c2-move-item-legacy     | Move-Item __P__/__LEG__ __P__/__SID__-renamed.txt
c2-rename-item-legacy   | Rename-Item __P__/__LEG__ __SID__-note-renamed.md
TABLE
rm -f "$PL_RAW/$LEG" "$PL_RAW/$UNR" "$PL_RAW/$BAK" "$PL_RAW/$NOTE" 2>/dev/null || true

case_end
