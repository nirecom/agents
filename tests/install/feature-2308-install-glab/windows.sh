# ---------------------------------------------------------------------------
# Section 5: Windows/pwsh — glab.ps1 flag gate and non-interactive auth
# ---------------------------------------------------------------------------

win_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
ps_path()  { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

_GLAB_PS1="$AGENTS_DIR/install/win/glab.ps1"
_RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
_PS_TIMEOUT=30

run_glab_ps1() {
    local dir="$1"
    P_RC=0
    P_OUT="$(bash "$_RWT" "$_PS_TIMEOUT" \
        "$_ps_bin" -NoProfile -NonInteractive -File "$(win_path "$dir/driver.ps1")" 2>&1)" || P_RC=$?
}

_ps_bin=""
for _c in pwsh powershell powershell.exe; do
    if command -v "$_c" >/dev/null 2>&1; then _ps_bin="$_c"; break; fi
done

if [ -z "$_ps_bin" ]; then
    echo "SKIP-ENV: no pwsh/powershell on PATH — install/win/glab.ps1 tests skipped"
elif [ ! -f "$_GLAB_PS1" ]; then
    fail "P-all: install/win/glab.ps1 not found at $_GLAB_PS1"
else

_GLAB_PS1_WIN="$(ps_path "$_GLAB_PS1")"

# Driver for the TCP reachability guard (#2476): <mode> open = loopback TcpListener whose
# port goes to GLAB_PROBE_PORT (LISTENER_PENDING=True proves the probe connected); closed =
# same port after Stop (connection refused); none = no listener, default port 443.
_ps_driver() {  # $1=dir $2=hostname $3=token $4=subfolder $5=open|closed|none
    local cfg; cfg="$(win_path "$1")"
    cat > "$1/driver.ps1" << PS1EOF
\$env:PATH = '$cfg;' + \$env:PATH
\$env:AGENTS_CONFIG_DIR = '$cfg'
Set-Location '$cfg'
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = '$2'
\$env:GITLAB_TOKEN = '$3'
\$env:GITLAB_SUBFOLDER = '$4'
if ('$5' -ne 'none') {
    \$_l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    \$_l.Start()
    \$env:GLAB_PROBE_PORT = [string]\$_l.LocalEndpoint.Port
    Write-Host "PROBE_PORT=\$env:GLAB_PROBE_PORT"
    if ('$5' -eq 'closed') { \$_l.Stop() }
}
try { & '$_GLAB_PS1_WIN' } finally {
    if ('$5' -eq 'open') { Write-Host "LISTENER_PENDING=\$(\$_l.Pending())"; \$_l.Stop() }
}
PS1EOF
}

case_begin "P1" "install/win/glab.ps1"
# P1: GITLAB=off → exit 0, winget NOT called (flag gate)
P1="$TMP/p1"
mkdir -p "$P1"
P1_WINGET_WIN="$(win_path "$P1/winget-called.txt")"
printf '@echo off\necho %%* >> "%s"\nexit /b 0\n' "$P1_WINGET_WIN" > "$P1/winget.cmd"
cat > "$P1/driver.ps1" << PS1EOF
\$env:PATH = '$(win_path "$P1");' + \$env:PATH
\$env:GITLAB = 'off'
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P1"
if [ "$P_RC" -eq 0 ] && [ ! -f "$P1/winget-called.txt" ]; then
    pass "P1: glab.ps1 — GITLAB=off -> exit 0, winget not called (flag gate)"
else
    fail "P1: rc=$P_RC winget_called=$([ -f "$P1/winget-called.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

case_begin "P2" "install/win/glab.ps1"
# P2: GITLAB=on, glab in PATH, HOSTNAME+TOKEN (reachable loopback listener) → auth login
#     called with --hostname and --stdin; the token arrives on stdin, never in argv.
#     No external network is touched.
P2="$TMP/p2"
mkdir -p "$P2"
P2_AUTH_WIN="$(win_path "$P2/auth-args.txt")"
P2_STDIN_WIN="$(win_path "$P2/auth-stdin.txt")"
printf '@echo off\nexit /b 1\n' > "$P2/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & findstr "^" >> "%s" & exit /b 0)\n)\nif "%%1"=="config" (exit /b 0)\nexit /b 0\n' \
    "$P2_AUTH_WIN" "$P2_STDIN_WIN" > "$P2/glab.cmd"
_ps_driver "$P2" 127.0.0.1 glpat-test '' open
run_glab_ps1 "$P2"
P2_AUTH="$(cat "$P2/auth-args.txt" 2>/dev/null || echo "")"
P2_STDIN="$(tr -d '\r' 2>/dev/null < "$P2/auth-stdin.txt" || echo "")"
if [ "$P_RC" -eq 0 ] && \
   printf '%s' "$P2_AUTH" | grep -qi -- "--hostname" && \
   printf '%s' "$P2_AUTH" | grep -qi "127.0.0.1" && \
   printf '%s' "$P2_AUTH" | grep -qi -- "--stdin" && \
   ! printf '%s' "$P2_AUTH" | grep -qi -- "--token" && \
   ! printf '%s' "$P2_AUTH" | grep -q "glpat-test" && \
   [ "$P2_STDIN" = "glpat-test" ]; then
    pass "P2: glab.ps1 — GITLAB_HOSTNAME+TOKEN -> auth login called with --hostname and --stdin, token on stdin only"
else
    fail "P2: rc=$P_RC auth_args='$P2_AUTH' stdin='$P2_STDIN' out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

case_begin "P3" "install/win/glab.ps1"
# P3: GITLAB=on, glab in PATH, HOSTNAME+TOKEN+SUBFOLDER → glab config set subfolder called
P3="$TMP/p3"
mkdir -p "$P3"
P3_AUTH_WIN="$(win_path "$P3/auth-args.txt")"
P3_CONFIG_WIN="$(win_path "$P3/config-args.txt")"
printf '@echo off\nexit /b 1\n' > "$P3/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nif "%%1"=="config" (\n  if "%%2"=="set" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$P3_AUTH_WIN" "$P3_CONFIG_WIN" > "$P3/glab.cmd"
_ps_driver "$P3" 127.0.0.1 glpat-test group1/gitlab open
run_glab_ps1 "$P3"
P3_CONFIG="$(cat "$P3/config-args.txt" 2>/dev/null || echo "")"
if [ "$P_RC" -eq 0 ] && \
   printf '%s' "$P3_CONFIG" | grep -qi "subfolder" && \
   printf '%s' "$P3_CONFIG" | grep -qi "group1/gitlab"; then
    pass "P3: glab.ps1 — GITLAB_SUBFOLDER -> glab config set subfolder called"
else
    fail "P3: rc=$P_RC config_args='$P3_CONFIG' out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

case_begin "P4" "install/win/glab.ps1"
# P4: GITLAB=on, glab in PATH, no creds → auth login NOT called
P4="$TMP/p4"
mkdir -p "$P4"
P4_LOGIN_WIN="$(win_path "$P4/login-called.txt")"
printf '@echo off\nexit /b 1\n' > "$P4/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$P4_LOGIN_WIN" > "$P4/glab.cmd"
cat > "$P4/driver.ps1" << PS1EOF
\$env:PATH = '$(win_path "$P4");' + \$env:PATH
\$env:AGENTS_CONFIG_DIR = '$(win_path "$P4")'
Set-Location '$(win_path "$P4")'
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = ''
\$env:GITLAB_TOKEN = ''
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P4"
if [ "$P_RC" -eq 0 ] && [ ! -f "$P4/login-called.txt" ]; then
    pass "P4: glab.ps1 — GITLAB=on, no creds -> auth login never called"
else
    fail "P4: rc=$P_RC login_called=$([ -f "$P4/login-called.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

case_begin "P5" "install/win/glab.ps1"
# P5: GITLAB=on + HOSTNAME + TOKEN + DNS failure (unresolvable host) -> auth login NOT called, warning printed
# AGENTS_CONFIG_DIR + neutral CWD isolate the fixture from the developer's real .env.
P5="$TMP/p5"
mkdir -p "$P5"
P5_LOGIN_WIN="$(win_path "$P5/login-called.txt")"
P5_CFG_WIN="$(win_path "$P5")"
printf '@echo off\nexit /b 1\n' > "$P5/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$P5_LOGIN_WIN" > "$P5/glab.cmd"
cat > "$P5/driver.ps1" << PS1EOF
\$env:PATH = '$P5_CFG_WIN;' + \$env:PATH
\$env:AGENTS_CONFIG_DIR = '$P5_CFG_WIN'
Set-Location '$P5_CFG_WIN'
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = 'nonexistent.test.invalid'
\$env:GITLAB_TOKEN = 'glpat-test'
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P5"
if [ "$P_RC" -eq 0 ] && [ ! -f "$P5/login-called.txt" ] && \
   printf '%s' "$P_OUT" | grep -qi "warning\|unreachable\|skip"; then
    pass "P5: glab.ps1 — DNS failure -> auth login skipped, warning printed"
else
    fail "P5: rc=$P_RC login_called=$([ -f "$P5/login-called.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

case_begin "P6" "install/win/glab.ps1"
# P6: GITLAB=on + no HOSTNAME -> manual auth message; glab auth status NOT called
P6="$TMP/p6"
mkdir -p "$P6"
P6_STATUS_WIN="$(win_path "$P6/auth-status-marker.txt")"
P6_CFG_WIN="$(win_path "$P6")"
printf '@echo off\nexit /b 1\n' > "$P6/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$P6_STATUS_WIN" > "$P6/glab.cmd"
cat > "$P6/driver.ps1" << PS1EOF
\$env:PATH = '$P6_CFG_WIN;' + \$env:PATH
\$env:AGENTS_CONFIG_DIR = '$P6_CFG_WIN'
Set-Location '$P6_CFG_WIN'
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = ''
\$env:GITLAB_TOKEN = ''
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P6"
if [ "$P_RC" -eq 0 ] && [ ! -f "$P6/auth-status-marker.txt" ] && \
   printf '%s' "$P_OUT" | grep -qi "manual\|GITLAB_HOSTNAME"; then
    pass "P6: glab.ps1 — no HOSTNAME -> manual auth message, auth status not called"
else
    fail "P6: rc=$P_RC status_called=$([ -f "$P6/auth-status-marker.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

case_begin "PA" "install/win/glab.ps1"
# PA: GITLAB=on + HOSTNAME=127.0.0.1 + TOKEN + open loopback listener on GLAB_PROBE_PORT ->
#     the TCP probe connects (LISTENER_PENDING=True) -> auth login called with --hostname/--stdin,
#     token on stdin only.
PA="$TMP/pa"
mkdir -p "$PA"
PA_AUTH_WIN="$(win_path "$PA/auth-args.txt")"
PA_STDIN_WIN="$(win_path "$PA/auth-stdin.txt")"
printf '@echo off\nexit /b 1\n' > "$PA/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & findstr "^" >> "%s" & exit /b 0)\n)\nif "%%1"=="config" (exit /b 0)\nexit /b 0\n' \
    "$PA_AUTH_WIN" "$PA_STDIN_WIN" > "$PA/glab.cmd"
_ps_driver "$PA" 127.0.0.1 glpat-test '' open
run_glab_ps1 "$PA"
PA_AUTH="$(cat "$PA/auth-args.txt" 2>/dev/null || echo "")"
PA_STDIN="$(tr -d '\r' 2>/dev/null < "$PA/auth-stdin.txt" || echo "")"
if [ "$P_RC" -eq 0 ] && \
   printf '%s' "$PA_AUTH" | grep -qi -- "--hostname" && \
   printf '%s' "$PA_AUTH" | grep -qi "127.0.0.1" && \
   printf '%s' "$PA_AUTH" | grep -qi -- "--stdin" && \
   ! printf '%s' "$PA_AUTH" | grep -qi -- "--token" && \
   ! printf '%s' "$PA_AUTH" | grep -q "glpat-test" && \
   [ "$PA_STDIN" = "glpat-test" ] && \
   printf '%s' "$P_OUT" | grep -q "LISTENER_PENDING=True"; then
    pass "PA: glab.ps1 — probe connected to GLAB_PROBE_PORT listener, auth login called with --hostname/--stdin, token on stdin only"
else
    fail "PA: rc=$P_RC auth_args='$PA_AUTH' stdin='$PA_STDIN' out=$(printf '%s' "$P_OUT" | grep -E 'PENDING|WARN|Cannot' | head -3)"
fi
case_end

case_begin "PB" "install/win/glab.ps1"
# PB: GITLAB=on + HOSTNAME=127.0.0.1 but NO TOKEN -> partial creds: auth status NOT called,
#     manual-setup message printed, and the probe never connects (LISTENER_PENDING=False).
PB="$TMP/pb"
mkdir -p "$PB"
PB_STATUS_WIN="$(win_path "$PB/auth-status-marker.txt")"
printf '@echo off\nexit /b 1\n' > "$PB/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$PB_STATUS_WIN" > "$PB/glab.cmd"
_ps_driver "$PB" 127.0.0.1 '' '' open
run_glab_ps1 "$PB"
if [ "$P_RC" -eq 0 ] && [ ! -f "$PB/auth-status-marker.txt" ] && \
   printf '%s' "$P_OUT" | grep -q "LISTENER_PENDING=False" && \
   printf '%s' "$P_OUT" | grep -qi "manual\|GITLAB_HOSTNAME\|GITLAB_TOKEN"; then
    pass "PB: glab.ps1 — HOSTNAME without TOKEN -> manual auth message, auth status + probe not called"
else
    fail "PB: rc=$P_RC status_called=$([ -f "$PB/auth-status-marker.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

case_begin "PC" "install/win/glab.ps1"
# PC: GITLAB=on + NO HOSTNAME + TOKEN set -> partial creds: auth status NOT called,
#     manual-setup message printed, and the probe never connects (LISTENER_PENDING=False).
PC="$TMP/pc"
mkdir -p "$PC"
PC_STATUS_WIN="$(win_path "$PC/auth-status-marker.txt")"
printf '@echo off\nexit /b 1\n' > "$PC/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$PC_STATUS_WIN" > "$PC/glab.cmd"
_ps_driver "$PC" '' glpat-test '' open
run_glab_ps1 "$PC"
if [ "$P_RC" -eq 0 ] && [ ! -f "$PC/auth-status-marker.txt" ] && \
   printf '%s' "$P_OUT" | grep -q "LISTENER_PENDING=False" && \
   printf '%s' "$P_OUT" | grep -qi "manual\|GITLAB_HOSTNAME\|GITLAB_TOKEN"; then
    pass "PC: glab.ps1 — TOKEN without HOSTNAME -> manual auth message, auth status + probe not called"
else
    fail "PC: rc=$P_RC status_called=$([ -f "$PC/auth-status-marker.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

case_begin "P7" "install/win/glab.ps1"
# P7: GITLAB=on + HOSTNAME + TOKEN + unresolvable host -> the guard fails fast; the script
#     finishes under the run wrapper and auth login is NOT called (elapsed < _PS_TIMEOUT).
# The true connect hang (3s cut) is P9.
P7="$TMP/p7"
mkdir -p "$P7"
P7_LOGIN_WIN="$(win_path "$P7/login-called.txt")"
P7_CFG_WIN="$(win_path "$P7")"
printf '@echo off\nexit /b 1\n' > "$P7/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$P7_LOGIN_WIN" > "$P7/glab.cmd"
cat > "$P7/driver.ps1" << PS1EOF
\$env:PATH = '$P7_CFG_WIN;' + \$env:PATH
\$env:AGENTS_CONFIG_DIR = '$P7_CFG_WIN'
Set-Location '$P7_CFG_WIN'
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = 'nonexistent.test.invalid'
\$env:GITLAB_TOKEN = 'glpat-test'
& '$_GLAB_PS1_WIN'
PS1EOF
_p7_start=$(date +%s)
run_glab_ps1 "$P7"
_p7_end=$(date +%s)
_p7_elapsed=$(( _p7_end - _p7_start ))
if [ "$P_RC" -eq 0 ] && [ ! -f "$P7/login-called.txt" ] && [ "$_p7_elapsed" -lt "$_PS_TIMEOUT" ]; then
    pass "P7: glab.ps1 — unresolvable host -> DNS probe bounded (${_p7_elapsed}s), auth login skipped"
else
    fail "P7: rc=$P_RC elapsed=${_p7_elapsed}s login_called=$([ -f "$P7/login-called.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

# glab stub recording `auth login` into $2 (P8/P9).
_ps_login_stub() {  # $1=dir $2=marker (win path)
    printf '@echo off\nexit /b 1\n' > "$1/winget.cmd"
    printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
        "$2" > "$1/glab.cmd"
}

case_begin "P8" "install/win/glab.ps1"
# P8: HOSTNAME=127.0.0.1 + closed loopback port -> connection refused -> auth skipped with
#     the neutral warning "Cannot connect to 127.0.0.1:<port>".
P8="$TMP/p8"
mkdir -p "$P8"
_ps_login_stub "$P8" "$(win_path "$P8/login-called.txt")"
_ps_driver "$P8" 127.0.0.1 glpat-test '' closed
run_glab_ps1 "$P8"
P8_PORT="$(printf '%s' "$P_OUT" | tr -d '\r' | sed -n 's/^PROBE_PORT=//p' | head -n1)"
if [ "$P_RC" -eq 0 ] && [ ! -f "$P8/login-called.txt" ] && [ -n "$P8_PORT" ] && \
   printf '%s' "$P_OUT" | grep -q "Cannot connect to 127.0.0.1:$P8_PORT"; then
    pass "P8: glab.ps1 — closed port $P8_PORT -> 'Cannot connect to' warning, auth login skipped"
else
    fail "P8: rc=$P_RC port=$P8_PORT login_called=$([ -f "$P8/login-called.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

case_begin "P9" "install/win/glab.ps1"
# P9: HOSTNAME=192.0.2.1 (TEST-NET-1, never answers) on the default port -> the connect is
#     cut at 3s; the whole run must finish in under 8s with auth login skipped.
P9="$TMP/p9"
mkdir -p "$P9"
_ps_login_stub "$P9" "$(win_path "$P9/login-called.txt")"
_ps_driver "$P9" 192.0.2.1 glpat-test '' none
_p9_start=$SECONDS
run_glab_ps1 "$P9"
_p9_elapsed=$((SECONDS - _p9_start))
if [ "$P_RC" -eq 0 ] && [ ! -f "$P9/login-called.txt" ] && [ "$_p9_elapsed" -lt 8 ] && \
   printf '%s' "$P_OUT" | grep -q "Cannot connect to 192.0.2.1:443"; then
    pass "P9: glab.ps1 — unanswered connect cut in ${_p9_elapsed}s (<8s), warning printed, auth login skipped"
else
    fail "P9: rc=$P_RC elapsed=${_p9_elapsed}s login_called=$([ -f "$P9/login-called.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

fi  # end pwsh skip gate
