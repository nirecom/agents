=== bin/format-scripts.sh
ROOT="${1:-.}"
find "$ROOT" -name '*.sh' -print0 | xargs -0 shfmt -w
git diff --cached --name-only -- '*.sh'
