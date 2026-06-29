> Shared reference for `skills/write-tests` and `skills/review-tests`. Read explicitly by each skill's Step 1/2.

## Test Case Categories

- **Normal cases**: Expected inputs and typical usage
- **Error cases**: Invalid inputs, missing resources, permission errors
- **Edge cases**: Boundary values and unexpected-but-valid inputs
  - Numeric: 0, negative, `MAX_INT`, off-by-one
  - String: empty `""`, `null`, single character, extremely long
  - Collection: empty array/list, single element, duplicates
  - File/path: non-existent, empty file, special characters in name

- **Idempotency cases**: Re-running the same operation produces the same result without side effects
  - File/config: re-running doesn't duplicate entries (e.g., same line appended twice to `.bashrc`), template generation produces identical output
  - Cleanup: deletion/uninstall of already-removed targets doesn't error

- **Security cases**: Verify that security boundaries hold under adversarial input
  Source: OWASP ASVS V8 (Data Protection), OWASP WSTG (Input Validation), CWE Top 25
  - Secret leakage: secrets never appear in output, logs, temp files, or error messages (OWASP ASVS V8)
  - Input injection: malicious CLI args, file paths, and shell metacharacters are rejected or sanitized (OWASP WSTG, CWE-78 OS Command Injection, CWE-22 Path Traversal)
  - Permission: operations respect access control boundaries — unprivileged callers are denied (OWASP ASVS V4 Access Control)
  - Prompt injection: LLM/agent inputs from untrusted sources do not override system instructions or trigger unintended tool calls (OWASP LLM Top 10 LLM01, MCP Top 10 MCP06)
  - Security idempotency: re-running security-relevant operations (e.g., permission grants, secret rotation) does not escalate privileges or leave duplicate entries (extension of Idempotency cases)

## Security vs Test Compatibility

- Never weaken new security to preserve old tests — update the tests instead.

## Test File Naming

Name test files after the branch they belong to, replacing `/` with `-`:

```
tests/<branch-type>-<branch-name>.<ext>
```

- `feature/claude-rules` → `tests/feature-claude-rules.sh`
- `fix/ssh-keys` → `tests/fix-ssh-keys.sh`
- main direct work: `tests/main-<name>.sh`
- Multiple files per feature: add a suffix (e.g., `feature-claude-rules-global.sh`)

Python (pytest) requires a `test_` prefix for auto-discovery:

| Language | Extension |
|---|---|
| Python (pytest) | `test_<branch-type>-<branch-name>.py` |
| bash | `.sh` |
| PowerShell (Pester) | `.Tests.ps1` |

## Test Layer Selection

Follow Martin Fowler's narrow/broad integration distinction and Kent C. Dodds'
Testing Trophy: pick the lowest test layer that can actually fail when the code
under test is broken.

| Layer | What it must catch |
|---|---|
| Static (schema / lint / types) | Config file structure errors, typos in known schemas |
| Unit | Pure logic of a single function with all I/O mocked |
| Narrow integration | Module reads real config files / env vars / fixtures |
| Broad integration | Real subprocess, real filesystem, real plugin/hook registration |
| Smoke (post-install) | "Is it actually wired up in the real environment?" |

### Mandatory integration or E2E coverage

Add an integration or E2E test (not just unit) when the change touches any of
the following — unit tests are structurally blind to these failure modes:

1. **Configuration files** (`settings.json`, YAML, TOML, etc.) — load the real
   file and assert the feature activates. Consider schema validation as a static
   test.
2. **Hook / plugin / event-handler registration** — the test must verify the
   hook actually fires in the real host process, not just that the handler
   function works when called directly.
3. **Subprocess boundaries** — spawn the real CLI and assert on
   stdout/stderr/exit code/side-effect files.
4. **Cross-module wiring** added or modified (DI, routing, event bus).
5. **Regression for a bug that slipped past unit tests** — the regression test
   must live at the layer that would have caught it.

### Fail-before-fix (BUGFIX sessions only, mandatory)

For BUGFIX sessions (`fix/*` branch), tests must be written and run BEFORE the implementation:
- Write tests that target the broken behavior → confirm they fail.
- Write the fix → confirm tests now pass.
- This fail-before-fix evidence is enforced by the workflow gate: `write_tests` and `review_tests` cannot be skipped in BUGFIX sessions.

