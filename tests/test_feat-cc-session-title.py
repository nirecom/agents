"""Tests for bin/cc-session-title.py — written TDD style before source exists.

All tests are skipped when the source file is absent.
"""

import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Module loader (importlib — filename contains a hyphen)
# ---------------------------------------------------------------------------

def load_module():
    path = Path(__file__).resolve().parent.parent / "bin" / "cc-session-title.py"
    spec = importlib.util.spec_from_file_location("cc_session_title", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    mod = load_module()
    IMPORT_OK = True
except Exception:
    IMPORT_OK = False

pytestmark = pytest.mark.skipif(not IMPORT_OK, reason="source not yet implemented")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def m():
    """Session-scoped module fixture."""
    return load_module()


# ---------------------------------------------------------------------------
# 1. encode_cwd
# ---------------------------------------------------------------------------

class TestEncodeCwd:
    def test_backslash_path(self, m):
        assert m.encode_cwd("C:\\git\\agents") == "c--git-agents"

    def test_forward_slash_path(self, m):
        assert m.encode_cwd("C:/git/agents") == "c--git-agents"

    def test_posix_path(self, m):
        assert m.encode_cwd("/home/user/project") == "-home-user-project"

    def test_drive_root(self, m):
        assert m.encode_cwd("C:\\") == "c--"

    def test_empty_string(self, m):
        assert m.encode_cwd("") == ""


# ---------------------------------------------------------------------------
# 2. latest_custom_title
# ---------------------------------------------------------------------------

class TestLatestCustomTitle:
    def test_empty_string(self, m):
        assert m.latest_custom_title("") is None

    def test_only_ai_title_records(self, m):
        lines = "\n".join([
            json.dumps({"type": "ai-title", "title": "Auto title"}),
            json.dumps({"type": "ai-title", "title": "Another auto"}),
        ])
        assert m.latest_custom_title(lines) is None

    def test_single_custom_title(self, m):
        line = json.dumps({"type": "custom-title", "customTitle": "My title"})
        assert m.latest_custom_title(line) == "My title"

    def test_two_custom_titles_returns_last(self, m):
        lines = "\n".join([
            json.dumps({"type": "custom-title", "customTitle": "First"}),
            json.dumps({"type": "custom-title", "customTitle": "Second"}),
        ])
        assert m.latest_custom_title(lines) == "Second"

    def test_mixed_returns_last_custom(self, m):
        lines = "\n".join([
            json.dumps({"type": "ai-title", "title": "Auto"}),
            json.dumps({"type": "custom-title", "customTitle": "First custom"}),
            json.dumps({"type": "ai-title", "title": "Auto 2"}),
            json.dumps({"type": "custom-title", "customTitle": "Second custom"}),
        ])
        assert m.latest_custom_title(lines) == "Second custom"

    def test_malformed_json_line_skipped(self, m):
        lines = "\n".join([
            "this is not json",
            json.dumps({"type": "custom-title", "customTitle": "Valid"}),
        ])
        assert m.latest_custom_title(lines) == "Valid"

    def test_wrong_type_ignored(self, m):
        lines = "\n".join([
            json.dumps({"type": "other-type", "customTitle": "Should not appear"}),
        ])
        assert m.latest_custom_title(lines) is None


# ---------------------------------------------------------------------------
# 3. is_workflow_generated
# ---------------------------------------------------------------------------

class TestIsWorkflowGenerated:
    def test_none_is_workflow_generated(self, m):
        assert m.is_workflow_generated(None) is True

    def test_issue_number_with_space(self, m):
        assert m.is_workflow_generated("#299 foo") is True

    def test_checkmark_prefix(self, m):
        assert m.is_workflow_generated("✓ done") is True

    def test_plain_title(self, m):
        assert m.is_workflow_generated("My title") is False

    def test_empty_string(self, m):
        assert m.is_workflow_generated("") is False

    def test_leading_space_before_hash(self, m):
        assert m.is_workflow_generated(" #299 foo") is False

    def test_hash_note_heading(self, m):
        assert m.is_workflow_generated("# notes") is False

    def test_hashtag_word(self, m):
        assert m.is_workflow_generated("#hashtag") is False

    def test_hash_digits_no_trailing_space(self, m):
        assert m.is_workflow_generated("#299") is False

    def test_hash_one_digit_with_space(self, m):
        assert m.is_workflow_generated("#1 a") is True


# ---------------------------------------------------------------------------
# 4. build_record
# ---------------------------------------------------------------------------

class TestBuildRecord:
    def test_ends_with_newline(self, m):
        record = m.build_record("sid123", "My title")
        assert record.endswith("\n")

    def test_single_line(self, m):
        record = m.build_record("sid123", "My title")
        # Should be exactly one non-empty line (plus the trailing newline)
        lines = record.splitlines()
        assert len(lines) == 1

    def test_round_trip_json(self, m):
        record = m.build_record("abc-session-id", "Hello World")
        parsed = json.loads(record.strip())
        assert parsed["type"] == "custom-title"
        assert parsed["sessionId"] == "abc-session-id"
        assert parsed["customTitle"] == "Hello World"

    def test_japanese_not_escaped(self, m):
        record = m.build_record("sid", "日本語タイトル")
        # ensure_ascii=False means the Japanese chars appear literally, not as \uXXXX
        assert "日本語タイトル" in record

    def test_embedded_quotes_and_backslashes(self, m):
        title = 'Has "quotes" and \\backslash'
        record = m.build_record("sid", title)
        parsed = json.loads(record.strip())
        assert parsed["customTitle"] == title


# ---------------------------------------------------------------------------
# 5. format_set_issue_title
# ---------------------------------------------------------------------------

class TestFormatSetIssueTitle:
    def test_basic(self, m):
        assert m.format_set_issue_title(299, "Hello") == "#299 Hello"

    def test_strips_whitespace(self, m):
        assert m.format_set_issue_title(1, "  title with spaces  ") == "#1 title with spaces"


# ---------------------------------------------------------------------------
# 6. run_set_issue integration
# ---------------------------------------------------------------------------

def make_jsonl(tmp_path, cwd_encoded, session_id, content):
    """Create a fake project dir + JSONL file."""
    d = tmp_path / cwd_encoded
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"{session_id}.jsonl"
    f.write_text(content, encoding="utf-8")
    return f


class TestRunSetIssue:
    @pytest.fixture(autouse=True)
    def set_projects_dir(self, tmp_path, monkeypatch):
        monkeypatch.setenv("CLAUDE_PROJECTS_DIR", str(tmp_path))
        self.tmp_path = tmp_path

    def _cwd_encoded(self, m):
        return m.encode_cwd(os.getcwd())

    # a. Only ai-title records → appends new custom-title line
    def test_appends_when_only_ai_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-aaa"
        original = json.dumps({"type": "ai-title", "title": "Auto"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_lines = f.read_text(encoding="utf-8").splitlines()
        result = m.run_set_issue(42, "New Title", os.getcwd())
        assert result == 0

        new_lines = f.read_text(encoding="utf-8").splitlines()
        assert len(new_lines) == len(original_lines) + 1

        appended = json.loads(new_lines[-1])
        assert appended["type"] == "custom-title"
        assert appended["sessionId"] == session_id
        assert appended["customTitle"] == "#42 New Title"

    # b. Existing workflow-generated custom-title → new line appended (not replaced)
    def test_appends_when_workflow_custom_title_present(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-bbb"
        original = json.dumps({"type": "custom-title", "customTitle": "#100 old"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        m.run_set_issue(42, "New Title", os.getcwd())

        lines = f.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2
        first = json.loads(lines[0])
        second = json.loads(lines[1])
        assert first["customTitle"] == "#100 old"
        assert second["customTitle"] == "#42 New Title"

    # c. Manual custom-title (not workflow-generated) → file unchanged
    def test_skips_when_manual_custom_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-ccc"
        original = json.dumps({"type": "custom-title", "customTitle": "User typed this"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_content = f.read_text(encoding="utf-8")
        result = m.run_set_issue(42, "New Title", os.getcwd())
        assert result == 0
        assert f.read_text(encoding="utf-8") == original_content

    # d. Custom-title "# notes" (not matching ^(#\d+\s|✓)) → file unchanged
    def test_skips_when_hash_note_custom_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-ddd"
        original = json.dumps({"type": "custom-title", "customTitle": "# notes"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_content = f.read_text(encoding="utf-8")
        m.run_set_issue(42, "New Title", os.getcwd())
        assert f.read_text(encoding="utf-8") == original_content

    # e. Two JSONL files with different mtimes → newer file gets append
    def test_uses_newest_jsonl(self, m):
        cwd_encoded = self._cwd_encoded(m)
        d = self.tmp_path / cwd_encoded
        d.mkdir(parents=True, exist_ok=True)

        older_id = "session-older"
        newer_id = "session-newer"

        older_content = json.dumps({"type": "ai-title", "title": "Older"}) + "\n"
        newer_content = json.dumps({"type": "ai-title", "title": "Newer"}) + "\n"

        older_file = d / f"{older_id}.jsonl"
        older_file.write_text(older_content, encoding="utf-8")

        # Ensure different mtime by sleeping briefly or using utime
        time.sleep(0.05)

        newer_file = d / f"{newer_id}.jsonl"
        newer_file.write_text(newer_content, encoding="utf-8")

        result = m.run_set_issue(42, "New Title", os.getcwd())
        assert result == 0

        # newer file should have an extra line
        newer_lines = newer_file.read_text(encoding="utf-8").splitlines()
        older_lines = older_file.read_text(encoding="utf-8").splitlines()
        assert len(newer_lines) == 2
        assert len(older_lines) == 1  # unchanged

        appended = json.loads(newer_lines[-1])
        assert appended["sessionId"] == newer_id

    # f. No *.jsonl files in project dir → returns 0, stderr message
    def test_no_jsonl_returns_zero(self, m, capsys):
        cwd_encoded = self._cwd_encoded(m)
        d = self.tmp_path / cwd_encoded
        d.mkdir(parents=True, exist_ok=True)

        result = m.run_set_issue(42, "Title", os.getcwd())
        assert result == 0
        captured = capsys.readouterr()
        assert captured.err  # some message on stderr

    # g. Project directory does not exist → returns 0, stderr message
    def test_missing_project_dir_returns_zero(self, m, capsys):
        # Use a cwd that won't match any existing encoded dir
        result = m.run_set_issue(42, "Title", "/nonexistent/path/xyz")
        assert result == 0
        captured = capsys.readouterr()
        assert captured.err  # some message on stderr


# ---------------------------------------------------------------------------
# 7. main stubs
# ---------------------------------------------------------------------------

class TestMainStubs:
    def test_add_pr_not_implemented(self, m, capsys):
        result = m.main(["add-pr", "123"])
        assert result == 1
        captured = capsys.readouterr()
        assert "not yet implemented" in captured.err.lower()

    def test_mark_complete_not_implemented(self, m, capsys):
        result = m.main(["mark-complete"])
        assert result == 1
        captured = capsys.readouterr()
        assert "not yet implemented" in captured.err.lower()
