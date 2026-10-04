=== bin/exec-bit.sh
for f in tests/hooks/*.sh; do chmod +x "$f"; done
=== @allowlist
bin/exec-bit.sh	tests/hooks/*.sh
bin/exec-bit.sh	chmod +x	the executable bit is set on staged shell scripts, not a test discovery
