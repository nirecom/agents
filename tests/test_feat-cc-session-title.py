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
# 6. format_add_pr_title
# ---------------------------------------------------------------------------

class TestFormatAddPrTitle:
    @pytest.fixture(autouse=True)
    def require_func(self, m):
        if not hasattr(m, 'format_add_pr_title'):
            pytest.skip("format_add_pr_title not yet implemented")

    def test_first_pr_uses_space_separator(self, m):
        assert m.format_add_pr_title("#299 Foo", 310) == "#299 Foo PR #310"

    def test_second_pr_uses_comma_separator(self, m):
        assert m.format_add_pr_title("#299 Foo PR #310", 311) == "#299 Foo PR #310, PR #311"

    def test_third_pr_uses_comma_separator(self, m):
        assert m.format_add_pr_title("#299 Foo PR #310, PR #311", 312) == "#299 Foo PR #310, PR #311, PR #312"

    def test_idempotent_when_pr_already_first(self, m):
        assert m.format_add_pr_title("#299 Foo PR #310", 310) is None

    def test_idempotent_when_pr_already_mid_list(self, m):
        assert m.format_add_pr_title("#299 Foo PR #310, PR #311", 310) is None

    # PR reference in issue title BODY — must not corrupt separator choice
    def test_pr_ref_in_body_no_pr_appended_yet(self, m):
        # Body contains "PR #123" but no real PR has been appended yet
        # → should use SPACE separator (not comma) for the first real PR
        assert m.format_add_pr_title("#299 Fix PR #123 regression", 310) == "#299 Fix PR #123 regression PR #310"

    def test_pr_ref_in_body_with_real_pr(self, m):
        # Body has "PR #123", one real PR already appended → second real PR uses comma
        assert m.format_add_pr_title("#299 Fix PR #123 regression PR #310", 311) == "#299 Fix PR #123 regression PR #310, PR #311"

    def test_pr_ref_in_body_idempotent(self, m):
        # Already has PR #310 at tail → idempotent (return None)
        assert m.format_add_pr_title("#299 Fix PR #123 regression PR #310", 310) is None

    def test_pr_ref_in_body_same_number_as_body_ref(self, m):
        # Body reference "PR #123" must NOT block appending the actual PR #123
        assert m.format_add_pr_title("#299 Fix PR #123 regression", 123) == "#299 Fix PR #123 regression PR #123"

    def test_word_boundary_longer_not_blocked_by_shorter(self, m):
        # PR #31 in suffix should not block appending PR #310
        assert m.format_add_pr_title("#299 X PR #31", 310) == "#299 X PR #31, PR #310"

    def test_word_boundary_shorter_not_blocked_by_longer(self, m):
        # PR #310 in suffix should not block appending PR #31
        assert m.format_add_pr_title("#299 X PR #310", 31) == "#299 X PR #310, PR #31"

    def test_checkmark_title_still_appends(self, m):
        # ✓-prefixed titles are workflow-generated, so append should work
        assert m.format_add_pr_title("✓#299 Foo", 310) == "✓#299 Foo PR #310"

    def test_returns_none_for_plain_title(self, m):
        assert m.format_add_pr_title("My work", 1) is None

    def test_returns_none_for_none_input(self, m):
        assert m.format_add_pr_title(None, 1) is None


# ---------------------------------------------------------------------------
# 7. format_mark_complete_title
# ---------------------------------------------------------------------------

class TestFormatMarkCompleteTitle:
    @pytest.fixture(autouse=True)
    def require_func(self, m):
        if not hasattr(m, 'format_mark_complete_title'):
            pytest.skip("format_mark_complete_title not yet implemented")

    def test_adds_checkmark_to_issue_title(self, m):
        assert m.format_mark_complete_title("#299 Foo") == "✓#299 Foo"

    def test_preserves_pr_list(self, m):
        assert m.format_mark_complete_title("#299 Foo PR #310, PR #311") == "✓#299 Foo PR #310, PR #311"

    def test_idempotent_when_already_marked(self, m):
        assert m.format_mark_complete_title("✓#299 Foo") is None

    def test_returns_none_for_plain_title(self, m):
        assert m.format_mark_complete_title("My work") is None

    def test_returns_none_for_none_input(self, m):
        assert m.format_mark_complete_title(None) is None


