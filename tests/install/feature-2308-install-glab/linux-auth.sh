# ---------------------------------------------------------------------------
# Section 1: GITLAB flag gate
# ---------------------------------------------------------------------------

case_begin "T1" "install/linux/glab.sh"
# T1: GITLAB not set → exit 0, no package manager called (flag gate)
T1_BIN="$TMP/t1-bin"
mkdir -p "$T1_BIN"
T1_PKG_MARKER="$TMP/t1-pkg-called"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T1_PKG_MARKER" > "$T1_BIN/apt-get"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T1_PKG_MARKER" > "$T1_BIN/brew"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T1_BIN/sudo"
chmod +x "$T1_BIN/apt-get" "$T1_BIN/brew" "$T1_BIN/sudo"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T1_BIN:$PATH" HOME="$TMP/home-t1" AGENTS_CONFIG_DIR="$T1_BIN" \
        bash "$GLAB_SH" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T1_PKG_MARKER" ]; then
        pass "T1: glab.sh — GITLAB not set -> exit 0, no package manager called (flag gate)"
    else
        fail "T1: rc=$RC pkg_called=$([ -f "$T1_PKG_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T1: install/linux/glab.sh not found"
fi
case_end

# ---------------------------------------------------------------------------
# Section 2: install/upgrade and fallback behavior (GITLAB=on)
# ---------------------------------------------------------------------------

case_begin "T2" "install/linux/glab.sh"
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
    run_with_timeout 15 env -i PATH="$T2_BIN:$PATH" HOME="$TMP/home-t2" GITLAB=on \
        bash "$GLAB_SH" >"$STDOUT_FILE" 2>"$STDERR_FILE" </dev/null
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
case_end

# ---------------------------------------------------------------------------
# Section 3: auth behavior (GITLAB=on, glab installed)
# ---------------------------------------------------------------------------

case_begin "T3" "install/linux/glab.sh"
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
    run_with_timeout 15 env -i PATH="$T3_BIN:$PATH" HOME="$TMP/home-t3" GITLAB=on AGENTS_CONFIG_DIR="$T3_BIN" \
        bash "$GLAB_SH" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T3_LOGIN_MARKER" ]; then
        pass "T3: glab.sh — GITLAB=on, already authenticated -> auth login skipped, exit 0"
    else
        fail "T3: rc=$RC login_called=$([ -f "$T3_LOGIN_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T3: install/linux/glab.sh not found"
fi
case_end

case_begin "T4" "install/linux/glab.sh"
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
    run_with_timeout 15 env -i PATH="$T4_BIN:$PATH" HOME="$TMP/home-t4" GITLAB=on AGENTS_CONFIG_DIR="$T4_BIN" \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T4_LOGIN_MARKER" ]; then
        pass "T4: glab.sh — GITLAB=on, no creds configured -> auth login never called"
    else
        fail "T4: rc=$RC login_called=$([ -f "$T4_LOGIN_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T4: install/linux/glab.sh not found"
fi
case_end

case_begin "T5" "install/linux/glab.sh"
# T5: GITLAB=on + HOSTNAME + TOKEN → glab auth login called with --hostname and --token flags
# DNS guard success is mocked (getent/host exit 0, fake timeout execs the probe) so T5 stays
# deterministic once the DNS guard lands — no real network resolution of example.com required.
T5_BIN="$TMP/t5-bin"
mkdir -p "$T5_BIN"
T5_AUTH_ARGS="$TMP/t5-auth-args.txt"
cat > "$T5_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$1" in
  --version)  echo "glab version 1.0.0"; exit 0 ;;
  auth)
    if [ "${2:-}" = "login" ]; then
      echo "$@" >> "AUTH_ARGS_PLACEHOLDER"
    fi
    exit 0 ;;
  config) exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|AUTH_ARGS_PLACEHOLDER|$T5_AUTH_ARGS|" "$T5_BIN/glab"
chmod +x "$T5_BIN/glab"
# DNS guard success mock: resolvers exit 0; fake timeout drops the duration then execs the probe.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T5_BIN/getent"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T5_BIN/host"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$T5_BIN/timeout"
chmod +x "$T5_BIN/getent" "$T5_BIN/host" "$T5_BIN/timeout"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T5_BIN:$PATH" HOME="$TMP/home-t5" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    AUTH_ARGS="$(cat "$T5_AUTH_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$AUTH_ARGS" | grep -q -- "--hostname" && \
       echo "$AUTH_ARGS" | grep -q "example.com" && \
       echo "$AUTH_ARGS" | grep -q -- "--token"; then
        pass "T5: glab.sh — GITLAB_HOSTNAME+TOKEN -> auth login called with --hostname and --token"
    else
        fail "T5: rc=$RC auth_args='$AUTH_ARGS'"
    fi
else
    fail "T5: install/linux/glab.sh not found"
fi
case_end

case_begin "T6" "install/linux/glab.sh"
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

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T6_BIN:$PATH" HOME="$TMP/home-t6" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test GITLAB_SUBFOLDER=group1/gitlab \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
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
case_end

# Helper (T8/T9): glab stub touching MARKER when `auth <SUB>` runs; else exit 0.
# AGENTS_CONFIG_DIR is pinned to the (dot-env-less) fake bin dir so the developer's
# real .env cannot leak GITLAB_HOSTNAME/TOKEN into the no-cred paths (fixture isolation).
make_glab_stub() {  # $1=path  $2=auth-subcmd  $3=marker
    printf '#!/usr/bin/env bash\nif [ "$1" = "--version" ]; then echo "glab version 1.0.0"; exit 0; fi\nif [ "$1" = "auth" ] && [ "$2" = "%s" ]; then touch "%s"; exit 0; fi\nexit 0\n' "$2" "$3" > "$1"
    chmod +x "$1"
}
