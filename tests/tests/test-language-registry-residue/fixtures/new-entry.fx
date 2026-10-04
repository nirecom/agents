=== bin/fake-discovery.sh
for f in tests/hooks/*.fakelang; do add_work "$f"; done
if [ "$kind" = fakelang ]; then :; fi
