# Tests: bin/lib/test-language-parts/pytest-case-analyzer.py
# Tags: TL2, bin, case-markers, test-language-registry, sweep-tests, pytest, scope:issue-specific
"""The pytest analyzer answers each caseEmbedRules op as TSV for one test file.

Called as `<op> <file> [args]`: deps (ORDER lines matching the test case reader's ranges,
then idx<TAB>csv), leftover-defs (line<TAB>name), self-impl <file> <helper> (line<TAB>kind
<TAB>detail), skip-reason (one word or nothing) and syntax-check (no stdout; rc 0 / 1). The
file under analysis is parsed with `ast`, never imported.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401

ROOT = Path(__file__).resolve().parents[2]
PARTS = ROOT / "bin" / "lib" / "test-language-parts"
ANALYZER = PARTS / "pytest-case-analyzer.py"
READER = PARTS / "pytest-case-reader.py"
HELPER = ROOT / "tests" / "lib" / "harness.py"

# Three cases: case 0 uses helper_alpha; case 1 uses helper_alpha, the fixture beta_value and
# LIMIT; case 2 uses nothing; helper_unused (line 16) is used by no case.
SAMPLE = [
    "import sys",
    "from pathlib import Path",
    "",
    "import pytest",
    "",
    'sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))',
    "import harness  # noqa: E402,F401",
    "",
    "LIMIT = 3",
    "",
    "",
    "def helper_alpha():",
    "    return 1",
    "",
    "",
    "def helper_unused():",
    "    return 9",
    "",
    "",
    "@pytest.fixture",
    "def beta_value():",
    "    return 2",
    "",
    "",
    '@pytest.mark.target("bin/a.sh")',
    "def test_alpha():",
    "    assert helper_alpha() == 1",
    "",
    "",
    '@pytest.mark.target("bin/b.sh")',
    "def test_beta(beta_value):",
    "    assert helper_alpha() + beta_value == LIMIT",
    "",
    "",
    '@pytest.mark.target("bin/c.sh")',
    "def test_plain():",
    "    assert True",
]

# self-impl: counter-init on 7 (PASS) and 8 (failed); harness-redef on 11 (isolate) and 15
# (_tl3_value, a private helper name counts too).
SELF = [
    "import sys",
    "from pathlib import Path",
    "",
    'sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))',
    "import harness  # noqa: E402,F401",
    "",
    "PASS = 0",
    "failed = 0",
    "",
    "",
    "def isolate(tmp):",
    "    return tmp",
    "",
    "",
    "def _tl3_value():",
    '    return "off"',
    "",
    "",
    "def test_x():",
    "    assert True",
]

# Look-alikes the self-impl op must not report: a renamed helper (the accepted limit), a
# counter inside a function, a method named like a helper.
CLEAN = [
    "count = 0",
    "",
    "",
    "def my_isolate(tmp):",
    "    passed = 0",
    "    return tmp, passed",
    "",
    "",
    "class Box:",
    "    def isolate(self):",
    "        return 1",
    "",
    "",
    "def test_x():",
    "    assert my_isolate(1) == (1, 0)",
]

PARAMETRIZED = [
    "import pytest",
    "",
    "",
    '@pytest.mark.target("bin/a.sh")',
    '@pytest.mark.parametrize("n", [1, 2])',
    "def test_alpha(n):",
    "    assert n",
]


def write(path: Path, lines: list[str]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
    return path


def run(case: str, script: Path, *args: str) -> subprocess.CompletedProcess:
    done = subprocess.run(
        [sys.executable, str(script), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
        check=False,
    )
    assert ANALYZER.is_file(), f"{case}: analyzer {ANALYZER.name} missing"
    return done


def rows(done: subprocess.CompletedProcess) -> list[list[str]]:
    return [line.split("\t") for line in done.stdout.splitlines() if line]


def analyze_ok(case: str, op: str, path: Path, *args: str) -> list[list[str]]:
    done = run(case, ANALYZER, op, str(path), *args)
    assert done.returncode == 0, f"{case}: {op} exit code; stderr: {done.stderr}"
    return rows(done)


@pytest.fixture
def case(request) -> str:
    """The running test's name; every assertion message starts with it."""
    return request.node.name


def test_deps_order_lines_match_the_case_reader(case, tmp_path):
    path = write(tmp_path / "tests" / "bin" / "test_sample.py", SAMPLE)
    got = analyze_ok(case, "deps", path)
    order = [r[1:] for r in got if r[0] == "ORDER"]
    reader = run(case, READER, str(path))
    ranges = [[str(i), r[3], r[4]] for i, r in enumerate(x for x in rows(reader) if x[0] == "CASE")]
    assert ranges == [["0", "25", "27"], ["1", "30", "32"], ["2", "35", "37"]], f"{case}: reader ranges"
    assert order == ranges, f"{case}: ORDER lines equal the reader's case ranges"
    first_dep = next((i for i, r in enumerate(got) if r[0] != "ORDER"), len(got))
    assert all(r[0] != "ORDER" for r in got[first_dep:]), f"{case}: ORDER lines come first"


