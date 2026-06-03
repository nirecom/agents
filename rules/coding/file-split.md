# File Split Rule

HARD 超のファイルは分割必須。対象ファイル種別ごとに分割パターンが異なる。

## Pattern A — Code files (>500 lines)

- 対象拡張子は CODE_FILE_EXTENSIONS 環境変数で設定する（既定値は .env.example 参照）。
- `<name>.<ext>` はエントリポイントとして残し、dispatch と re-export shim のみに留める。
- 同階層に `<name>/` フォルダを作成し、domain-named modules をそこに配置する。
- hooks 間で共有されるユーティリティは `hooks/lib/` に置く（hook 以外の場合は隣接する `lib/` を使う）。
- エントリポイント側にはロジックを残さない。
- 実例: `hooks/enforce-worktree.js` + `hooks/enforce-worktree/`。

## Pattern B — SKILL.md (>200 lines)

- 対象は `skills/<name>/SKILL.md`。
- SKILL.md はプロンプトのエントリポイントとして常に残す。shim 化しない。
- 3 ステップ以上の手続きは `skills/<name>/scripts/<verb>.sh` または `bin/<tool>` に切り出す。
- SKILL.md は CLI への 1 行参照で置換し、手続きを SKILL.md に inline 維持しない。
- `skills/<name>/lib/` は分割先として使わない。
- 共有ロジックは `bin/<tool>` または `skills/<name>/scripts/` 配下で関数化する。
