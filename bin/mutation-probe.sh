#!/usr/bin/env bash
# bin/mutation-probe.sh
# T1-E1: 軽量 mutation probe — 単一行 const NAME = /regex/; 形式の正規表現定数を
# 1つずつ /(?!)/ に差し替えてテストが FAIL することを確認する。
#
# 使用法: mutation-probe.sh [options] <target-js-file>
#   --help        このヘルプを表示して終了する
#   --test-cmd    テスト実行コマンドを指定する（デフォルト: 自動検出）
#   --threshold   合格閾値 % を指定する（デフォルト: 80）
#
# 終了コード:
#   0 = mutation score が閾値以上
#   1 = mutation score が閾値未満（カバレッジギャップ）または定数未検出
#   2 = 使用エラーまたはファイル未検出

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

show_help() {
    cat <<'HELP'
Usage: mutation-probe.sh [options] <target-js-file>

T1-E1 lightweight mutation probe. Mutates single-line const NAME = /regex/; declarations
one at a time and verifies that the test suite FAILs for each mutation.

Options:
  --help        Show this help and exit (exit 0)
  --test-cmd    Test command to run (default: auto-detect from # Tests: header)
  --threshold   Pass threshold in % (default: 80)

Exit codes:
  0 = mutation score meets threshold
  1 = mutation score below threshold or no regex constants found
  2 = usage error or target file not found

Partial coverage: only single-line const NAME = /regex/; form is handled.
Multi-line forms and WRITE_PATTERNS arrays are excluded (T1-E2/Stryker target).
HELP
}

TARGET=""
TEST_CMD=""        # --test-cmd: trusted operator string, executed via bash -c
TEST_CMD_ARGV=()   # auto-detect: safe array, executed directly
USE_ARGV=false
THRESHOLD=80

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            exit 0
            ;;
        --test-cmd)
            TEST_CMD="$2"
            shift 2
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            show_help >&2
            exit 2
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "ERROR: target JS file required" >&2
    show_help >&2
    exit 2
fi

# Resolve absolute path
if [[ "$TARGET" != /* ]]; then
    TARGET="$REPO_ROOT/$TARGET"
fi

if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: file not found: $TARGET" >&2
    exit 2
fi

basename_target="$(basename "$TARGET")"

# Emit partial coverage warnings for known files
case "$basename_target" in
    sentinel-patterns.js)
        echo "WARNING: sentinel-patterns.js には2行形式の定数が多数含まれます。" >&2
        echo "         単一行形式のみを対象とします（partial coverage）。" >&2
        echo "         完全なカバレッジは T1-E2（Stryker）で対応予定。" >&2
        ;;
    bash-write-patterns.js)
        echo "WARNING: bash-write-patterns.js の WRITE_PATTERNS 配列内の regex フィールドは" >&2
        echo "         対象外です（partial coverage）。単一行 const 形式のみを対象とします。" >&2
        ;;
esac

# Auto-detect test command if not specified
if [[ -z "$TEST_CMD" ]]; then
    bname_noext="${basename_target%.js}"
    if [[ -f "$REPO_ROOT/tests/lib/test-${bname_noext}.js" ]]; then
        TEST_CMD_ARGV=(node "$REPO_ROOT/tests/lib/test-${bname_noext}.js")
        USE_ARGV=true
    else
        sh_test="$(grep -rl "# Tests:.*${basename_target}" "$REPO_ROOT/tests" --include="*.sh" 2>/dev/null | head -1 || true)"
        if [[ -n "$sh_test" ]]; then
            TEST_CMD_ARGV=(bash "$sh_test")
            USE_ARGV=true
        else
            echo "ERROR: no test file found for $basename_target" >&2
            echo "       Use --test-cmd to specify the test command." >&2
            exit 2
        fi
    fi
fi

TARGET_ABS="$TARGET"
BACKUP="${TARGET_ABS}.probe-backup"

# Safety trap: always restore backup on exit
trap 'rc=$?; if [[ -f "$BACKUP" ]]; then mv "$BACKUP" "$TARGET_ABS"; fi; exit $rc' EXIT INT TERM

TOTAL=0
KILLED=0

# Find single-line const regex declarations
# Pattern: const NAME = /.../ [flags];
CONST_PATTERN='^[[:space:]]*const[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*/[^/].*[gimsuvyd]*;'

mapfile -t MATCHES < <(grep -n "$CONST_PATTERN" "$TARGET_ABS" 2>/dev/null || true)

for match in "${MATCHES[@]}"; do
    [[ -z "$match" ]] && continue
    lineno="${match%%:*}"
    line="${match#*:}"

    # Extract const name
    const_name="$(echo "$line" | grep -oE 'const[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | head -1 | awk '{print $NF}' || true)"
    [[ -z "$const_name" ]] && continue
    # Guard: const_name must be a plain identifier (no shell metacharacters for sed safety)
    [[ "$const_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    TOTAL=$((TOTAL + 1))

    # Backup original
    cp "$TARGET_ABS" "$BACKUP"

    # Replace the matching line with a never-match mutation (use | as sed delimiter)
    sed -i "${lineno}s|.*|const ${const_name} = /(?!)/; // MUTATED by mutation-probe.sh|" "$TARGET_ABS"

    # Run test and capture exit code
    # Auto-detect case: use array to avoid quote-injection (M1 security fix)
    # --test-cmd case: trusted operator input, bash -c is acceptable
    test_rc=0
    if $USE_ARGV; then
        "${TEST_CMD_ARGV[@]}" >/dev/null 2>&1 || test_rc=$?
    else
        bash -c "$TEST_CMD" >/dev/null 2>&1 || test_rc=$?
    fi

    # Restore from backup
    mv "$BACKUP" "$TARGET_ABS"

    if [[ $test_rc -ne 0 ]]; then
        echo "KILLED: $const_name (line $lineno)"
        KILLED=$((KILLED + 1))
    else
        echo "LIVE:   $const_name (line $lineno — coverage gap)"
    fi
done

if [[ $TOTAL -eq 0 ]]; then
    echo "INFO: no single-line const regex found in $TARGET" >&2
    echo "      (partial coverage — see bin/mutation-probe.sh --help)" >&2
    exit 1
fi

SCORE=$(( KILLED * 100 / TOTAL ))
echo ""
echo "=== Mutation Score ==="
echo "KILLED: $KILLED / $TOTAL (score: ${SCORE}%)"
echo "Threshold: ${THRESHOLD}%"

if [[ $SCORE -ge $THRESHOLD ]]; then
    echo "PASS: mutation score meets threshold"
    exit 0
else
    echo "FAIL: mutation score below threshold"
    exit 1
fi
