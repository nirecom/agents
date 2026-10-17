# Tests: bin/lib/test-language-parts/pytest-case-reader.py
# Tags: TL2, bin, case-markers, test-language-registry, pytest, scope:issue-specific
"""The pytest case reader parses a test file with `ast` and reports its marked cases as TSV.

One FILE line, one CASE line per module-level `test_*` function or `Test*` class carrying
`@pytest.mark.target("<path>")`. The file under read is never imported or executed.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401

READER = Path(__file__).resolve().parents[2] / "bin" / "lib" / "test-language-parts" / "pytest-case-reader.py"

TWO_CASES = [
    "import pytest",
    "",
    "",
    '@pytest.mark.target("bin/a.sh")',
    "def test_alpha():",
    "    assert True",
    "",
    "",
    "@pytest.mark.slow",
    '@pytest.mark.target("bin/lib/b.py")',
    "class TestBeta:",
    "    def test_one(self):",
    "        assert True",
    "",
    "    def test_two(self):",
    "        assert True",
]
TWO_CASES_ROWS = [
    ["CASE", "test_alpha", "bin/a.sh", "4", "6", "", ""],
    ["CASE", "TestBeta", "bin/lib/b.py", "9", "16", "", ""],
]


def write_sample(path: Path, lines: list[str], eol: str = "\n", bom: bool = False) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "".join(line + eol for line in lines).encode("utf-8")
    path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + body)
    return path


@pytest.fixture
def case(request) -> str:
    """The running test's name with its parameter id; every assertion message starts with it."""
    return request.node.name


