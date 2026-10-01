# Sourced by tests/install/feature-2308-install-glab.sh outside any case span:
# shared by linux-auth.sh and linux-dns.sh.

# TCP probe seam (#2476): a fake `timeout` that records its
# args ("3 <bash> -c … <host> <port>") and exits <rc> WITHOUT exec — no real connection.
make_probe_timeout() {  # $1=path  $2=rc  $3=record file
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit %s\n' "$3" "$2" > "$1"
    chmod +x "$1"
}
