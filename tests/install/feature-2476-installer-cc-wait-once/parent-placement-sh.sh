# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh (needs parent-placement-lib.sh).
# Static: install.sh runs the wait helper once, after its Node.js check
# and before the first child (dotfileslink), and publishes the verdict as WAIT_CC_RESULT.

_PP_SH="$SCRIPT_CHECKOUT_ROOT/install.sh"

_pp_npm="$(_pp_line "$_PP_SH" '^if ! type npm')"
_pp_npm_end="$(_pp_line "$_PP_SH" '^fi' "$_pp_npm")"
_pp_unset="$(_pp_line "$_PP_SH" '^unset WAIT_CC_RESULT' "$_pp_npm_end")"
_pp_shcall="$(_pp_line "$_PP_SH" '^if bash .*wait-cc-exit\.sh.*then WAIT_CC_RESULT=clear;? *else WAIT_CC_RESULT=timeout' "$_pp_unset")"
_pp_export="$(_pp_line "$_PP_SH" '^export WAIT_CC_RESULT' "$_pp_shcall")"
_pp_shdot="$(_pp_line "$_PP_SH" 'install/linux/dotfileslink\.sh')"

if [ "$_pp_npm_end" -gt 0 ] && [ "$_pp_unset" -gt "$_pp_npm_end" ] && [ "$_pp_shcall" -gt "$_pp_unset" ] \
   && [ "$_pp_export" -gt "$_pp_shcall" ] && [ "$_pp_shdot" -gt "$_pp_export" ]; then
    pass "PP-sh-order: unset -> helper (clear/timeout) -> export, after nvm check, before dotfileslink.sh"
else
    fail "PP-sh-order: want nvm_end < unset < helper < export < dotfileslink.sh" \
        "nvm_end=$_pp_npm_end unset=$_pp_unset call=$_pp_shcall export=$_pp_export dotfileslink=$_pp_shdot"
fi