def read_cases(case: str, path: Path) -> tuple[int, list[list[str]], list[list[str]]]:
    done = subprocess.run(
        [sys.executable, str(READER), str(path)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
        check=False,
    )
    rows = [line.split("\t") for line in done.stdout.splitlines() if line]
    stray = [row for row in rows if row[0] not in ("FILE", "CASE")]
    assert stray == [], f"{case}: unexpected stdout lines; stderr: {done.stderr}"
    files = [row for row in rows if row[0] == "FILE"]
    cases = [row for row in rows if row[0] == "CASE"]
    return done.returncode, files, cases


def assert_records(case: str, path: Path, state: str, cases: list[list[str]]) -> None:
    code, files, got_cases = read_cases(case, path)
    assert code == 0, f"{case}: exit code"
    assert files == [["FILE", state, "", ""]], f"{case}: FILE line"
    assert got_cases == cases, f"{case}: CASE lines"


def assert_malformed(case: str, path: Path, reason: str) -> None:
    code, files, cases = read_cases(case, path)
    assert code == 0, f"{case}: exit code"
    assert len(files) == 1, f"{case}: exactly one FILE line"
    assert len(files[0]) == 4, f"{case}: FILE line has four fields"
    assert [files[0][1], files[0][3]] == ["malformed", reason], f"{case}: state and reason"
    assert files[0][2].isdigit() and int(files[0][2]) >= 1, f"{case}: line number"
    assert cases == [], f"{case}: no CASE line"


def marked(target_expr: str) -> list[str]:
    return ["import pytest", "", "", f"@pytest.mark.target({target_expr})", "def test_alpha():", "    assert True"]


def test_no_marks_is_none(case, tmp_path):
    lines = ["def test_alpha():", "    assert True", "", "", "class TestBeta:", "    def test_one(self):", "        assert True"]
    assert_records(case, write_sample(tmp_path / "test_none.py", lines), "none", [])


def test_empty_file_is_none(case, tmp_path):
    assert_records(case, write_sample(tmp_path / "test_empty.py", []), "none", [])


def test_two_cases_are_conforming_from_first_decorator_to_last_body_line(case, tmp_path):
    assert_records(case, write_sample(tmp_path / "test_two.py", TWO_CASES), "conforming", TWO_CASES_ROWS)


@pytest.mark.parametrize(
    ("name", "eol", "bom"),
    [
        pytest.param("test_crlf.py", "\r\n", False, id="crlf"),
        pytest.param("test_bom.py", "\n", True, id="bom"),
        pytest.param("test_bom_crlf.py", "\r\n", True, id="bom-crlf"),
        pytest.param("dir with space/test_two cases.py", "\n", False, id="path-with-space"),
    ],
)
def test_encoding_and_path_variants_give_the_same_records(case, tmp_path,name, eol, bom):
    assert_records(case, write_sample(tmp_path / name, TWO_CASES, eol=eol, bom=bom), "conforming", TWO_CASES_ROWS)


def test_trailing_blank_lines_and_comments_stay_outside_the_range(case, tmp_path):
    lines = [*marked('"bin/a.sh"'), "", "", "# trailing note", ""]
    rows = [["CASE", "test_alpha", "bin/a.sh", "4", "6", "", ""]]
    assert_records(case, write_sample(tmp_path / "test_trailing.py", lines), "conforming", rows)


def test_unmarked_non_test_definitions_are_not_cases(case, tmp_path):
    lines = [*marked('"bin/a.sh"'), "", "", "def helper():", "    return 1", "", "", "class Fixture:", "    pass"]
    rows = [["CASE", "test_alpha", "bin/a.sh", "4", "6", "", ""]]
    assert_records(case, write_sample(tmp_path / "test_helpers.py", lines), "conforming", rows)


@pytest.mark.parametrize(
    "target_expr",
    [
        pytest.param("TARGET", id="name"),
        pytest.param('"bin/" + LEAF', id="concatenation"),
        pytest.param('f"bin/{LEAF}"', id="f-string"),
        pytest.param('"bin/{}".format(LEAF)', id="call"),
        pytest.param("42", id="non-string-constant"),
    ],
)
def test_non_constant_target_is_constant(case, tmp_path,target_expr):
    assert_malformed(case, write_sample(tmp_path / "test_constant.py", marked(target_expr)), "constant")


@pytest.mark.parametrize(
    "target",
    [
        pytest.param("", id="empty"),
        pytest.param("/abs/a.sh", id="absolute"),
        pytest.param("C:/abs/a.sh", id="drive-letter"),
        pytest.param("bin\\a.sh", id="backslash"),
        pytest.param("../a.sh", id="leading-dot-dot"),
        pytest.param("bin/../a.sh", id="inner-dot-dot"),
        pytest.param("bin/..", id="trailing-dot-dot"),
        pytest.param("bin/a.sh;id", id="semicolon"),
        pytest.param("bin/$HOME.sh", id="dollar"),
        pytest.param("bin/`id`.sh", id="backtick"),
        pytest.param("bin/a|b.sh", id="pipe"),
        pytest.param("bin/a&b.sh", id="ampersand"),
        pytest.param("bin/a>b.sh", id="redirect"),
        pytest.param("bin/a(b).sh", id="parenthesis"),
        pytest.param("bin/a b.sh", id="space"),
    ],
)
def test_invalid_target_path_is_target(case, tmp_path,target):
    assert_malformed(case, write_sample(tmp_path / "test_target.py", marked(json.dumps(target))), "target")


@pytest.mark.parametrize(
    "unmarked",
    [
        pytest.param(["def test_beta():", "    assert True"], id="function"),
        pytest.param(["class TestBeta:", "    def test_one(self):", "        assert True"], id="class"),
    ],
)
def test_marked_and_unmarked_cases_mixed_is_missing_target(case, tmp_path,unmarked):
    lines = [*marked('"bin/a.sh"'), "", "", *unmarked]
    assert_malformed(case, write_sample(tmp_path / "test_missing.py", lines), "missing-target")


def test_two_target_marks_on_one_case_is_duplicate_target(case, tmp_path):
    lines = [
        "import pytest",
        "",
        "",
        '@pytest.mark.target("bin/a.sh")',
        '@pytest.mark.target("bin/b.sh")',
        "def test_alpha():",
        "    assert True",
    ]
    assert_malformed(case, write_sample(tmp_path / "test_duplicate.py", lines), "duplicate-target")


@pytest.mark.parametrize(
    "lines",
    [
        pytest.param(
            ["import pytest", "", "", "class TestOuter:", '    @pytest.mark.target("bin/a.sh")', "    def test_inner(self):", "        assert True"],
            id="method",
        ),
        pytest.param(
            ["import pytest", "", "", "def test_outer():", '    @pytest.mark.target("bin/a.sh")', "    def test_inner():", "        assert True"],
            id="nested-function",
        ),
        pytest.param(
            ["import pytest", "", "", "if True:", '    @pytest.mark.target("bin/a.sh")', "    def test_inner():", "        assert True"],
            id="inside-if",
        ),
    ],
)
def test_mark_below_module_level_is_nested_target(case, tmp_path,lines):
    assert_malformed(case, write_sample(tmp_path / "test_nested.py", lines), "nested-target")


@pytest.mark.parametrize(
    "lines",
    [
        pytest.param(["def test_alpha(:", "    assert True"], id="bad-signature"),
        pytest.param(["import pytest", "", '@pytest.mark.target("bin/a.sh")', "def test_alpha():", "assert True"], id="bad-indent"),
        pytest.param(["value = (1,", "def test_alpha():", "    assert True"], id="unclosed-paren"),
    ],
)
def test_syntax_error_is_malformed_grammar(case, tmp_path,lines):
    assert_malformed(case, write_sample(tmp_path / "test_broken.py", lines), "grammar")


def test_duplicate_names_pass_through_the_reader_the_shared_state_rule_rejects_them(case, tmp_path):
    """The reader reports both; rejecting the repeated name is the shared state rule's job (#2673)."""
    lines = [*marked('"bin/a.sh"'), "", "", *marked('"bin/b.sh"')[3:]]
    rows = [["CASE", "test_alpha", "bin/a.sh", "4", "6", "", ""], ["CASE", "test_alpha", "bin/b.sh", "9", "11", "", ""]]
    assert_records(case, write_sample(tmp_path / "test_dup_name.py", lines), "conforming", rows)


def test_file_under_read_is_never_executed(case, tmp_path):
    sentinel = tmp_path / "executed.flag"
    lines = [
        "from pathlib import Path",
        "",
        f"Path({json.dumps(str(sentinel))}).write_text('ran')",
        *marked('"bin/a.sh"'),
    ]
    rows = [["CASE", "test_alpha", "bin/a.sh", "7", "9", "", ""]]
    assert_records(case, write_sample(tmp_path / "test_side_effect.py", lines), "conforming", rows)
    assert not sentinel.exists(), f"{case}: sentinel must not be written"


def test_unreadable_path_exits_non_zero_without_a_file_line(case, tmp_path):
    code, files, _cases = read_cases(case, tmp_path / "test_absent.py")
    assert code != 0, f"{case}: exit code"
    assert files == [], f"{case}: no FILE line"
