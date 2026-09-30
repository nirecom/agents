# TCP reachability guard (#2476; the file name predates it): glab.sh probes
# <hostname>:<port> through bash /dev/tcp bounded by `timeout 3`. make_probe_timeout
# (linux-auth.sh) fakes that seam; T10/T11 use the real timeout and /dev/tcp instead.

case_begin "T8" "install/linux/glab.sh"
# T8: GITLAB=on + HOSTNAME + TOKEN + probe failure -> auth login NOT called, warning printed, exit 0
T8_BIN="$TMP/t8-bin"; mkdir -p "$T8_BIN"
T8_LOGIN_MARKER="$TMP/t8-login-called"
make_glab_stub "$T8_BIN/glab" login "$T8_LOGIN_MARKER"
make_probe_timeout "$T8_BIN/timeout" 1 "$TMP/t8-probe-args.txt"
if [ "$GLAB_SH_OK" = "1" ]; then
    T8_OUT="$TMP/t8.log"
    run_with_timeout 15 env -i PATH="$T8_BIN:$PATH" HOME="$TMP/home-t8" AGENTS_CONFIG_DIR="$T8_BIN" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >"$T8_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T8_LOGIN_MARKER" ] && grep -q "Cannot connect to example.com:443" "$T8_OUT"; then
        pass "T8: glab.sh — probe failure -> auth login skipped, 'Cannot connect to' warning, exit 0"
    else
        fail "T8: rc=$RC login=$([ -f "$T8_LOGIN_MARKER" ] && echo yes || echo no) out=$(head -3 "$T8_OUT")"
    fi
else
    fail "T8: install/linux/glab.sh not found"
fi
case_end

case_begin "T9" "install/linux/glab.sh"
# T9: GITLAB=on + no HOSTNAME -> manual auth message; glab auth status NOT called
T9_BIN="$TMP/t9-bin"; mkdir -p "$T9_BIN"
T9_STATUS_MARKER="$TMP/t9-auth-status-marker"
make_glab_stub "$T9_BIN/glab" status "$T9_STATUS_MARKER"
if [ "$GLAB_SH_OK" = "1" ]; then
    T9_OUT="$TMP/t9.log"
    run_with_timeout 15 env -i PATH="$T9_BIN:$PATH" HOME="$TMP/home-t9" AGENTS_CONFIG_DIR="$T9_BIN" GITLAB=on \
        bash "$GLAB_SH" >"$T9_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T9_STATUS_MARKER" ] && grep -qi "manual\|GITLAB_HOSTNAME" "$T9_OUT"; then
        pass "T9: glab.sh — no HOSTNAME -> manual auth message, auth status not called"
    else
        fail "T9: rc=$RC status_called=$([ -f "$T9_STATUS_MARKER" ] && echo yes || echo no) out=$(head -3 "$T9_OUT")"
    fi
else
    fail "T9: install/linux/glab.sh not found"
fi
case_end

case_begin "T10" "install/linux/glab.sh"
# T10: hanging connect — GITLAB_HOSTNAME=192.0.2.1 (TEST-NET-1, never answers) with the REAL
#      timeout and /dev/tcp: the probe must be cut at 3s, auth skipped, exit 0 inside the 8s wrapper.
T10_BIN="$TMP/t10-bin"; mkdir -p "$T10_BIN"
T10_LOGIN_MARKER="$TMP/t10-login-called"
make_glab_stub "$T10_BIN/glab" login "$T10_LOGIN_MARKER"
if [ "$GLAB_SH_OK" = "1" ]; then
    T10_OUT="$TMP/t10.log"
    _t10_start=$SECONDS
    run_with_timeout 8 env -i PATH="$T10_BIN:$PATH" HOME="$TMP/home-t10" AGENTS_CONFIG_DIR="$T10_BIN" \
        GITLAB=on GITLAB_HOSTNAME=192.0.2.1 GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >"$T10_OUT" 2>&1 </dev/null
    RC=$?
    _t10_secs=$((SECONDS - _t10_start))
    if [ "$RC" -eq 0 ] && [ ! -f "$T10_LOGIN_MARKER" ] && [ "$_t10_secs" -lt 8 ]; then
        pass "T10: glab.sh — unanswered connect -> probe bounded (${_t10_secs}s), auth login skipped, exit 0"
    else
        fail "T10: rc=$RC ${_t10_secs}s login=$([ -f "$T10_LOGIN_MARKER" ] && echo yes || echo no) out=$(head -3 "$T10_OUT")"
    fi
