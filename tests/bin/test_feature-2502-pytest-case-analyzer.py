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


# leftover-defs must not report a function pytest itself calls: a fixture (by @pytest.fixture or an
# imported @fixture, called or not), a pytest_* hook or an xunit-style setup_/teardown_ function.
# Other unused functions stay reported.
PYTEST_IMPORT = ["import pytest", "", ""]
FIXTURE_IMPORT = ["from pytest import fixture", "", ""]
FUNCTOOLS_IMPORT = ["import functools", "", ""]
OTHER_IMPORT = ["import other", "", ""]
ALIASED_PYTEST_IMPORT = ["import pytest as pt", "", ""]
OTHER_FIXTURE_IMPORT = ["from other import fixture", "", ""]
REAL_CASE = ["", "", "def test_alpha():", "    assert True"]


def lone_function(header: list[str], decorators: list[str], signature: str) -> tuple[list[str], str]:
    """The source with one function after header and decorators, and that function's def line."""
    lines = [*header, *decorators, signature, "    return 1", *REAL_CASE]
    return lines, str(len(header) + len(decorators) + 1)


@pytest.mark.parametrize(
    ("header", "decorators", "signature", "name", "reported"),
    [
        pytest.param(PYTEST_IMPORT, ["@pytest.fixture(autouse=True)"], "def setup_env():", "setup_env", False, id="pytest-fixture-autouse"),
        pytest.param(PYTEST_IMPORT, ["@pytest.fixture"], "def unused_value():", "unused_value", False, id="pytest-fixture-uncalled"),
        pytest.param(FIXTURE_IMPORT, ["@fixture"], "def unused_value():", "unused_value", False, id="imported-fixture"),
        pytest.param(FIXTURE_IMPORT, ["@fixture(autouse=True)"], "def setup_env():", "setup_env", False, id="imported-fixture-autouse"),
        pytest.param(ALIASED_PYTEST_IMPORT, ["@pt.fixture"], "def unused_value():", "unused_value", False, id="aliased-pytest-fixture"),
        pytest.param(OTHER_FIXTURE_IMPORT, ["@fixture"], "def unused_value():", "unused_value", False, id="bare-fixture-from-other-module"),
        pytest.param([], [], "def pytest_configure(config):", "pytest_configure", False, id="hook-pytest-configure"),
        pytest.param([], [], "def pytest_collection_modifyitems(config, items):", "pytest_collection_modifyitems", False, id="hook-collection-modifyitems"),
        pytest.param([], [], "def setup_module(module):", "setup_module", False, id="xunit-setup-module"),
        pytest.param([], [], "def teardown_module(module):", "teardown_module", False, id="xunit-teardown-module"),
        pytest.param([], [], "def setup_function(function):", "setup_function", False, id="xunit-setup-function"),
        pytest.param([], [], "def teardown_function(function):", "teardown_function", False, id="xunit-teardown-function"),
        pytest.param([], [], "def setup_modules_helper():", "setup_modules_helper", True, id="control-xunit-look-alike"),
        pytest.param([], [], "def helper_unused():", "helper_unused", True, id="control-undecorated-helper"),
        pytest.param(FUNCTOOLS_IMPORT, ["@functools.cache"], "def cached_value():", "cached_value", True, id="control-non-fixture-decorator"),
        pytest.param(OTHER_IMPORT, ["@other.fixture"], "def unused_value():", "unused_value", True, id="control-non-pytest-fixture-attribute"),
        pytest.param([], [], "def my_pytest_helper():", "my_pytest_helper", True, id="control-pytest-infix-name"),
    ],
)
def test_leftover_defs_skip_functions_pytest_calls(case, tmp_path, header, decorators, signature, name, reported):
    lines, line = lone_function(header, decorators, signature)
    want = [[line, name]] if reported else []
    got = analyze_ok(case, "leftover-defs", write(tmp_path / "test_leftover.py", lines))
    assert got == want, f"{case}: leftover-defs"


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


# Only a test case's own parametrize counts: a top-level test_* function or a test_* method of a
# top-level Test* class. A parametrized helper or nested function leaves every case cuttable.
PARAM = '@pytest.mark.parametrize("n", [1, 2])'
PLAIN_CASE = ["", "", '@pytest.mark.target("bin/a.sh")', "def test_alpha():", "    assert True"]
# `from pytest import mark` spells the same decorator without the `pytest.` prefix.
MARK_IMPORT = ["from pytest import mark", "", ""]


