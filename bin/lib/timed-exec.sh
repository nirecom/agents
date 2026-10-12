# shellcheck shell=bash
# bin/lib/timed-exec.sh — timed_exec [--fired-file <path>] <secs> <cmd...>; source only. Shared by
# bin/lib/run-all-launch.sh and bin/run-with-timeout.sh. Returns the command's exit code, or 124 when
# <secs> ran out; only then is <path> created, so a command's own 124 is never read as an expiry.
# The command runs in its own process group (GNU `timeout` without --foreground, or the perl
# fallback's setpgrp); a TERM / INT / HUP to the caller is forwarded as TERM to the watchdog, which
# stops the whole group and KILLs it 2 s later. The caller's own traps are restored before returning.

# Perl fallback (no GNU timeout, e.g. macOS): on expiry it writes the fired file and exits 124; a
# signal to perl stops the group with exit 143 and no fired file; otherwise the status passes through.
_TEX_PERL='
use POSIX ();
my $fired = shift @ARGV;
my $secs = shift @ARGV;
my $pid = fork;
defined $pid or die "timed_exec: fork: $!\n";
if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
eval { setpgrp($pid, $pid) };
my $stop = sub {
  my $code = shift;
  kill "TERM", -$pid;
  for (1 .. 20) { last if waitpid($pid, POSIX::WNOHANG()) != 0; select(undef, undef, undef, 0.1); }
  kill "KILL", -$pid;
  waitpid($pid, 0);
  exit $code;
};
$SIG{ALRM} = sub {
  if ($fired ne "") { open(my $fh, ">", $fired) and close($fh); }
  $stop->(124);
};
$SIG{$_} = sub { $stop->(143) } for qw(TERM INT HUP);
alarm $secs;
waitpid($pid, 0);
my $st = $?;
exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
'

timed_exec() {
  local fired="" secs saved rc xdir="" xrc=""
  if [ "${1:-}" = --fired-file ]; then
    fired="$2"
    shift 2
  fi
  secs="$1"
  shift
  saved="$(trap -p TERM INT HUP)"
  # `0<&0`: without job control a background command's stdin defaults to /dev/null; keep the caller's.
  if command -v timeout >/dev/null 2>&1 && xdir="$(mktemp -d "${TMPDIR:-/tmp}/timed-exec.XXXXXX")"; then
    # The exit file is written only when the command returned by itself; its absence with 124 (or
    # 137, when the KILL was needed) is timeout's own expiry. The inner shell traps TERM (children
    # get the default back) so it outlives the command and timeout still sends the -k KILL.
    # shellcheck disable=SC2016 # expanded by the inner bash
    timeout -k 2 "$secs" bash -c 'trap "f=1" TERM; "$@"; r=$?; if [ -z "${f:-}" ]; then printf "%s" "$r" >"$0"; fi; exit "$r"' "$xdir/rc" "$@" 0<&0 &
  else
    xdir=""
    perl -e "$_TEX_PERL" -- "$fired" "$secs" "$@" 0<&0 &
  fi
  _TEX_PID=$!
  # A background child of a non-interactive shell ignores INT, so every stop is forwarded as TERM.
  trap 'kill -TERM "$_TEX_PID" 2>/dev/null' TERM INT HUP
  while :; do
    rc=0
    wait "$_TEX_PID" || rc=$?
    # A trapped signal interrupts wait with rc > 128 while the watchdog still runs.
    if [ "$rc" -gt 128 ] && kill -0 "$_TEX_PID" 2>/dev/null; then continue; fi
    break
  done
  trap - TERM INT HUP
  if [ -n "$saved" ]; then eval "$saved"; fi
  if [ -n "$xdir" ]; then
    if [ -s "$xdir/rc" ]; then IFS= read -r xrc <"$xdir/rc" || true; fi
    rm -rf "$xdir"
    if [[ "$xrc" =~ ^[0-9]+$ ]]; then
      rc="$xrc"
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      rc=124
      if [ -n "$fired" ]; then : >"$fired"; fi
    fi
  fi
  return "$rc"
}
