case_begin "T8" "install/linux/glab.sh"
# T8: GITLAB=on + HOSTNAME + TOKEN + DNS failure -> auth login NOT called, warning printed, exit 0
T8_BIN="$TMP/t8-bin"; mkdir -p "$T8_BIN"
T8_LOGIN_MARKER="$TMP/t8-login-called"
make_glab_stub "$T8_BIN/glab" login "$T8_LOGIN_MARKER"
# Fake resolvers exit 1 (DNS failure, no network); fake timeout drops the duration then execs the rest.
printf '#!/usr/bin/env bash\nexit 1\n' > "$T8_BIN/getent"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T8_BIN/host"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$T8_BIN/timeout"
chmod +x "$T8_BIN/getent" "$T8_BIN/host" "$T8_BIN/timeout"
if [ "$GLAB_SH_OK" = "1" ]; then
    T8_OUT="$TMP/t8.log"
    run_with_timeout 15 env -i PATH="$T8_BIN:$PATH" HOME="$TMP/home-t8" AGENTS_CONFIG_DIR="$T8_BIN" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >"$T8_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T8_LOGIN_MARKER" ] && grep -qi "warning\|unreachable\|skip" "$T8_OUT"; then
        pass "T8: glab.sh — DNS failure -> auth login skipped, warning printed, exit 0"
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
# T10 (C1): GITLAB=on + HOSTNAME + TOKEN + hanging resolver (getent sleeps 30s) ->
#           the DNS guard must bound the probe with the real `timeout` (no fake timeout
#           is injected), treat it as failure, skip auth login, and exit 0 quickly —
#           well under the 8s wrapper.
T10_BIN="$TMP/t10-bin"; mkdir -p "$T10_BIN"
T10_LOGIN_MARKER="$TMP/t10-login-called"
make_glab_stub "$T10_BIN/glab" login "$T10_LOGIN_MARKER"
printf '#!/usr/bin/env bash\nsleep 30\nexit 0\n' > "$T10_BIN/getent"
printf '#!/usr/bin/env bash\nsleep 30\nexit 0\n' > "$T10_BIN/host"
chmod +x "$T10_BIN/getent" "$T10_BIN/host"
if [ "$GLAB_SH_OK" = "1" ]; then
    T10_OUT="$TMP/t10.log"
    run_with_timeout 8 env -i PATH="$T10_BIN:$PATH" HOME="$TMP/home-t10" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >"$T10_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T10_LOGIN_MARKER" ]; then
        pass "T10: glab.sh — hanging resolver -> DNS probe bounded, auth login skipped, exit 0"
    else
        fail "T10: rc=$RC login=$([ -f "$T10_LOGIN_MARKER" ] && echo yes || echo no) out=$(head -3 "$T10_OUT")"
    fi
else
    fail "T10: install/linux/glab.sh not found"
fi
case_end

case_begin "TA" "install/linux/glab.sh"
# TA (C2): GITLAB=on + HOSTNAME + TOKEN + resolver SUCCESS -> auth login IS called AND
#          the DNS guard probed the configured hostname (fake getent records its args).
TA_BIN="$TMP/ta-bin"; mkdir -p "$TA_BIN"
TA_AUTH_ARGS="$TMP/ta-auth-args.txt"
TA_GETENT_ARGS="$TMP/ta-getent-args.txt"
TA_HOST="ta-host.example.com"
cat > "$TA_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$1" in
  --version)  echo "glab version 1.0.0"; exit 0 ;;
  auth)
    if [ "${2:-}" = "login" ]; then echo "$@" >> "AUTH_ARGS_PLACEHOLDER"; fi
    exit 0 ;;
  config) exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|AUTH_ARGS_PLACEHOLDER|$TA_AUTH_ARGS|" "$TA_BIN/glab"
