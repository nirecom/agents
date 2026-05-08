# Todo

## Current Work

### install/win/global-gitignore.ps1 の Pester テスト追加

bash 版 (`global-gitignore.sh`) は `tests/feature-parallel-sessions-worktree-installer-ignore.sh` でカバーされているが、PowerShell 版 (`global-gitignore.ps1`) は無テスト。今回 `.Count` バグ（空 Where-Object 結果での null 参照）が production で初めて発覚したのはこのカバレッジ欠落が原因。
- [ ] Pester ベースのテストファイル追加 (`tests/feature-parallel-sessions-worktree-installer-ignore.Tests.ps1`)
- [ ] bash 版と同等のケース網羅: 初回作成、idempotent 再実行、既存ファイル末尾追記、マーカー破損 (BEGIN-only / END-only / 2x BEGIN)、空ファイル、巨大ファイル
- [ ] CI で Windows 上で実行されるよう設定（GitHub Actions windows-latest 等）

### commit gate の「commit 前ステップが commit 後の状態に依存する」設計矛盾

**根本原因**: workflow-gate は commit 前に全ステップ（review → user_verification）の完了を要求する。しかし一部のステップは commit 後の状態に依存するため、鶏と卵の問題が発生する。

**前提の整理**:
- `review-code-codex` (`git diff BASE...HEAD`): **commit 必要**、push 不要
- `gh pr create`: **commit + push 両方必要**（push なしでは branch がリモートに存在しない）

**既知の発生パターン**:

1. **review-code-codex が実行できない**: commit 済み差分のみ対象だが、commit には user_verification が必要で、user_verification は review 後に行うもの。
   - 発生条件: 実装完了まで一度もコミットしない場合
   - 当面の回避策: `git diff --cached` を直接 codex に流す

2. **fixup commit でも user_verification が再要求される**: 本実装 commit 後に小さな修正（SKILL.md 誤削除の復元等）を加えると、同一セッション内でも commit gate が user_verification を再度要求する。review-code-codex も同様に再実行が必要になる。
   - 発生条件: 同一セッション内で複数回 commit が必要になった場合

3. **PR 作成（`gh pr create`）には commit だけでなく push まで必要**: commit gate を突破して commit した後、さらに `git push` を実行して初めて PR が作れる。/worktree-end の手順では push タイミングが「PR 解決ステップ（Step 2）内で push する」と定義されているが、commit gate との順序関係（commit → user_verification → push → gh pr create）がワークフロー全体として明文化されていない。
   - 発生条件: /worktree-end 実行時に branch がリモートに未 push の場合

4. **worktree commit skip が `git -C <path>` なしだと効かない**: `resolveRepoDir` が `CLAUDE_PROJECT_DIR`（dotfiles 等）にフォールバックし `isWorktreeContext` が false を返すため user_verification が要求される。
   - 発生条件: worktree 内で素の `git commit`（`-C` なし）を実行した場合
   - 当面の回避策: `git -C <worktree-path> commit` を明示する

5. **`git branch -d` が enforce-worktree にブロックされる**: bash-write-patterns.js が `git branch` を write 分類するため、worktree 削除後に main checkout からローカルブランチを削除できない。
   - 発生条件: `git worktree remove` 後に main から `git branch -d` を実行した場合
   - 当面の回避策: ユーザーが手動で実行する
   - 根本対処: `/worktree-end` で branch 削除を `worktree remove` より前に実行するよう順序変更

**解決候補**:
- [x] `review-code-codex` に staged diff フォールバックを追加 — PR #7 で実装済み（commit なし時は `git diff --cached` を自動使用）
- [ ] 中間 commit / fixup commit は `user_verification` gate を免除するモードを追加（`--wip` フラグ等）
- [ ] ワークフロー手順に「実装ステップごとに WIP commit を積む」を明記（運用回避）
- [ ] `resolveRepoDir` に worktrees ディレクトリのスキャンを追加（staged 変更検出の精度向上）
- [ ] `git branch -d`（マージ済みブランチ削除）を bash-write-patterns.js で read 扱いに変更

