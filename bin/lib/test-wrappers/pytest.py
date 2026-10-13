"""Runs one pytest file for the run-all launcher (#2501).

argv: <path> <minVersion>. Writes <RUN_ALL_RESULT_DIR>/cases.tsv; exit 0 pass, 1 any failure,
77 no test ran or all skipped, 79 + an `unrunnable` marker when pytest < minVersion.
pytest runs in a child (argv: --run <casesFile> <path>) that is never told the result directory,
so test code can neither write the marker nor choose this wrapper's exit code.
Runs on Python 3.8+: `uv run` picks the interpreter, and the registry pins pytest only.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CHILD_FLAG = "--run"
FINISHED_NAME = "finished"
NO_TESTS_COLLECTED = 5


def version_tuple(text: str) -> tuple[int, ...]:
    parts = []
    for piece in text.split(".")[:3]:
        digits = "".join(ch for ch in piece if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts + [0] * (3 - len(parts)))


def clean(text: object) -> str:
    return str(text).replace("\t", " ").replace("\r", " ").replace("\n", " ")


class Collector:
    """pytest plugin: cases.tsv records in report order, one seq per test.

    A later phase of the same test (a teardown failure after a passing call) reuses the seq, so the
    readers, which keep the last record of a seq, see one result per case.
    """

    def __init__(self, path: str, cases_file: Path):
        self.path = path
        self.cases_file = cases_file
        self.seqs: dict[str, int] = {}

    def record(self, state: str, name: str) -> None:
        seq = self.seqs.setdefault(name, len(self.seqs) + 1)
        with self.cases_file.open("a", encoding="utf-8", newline="\n") as fh:
            fh.write(f"{seq}\t{state}\t{clean(name)}\t{clean(self.path)}\n")

    def pytest_runtest_logreport(self, report) -> None:
        xfail = hasattr(report, "wasxfail")
        if report.when == "call":
            if xfail:
                self.record("XFAIL" if report.skipped else "XPASS", report.nodeid)
            elif report.passed:
                self.record("PASS", report.nodeid)
            elif report.failed:
                self.record("FAIL", report.nodeid)
            else:
                self.record("SKIP", report.nodeid)
        elif report.when == "setup" and not report.passed:
            if xfail and report.skipped:
                self.record("XFAIL", report.nodeid)
            else:
                self.record("FAIL" if report.failed else "SKIP", report.nodeid)
        elif report.when == "teardown" and report.failed:
            self.record("FAIL", report.nodeid)

    def pytest_collectreport(self, report) -> None:
        if report.failed:
            self.record("FAIL", report.nodeid or self.path)

    def pytest_sessionfinish(self, session, exitstatus) -> None:
        # Proof that pytest itself ended the session: a test that kills the process leaves none.
        self.cases_file.with_name(FINISHED_NAME).write_text(f"{int(exitstatus)}\n", encoding="utf-8")


def import_pytest():
    # This file is named pytest.py: its own directory on sys.path would shadow the real package.
    here = Path(__file__).resolve().parent
    sys.path[:] = [p for p in sys.path if Path(p or ".").resolve() != here]
    sys.modules.pop("pytest", None)
    # An import failure (pytest absent or broken) is a FAIL: the install pre-fetches the package.
    import pytest

    return pytest


def run_child(cases_file: str, path: str) -> int:
    pytest = import_pytest()
    collector = Collector(path, Path(cases_file))
    # "--" keeps a path starting with '-' a path, never a pytest option.
    return int(pytest.main(["-q", "-p", "no:cacheprovider", "--", path], plugins=[collector]))


def main() -> int:
    path, min_version = sys.argv[1], sys.argv[2]
    # The result env belongs to this wrapper; the child and the test code under it never see it.
    result_dir = Path(os.environ.pop("RUN_ALL_RESULT_DIR", "") or tempfile.mkdtemp(prefix="pytest-"))
    os.environ.pop("RUN_ALL_RESULT_OWNER", None)
    result_dir.mkdir(parents=True, exist_ok=True)
    label = f"pytest>={min_version}"
    pytest = import_pytest()
    if version_tuple(pytest.__version__) < version_tuple(min_version):
        print(f"UNRUNNABLE: {label} (have {pytest.__version__})")
        # open(), not write_text(newline=): that keyword needs Python 3.10.
        with (result_dir / "unrunnable").open("w", encoding="utf-8", newline="\n") as fh:
            fh.write(label + "\n")
        return 79
    states: list[str] = []
    finished = ""
    with tempfile.TemporaryDirectory(prefix="pytest-cases-") as scratch:
        cases = Path(scratch) / "cases.tsv"
        argv = [sys.executable, str(Path(__file__).resolve()), CHILD_FLAG, str(cases), path]
        rc = subprocess.run(argv, check=False).returncode
        if cases.exists():
            shutil.copyfile(cases, result_dir / "cases.tsv")
            lines = cases.read_text(encoding="utf-8").splitlines()
            states = [fields[1] for fields in (line.split("\t") for line in lines) if len(fields) > 1]
        if (Path(scratch) / FINISHED_NAME).exists():
            finished = (Path(scratch) / FINISHED_NAME).read_text(encoding="utf-8").strip()
    # "No tests collected" only when pytest ended the session saying so; the bare rc can be a test's own exit.
    if rc == NO_TESTS_COLLECTED and not states and finished == str(NO_TESTS_COLLECTED):
        return 77
    if rc != 0 or "FAIL" in states:
        return 1
    if not states or all(s == "SKIP" for s in states):
        return 77
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == CHILD_FLAG:
        sys.exit(run_child(sys.argv[2], sys.argv[3]))
    sys.exit(main())
