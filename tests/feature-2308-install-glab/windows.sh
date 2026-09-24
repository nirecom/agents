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
# P2: GITLAB=on, glab in PATH, HOSTNAME+TOKEN → auth login called with --hostname and --token
# Note: uses example.com with the real resolver (no PS-side DNS mock — [System.Net.Dns] is not
# injectable here). PA covers the DNS-success path deterministically via localhost. (TL3 gap)
P2="$TMP/p2"
mkdir -p "$P2"
P2_AUTH_WIN="$(win_path "$P2/auth-args.txt")"
printf '@echo off\nexit /b 1\n' > "$P2/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nif "%%1"=="config" (exit /b 0)\nexit /b 0\n' \
    "$P2_AUTH_WIN" > "$P2/glab.cmd"
cat > "$P2/driver.ps1" << PS1EOF
\$env:PATH = '$(win_path "$P2");' + \$env:PATH
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = 'example.com'
\$env:GITLAB_TOKEN = 'glpat-test'
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P2"
P2_AUTH="$(cat "$P2/auth-args.txt" 2>/dev/null || echo "")"
if [ "$P_RC" -eq 0 ] && \
   printf '%s' "$P2_AUTH" | grep -qi -- "--hostname" && \
   printf '%s' "$P2_AUTH" | grep -qi "example.com" && \
   printf '%s' "$P2_AUTH" | grep -qi -- "--token"; then
    pass "P2: glab.ps1 — GITLAB_HOSTNAME+TOKEN -> auth login called with --hostname and --token"
else
    fail "P2: rc=$P_RC auth_args='$P2_AUTH' out=$(printf '%s' "$P_OUT" | head -2)"
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
cat > "$P3/driver.ps1" << PS1EOF
\$env:PATH = '$(win_path "$P3");' + \$env:PATH
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = 'example.com'
\$env:GITLAB_TOKEN = 'glpat-test'
\$env:GITLAB_SUBFOLDER = 'group1/gitlab'
& '$_GLAB_PS1_WIN'
PS1EOF
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
# PA (C2): GITLAB=on + HOSTNAME=localhost (always resolvable, no network) + TOKEN ->
#          DNS success path -> auth login called with --hostname localhost --token.
PA="$TMP/pa"
mkdir -p "$PA"
PA_AUTH_WIN="$(win_path "$PA/auth-args.txt")"
PA_CFG_WIN="$(win_path "$PA")"
printf '@echo off\nexit /b 1\n' > "$PA/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nif "%%1"=="config" (exit /b 0)\nexit /b 0\n' \
    "$PA_AUTH_WIN" > "$PA/glab.cmd"
cat > "$PA/driver.ps1" << PS1EOF
\$env:PATH = '$PA_CFG_WIN;' + \$env:PATH
\$env:AGENTS_CONFIG_DIR = '$PA_CFG_WIN'
Set-Location '$PA_CFG_WIN'
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = 'localhost'
\$env:GITLAB_TOKEN = 'glpat-test'
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$PA"
PA_AUTH="$(cat "$PA/auth-args.txt" 2>/dev/null || echo "")"
if [ "$P_RC" -eq 0 ] && \
   printf '%s' "$PA_AUTH" | grep -qi -- "--hostname" && \
   printf '%s' "$PA_AUTH" | grep -qi "localhost" && \
   printf '%s' "$PA_AUTH" | grep -qi -- "--token"; then
    pass "PA: glab.ps1 — resolvable host (localhost) -> DNS success, auth login called with --hostname/--token"
else
    fail "PA: rc=$P_RC auth_args='$PA_AUTH' out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

case_begin "PB" "install/win/glab.ps1"
# PB (C3): GITLAB=on + HOSTNAME=localhost but NO TOKEN -> partial creds:
#          glab auth status NOT called, manual-setup message printed.
# TL3 gap: PS DNS is Job-based (not getent/host), so DNS invocation for this path is not markable at TL2.
PB="$TMP/pb"
mkdir -p "$PB"
PB_STATUS_WIN="$(win_path "$PB/auth-status-marker.txt")"
PB_CFG_WIN="$(win_path "$PB")"
printf '@echo off\nexit /b 1\n' > "$PB/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$PB_STATUS_WIN" > "$PB/glab.cmd"
cat > "$PB/driver.ps1" << PS1EOF
\$env:PATH = '$PB_CFG_WIN;' + \$env:PATH
\$env:AGENTS_CONFIG_DIR = '$PB_CFG_WIN'
Set-Location '$PB_CFG_WIN'
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = 'localhost'
\$env:GITLAB_TOKEN = ''
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$PB"
if [ "$P_RC" -eq 0 ] && [ ! -f "$PB/auth-status-marker.txt" ] && \
   printf '%s' "$P_OUT" | grep -qi "manual\|GITLAB_HOSTNAME\|GITLAB_TOKEN"; then
    pass "PB: glab.ps1 — HOSTNAME without TOKEN -> manual auth message, auth status not called"
else
    fail "PB: rc=$P_RC status_called=$([ -f "$PB/auth-status-marker.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

case_begin "PC" "install/win/glab.ps1"
# PC (C3): GITLAB=on + NO HOSTNAME + TOKEN set -> partial creds:
#          glab auth status NOT called, manual-setup message printed.
# TL3 gap: PS DNS is Job-based (not getent/host), so "DNS skipped for no-HOSTNAME" is not markable at TL2.
PC="$TMP/pc"
mkdir -p "$PC"
PC_STATUS_WIN="$(win_path "$PC/auth-status-marker.txt")"
PC_CFG_WIN="$(win_path "$PC")"
printf '@echo off\nexit /b 1\n' > "$PC/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$PC_STATUS_WIN" > "$PC/glab.cmd"
cat > "$PC/driver.ps1" << PS1EOF
\$env:PATH = '$PC_CFG_WIN;' + \$env:PATH
\$env:AGENTS_CONFIG_DIR = '$PC_CFG_WIN'
Set-Location '$PC_CFG_WIN'
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = ''
\$env:GITLAB_TOKEN = 'glpat-test'
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$PC"
if [ "$P_RC" -eq 0 ] && [ ! -f "$PC/auth-status-marker.txt" ] && \
   printf '%s' "$P_OUT" | grep -qi "manual\|GITLAB_HOSTNAME\|GITLAB_TOKEN"; then
    pass "PC: glab.ps1 — TOKEN without HOSTNAME -> manual auth message, auth status not called"
else
    fail "PC: rc=$P_RC status_called=$([ -f "$PC/auth-status-marker.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -3)"
fi
case_end

case_begin "P7" "install/win/glab.ps1"
# P7 (C1): GITLAB=on + HOSTNAME + TOKEN + unresolvable host -> the DNS guard's timeout
#          bounds the probe; the script finishes under the run wrapper and auth login is
#          NOT called. Timing guard: elapsed must stay under _PS_TIMEOUT (hang detector).
# Note: uses fast NXDOMAIN, not a true DNS hang; Wait-Job -Timeout 3 branch is a TL3 gap.
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

fi  # end pwsh skip gate
