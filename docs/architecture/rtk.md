# RTK Integration

[RTK](https://github.com/rtk-ai/rtk) is a third-party CLI that compresses Bash
command output to reduce LLM input token usage. This repository hooks into it;
it is never a required dependency.

## Enabling

Set `RTK=on` in `.env`. RTK must already be installed (`rtk` on `PATH` or at a
known location — see `RTK_BIN` in `.env.example`).

## How the hook works

`hooks/rtk-rewrite.js` intercepts each Bash `PreToolUse` event and, when RTK is
enabled, delegates eligible commands to `rtk hook claude` so RTK's output
compression and native audit both apply.

Agents repo internal commands are always excluded: any command headed by a
`bin/` script or referencing `$AGENTS_CONFIG_DIR` bypasses RTK wrapping
unconditionally (`isAgentsEmit` guard). This ensures workflow-critical plumbing
runs at full fidelity regardless of RTK being on or off.

## Audit

Set `RTK_AUDIT=on` in `.env` to record a JSONL line each time the hook's own
guards reject a command. The log is written to
`~/.agents/logs/rtk-guard-audit.log` and is independent of RTK's native audit.

## bin/rtk-cmd 採用規約

`bin/rtk-cmd` は RTK=on 時に出力圧縮の対象となるコマンド (`git`, `gh`, `grep`, `docker`
など RTK 本家がサポートするもの) の**生の人間可読出力を Claude に意図的に emit するスクリプト**
だけで使う軽量ラッパーである。

### 使う状況

スクリプトが `git log` や `gh issue list` などの生テキスト出力を Claude の stdout に
そのまま流す設計の場合。例:
    bin/rtk-cmd git log --oneline -20   # 生の git log 出力を圧縮して Claude に渡す
    bin/rtk-cmd gh issue list           # 生の issue 一覧出力を圧縮して Claude に渡す

### 使わない状況（現行 bin/ スクリプト 195 件すべてが該当）

- `--json` / `--format=` / `--numstat` などの機械可読フラグ付き呼び出し（RTK がパススルーするため無効）
- 変数に捕捉して node/jq/awk で再整形する呼び出し（RTK は node 出力に手を出せない）
- `grep`/`find`/`cat` を内部制御フローや判定のみに使う呼び出し（Claude に渡らない）

issue #2370 の横断調査（全 RTK 対象コマンド × bin/ 195 ファイル）でこれらが
構造的不変条件であることを確認済み。適用先が生じた時点で使い始める。
