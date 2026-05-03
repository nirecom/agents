# Todo

## Current Work

### /boost + judge-task-complexity — manual smoke test (post-push)

- [x] Invoke `/judge-task-complexity` directly: simple task → `VERDICT: sonnet | none`; multi-file + security task → `VERDICT: opus | S1-multi-file, S3-security`
- [x] Invoke `/boost test task`: confirm Opus subagent launches
- [ ] Run `make-detail-plan`: confirm step 2 calls judge before detail-planner starts

### AWS IAM ポリシー設定（server-side enforcement）

- [ ] personal / work 各アカウントに読み取り専用 IAM ポリシーを作成（`docs/architecture/claude-code/settings.md` 参照）
- [ ] aws-scan-* スキル動作確認を IAM 制限下で実施
- [ ] AWS_WORK_DIR と AWS_STATE_DIR を各マシンのローカル設定に追記