chmod +x "$TA_BIN/glab"
# Resolver success + arg recorder; fake timeout drops the duration then execs the probe.
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$TA_GETENT_ARGS" > "$TA_BIN/getent"
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$TA_GETENT_ARGS" > "$TA_BIN/host"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$TA_BIN/timeout"
chmod +x "$TA_BIN/getent" "$TA_BIN/host" "$TA_BIN/timeout"
if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$TA_BIN:$PATH" HOME="$TMP/home-ta" \
        GITLAB=on GITLAB_HOSTNAME="$TA_HOST" GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    AUTH_ARGS="$(cat "$TA_AUTH_ARGS" 2>/dev/null || echo "")"
    GETENT_ARGS="$(cat "$TA_GETENT_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$AUTH_ARGS" | grep -q -- "--hostname" && \
       echo "$AUTH_ARGS" | grep -q "$TA_HOST" && \
       echo "$AUTH_ARGS" | grep -q -- "--token" && \
       echo "$GETENT_ARGS" | grep -q "$TA_HOST"; then
        pass "TA: glab.sh — resolver success -> auth login called, guard probed configured hostname"
    else
        fail "TA: rc=$RC auth='$AUTH_ARGS' getent='$GETENT_ARGS'"
    fi
else
    fail "TA: install/linux/glab.sh not found"
fi
case_end

case_begin "TA-MAC" "install/linux/glab.sh"
# TA-MAC (C2): fake uname=Darwin -> macOS DNS branch must probe with 'host' (not getent).
#   Verifies host received the configured hostname, getent was NOT called, and auth login ran.
#   The real Darwin `host` binary stays a TL3 gap; this proves branch selection only.
TA_MAC_BIN="$TMP/ta-mac-bin"; mkdir -p "$TA_MAC_BIN"
TA_MAC_HOST_ARGS="$TMP/ta-mac-host-args.txt"
TA_MAC_GETENT_MARKER="$TMP/ta-mac-getent-called"
TA_MAC_AUTH_ARGS="$TMP/ta-mac-auth-args.txt"
TA_MAC_HOST="mac.example.com"
cat > "$TA_MAC_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$1" in
  --version)  echo "glab version 1.0.0"; exit 0 ;;
  auth)
    if [ "${2:-}" = "login" ]; then echo "$@" >> "AUTH_ARGS_PLACEHOLDER"; fi
    exit 0 ;;
  config) exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|AUTH_ARGS_PLACEHOLDER|$TA_MAC_AUTH_ARGS|" "$TA_MAC_BIN/glab"
chmod +x "$TA_MAC_BIN/glab"
# Fake uname forces the Darwin branch; host records its args; getent (Linux branch) must not run;
# brew stub absorbs the Darwin upgrade path; fake timeout drops the duration then execs the probe.
printf '#!/usr/bin/env bash\necho "Darwin"\n' > "$TA_MAC_BIN/uname"
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$TA_MAC_HOST_ARGS" > "$TA_MAC_BIN/host"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$TA_MAC_GETENT_MARKER" > "$TA_MAC_BIN/getent"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$TA_MAC_BIN/timeout"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TA_MAC_BIN/brew"
chmod +x "$TA_MAC_BIN/uname" "$TA_MAC_BIN/host" "$TA_MAC_BIN/getent" "$TA_MAC_BIN/timeout" "$TA_MAC_BIN/brew"
if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$TA_MAC_BIN:$PATH" HOME="$TMP/home-ta-mac" AGENTS_CONFIG_DIR="$TA_MAC_BIN" \
        GITLAB=on GITLAB_HOSTNAME="$TA_MAC_HOST" GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    MAC_AUTH_ARGS="$(cat "$TA_MAC_AUTH_ARGS" 2>/dev/null || echo "")"
    MAC_HOST_ARGS="$(cat "$TA_MAC_HOST_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$MAC_HOST_ARGS" | grep -q "$TA_MAC_HOST" && \
       [ ! -f "$TA_MAC_GETENT_MARKER" ] && \
       echo "$MAC_AUTH_ARGS" | grep -q -- "--hostname" && echo "$MAC_AUTH_ARGS" | grep -q "$TA_MAC_HOST"; then
        pass "TA-MAC: glab.sh — fake uname=Darwin -> host probed hostname (not getent), auth login called"
    else
        fail "TA-MAC: rc=$RC host_args='$MAC_HOST_ARGS' getent_called=$([ -f "$TA_MAC_GETENT_MARKER" ] && echo yes || echo no) auth='$MAC_AUTH_ARGS'"
    fi
else
    fail "TA-MAC: install/linux/glab.sh not found"
fi
case_end

# TL3 gap — TA-MAC-NOTO: Darwin background+kill fallback (no gtimeout, no timeout) requires a
# real macOS host without timeout utilities; system /usr/bin/timeout cannot be reliably excluded
# from PATH on Linux so the elif-timeout branch would fire instead of the kill-after else branch.
# Covered in the TL3 suite via a real Darwin runner.

