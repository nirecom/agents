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

- [ ] `resolveRepoDir` が env var 展開に対応していないため、`git -C "$FORNIX_DIR" commit` のように env var を使うとコミットがブロックされる問題を修正する

**状況:** PreToolUse フックはコマンド文字列を Bash 展開前に受け取るため、`parseGitCArg` が `$FORNIX_DIR` のリテラル文字列を返す。`resolveRepoDir` はこれをパスとして解釈できず、`hasStagedDocChanges` が誤ったディレクトリを参照して docs ステップ未完了と判定する。`git -C "C:/git/fornix-stream" commit ...` と展開済みパスにすると通る。修正案: `resolveRepoDir` 内で `p.replace(/\$(\w+)/g, (_, k) => process.env[k] || '')` で展開する。fornix-stream への salvage bulk import 時に発覚（2026-05-02）。

### check-japanese-in-docs.js: dotfiles-private を誤ってパブリック判定するバグ

- [ ] `doc-append` を dotfiles-private ディレクトリから実行しても「This is a public repository」としてブロックされる
- [ ] フック内のリポジトリ判定ロジック（`gh api` / `git rev-parse` の参照先）を調査し、CWD が正しく伝わっているか確認する
- [ ] 修正後、dotfiles-private の history.md に日本語で doc-append できることを確認する