### awesome-lists 投稿（agents repo split プロジェクトの残作業）
- [x] [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) へエントリ追加 PR — [issue #1750](https://github.com/hesreallyhim/awesome-claude-code/issues/1750)
- [x] [rohitg00/awesome-claude-code-toolkit](https://github.com/rohitg00/awesome-claude-code-toolkit) へエントリ追加 PR — [PR #363](https://github.com/rohitg00/awesome-claude-code-toolkit/pull/363)
- [ ] [travisvn/awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills) へエントリ追加 PR — 10 stars 到達後
- [ ] [VoltAgent/awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills) へエントリ追加 PR — 見送り

### scan-inbound 拡張候補 — 要検討
- [ ] **Read** 対象追加: git clone した悪意ファイルの injection 検出。誤検知（HTML/XML/コード）とのトレードオフを評価してから判断
- [ ] **Bash** 対象追加: git log / npm install 等の stdout injection 検出。誤検知（ビルド出力・テスト結果）が多いため慎重に評価

### セキュリティスキャンツール統合検討
- [ ] Gitleaks: git history 対応シークレットスキャン。scan-outbound.sh との役割分担を評価 (https://github.com/gitleaks/gitleaks)
- [ ] Semgrep: 構文認識型静的解析（shell, Python, JS）。review-code-security の手動パターンを自動化できるか評価 (https://github.com/semgrep/semgrep)
- [ ] detect-secrets: エントロピーベースの汎用シークレット検出。openssl rand -hex 32 系ジェネリック乱数をカバーできるか評価 (https://github.com/Yelp/detect-secrets)

### SSOT 参照ルールの設計 — 検討中
ポート・URL・ホスト名を推測せず SSOT を確認させる仕組みの設計:
- [ ] claude-global/rules/ に汎用行動ルール追加（「SSOT を確認してから提示」— ファイル名は含めない）
- [ ] ai-specs/CLAUDE.md の Infrastructure SSOT セクションに行動指示を追記
- [ ] docs-convention.md の Standard Files が nirecom PJ 前提である点の整理（他 doc 体系との分離）

### history.md 全エントリへの通し番号付与 — 将来タスク
- [ ] 現状: `### #N: ...` 形式は INCIDENT カテゴリのみ
- [ ] 動機: JIRA 移行・エントリ数増加時に、commit や別セッションから「前回の Task #N の続き」と参照できるようにしたい
- [ ] 検討: `doc-append` による自動採番、既存エントリの一括番号振りスクリプト
- docs-only short-circuit 導入により当面の必須条件ではない

### Gemini CLI — クロスプロバイダレビュー統合

Codex CLI と同様に、`review-code-gemini` / `review-plan-gemini` を実装してワークフロー step 6 に並列で乗せる。
- [ ] `bin/review-code-gemini` スクリプト作成（`review-code-codex` を参照）
- [ ] `bin/review-plan-gemini` スクリプト作成（`review-plan-codex` を参照）
- [ ] `skills/review-code-gemini` / `skills/review-plan-gemini` SKILL.md 作成
- [ ] `CLAUDE.md` の step 6 に Gemini レビューを追加
- [ ] README.md 更新（Gemini CLI supported に変更）
- 前提: `gemini` CLI インストール済み・API キー設定済み（Google AI Studio）

### AWS IAM ポリシー設定（server-side enforcement）

- [ ] personal / work 各アカウントに読み取り専用 IAM ポリシーを作成（`docs/architecture/claude-code/settings.md` 参照）
- [ ] aws-scan-* スキル動作確認を IAM 制限下で実施
- [ ] AWS_WORK_DIR と AWS_STATE_DIR を各マシンのローカル設定に追記

### enforce-worktree.js の AGENT_AUTO_BRANCH migration ブロック削除

`hooks/enforce-worktree.js` の `--- BEGIN/END temporary: AGENT_AUTO_BRANCH → ENFORCE_WORKTREE migration ---` ブロック（コメント + backward compat コード）は全マシンの移行完了後に削除する。
- [ ] 全マシンの agents config が `ENFORCE_WORKTREE` / `DEFAULT_BRANCHES` を使うよう更新されたことを確認
- [ ] `isEnforceWorktreeOn()` の `AGENT_AUTO_BRANCH` fallback 削除
- [ ] `getProtectedBranches()` の `AGENT_DEFAULT_BRANCHES` fallback 削除
- [ ] 対応する migration コメントブロック削除

### Workflow Step 6 のテスト実行を専任 subagent に分離 — 検討

**動機（context window の分離）**：今回の AGENT_AUTO_BRANCH 実装で、**code を直す側と動作確認する側を別 CC session に分けた**結果、F1〜F4 の production bug を効率良く発見・修正できた。最大の理由は context window の分離：「code を書く文脈」と「動作確認する文脈」を同一 context window に詰め込むと、片方が溢れて他方を阻害する。検証側は試行錯誤の log・再現手順・前回の失敗パターンを context に保持し続ける必要があり、main session が抱えると実装側の思考領域を圧迫する。subagent として閉じ込めれば、main conversation は実装と bug fix の思考に集中でき、subagent は検証の試行錯誤を context-isolate できる。

**現状**：
- Step 6（Run tests & Security review）で `review-code-security` と `review-code-codex` は subagent / parallel で動いている
- しかし **テスト実行（`bash tests/...`）は main conversation 自身が走らせている**
- 自動テスト 37/37 pass でも production-shape の bug が漏れたケース（今回の R1〜F4）では、別人格の検証者が必要

**提案**：
- [ ] Step 6 に `/run-tests` skill（仮称）を導入し、subagent で：
  - 自動テスト実行（既存の bash tests/...）
  - production-shape の動作確認手順 `.md` を生成（手動検証用 → 別 session で実行）または subagent 内で simulate
  - 結果を構造化レポートで返却（pass/fail サマリ + 再現手順 + stderr 抜粋）
- [ ] main conversation は report を受け取って bug fix に専念（context window を実装側に温存）
- [ ] CLAUDE.md Step 6 を「`/run-tests` をデフォルト経路に」と更新
- [ ] 既存の `workflow-run-tests.js` PostToolUse hook（exit code から auto-mark）との関係整理

**前提（CC subagent 機構）**：
- Claude Code の subagent は **context-isolate を提供する**（main の context window を消費しない）
- subagent 内から bash 実行 + 結果 grep / parse は可能
- ただし production 環境で人手が必要な動作確認（実 push、UI 操作、別 PC 切替、CC 再起動など）は subagent では完結しない → そういうケースは「別 CC session 用の検証 doc」を生成して main に返す責務にとどめる
- 今回の F1〜F4 のうち、subagent で完結可能だったのは F2〜F4（環境設定 + 自動 invoke で再現可能）。F1（CC 自身が出力する additionalContext を見る）は実 CC session が必要

### my-private-repo: dotenv ファイルの初回 git 追加

`ENFORCE_WORKTREE_EXCLUDE` はメイン checkout ゲートをバイパスするが、pre-commit の dotenv ブロック（`--diff-filter=A`）は独立して動作するため、新規追加コミットは別途ブロックされる。

- [ ] 対応策を選択・実装: (1) リモートが private repo と確認できる場合は dotenv ブロックをスキップ、(2) ワンタイムで worktree から初回コミット、(3) per-repo allowlist 機構の追加

### enforce-worktree.js への ENFORCE_WORKTREE_EXCLUDE 対応

現状、EXCLUDE は pre-commit（git コミット時）にのみ実装されており、PreToolUse フック（enforce-worktree.js）での Bash write コマンド判定には未対応。todo.md 等の直接コミットを end-to-end で動作させるには JS 側への対応が必要。

- [ ] enforce-worktree.js の Bash write チェックに ENFORCE_WORKTREE_EXCLUDE を適用（書き込み先ファイルパスがパターンにマッチする場合は許可）
