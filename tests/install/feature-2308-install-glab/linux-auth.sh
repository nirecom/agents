# Sourced by tests/install/feature-2308-install-glab.sh (needs linux-lib.sh).

# ---------------------------------------------------------------------------
# Section 1: GITLAB flag gate
# ---------------------------------------------------------------------------

# T1: GITLAB not set → exit 0, no package manager called (flag gate)
T1_BIN="$TMP/t1-bin"
mkdir -p "$T1_BIN"
T1_PKG_MARKER="$TMP/t1-pkg-called"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T1_PKG_MARKER" > "$T1_BIN/apt-get"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T1_PKG_MARKER" > "$T1_BIN/brew"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T1_BIN/sudo"
chmod +x "$T1_BIN/apt-get" "$T1_BIN/brew" "$T1_BIN/sudo"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_glab_sh 15 "$TMP/home-t1" "$T1_BIN" AGENTS_MAIN_ROOT="$T1_BIN" \
        >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T1_PKG_MARKER" ]; then
        pass "T1: glab.sh — GITLAB not set -> exit 0, no package manager called (flag gate)"
    else
        fail "T1: rc=$RC pkg_called=$([ -f "$T1_PKG_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T1: install/linux/glab.sh not found"
fi

# ---------------------------------------------------------------------------
# Section 2: install/upgrade and fallback behavior (GITLAB=on)
# ---------------------------------------------------------------------------

# T2: GITLAB=on, not installed, package manager fails → exit 0, warning printed
T2_BIN="$TMP/t2-bin"
mkdir -p "$T2_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T2_BIN/apt-get"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T2_BIN/brew"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T2_BIN/sudo"
chmod +x "$T2_BIN/apt-get" "$T2_BIN/brew" "$T2_BIN/sudo"

if [ "$GLAB_SH_OK" = "1" ]; then
    STDOUT_FILE="$TMP/t2-stdout.log"
    STDERR_FILE="$TMP/t2-stderr.log"
    run_glab_sh 15 "$TMP/home-t2" "$T2_BIN" GITLAB=on \
        >"$STDOUT_FILE" 2>"$STDERR_FILE" </dev/null
    RC=$?
    COMBINED="$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null)"
    if [ "$RC" -eq 0 ] && echo "$COMBINED" | grep -qi "manual\|could not\|warning\|failed\|install"; then
        pass "T2: glab.sh — GITLAB=on, pkg manager fails -> exit 0, fallback message printed"
    else
        fail "T2: rc=$RC output=$(printf '%s' "$COMBINED" | head -3)"
    fi
else
    fail "T2: install/linux/glab.sh not found"
fi

# ---------------------------------------------------------------------------
# Section 3: auth behavior (GITLAB=on, glab installed)
# ---------------------------------------------------------------------------

# T3: GITLAB=on, already authenticated (auth status 0) → auth login never called
T3_BIN="$TMP/t3-bin"
mkdir -p "$T3_BIN"
T3_LOGIN_MARKER="$TMP/t3-login-called"
cat > "$T3_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$*" in
  --version*)    echo "glab version 1.0.0" ;;
  auth\ status*) exit 0 ;;
  auth\ login*)  touch "LOGIN_MARKER_PLACEHOLDER"; exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|LOGIN_MARKER_PLACEHOLDER|$T3_LOGIN_MARKER|" "$T3_BIN/glab"
chmod +x "$T3_BIN/glab"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_glab_sh 15 "$TMP/home-t3" "$T3_BIN" GITLAB=on AGENTS_MAIN_ROOT="$T3_BIN" \
        >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T3_LOGIN_MARKER" ]; then
        pass "T3: glab.sh — GITLAB=on, already authenticated -> auth login skipped, exit 0"
    else
        fail "T3: rc=$RC login_called=$([ -f "$T3_LOGIN_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T3: install/linux/glab.sh not found"
fi

# T4: GITLAB=on, no HOSTNAME/TOKEN, not authenticated → auth login NOT called (no creds)
T4_BIN="$TMP/t4-bin"
mkdir -p "$T4_BIN"
T4_LOGIN_MARKER="$TMP/t4-login-called"
cat > "$T4_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$*" in
  --version*)    echo "glab version 1.0.0" ;;
  auth\ status*) exit 1 ;;
  auth\ login*)  touch "LOGIN_MARKER_PLACEHOLDER"; exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|LOGIN_MARKER_PLACEHOLDER|$T4_LOGIN_MARKER|" "$T4_BIN/glab"
