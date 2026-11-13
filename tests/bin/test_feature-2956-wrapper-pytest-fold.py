# Tests: bin/lib/test-wrappers/pytest.py
# Tags: scope:issue-specific, test-language-wrapper, pytest, run-all, result-dir, fail-details, TL2
"""#2956 S3: the pytest wrapper writes one fail-details.tsv record per failed test.

The record is <seq>\\t<case>\\t<text>, <text> the whole failure message folded by the shared rule;
every row of tests/fixtures/fail-detail-fold.tsv must come out as its expected text, with the seq
cases.tsv gives the same case.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401

ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / "bin" / "lib" / "test-wrappers" / "pytest.py"
FIXTURE = ROOT / "tests" / "fixtures" / "fail-detail-fold.tsv"
ESC = {"\\": "\\", "t": "\t", "r": "\r", "n": "\n"}


def expand(s: str) -> str:
    return re.sub(r"@@REP:(\d+):([A-Za-z])@@", lambda m: m.group(2) * int(m.group(1)), s)


def decode(s: str) -> str:
    return re.sub(r"\\([\\trn])", lambda m: ESC[m.group(1)], s)


def load_rows() -> list[tuple[str, str, str]]:
    rows = []
    for line in FIXTURE.read_text(encoding="utf-8").split("\n"):
        line = line.rstrip("\r")
        if not line or line.startswith("#"):
            continue
        name, inp, want = line.split("\t")
        rows.append((name, expand(decode(inp)), expand(want)))
    return rows


def read_tsv(path: Path) -> list[list[str]] | None:
    if not path.is_file():
        return None
    return [ln.split("\t") for ln in path.read_text(encoding="utf-8").split("\n") if ln]


@pytest.mark.target("bin/lib/test-wrappers/pytest.py")
def test_fail_details_fold_matches_fixture(tmp_path: Path) -> None:
    rows = load_rows()
    in_dir = tmp_path / "in"
    res = tmp_path / "res"
    in_dir.mkdir()
    res.mkdir()
    src = ["import pytest", "", "", "def _m(i):", f"    with open({str(in_dir)!r} + '/' + str(i) + '.txt', encoding='utf-8', newline='') as fh:", "        return fh.read()"]
    for i, (_, inp, _) in enumerate(rows):
        with open(in_dir / f"{i}.txt", "w", encoding="utf-8", newline="") as fh:
            fh.write(inp)
        src += ["", "", f"def test_row_{i}_end():", f"    pytest.fail(_m({i}), pytrace=False)"]
    fx = tmp_path / "test_fold.py"
    fx.write_text("\n".join(src) + "\n", encoding="utf-8")
    env = dict(os.environ, RUN_ALL_RESULT_DIR=str(res), RUN_ALL_RESULT_OWNER=str(fx))
    done = subprocess.run(
        [sys.executable, str(WRAPPER), str(fx), "7.0"],
        cwd=tmp_path, env=env, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL,
    )
    assert done.returncode == 1, f"wrapper rc {done.returncode}: {done.stdout} {done.stderr}"
    cases = read_tsv(res / "cases.tsv") or []
    assert sum(1 for c in cases if len(c) > 1 and c[1] == "FAIL") == len(rows), "one FAIL case record per fixture row"
    details = read_tsv(res / "fail-details.tsv")
    assert details is not None, "fail-details.tsv written to the result dir"
    for i, (name, _, want) in enumerate(rows):
        key = f"test_row_{i}_end"
        got = [d for d in details if key in d[1]]
        assert len(got) == 1, f"{name}: one record for {key}, got {len(got)}"
        assert got[0][2] == want, f"{name}: folded text len {len(got[0][2])} != {len(want)}"
        seqs = {c[0] for c in cases if len(c) > 2 and key in c[2]}
        assert got[0][0] in seqs, f"{name}: seq {got[0][0]} not in cases.tsv {seqs}"
