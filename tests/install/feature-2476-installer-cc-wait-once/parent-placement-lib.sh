# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh outside any case span:
# shared by parent-placement-ps.sh and parent-placement-sh.sh.

# _pp_line <file> <ERE> [after-line] -> first matching line number after <after-line>, or 0
_pp_line() {
    PP_RE="$2" awk -v after="${3:-0}" 'NR > after && $0 ~ ENVIRON["PP_RE"] { print NR; found=1; exit } END { if (!found) print 0 }' "$1"
}