# ---------------------------------------------------------------------------
# 8. run_set_issue integration
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

    # c. Manual custom-title → unconditional overwrite appends new record
    def test_overwrites_manual_custom_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-ccc"
        original = json.dumps({"type": "custom-title", "customTitle": "User typed this"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        result = m.run_set_issue(42, "New Title", os.getcwd())
        assert result == 0

        new_lines = f.read_text(encoding="utf-8").splitlines()
        assert len(new_lines) == 2
        appended = json.loads(new_lines[-1])
        assert appended["type"] == "custom-title"
        assert appended["sessionId"] == session_id
        assert appended["customTitle"] == "#42 New Title"

    # d. Custom-title "# notes" → unconditional overwrite appends new record
    def test_overwrites_hash_note_custom_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-ddd"
        original = json.dumps({"type": "custom-title", "customTitle": "# notes"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        result = m.run_set_issue(42, "New Title", os.getcwd())
        assert result == 0

        new_lines = f.read_text(encoding="utf-8").splitlines()
        assert len(new_lines) == 2
        appended = json.loads(new_lines[-1])
        assert appended["type"] == "custom-title"
        assert appended["customTitle"] == "#42 New Title"

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
# 9. run_add_pr integration
# ---------------------------------------------------------------------------

class TestRunAddPr:
    @pytest.fixture(autouse=True)
    def require_func(self, m):
        if not hasattr(m, 'run_add_pr'):
            pytest.skip("run_add_pr not yet implemented")

    @pytest.fixture(autouse=True)
    def set_projects_dir(self, tmp_path, monkeypatch):
        monkeypatch.setenv("CLAUDE_PROJECTS_DIR", str(tmp_path))
        self.tmp_path = tmp_path

    def _cwd_encoded(self, m):
        return m.encode_cwd(os.getcwd())

    def test_appends_first_pr(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-add-pr-a"
        original = json.dumps({"type": "custom-title", "customTitle": "#299 Foo"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        result = m.run_add_pr(310, os.getcwd())
        assert result == 0

        lines = f.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2
        appended = json.loads(lines[-1])
        assert appended["customTitle"] == "#299 Foo PR #310"

    def test_appends_second_pr_with_comma(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-add-pr-b"
        original = json.dumps({"type": "custom-title", "customTitle": "#299 Foo PR #310"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        m.run_add_pr(311, os.getcwd())

        lines = f.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2
        appended = json.loads(lines[-1])
        assert appended["customTitle"] == "#299 Foo PR #310, PR #311"

    def test_idempotent_skip_when_pr_present(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-add-pr-c"
        original = json.dumps({"type": "custom-title", "customTitle": "#299 Foo PR #310"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_content = f.read_text(encoding="utf-8")
        result = m.run_add_pr(310, os.getcwd())
        assert result == 0
        assert f.read_text(encoding="utf-8") == original_content

    def test_pr_ref_in_body_first_real_pr(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-add-pr-d"
        original = json.dumps({"type": "custom-title", "customTitle": "#299 Fix PR #123 regression"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        m.run_add_pr(310, os.getcwd())

        lines = f.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2
        appended = json.loads(lines[-1])
        # Space separator (not comma) because no real PR was in the suffix yet
        assert appended["customTitle"] == "#299 Fix PR #123 regression PR #310"

    def test_skip_when_manual_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-add-pr-e"
        original = json.dumps({"type": "custom-title", "customTitle": "User typed this"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_content = f.read_text(encoding="utf-8")
        result = m.run_add_pr(310, os.getcwd())
        assert result == 0
        assert f.read_text(encoding="utf-8") == original_content

    def test_skip_when_no_custom_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-add-pr-f"
        original = json.dumps({"type": "ai-title", "title": "Auto"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_content = f.read_text(encoding="utf-8")
        result = m.run_add_pr(310, os.getcwd())
        assert result == 0
        assert f.read_text(encoding="utf-8") == original_content

    def test_no_jsonl_returns_zero(self, m, capsys):
        cwd_encoded = self._cwd_encoded(m)
        d = self.tmp_path / cwd_encoded
        d.mkdir(parents=True, exist_ok=True)

        result = m.run_add_pr(310, os.getcwd())
        assert result == 0
        captured = capsys.readouterr()
        assert captured.err

    def test_missing_project_dir_returns_zero(self, m, capsys):
        result = m.run_add_pr(310, "/nonexistent/path/xyz")
        assert result == 0
        captured = capsys.readouterr()
        assert captured.err


# ---------------------------------------------------------------------------
# 10. run_mark_complete integration
# ---------------------------------------------------------------------------

class TestRunMarkComplete:
    @pytest.fixture(autouse=True)
    def require_func(self, m):
        if not hasattr(m, 'run_mark_complete'):
            pytest.skip("run_mark_complete not yet implemented")

    @pytest.fixture(autouse=True)
    def set_projects_dir(self, tmp_path, monkeypatch):
        monkeypatch.setenv("CLAUDE_PROJECTS_DIR", str(tmp_path))
        self.tmp_path = tmp_path

    def _cwd_encoded(self, m):
        return m.encode_cwd(os.getcwd())

    def test_prepends_checkmark(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-mark-a"
        original = json.dumps({"type": "custom-title", "customTitle": "#299 Foo"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        result = m.run_mark_complete(os.getcwd())
        assert result == 0

        lines = f.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2
        appended = json.loads(lines[-1])
        assert appended["customTitle"] == "✓#299 Foo"

    def test_preserves_pr_list(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-mark-b"
        original = json.dumps({"type": "custom-title", "customTitle": "#299 Foo PR #310, PR #311"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        m.run_mark_complete(os.getcwd())

        lines = f.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 2
        appended = json.loads(lines[-1])
        assert appended["customTitle"] == "✓#299 Foo PR #310, PR #311"

    def test_idempotent_when_already_marked(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-mark-c"
        original = json.dumps({"type": "custom-title", "customTitle": "✓#299 Foo"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_content = f.read_text(encoding="utf-8")
        result = m.run_mark_complete(os.getcwd())
        assert result == 0
        assert f.read_text(encoding="utf-8") == original_content

    def test_skip_when_manual_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-mark-d"
        original = json.dumps({"type": "custom-title", "customTitle": "My manual title"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_content = f.read_text(encoding="utf-8")
        result = m.run_mark_complete(os.getcwd())
        assert result == 0
        assert f.read_text(encoding="utf-8") == original_content

    def test_skip_when_no_custom_title(self, m):
        cwd_encoded = self._cwd_encoded(m)
        session_id = "session-mark-e"
        original = json.dumps({"type": "ai-title", "title": "Auto generated"}) + "\n"
        f = make_jsonl(self.tmp_path, cwd_encoded, session_id, original)

        original_content = f.read_text(encoding="utf-8")
        result = m.run_mark_complete(os.getcwd())
        assert result == 0
        assert f.read_text(encoding="utf-8") == original_content

    def test_no_jsonl_returns_zero(self, m, capsys):
        cwd_encoded = self._cwd_encoded(m)
        d = self.tmp_path / cwd_encoded
        d.mkdir(parents=True, exist_ok=True)

        result = m.run_mark_complete(os.getcwd())
        assert result == 0
        captured = capsys.readouterr()
        assert captured.err

    def test_missing_project_dir_returns_zero(self, m, capsys):
        result = m.run_mark_complete("/nonexistent/path/xyz")
        assert result == 0
        captured = capsys.readouterr()
        assert captured.err


# ---------------------------------------------------------------------------
# 11. main dispatch
# ---------------------------------------------------------------------------

class TestMainDispatch:
    @pytest.fixture(autouse=True)
    def set_projects_dir(self, tmp_path, monkeypatch):
        monkeypatch.setenv("CLAUDE_PROJECTS_DIR", str(tmp_path))
        self.tmp_path = tmp_path

    def _seed_workflow_title(self, m, tmp_path, title="#299 Test"):
        cwd_encoded = m.encode_cwd(os.getcwd())
        return make_jsonl(tmp_path, cwd_encoded, "session-dispatch",
                          json.dumps({"type": "custom-title", "customTitle": title}) + "\n")

    def test_set_issue_dispatch_returns_zero(self, m):
        cwd_encoded = m.encode_cwd(os.getcwd())
        d = self.tmp_path / cwd_encoded
        d.mkdir(parents=True, exist_ok=True)
        (d / "session-si.jsonl").write_text(
            json.dumps({"type": "ai-title", "title": "Auto"}) + "\n", encoding="utf-8"
        )
        result = m.main(["set-issue", "299", "Test title"])
        assert result == 0

    def test_add_pr_dispatch_returns_zero(self, m):
        self._seed_workflow_title(m, self.tmp_path)
        result = m.main(["add-pr", "310"])
        assert result == 0

    def test_mark_complete_dispatch_returns_zero(self, m):
        self._seed_workflow_title(m, self.tmp_path)
        result = m.main(["mark-complete"])
        assert result == 0

    def test_unknown_subcommand_exits_nonzero(self, m):
        with pytest.raises(SystemExit) as exc_info:
            m.main(["unknown-cmd"])
        assert exc_info.value.code != 0
