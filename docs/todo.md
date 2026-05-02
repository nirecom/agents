# Todo

## Current Work

### research ステップの commit ゲート除外 — 動作確認

- [ ] 小規模タスクで `<<WORKFLOW_RESEARCH_NOT_NEEDED:` の確認ダイアログが出なくなったことを確認する
- [ ] `clarify_intent` 完了後に `[workflow] Invoke survey-code or deep-research ...` の NEXT ヒントが引き続き表示されることを確認する
- [ ] research が pending のまま commit まで進んでも workflow-gate にブロックされないことを確認する


### intent-log.md の Write パーミッションダイアログ抑制 — 動作確認

- [ ] clarify-intent を実行し、intent-log.md 書き込み時にパーミッションダイアログが出ないことを確認する
- [ ] ダイアログが出る場合は `**/.claude/plans/*-intent-log.md` のグロブパターンを再検討する

### agents repo のライセンスを MIT → Apache-2.0 に変更する

- [ ] `LICENSE` ファイルを Apache-2.0 テキストに差し替える
- [ ] `README.md` のバッジ・本文中のライセンス表記を更新する
- [ ] CONTRIBUTING.md があれば Apache-2.0 への言及を追加する
- 背景: Apache-2.0 は MIT にない特許ライセンス付与条項と特許訴訟終了条項を持つ。
  依存先の Apache-2.0 ライブラリ（LightRAG 等）とのライセンス整合性も高まる。

### Stop hook による branch/worktree 後始末リマインダー

- [ ] 実際のワークフローで動作確認する（worktree または branch を使うタスクで end-to-end 検証）
- [ ] うまくいかず revert する場合は commit hash `590d8a1` を巻き戻せ

### workflow-gate: `git -C "$ENV_VAR"` でパス解決が失敗する

- [ ] `parseGitCArg` が PreToolUse フックで受け取るコマンド文字列に対し、env var が**展開前**のリテラル (`$FORNIX_DIR` 等) のまま渡されるため、`resolveRepoDir` が正しいリポジトリを特定できない
- [ ] 結果として `hasStagedDocChanges` が誤ったディレクトリを対象にし、docs ステップが通らずコミットがブロックされる
- [ ] 再現手順: `git -C "$FORNIX_DIR" commit ...` のように env var を使ったコミット → workflow-gate が `docs` 未完了でブロック。`git -C "C:/git/fornix-stream" commit ...` と展開済みパスにすると通る
- [ ] 修正案 A: `resolveRepoDir` 内で `p` を `process.env` で展開する (`p.replace(/\$(\w+)/g, (_, k) => process.env[k] || '')`)
- [ ] 修正案 B: `parseGitCArg` 側で shell-style 展開に対応する
- [ ] 修正後、env var パスでのコミットが docs ステップを正しく通過することを確認する
- 背景: fornix-stream（データ専用 repo）への salvage bulk import コミット時に発覚（2026-05-02）。`$FORNIX_DIR=C:\git\fornix-stream` で再現済み。

### check-japanese-in-docs.js: my-private-repo を誤ってパブリック判定するバグ

- [ ] `doc-append` を my-private-repo ディレクトリから実行しても「This is a public repository」としてブロックされる
- [ ] フック内のリポジトリ判定ロジック（`gh api` / `git rev-parse` の参照先）を調査し、CWD が正しく伝わっているか確認する
- [ ] 修正後、my-private-repo の history.md に日本語で doc-append できることを確認する
