# Sourced by tests/install/feature-2308-install-glab.sh outside any case span:
# shared by linux-auth.sh and linux-dns.sh.

# TCP probe seam (#2476): a fake `timeout` that records its
# args ("3 <bash> -c … <host> <port>") and exits <rc> WITHOUT exec — no real connection.
make_probe_timeout() {  # $1=path  $2=rc  $3=record file
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit %s\n' "$3" "$2" > "$1"
    chmod +x "$1"
}

# run_glab_sh <secs> <home> <bin-dir> [NAME=VALUE…] — run install/linux/glab.sh under
# `env -i` with HOME and USERPROFILE both pinned at <home>; the caller redirects.
# Subshell: the pin must not outlive this run.
run_glab_sh() {
    local secs="$1" home_dir="$2" bin_dir="$3"; shift 3
    (
    pin_home_and_userprofile "$home_dir"
    run_with_timeout "$secs" env -i PATH="$bin_dir:$PATH" HOME="$HOME" USERPROFILE="$USERPROFILE" "$@" \
        bash "$GLAB_SH"
    )
}
