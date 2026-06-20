# ============================================================
# Section A: resolveRepoDir unit tests
# ============================================================
echo ""
echo "=== A. resolveRepoDir unit tests ==="

# N1: /c/git/dotfiles -> C:\git\dotfiles
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C /c/git/dotfiles commit -m "msg"'));
EOF
)
assert_eq 'N1: /c/path -> C:\git\dotfiles' 'C:\git\dotfiles' "$result"

# N2: /C/Users/foo/bar -> C:\Users\foo\bar
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C /C/Users/foo/bar commit -m "msg"'));
EOF
)
assert_eq 'N2: /C/path (uppercase) -> C:\Users\foo\bar' 'C:\Users\foo\bar' "$result"

# N3: C:\git\dotfiles -> C:\git\dotfiles (no conversion)
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C C:\\git\\dotfiles commit -m "msg"'));
EOF
)
assert_eq 'N3: Windows path unchanged' 'C:\git\dotfiles' "$result"

# N4: no -C flag -> process.cwd()
expected_cwd=$(node --input-type=module <<'EOF'
process.stdout.write(process.cwd());
EOF
)
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git commit -m "msg"'));
EOF
)
assert_eq "N4: no -C -> process.cwd()" "$expected_cwd" "$result"

# E1: /c -> C:\
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C /c commit -m "msg"'));
EOF
)
assert_eq 'E1: /c -> C:\' 'C:\' "$result"

# E2: /git/dotfiles (no drive letter) -> unchanged
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C /git/dotfiles commit -m "msg"'));
EOF
)
assert_eq "E2: /git/dotfiles (no drive) -> unchanged" '/git/dotfiles' "$result"

# E3: . -> .
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C . commit -m "msg"'));
EOF
)
assert_eq "E3: dot path -> dot" '.' "$result"

# N5: $VAR -> expanded Windows path (env var in double quotes)
result=$(FORNIX_DIR_TEST="C:/git/fornix-stream" node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C "$FORNIX_DIR_TEST" commit -m "msg"'));
EOF
)
assert_eq 'N5: $VAR in double quotes -> expanded+normalized' 'C:\git\fornix-stream' "$result"

# N6: ${VAR} braced form
result=$(AGENTS_DIR_TEST="C:/git/agents" node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C "${AGENTS_DIR_TEST}" commit -m "msg"'));
EOF
)
assert_eq 'N6: ${VAR} braced form -> expanded+normalized' 'C:\git\agents' "$result"

# N7: undefined $VAR -> fallback to cwd
result=$(node_hook --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveRepoDir } = require(process.env.HOOK_PATH);
process.stdout.write(resolveRepoDir('git -C "$UNDEFINED_VAR_XYZ_NONEXISTENT" commit -m "msg"'));
EOF
)
assert_eq 'N7: undefined $VAR -> fallback cwd' "$expected_cwd" "$result"
