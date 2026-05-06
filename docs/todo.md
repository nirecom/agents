# Todo

## Current Work

### review-code-codex が commit 前に実行できない問題 — ワークフロー設計の欠陥

**症状**: `review-code-codex` は `git diff BASE...HEAD` を使うため commit 済み差分のみ対象。しかし commit には workflow-gate の `user_verification` が必要で、`user_verification` は本来 review-code-codex の**後**に行うもの。結果として鶏と卵の問題になる。

**発生条件**: 実装ステップごとに commit を積まず、実装完了まで一度もコミットしない場合（TDD フェーズで tests + implementation を一気に進めたセッションで発生）。

**解決候補**:
- [ ] `review-code-codex` に `--staged` モードを追加（`git diff --cached` を使う）— 最小変更、後方互換
- [ ] 中間 commit（WIP）は `user_verification` gate を免除するモードを追加
- [ ] ワークフロー手順に「実装ステップごとに WIP commit を積む」を明記（運用回避）

**当面の回避策**: `git diff --cached` を直接 codex に流す（今回実施済み）。

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

### workflow step 内部名 `branching_decision` のリネーム検討

AGENT_AUTO_BRANCH=on 下では「decision」よりも「creation」が実態。CLAUDE.md ラベルは更新済（Branch/Worktree creation）だが、内部識別子は据置。
- [ ] 内部名 `branching_decision` → `branching_creation` 等にリネーム
- [ ] sentinel `WORKFLOW_BRANCHING_DECIDED` を新名に更新（後方互換のため両方受理する移行期間を設ける）
- [ ] 既存セッションの workflow state file に対する migration（`branching_decision` → 新名へのコピー）
- [ ] `hooks/lib/workflow-state.js`, `hooks/workflow-mark.js`, `hooks/workflow-gate.js`, `hooks/session-start.js` 等を一斉更新
- 動機：「名は体を表す」原則に沿わせる（label と内部名の乖離解消）

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

### 補助リポジトリ（ai-specs 等）に対する AGENT_AUTO_BRANCH の扱い — 検討中

main 直書きが普通だった補助 repo（ai-specs の research-results、メモ系）も AUTO_BRANCH=on の対象になり、毎回 feature branch + ff merge が必要に。
- [ ] 運用ルール案：feature branch + ff merge を補助 repo でも徹底（記録の追跡可能性が上がる副次効果）
- [ ] 仕組み案：`.agent/policy.json` のような per-repo 設定を読んで、特定 repo は AUTO_BRANCH 対象外にする
- [ ] 関連リスク：**docs の中間状態の同期問題** — agents の機能 commit 中に対応する ai-specs research entry を main 直書きすると、機能 commit の前後で docs/research の sync が壊れる可能性。両者を一緒に branch で進めて、完了時に同時 merge する運用が安全
- 動機：今回の研究 commit で初めて表面化。auxiliary repo の運用が不明確

### 多セッション並行検出（session-sync mutterings 応用）— 将来拡張

現行の AGENT_AUTO_BRANCH 強制で「default branch race」は構造的に回避済だが、「同一 feature branch を別セッションが同時編集」のような細かい race は検出できない。情報レベルで知りたい場合の拡張。
- [ ] UserPromptSubmit hook で transcript に `[session-state] repo=X branch=Y worktree=Z` をつぶやく
- [ ] SessionStart で `~/.claude/projects/<encoded-cwd>/*.jsonl` の最新 N 件を読み、活動中の兄弟をリスト
- [ ] additionalContext に「Active CC sessions in this workspace context: N」を表示（advisory のみ）
- [ ] compact 後の再つぶやき（state self-healing）
- 前提：本タスクの AGENT_AUTO_BRANCH 機構が安定運用に入ってから着手

