# ─────────────────────────────────────────────────────────────────────────────
# A. bin/lib/sweep-write-mode.sh — the semantics SSOT
# ─────────────────────────────────────────────────────────────────────────────

A1_lib_exists_and_defaults_to_apply() {
    if [ ! -f "$WRITE_MODE_LIB" ]; then
        fail "A1 write-mode lib: $WRITE_MODE_LIB does not exist"
        return
    fi
    local out
    out="$(run_with_timeout bash -c '
        set -uo pipefail
        # shellcheck disable=SC1090
        . "$1"
        sweep_write_mode_init;    printf "init:%s/%s " "${APPLY:-?}" "${DRY_RUN:-?}"
        sweep_write_mode_dry_run; printf "dry:%s/%s "  "${APPLY:-?}" "${DRY_RUN:-?}"
        sweep_write_mode_apply;   printf "apply:%s/%s" "${APPLY:-?}" "${DRY_RUN:-?}"
    ' _ "$WRITE_MODE_LIB" 2>&1)"

    if [ "$out" = "init:1/0 dry:0/1 apply:1/0" ]; then
        pass "A1 write-mode lib: init=apply, dry_run=0/1, apply=1/0"
    else
        fail "A1 write-mode lib: got '$out', want 'init:1/0 dry:0/1 apply:1/0'"
    fi
}

A2_lib_footer_and_usage_helpers() {
    if [ ! -f "$WRITE_MODE_LIB" ]; then
        fail "A2 write-mode lib helpers: $WRITE_MODE_LIB does not exist"
        return
    fi
    local usage footer_dry footer_apply
    usage="$(run_with_timeout bash -c '. "$1"; sweep_write_mode_usage_lines' _ "$WRITE_MODE_LIB" 2>&1)"
    footer_dry="$(run_with_timeout bash -c '. "$1"; sweep_write_mode_dry_run; sweep_write_mode_footer' _ "$WRITE_MODE_LIB" 2>&1)"
    footer_apply="$(run_with_timeout bash -c '. "$1"; sweep_write_mode_init; sweep_write_mode_footer' _ "$WRITE_MODE_LIB" 2>&1)"

    if echo "$usage" | grep -q -- '--dry-run' && echo "$usage" | grep -q -- '--apply'; then
        pass "A2a usage lines mention both --dry-run and --apply"
    else
        fail "A2a usage lines incomplete: '$usage'"
    fi
    if echo "$footer_dry" | grep -qi 'dry-run'; then
        pass "A2b footer printed in dry-run mode"
    else
        fail "A2b footer missing in dry-run mode: '$footer_dry'"
    fi
    if [ -z "${footer_apply// /}" ]; then
        pass "A2c footer silent in apply mode"
    else
        fail "A2c footer should be empty in apply mode, got: '$footer_apply'"
    fi
}