### L2 fallback — required gap documentation

When you choose L2 over L3, you MUST add a `# L3 gap` block to the test file header documenting what L3 would additionally verify. Template:

    # L3 gap (what this test does NOT catch):
    # - <observable behavior 1 that only the real environment exhibits>
    # - <observable behavior 2 ...>
    # Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
    # via bin/check-verification-gate.sh category: <category-token>.

A test file without an L3 gap block is treated as a claim of full L3 coverage. `/review-tests` will challenge L1/L2 tests lacking this block when the file matches a risk category.

### Deciding whether to write an integration test

Ask: *"If someone deleted the registration / misplaced the config key / renamed
the event, would my unit tests still pass?"* If yes, a unit test is not enough.

## Required Frontmatter

Every `tests/*.sh` file (excluding `tests/_archive/`) must carry exactly two single-line
headers within the first 10 lines, right after the shebang and filename comment:

- `# Tests: <path1>, <path2>` — comma-separated repo-relative source paths (forward slash). Used by `bin/audit-tests.sh` for staleness checks and by Tier 2 semantic selection.
- `# Tags: <kw1>, <kw2>` — comma-separated kebab-case keywords. Used by the LLM Tier 2 matcher in `skills/run-tests/SKILL.md`.

Both lines are **single-line** — no multi-line blocks, no YAML-style `- ` continuation. Long lines are acceptable; parsers rely on single-line format.

- Recognized `# Tags:` values (non-exhaustive): `pwsh-required` — this file exercises PowerShell-specific behavior and must be re-verified under pwsh before merge. `pwsh-not-required` — explicit opt-out for files that mention `powershell` only in comments or docs.

## Scope Classification

- Filename convention classifies test files:
  - `feature-NNN-*` (numeric issue ID after `feature-`) = `scope:issue-specific`
  - All other files = `scope:common`
- Recognized `# Tags:` values: `scope:issue-specific`, `scope:common`.
- New or edited test files MUST include `scope:issue-specific` or `scope:common` in their `# Tags:`.
- Existing files without this tag are classified by filename convention; backfill of existing files is not required.

## Size Limits

