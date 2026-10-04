=== bin/exec-bit.sh
for f in tests/hooks/*.sh; do chmod +x "$f"; done
echo "plain line naming tests/run-all.sh only"
=== @allowlist
bin/exec-bit.sh	chmod +x	sets the executable bit only; listed to prove a used entry is not stale
bin/exec-bit.sh	plain line naming	stale: this line carries no pattern word, name pair or id comparison