else
    fail "T10: install/linux/glab.sh not found"
fi
case_end

# glab stub recording `auth login` args into $2 and its stdin into $2.stdin (TA / TA-MAC).
_make_login_recorder() {  # $1=path  $2=record file
    printf '#!/usr/bin/env bash\ncase "$1" in\n  --version) echo "glab version 1.0.0" ;;\n  auth) [ "${2:-}" = "login" ] && { echo "$@" >> "%s"; cat > "%s.stdin"; } ;;\nesac\nexit 0\n' "$2" "$2" > "$1"
    chmod +x "$1"
}

case_begin "TA" "install/linux/glab.sh"
# TA: probe success -> auth login IS called (--stdin, token on stdin, no --token) AND the probe
#     got the configured hostname and 443.
TA_BIN="$TMP/ta-bin"; mkdir -p "$TA_BIN"
TA_AUTH_ARGS="$TMP/ta-auth-args.txt"
TA_PROBE_ARGS="$TMP/ta-probe-args.txt"
TA_HOST="ta-host.example.com"
_make_login_recorder "$TA_BIN/glab" "$TA_AUTH_ARGS"
make_probe_timeout "$TA_BIN/timeout" 0 "$TA_PROBE_ARGS"
if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$TA_BIN:$PATH" HOME="$TMP/home-ta" AGENTS_CONFIG_DIR="$TA_BIN" \
        GITLAB=on GITLAB_HOSTNAME="$TA_HOST" GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    AUTH_ARGS="$(cat "$TA_AUTH_ARGS" 2>/dev/null || echo "")"
    AUTH_STDIN="$(cat "$TA_AUTH_ARGS.stdin" 2>/dev/null || echo "")"
    PROBE_ARGS="$(cat "$TA_PROBE_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$AUTH_ARGS" | grep -q -- "--hostname" && \
       echo "$AUTH_ARGS" | grep -q "$TA_HOST" && echo "$AUTH_ARGS" | grep -q -- "--stdin" && \
       ! echo "$AUTH_ARGS" | grep -q -- "--token" && ! echo "$AUTH_ARGS" | grep -q "glpat-test" && \
       [ "$AUTH_STDIN" = "glpat-test" ] && \
       echo "$PROBE_ARGS" | grep -q "$TA_HOST" && echo "$PROBE_ARGS" | grep -qE ' 443( |$)'; then
        pass "TA: glab.sh — probe success -> auth login called with --stdin (token on stdin only), probe got configured hostname and 443"
    else
        fail "TA: rc=$RC auth='$AUTH_ARGS' stdin='$AUTH_STDIN' probe='$PROBE_ARGS'"
    fi
else
    fail "TA: install/linux/glab.sh not found"
fi
case_end