case_begin "TB" "install/linux/glab.sh"
# TB (C3): GITLAB=on + HOSTNAME but NO TOKEN -> partial creds:
#          glab auth status NOT called, manual-setup message printed, exit 0.
# DNS gate: the guard exists only to protect a real `glab auth login`, which needs BOTH
#          HOSTNAME and TOKEN. With no TOKEN no login is attempted, so DNS must NOT be probed
#          (symmetric with TC; the both-set DNS-probe path is covered by TA). getent/host touch
#          a marker verified absent.
# AGENTS_CONFIG_DIR pinned to the (dot-env-less) fake bin dir so the real .env cannot
# leak GITLAB_TOKEN into this partial-cred path (fixture isolation).
TB_BIN="$TMP/tb-bin"; mkdir -p "$TB_BIN"
TB_STATUS_MARKER="$TMP/tb-auth-status-marker"
make_glab_stub "$TB_BIN/glab" status "$TB_STATUS_MARKER"
TB_DNS_MARKER="$TMP/tb-dns-called"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TB_DNS_MARKER" > "$TB_BIN/getent"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TB_DNS_MARKER" > "$TB_BIN/host"
chmod +x "$TB_BIN/getent" "$TB_BIN/host"
if [ "$GLAB_SH_OK" = "1" ]; then
    TB_OUT="$TMP/tb.log"
    run_with_timeout 15 env -i PATH="$TB_BIN:$PATH" HOME="$TMP/home-tb" AGENTS_CONFIG_DIR="$TB_BIN" \
        GITLAB=on GITLAB_HOSTNAME=example.com \
        bash "$GLAB_SH" >"$TB_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$TB_STATUS_MARKER" ] && [ ! -f "$TB_DNS_MARKER" ] && grep -qi "manual\|GITLAB_HOSTNAME\|GITLAB_TOKEN" "$TB_OUT"; then
        pass "TB: glab.sh — HOSTNAME without TOKEN -> manual auth message, auth status + DNS not called"
    else
        fail "TB: rc=$RC status_called=$([ -f "$TB_STATUS_MARKER" ] && echo yes || echo no) dns_called=$([ -f "$TB_DNS_MARKER" ] && echo yes || echo no) out=$(head -3 "$TB_OUT")"
    fi
else
    fail "TB: install/linux/glab.sh not found"
fi
case_end

case_begin "TC" "install/linux/glab.sh"
# TC (C3): GITLAB=on + NO HOSTNAME + TOKEN set -> partial creds:
#          glab auth status NOT called, manual-setup message printed, exit 0.
# AGENTS_CONFIG_DIR pinned to the fake bin dir so the real .env cannot leak GITLAB_HOSTNAME.
TC_BIN="$TMP/tc-bin"; mkdir -p "$TC_BIN"
TC_STATUS_MARKER="$TMP/tc-auth-status-marker"
make_glab_stub "$TC_BIN/glab" status "$TC_STATUS_MARKER"
# DNS marker: getent/host touch it — no HOSTNAME means the guard must NOT probe DNS at all.
TC_DNS_MARKER="$TMP/tc-dns-called"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TC_DNS_MARKER" > "$TC_BIN/getent"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TC_DNS_MARKER" > "$TC_BIN/host"
chmod +x "$TC_BIN/getent" "$TC_BIN/host"
if [ "$GLAB_SH_OK" = "1" ]; then
    TC_OUT="$TMP/tc.log"
    run_with_timeout 15 env -i PATH="$TC_BIN:$PATH" HOME="$TMP/home-tc" AGENTS_CONFIG_DIR="$TC_BIN" \
        GITLAB=on GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >"$TC_OUT" 2>&1 </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$TC_STATUS_MARKER" ] && [ ! -f "$TC_DNS_MARKER" ] && grep -qi "manual\|GITLAB_HOSTNAME\|GITLAB_TOKEN" "$TC_OUT"; then
        pass "TC: glab.sh — TOKEN without HOSTNAME -> manual auth message, auth status + DNS not called"
    else
        fail "TC: rc=$RC status_called=$([ -f "$TC_STATUS_MARKER" ] && echo yes || echo no) dns_called=$([ -f "$TC_DNS_MARKER" ] && echo yes || echo no) out=$(head -3 "$TC_OUT")"
    fi
else
    fail "TC: install/linux/glab.sh not found"
fi
case_end
