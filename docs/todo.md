# Todo

## Current Work

### /boost + judge-task-complexity — manual smoke test (post-push)

- [x] Invoke `/judge-task-complexity` directly: simple task → `VERDICT: sonnet | none`; multi-file + security task → `VERDICT: opus | S1-multi-file, S3-security`
- [x] Invoke `/boost test task`: confirm Opus subagent launches
- [ ] Run `make-detail-plan`: confirm step 2 calls judge before detail-planner starts

### session-sync を dotfiles なしで動作させる

session-sync の自動 push（ターミナル終了時）は現在 dotfiles の `.profile_common` にのみ実装されており、agents 単体では機能しない。

- [ ] `profile-snippet.sh` に `trap` で session-sync push を追加（dotfiles 不要）
- [ ] `profile-snippet.ps1` に相当する処理を追加（PowerShell `Register-EngineEvent PowerShell.Exiting`）
- [ ] README の Install セクションに dotfiles なし構成でも session-sync が動く旨を反映

### awesome-lists 投稿（agents repo split プロジェクトの残作業）
- [ ] [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) へエントリ追加 PR
- [ ] [rohitg00/awesome-claude-code-toolkit](https://github.com/rohitg00/awesome-claude-code-toolkit) へエントリ追加 PR
- [ ] [travisvn/awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills) へエントリ追加 PR
- [ ] [VoltAgent/awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills) へエントリ追加 PR

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

### AWS IAM ポリシー設定（server-side enforcement）

- [ ] personal / work 各アカウントに読み取り専用 IAM ポリシーを作成（`docs/architecture/claude-code/settings.md` 参照）
- [ ] aws-scan-* スキル動作確認を IAM 制限下で実施
- [ ] AWS_WORK_DIR と AWS_STATE_DIR を各マシンのローカル設定に追記

