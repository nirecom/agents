"""Regression tests for fix/session-title-set-issue-guard.

run_set_issue must unconditionally overwrite any existing title,
including Claude Code auto-titler style titles that previously caused no-ops.
"""

import importlib.util
import json
import os
import pytest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "bin", "cc-session-title.py")


@pytest.fixture(scope="module")
def m():
    spec = importlib.util.spec_from_file_location("cc_session_title", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def set_projects_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUDE_PROJECTS_DIR", str(tmp_path))
    return tmp_path


def make_jsonl(tmp_path, cwd_encoded, session_id, content):
    d = tmp_path / cwd_encoded
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"{session_id}.jsonl"
    f.write_text(content, encoding="utf-8")
    return f


class TestRunSetIssueUnconditionalOverwrite:
    """Regression guard: run_set_issue must always write, never skip."""

    def test_overwrites_auto_titler_style_title(self, m, set_projects_dir, monkeypatch):
        """Claude Code auto-titler style title (not matching workflow regex) must be overwritten.

        Previously this was a no-op because is_workflow_generated() returned False
        for titles like "Fix workflow-init #299 issue".
        """
        tmp_path = set_projects_dir
        cwd = os.getcwd()
        cwd_encoded = m.encode_cwd(cwd)
        session_id = "session-reg-auto-titler"
        # Title that looks like Claude Code auto-generated (not matching ^(#\d+\s|✓))
        auto_title = "Fix workflow-init #299 issue"
        original = json.dumps({"type": "custom-title", "customTitle": auto_title}) + "\n"
        f = make_jsonl(tmp_path, cwd_encoded, session_id, original)

        result = m.run_set_issue(
            299,
            "セッションタイトルをissue・PR確定・完了時に自動更新",
            cwd,
        )
        assert result == 0

        lines = f.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2, (
            f"Expected 2 lines (original + appended), got {len(lines)}: {lines}"
        )
        appended = json.loads(lines[-1])
        assert appended["type"] == "custom-title"
        assert appended["sessionId"] == session_id
        expected_title = "#299 セッションタイトルをissue・PR確定・完了時に自動更新"
        assert appended["customTitle"] == expected_title

    def test_overwrites_empty_string_title(self, m, set_projects_dir, monkeypatch):
        """Empty string title (not workflow-generated) must also be overwritten."""
        tmp_path = set_projects_dir
        cwd = os.getcwd()
        cwd_encoded = m.encode_cwd(cwd)
        session_id = "session-reg-empty-title"
        original = json.dumps({"type": "custom-title", "customTitle": ""}) + "\n"
        f = make_jsonl(tmp_path, cwd_encoded, session_id, original)

        result = m.run_set_issue(1, "title", cwd)
        assert result == 0

        lines = f.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2, (
            f"Expected 2 lines (original + appended), got {len(lines)}: {lines}"
        )
        appended = json.loads(lines[-1])
        assert appended["type"] == "custom-title"
        assert appended["sessionId"] == session_id
        assert appended["customTitle"] == "#1 title"