chmod +x "$T4_BIN/glab"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_glab_sh 15 "$TMP/home-t4" "$T4_BIN" GITLAB=on AGENTS_MAIN_ROOT="$T4_BIN" \
        >/dev/null 2>/dev/null </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T4_LOGIN_MARKER" ]; then
        pass "T4: glab.sh — GITLAB=on, no creds configured -> auth login never called"
    else
        fail "T4: rc=$RC login_called=$([ -f "$T4_LOGIN_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T4: install/linux/glab.sh not found"
fi

# T5: GITLAB=on + HOSTNAME + TOKEN → glab auth login called with --hostname and --stdin, the
# token arrives on stdin and never on argv (--token would expose it in process listings).
# DNS guard success is mocked (getent/host exit 0, fake timeout execs the probe) so T5 stays
# deterministic once the DNS guard lands — no real network resolution of example.com required.
T5_BIN="$TMP/t5-bin"
mkdir -p "$T5_BIN"
T5_AUTH_ARGS="$TMP/t5-auth-args.txt"
T5_STDIN="$TMP/t5-auth-stdin.txt"
cat > "$T5_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$1" in
  --version)  echo "glab version 1.0.0"; exit 0 ;;
  auth)
    if [ "${2:-}" = "login" ]; then
      echo "$@" >> "AUTH_ARGS_PLACEHOLDER"
      cat > "STDIN_PLACEHOLDER"
    fi
    exit 0 ;;
  config) exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i -e "s|AUTH_ARGS_PLACEHOLDER|$T5_AUTH_ARGS|" -e "s|STDIN_PLACEHOLDER|$T5_STDIN|" "$T5_BIN/glab"
chmod +x "$T5_BIN/glab"
# Probe seam (#2476): the fake timeout records its args and exits 0 WITHOUT exec, so the
# TCP probe never opens a real connection to example.com:443.
T5_PROBE_ARGS="$TMP/t5-probe-args.txt"
make_probe_timeout "$T5_BIN/timeout" 0 "$T5_PROBE_ARGS"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_glab_sh 15 "$TMP/home-t5" "$T5_BIN" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test \
        >/dev/null 2>/dev/null </dev/null
    RC=$?
    AUTH_ARGS="$(cat "$T5_AUTH_ARGS" 2>/dev/null || echo "")"
    AUTH_STDIN="$(cat "$T5_STDIN" 2>/dev/null || echo "")"
    PROBE_ARGS="$(cat "$T5_PROBE_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$AUTH_ARGS" | grep -q -- "--hostname" && \
       echo "$AUTH_ARGS" | grep -q "example.com" && \
       echo "$AUTH_ARGS" | grep -q -- "--stdin" && \
       ! echo "$AUTH_ARGS" | grep -q -- "--token" && \
       ! echo "$AUTH_ARGS" | grep -q "glpat-test" && \
       [ "$AUTH_STDIN" = "glpat-test" ] && \
       echo "$PROBE_ARGS" | grep -qE '(^| )3 .*example\.com.* 443( |$)'; then
        pass "T5: glab.sh — probe seam (3s, host, 443) reachable -> auth login with --hostname and --stdin, token on stdin only"
    else
        fail "T5: rc=$RC auth_args='$AUTH_ARGS' stdin='$AUTH_STDIN' probe_args='$PROBE_ARGS'"
    fi
else
    fail "T5: install/linux/glab.sh not found"
fi

# T6: GITLAB=on + HOSTNAME + TOKEN + SUBFOLDER → glab config set subfolder called
T6_BIN="$TMP/t6-bin"
mkdir -p "$T6_BIN"
T6_CONFIG_ARGS="$TMP/t6-config-args.txt"
cat > "$T6_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$1" in
  --version)  echo "glab version 1.0.0"; exit 0 ;;
  auth)       exit 0 ;;
  config)
    if [ "${2:-}" = "set" ]; then
      echo "$@" >> "CONFIG_ARGS_PLACEHOLDER"
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|CONFIG_ARGS_PLACEHOLDER|$T6_CONFIG_ARGS|" "$T6_BIN/glab"
chmod +x "$T6_BIN/glab"
# Probe seam reports reachable so the subfolder step is reached without real network.
make_probe_timeout "$T6_BIN/timeout" 0 "$TMP/t6-probe-args.txt"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_glab_sh 15 "$TMP/home-t6" "$T6_BIN" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test GITLAB_SUBFOLDER=group1/gitlab \
        >/dev/null 2>/dev/null </dev/null
    RC=$?
    CONFIG_ARGS="$(cat "$T6_CONFIG_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$CONFIG_ARGS" | grep -q "subfolder" && \
       echo "$CONFIG_ARGS" | grep -q "group1/gitlab"; then
        pass "T6: glab.sh — GITLAB_SUBFOLDER -> glab config set subfolder called"
    else
        fail "T6: rc=$RC config_args='$CONFIG_ARGS'"
    fi
else
    fail "T6: install/linux/glab.sh not found"
fi