- Same limits as code files: WARN at >300 lines, HARD at >500 lines.
- Split mechanism: same as code — `tests/<name>/` sibling folder with a dispatcher `.sh`. See `rules/coding/file-split.md`.
- Canonical split example: `tests/main-workflow-skip-sentinels/` (PR #867).
- `tests/_archive/` is excluded from size checks.

## Test Naming Convention (new tests only)

New test files follow `<area>-<issue-or-feature>-<topic>.sh` where `<area>` is one of `feature`, `fix`, `refactor`, `unit`, `main`.

Existing files are NOT renamed — `git blame` continuity is preserved. Frontmatter handles semantic grouping via `# Tags:`.

## Table-Driven Tests (パーサ/正規表現/allowlist 変更時必須)

パーサ、正規表現定数、または allowlist を変更する場合（例: sentinel-patterns.js,
bash-write-patterns.js, command-parser.js, scan-outbound.sh など）は、対応するテスト
ファイルで table-driven パターンを使用すること。

### bash テストの標準パターン

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got=$(eval_subject "$input")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
case-name-1 | input value 1 | expected-1
case-name-2 | input value 2 | expected-2
TABLE

assert_eq() を各テストファイルにインラインで定義する（共有ライブラリは使用しない）:

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

- 第1カラム name は全アサーションメッセージに注入する（Go の t.Run(name) 相当）
- IFS='|' によりフィールド内のスペースをクォートなしで許容。read -r でバックスラッシュ展開を防ぐ
- heredoc 内の空行・# コメント行はスキップする

### JS テストの同等パターン

JS テストでは以下を table-driven と見なす:
- cases.forEach() による反復
- for (const {name, input, want} of cases) による反復
- 各反復内で name をアサーションメッセージに含む

### このルールの適用条件

以下のいずれかに該当する場合:
- パターンファイルの正規表現定数を追加または変更する場合
- 同一関数を異なる入力でテストするケースが2件以上ある場合
- パーサ/regex/allowlist 対象の既存テストファイルに論理パスあたり2件未満のケースしかない場合

## Mutation Probe (軽量正規表現 kill 確認)

パーサ/正規表現ファイルに対して以下の場合に mutation probe を実行すること:
- 新しい正規表現定数を追加する場合（その定数を削除したときにテストが FAIL することを確認）
- 正規表現バグを修正する場合（未修正状態でリグレッションテストが FAIL することを確認）

### プローブ実行

bin/mutation-probe.sh <target-js-file>

プローブスクリプトの動作:
1. 対象ファイルの正規表現定数（単一行の const NAME = /regex/; 形式）を特定する
2. 各定数を /(?!)/ (never-match) に差し替えた一時コピーでテストを実行する
3. PASS および FAIL を記録する
4. mutation スコア = FAIL 数 / 総数 × 100% を算出して報告する

必須閾値: プローブ対象の正規表現定数の 80% 以上でテストが FAIL すること。

### 既知の制限 (Partial Coverage)

bin/mutation-probe.sh は単一行形式（const NAME = /regex/;）のみを対象とする。
以下は現バージョンではカバーされない:
- 2行形式（const NAME =\n  /regex/;）: sentinel-patterns.js に多数存在
- オブジェクトリテラル内のパターン（WRITE_PATTERNS 配列の regex フィールド）: bash-write-patterns.js

これらのファイルに対してプローブを実行した場合、スクリプトは検出済み定数数と
「partial coverage」警告を出力する。完全なカバレッジは T1-E2（Stryker）で対応予定。

### table-driven との関係

- table-driven: 入出力ケースをパラメトリックにカバーする
- mutation probe: 各正規表現定数が実際にテストで使われているか（dead code でないか）を確認する

パーサ/正規表現ファイルに追記する場合は両方を実行すること。

## False-Green 検出

false-green テスト（コードの状態によらず常に pass するテスト）は禁止。
以下のパターンは bin/check-false-green.sh によって検出される。

### 禁止パターン

1. アサーション不在の空テスト関数/ブロック
2. want と got が同じリテラルのアサーション: assert_eq name "x" "x"（両辺ハードコード）
3. exit コードを確認せずに pass "..." を呼ぶパターン（アンチェック）

### bin/check-false-green.sh のスコープ

grep ベース検出。パターン2をハード検出（FALSE-GREEN、終了コード 1）、行頭近傍の bare
pass を WARN 出力（終了コード 0）。パターン1・3（AST 解析が必要）は将来課題。

bare pass の WARN は誤検知（pass() 関数定義行）を含むため、CI でハード失敗させない。

### 背景

PR #865 で事後修正が必要になった 11 件の dead assertion が動機。
false-green 検出器を作成時点で適用することで再発を防ぐ。

## セキュリティ・保護系 Fix のテストパターン (#1001)

保護系 fix（セキュリティ境界、入力サニタイズ、アクセス制御強制）のテストでは
以下の3パターンをすべて適用すること。いずれか1つでも欠けると構造的カバレッジギャップになる。

### パターン1 — Negative アサーション

拒否された入力に対して、保護対象リソースが変更されていないことを directly アサートする。
exit コードやエラーメッセージのアサーションだけでは不十分。

例: symlink フォロー防止の修正では、コマンドが非ゼロで終了したことに加えて
リンク先ファイルが変更されていないことをアサートする。

### パターン2 — 攻撃シナリオ構造

bugfix テストは未修正コードで FAIL するように構造化する:
1. 修正前の脆弱な状態を再現する前提条件をセットアップする
2. テスト対象のアクションを実行する
3. 攻撃がブロックされた（保護対象リソースが未変更）ことをアサートする

この構造により、ワークフローレベルの fail-before-fix gate を補完するテスト層の証拠が得られる。

### パターン3 — Paired gap (Skipped-Because)

現レイヤーで実装できないシナリオ（fault インジェクションが必要、CI で再現不可など）は
削除せず以下の形式で残す:

# SKIPPED: <シナリオ説明>
# Because: <理由 — 例: "実 root アクセスが必要", "L2 では fault injection 不可">
# L3 gap: <実環境のみが検出できること>

1 シナリオにつき 1 つの Skipped-Because コメント。対象テストコードに隣接して配置する。
