=== bin/normalize-harness-position.py
def multi_path_tests(tests_dir):
    found = []
    for f in sorted(tests_dir.rglob('*.sh')):
        found.append(f)
    return found
