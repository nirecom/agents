# Todo

## Current Work

### /boost + judge-task-complexity — manual smoke test (post-push)

- [x] Invoke `/judge-task-complexity` directly: simple task → `VERDICT: sonnet | none`; multi-file + security task → `VERDICT: opus | S1-multi-file, S3-security`
- [x] Invoke `/boost test task`: confirm Opus subagent launches
- [ ] Run `make-detail-plan`: confirm step 2 calls judge before detail-planner starts

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

### 多セッション並行検出（session-sync mutterings 応用）— 将来拡張

現行の AGENT_AUTO_BRANCH 強制で「default branch race」は構造的に回避済だが、「同一 feature branch を別セッションが同時編集」のような細かい race は検出できない。情報レベルで知りたい場合の拡張。
- [ ] UserPromptSubmit hook で transcript に `[session-state] repo=X branch=Y worktree=Z` をつぶやく
- [ ] SessionStart で `~/.claude/projects/<encoded-cwd>/*.jsonl` の最新 N 件を読み、活動中の兄弟をリスト
- [ ] additionalContext に「Active CC sessions in this workspace context: N」を表示（advisory のみ）
- [ ] compact 後の再つぶやき（state self-healing）
- 前提：本タスクの AGENT_AUTO_BRANCH 機構が安定運用に入ってから着手