@pytest.mark.parametrize(
    ("lines", "word"),
    [
        pytest.param(["import pytest", "", "", PARAM, "def _helper(n):", "    return n", *PLAIN_CASE], [], id="top-level-helper"),
        pytest.param(
            ["import pytest", "", "", "def test_outer():", f"    {PARAM}", "    def inner(n):", "        return n", "    assert inner"],
            [],
            id="nested-in-test",
        ),
        pytest.param(
            ["import pytest", "", "", "class TestBox:", f"    {PARAM}", "    def helper(self, n):", "        return n", "", "    def test_one(self):", "        assert True"],
            [],
            id="non-test-method",
        ),
        pytest.param(
            ["import pytest", "", "", "class TestBox:", f"    {PARAM}", "    def test_one(self, n):", "        assert n"],
            [["parametrized-case"]],
            id="test-method-of-test-class",
        ),
        pytest.param(["import pytest", "", "", PARAM, "def test_alpha(n):", "    assert n"], [["parametrized-case"]], id="top-level-test"),
        pytest.param(["import pytest", *PLAIN_CASE], [], id="no-parametrize"),
        pytest.param(
            [*MARK_IMPORT, '@mark.parametrize("x", [1, 2])', "def test_a(x):", "    assert x"],
            [["parametrized-case"]],
            id="imported-mark-top-level-test",
        ),
        pytest.param(
            [*MARK_IMPORT, "@mark.parametrize", "def test_a(x):", "    assert x"],
            [["parametrized-case"]],
            id="imported-mark-uncalled",
        ),
        pytest.param(
            [*MARK_IMPORT, "class TestA:", '    @mark.parametrize("x", [1])', "    def test_m(self, x):", "        assert x"],
            [["parametrized-case"]],
            id="imported-mark-test-method",
        ),
        pytest.param(
            ["import other", "", "", '@other.parametrize("x", [1])', "def test_a(x):", "    assert x"],
            [],
            id="other-parametrize",
        ),
        pytest.param(
            ["from somewhere import parametrize", "", "", '@parametrize("x", [1])', "def test_a(x):", "    assert x"],
            [],
            id="bare-parametrize",
        ),
        pytest.param(
            [*MARK_IMPORT, '@mark.parametrize("n", [1, 2])', "def _helper(n):", "    return n", *PLAIN_CASE],
            [],
            id="imported-mark-helper",
        ),
    ],
)
def test_skip_reason_counts_only_a_test_cases_parametrize(case, tmp_path, lines, word):
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


# A file that parses but holds no test_* function or Test* class: case-count answers "no case
# unit" (rc 1), which a parse failure never prints, and syntax-check still passes it.
NO_UNIT = ["import sys", "", "", "def helper():", "    return sys.argv"]


def test_case_count_rejects_a_parsable_file_without_units(case, tmp_path):
    path = write(tmp_path / "test_empty.py", NO_UNIT)
    done = run(case, ANALYZER, "case-count", str(path))
    assert done.returncode == 1, f"{case}: case-count exit code"
    assert done.stdout == "", f"{case}: no stdout"
    assert "no case unit" in done.stderr, f"{case}: no-unit reason; stderr: {done.stderr}"
    assert analyze_ok(case, "syntax-check", path) == [], f"{case}: the file parses"
    bad = run(case, ANALYZER, "case-count", str(write(tmp_path / "test_bad.py", ["def test_x(:", "    assert True"])))
    assert bad.returncode == 1 and "no case unit" not in bad.stderr, f"{case}: a parse failure gives another reason"


def test_file_under_analysis_is_never_executed(case, tmp_path):
    sentinel = tmp_path / "executed.flag"
    lines = ["from pathlib import Path", f"Path({json.dumps(str(sentinel))}).write_text('ran')", *SAMPLE]
    path = write(tmp_path / "test_side.py", lines)
    for op in ("deps", "leftover-defs", "skip-reason", "syntax-check"):
        analyze_ok(case, op, path)
    analyze_ok(case, "self-impl", path, str(HELPER))
    assert not sentinel.exists(), f"{case}: sentinel must not be written"