case_begin "TA-MAC" "install/linux/glab.sh"
# TA-MAC: fake uname=Darwin -> the probe is OS-independent: it still goes through timeout
#   with host and 443, and neither `host` nor `getent` (the old DNS tools) is called.
TA_MAC_BIN="$TMP/ta-mac-bin"; mkdir -p "$TA_MAC_BIN"
TA_MAC_PROBE_ARGS="$TMP/ta-mac-probe-args.txt"
TA_MAC_DNS_MARKER="$TMP/ta-mac-dns-called"
TA_MAC_AUTH_ARGS="$TMP/ta-mac-auth-args.txt"
TA_MAC_HOST="mac.example.com"
_make_login_recorder "$TA_MAC_BIN/glab" "$TA_MAC_AUTH_ARGS"
printf '#!/usr/bin/env bash\necho "Darwin"\n' > "$TA_MAC_BIN/uname"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TA_MAC_DNS_MARKER" > "$TA_MAC_BIN/host"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TA_MAC_DNS_MARKER" > "$TA_MAC_BIN/getent"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TA_MAC_BIN/brew"
chmod +x "$TA_MAC_BIN/uname" "$TA_MAC_BIN/host" "$TA_MAC_BIN/getent" "$TA_MAC_BIN/brew"
make_probe_timeout "$TA_MAC_BIN/timeout" 0 "$TA_MAC_PROBE_ARGS"
if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$TA_MAC_BIN:$PATH" HOME="$TMP/home-ta-mac" AGENTS_CONFIG_DIR="$TA_MAC_BIN" \
        GITLAB=on GITLAB_HOSTNAME="$TA_MAC_HOST" GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    MAC_AUTH_ARGS="$(cat "$TA_MAC_AUTH_ARGS" 2>/dev/null || echo "")"
    MAC_PROBE_ARGS="$(cat "$TA_MAC_PROBE_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$MAC_PROBE_ARGS" | grep -q "$TA_MAC_HOST" && \
       echo "$MAC_PROBE_ARGS" | grep -qE ' 443( |$)' && [ ! -f "$TA_MAC_DNS_MARKER" ] && \
       echo "$MAC_AUTH_ARGS" | grep -q -- "--hostname" && echo "$MAC_AUTH_ARGS" | grep -q "$TA_MAC_HOST"; then
        pass "TA-MAC: glab.sh — fake uname=Darwin -> same timeout probe (host, 443), no host/getent, auth login called"
    else
        fail "TA-MAC: rc=$RC probe='$MAC_PROBE_ARGS' dns_called=$([ -f "$TA_MAC_DNS_MARKER" ] && echo yes || echo no) auth='$MAC_AUTH_ARGS'"
    fi
else
    fail "TA-MAC: install/linux/glab.sh not found"
fi
case_end

# TL3 gap — TA-MAC-NOTO: the Darwin gtimeout and background+kill fallbacks (no `timeout`) need
# a real macOS host; /usr/bin/timeout cannot be reliably removed from PATH on Linux.

# Partial creds (TB/TC): no login is attempted, so the probe must not run. Every probe tool
# (fake timeout/gtimeout, old getent/host) touches one marker that must stay absent.
_make_probe_markers() {  # $1=bin dir  $2=marker
    local _t
    for _t in timeout gtimeout getent host; do
        printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$2" > "$1/$_t"
        chmod +x "$1/$_t"
    done
}

case_begin "TB" "install/linux/glab.sh"
# TB: GITLAB=on + HOSTNAME but NO TOKEN -> auth status NOT called, manual message, no probe, exit 0.
# AGENTS_CONFIG_DIR pinned to the (dot-env-less) fake bin dir so the real .env cannot leak GITLAB_TOKEN.
TB_BIN="$TMP/tb-bin"; mkdir -p "$TB_BIN"
TB_STATUS_MARKER="$TMP/tb-auth-status-marker"
TB_PROBE_MARKER="$TMP/tb-probe-called"
make_glab_stub "$TB_BIN/glab" status "$TB_STATUS_MARKER"
_make_probe_markers "$TB_BIN" "$TB_PROBE_MARKER"
if [ "$GLAB_SH_OK" = "1" ]; then
    TB_OUT="$TMP/tb.log"
    run_with_timeout 15 env -i PATH="$TB_BIN:$PATH" HOME="$TMP/home-tb" AGENTS_CONFIG_DIR="$TB_BIN" \
        GITLAB=on GITLAB_HOSTNAME=example.com \
        bash "$GLAB_SH" >"$TB_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$TB_STATUS_MARKER" ] && [ ! -f "$TB_PROBE_MARKER" ] && grep -qi "manual\|GITLAB_HOSTNAME\|GITLAB_TOKEN" "$TB_OUT"; then
        pass "TB: glab.sh — HOSTNAME without TOKEN -> manual auth message, auth status + probe not called"
    else
        fail "TB: rc=$RC status_called=$([ -f "$TB_STATUS_MARKER" ] && echo yes || echo no) probe_called=$([ -f "$TB_PROBE_MARKER" ] && echo yes || echo no) out=$(head -3 "$TB_OUT")"
    fi
