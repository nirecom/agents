# tests/lib/home-userprofile-pin.sh — one place that re-points the home directory for a test.
# Tests: tests/lib/home-userprofile-pin.sh
# Tags: test-infrastructure, fixture-isolation, installer, shared-lib, scope:common
# Why both: Node's os.homedir() on Windows reads USERPROFILE and never HOME, so a test that
# re-points HOME alone sends install/assemble-settings.js to the real ~/.claude (#2561 S4-7).

# pin_home_and_userprofile <dir> — export HOME and USERPROFILE at the same directory.
# Under `env -i` forward both: HOME="$HOME" USERPROFILE="$USERPROFILE".
# Fails closed with `exit 1`: carrying on would start the installer against the real home.
pin_home_and_userprofile() {
  local dir="${1:-}" abs=0
  [ "${dir:0:1}" = "/" ] && abs=1
  case "$dir" in [A-Za-z]:[\\/]?*) abs=1 ;; esac
  if [ "$abs" -ne 1 ]; then
    echo "pin_home_and_userprofile: want one absolute directory, got '$dir'" >&2
    exit 1
  fi
  HOME="$dir"
  if command -v cygpath >/dev/null 2>&1; then
    USERPROFILE="$(cygpath -m "$dir")" || exit 1
  else
    USERPROFILE="$dir"
  fi
  export HOME USERPROFILE
}