def test_deps_name_the_definitions_each_case_uses(case, tmp_path):
    got = analyze_ok(case, "deps", write(tmp_path / "test_sample.py", SAMPLE))
    deps = {r[0]: set(filter(None, r[1].split(","))) if len(r) > 1 else set() for r in got if r[0] != "ORDER"}
    assert sorted(deps) == ["0", "1", "2"], f"{case}: one idx row per case"
    assert "helper_alpha" in deps["0"], f"{case}: case 0 uses helper_alpha"
    assert deps["0"].isdisjoint({"beta_value", "LIMIT", "helper_unused"}), f"{case}: case 0 extras {deps['0']}"
    assert {"helper_alpha", "beta_value", "LIMIT"} <= deps["1"], f"{case}: case 1 uses the fixture and LIMIT"
    assert "helper_unused" not in deps["1"], f"{case}: case 1 lacks helper_unused"
    assert deps["2"] == set(), f"{case}: case 2 depends on nothing"


def test_leftover_defs_name_the_unused_top_level_definition(case, tmp_path):
    got = analyze_ok(case, "leftover-defs", write(tmp_path / "test_sample.py", SAMPLE))
    assert got == [["16", "helper_unused"]], f"{case}: leftover-defs"


def test_self_impl_reports_counters_and_helper_redefinitions(case, tmp_path):
    got = analyze_ok(case, "self-impl", write(tmp_path / "test_self.py", SELF), str(HELPER))
    assert [[r[0], r[1]] for r in got] == [
        ["7", "counter-init"],
        ["8", "counter-init"],
        ["11", "harness-redef"],
        ["15", "harness-redef"],
    ], f"{case}: detections"
    assert "PASS" in got[0][2] and "failed" in got[1][2], f"{case}: counter details"
    assert [got[2][2], got[3][2]] == ["isolate", "_tl3_value"], f"{case}: harness-redef details"


def test_self_impl_does_not_report_look_alikes(case, tmp_path):
    assert analyze_ok(case, "self-impl", write(tmp_path / "test_clean.py", CLEAN), str(HELPER)) == [], f"{case}: no detection"


@pytest.mark.parametrize(
    ("lines", "word"),
    [
        pytest.param(PARAMETRIZED, [["parametrized-case"]], id="parametrized"),
        pytest.param(SAMPLE, [], id="plain"),
    ],
)
def test_skip_reason_names_the_unhandled_shape(case, tmp_path, lines, word):
    assert analyze_ok(case, "skip-reason", write(tmp_path / "test_skip.py", lines)) == word, f"{case}: skip-reason"


@pytest.mark.parametrize(
    ("lines", "code"),
    [
        pytest.param(SAMPLE, 0, id="valid"),
        pytest.param(["def test_x(:", "    assert True"], 1, id="bad-signature"),
        pytest.param(["value = (1,", "def test_x():", "    assert True"], 1, id="unclosed-paren"),
    ],
)
def test_syntax_check_answers_by_exit_code_only(case, tmp_path, lines, code):
    done = run(case, ANALYZER, "syntax-check", str(write(tmp_path / "test_syn.py", lines)))
    assert done.returncode == code, f"{case}: exit code; stderr: {done.stderr}"
    assert done.stdout == "", f"{case}: no stdout"
    assert (done.stderr != "") == (code == 1), f"{case}: stderr carries the reason only on failure"


# case-count (#2502 S4-4b): module-level test_* functions and Test* classes are the units; a
# class's methods and functions not named test_* are not, and markers do not change the count.
CLASSY = [
    "def helper():",
    "    return 1",
    "",
    "",
    "def test_alpha():",
    "    assert helper() == 1",
    "",
    "",
    "class TestBox:",
    "    def test_one(self):",
    "        assert True",
    "",
    "    def test_two(self):",
    "        assert True",
]
UNMARKED = [line for line in SAMPLE if not line.startswith("@pytest.mark.target")]


@pytest.mark.parametrize(
    ("lines", "code", "out"),
    [
        pytest.param(SAMPLE, 0, "3", id="marked-functions"),
        pytest.param(UNMARKED, 0, "3", id="markers-do-not-change-the-count"),
        pytest.param(CLASSY, 0, "2", id="class-is-one-unit"),
        pytest.param(["def test_x(:", "    assert True"], 1, "", id="syntax-error"),
    ],
)
def test_case_count_counts_module_level_units(case, tmp_path, lines, code, out):
    done = run(case, ANALYZER, "case-count", str(write(tmp_path / "test_count.py", lines)))
    assert done.returncode == code, f"{case}: exit code; stderr: {done.stderr}"
    assert done.stdout.strip() == out, f"{case}: case-count stdout"


def test_file_under_analysis_is_never_executed(case, tmp_path):
    sentinel = tmp_path / "executed.flag"
    lines = ["from pathlib import Path", f"Path({json.dumps(str(sentinel))}).write_text('ran')", *SAMPLE]
    path = write(tmp_path / "test_side.py", lines)
    for op in ("deps", "leftover-defs", "skip-reason", "syntax-check"):
        analyze_ok(case, op, path)
    analyze_ok(case, "self-impl", path, str(HELPER))
    assert not sentinel.exists(), f"{case}: sentinel must not be written"