else
    fail "TB: install/linux/glab.sh not found"
fi
case_end

case_begin "TC" "install/linux/glab.sh"
# TC: GITLAB=on + NO HOSTNAME + TOKEN -> auth status NOT called, manual message, no probe, exit 0.
# AGENTS_CONFIG_DIR pinned to the fake bin dir so the real .env cannot leak GITLAB_HOSTNAME.
TC_BIN="$TMP/tc-bin"; mkdir -p "$TC_BIN"
TC_STATUS_MARKER="$TMP/tc-auth-status-marker"
TC_PROBE_MARKER="$TMP/tc-probe-called"
make_glab_stub "$TC_BIN/glab" status "$TC_STATUS_MARKER"
_make_probe_markers "$TC_BIN" "$TC_PROBE_MARKER"
if [ "$GLAB_SH_OK" = "1" ]; then
    TC_OUT="$TMP/tc.log"
    run_with_timeout 15 env -i PATH="$TC_BIN:$PATH" HOME="$TMP/home-tc" AGENTS_CONFIG_DIR="$TC_BIN" \
        GITLAB=on GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >"$TC_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$TC_STATUS_MARKER" ] && [ ! -f "$TC_PROBE_MARKER" ] && grep -qi "manual\|GITLAB_HOSTNAME\|GITLAB_TOKEN" "$TC_OUT"; then
        pass "TC: glab.sh — TOKEN without HOSTNAME -> manual auth message, auth status + probe not called"
    else
        fail "TC: rc=$RC status_called=$([ -f "$TC_STATUS_MARKER" ] && echo yes || echo no) probe_called=$([ -f "$TC_PROBE_MARKER" ] && echo yes || echo no) out=$(head -3 "$TC_OUT")"
    fi
else
    fail "TC: install/linux/glab.sh not found"
fi
case_end

case_begin "T11" "install/linux/glab.sh"
# T11: closed loopback port through the REAL /dev/tcp -> auth skipped with the warning, and
#      bash's own "Connection refused" diagnostic must not leak to the output.
T11_BIN="$TMP/t11-bin"; mkdir -p "$T11_BIN"
T11_LOGIN_MARKER="$TMP/t11-login-called"
make_glab_stub "$T11_BIN/glab" login "$T11_LOGIN_MARKER"
# Ask the kernel for a free port, then release it (port 1 if node is unavailable).
T11_PORT="$(node -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{process.stdout.write(String(s.address().port));s.close()})" 2>/dev/null || true)"
[ -n "$T11_PORT" ] || T11_PORT=1
if [ "$GLAB_SH_OK" = "1" ]; then
    T11_OUT="$TMP/t11.log"
    run_with_timeout 15 env -i PATH="$T11_BIN:$PATH" HOME="$TMP/home-t11" AGENTS_CONFIG_DIR="$T11_BIN" \
        GITLAB=on GITLAB_HOSTNAME=127.0.0.1 GITLAB_TOKEN=glpat-test GLAB_PROBE_PORT="$T11_PORT" \
        bash "$GLAB_SH" >"$T11_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T11_LOGIN_MARKER" ] && grep -q "Cannot connect to 127.0.0.1:$T11_PORT" "$T11_OUT" \
       && ! grep -qi "connection refused" "$T11_OUT"; then
        pass "T11: glab.sh — closed port $T11_PORT via real /dev/tcp -> auth skipped, warning only (no bash diagnostic)"
    else
        fail "T11: rc=$RC port=$T11_PORT login=$([ -f "$T11_LOGIN_MARKER" ] && echo yes || echo no) out=$(head -3 "$T11_OUT")"
    fi
else
    fail "T11: install/linux/glab.sh not found"
fi
case_end
