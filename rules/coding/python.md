---
globs: "**/*.py,**/pyproject.toml,**/uv.lock,**/requirements.txt,**/setup.py,**/setup.cfg"
---

## Python

- Do not use bare `python`, `pip`, or `python3` commands. Always use `uv` (`uv run`, `uv pip`, etc.).
- For one-off scripts: `uv run script.py`
- For adding dependencies: `uv pip install` or `uv add`
