# E-series sourced fragment — split from fix-issue-724-sync-labels-status.sh (Pattern A).
# Globals required from parent: PASS, FAIL, pass(), fail(), run_with_timeout(), SYNC_SCRIPT, MOCK_DIR, REAL_GIT, AGENTS_DIR, ONE_LABEL_YML.

# ============================================================================
# E-series — GitLab forge routing (issue #2308)
# ============================================================================
# sync-labels.sh must route label ops by the CWD repo's forge: a gitlab origin
# goes through glab, a github origin stays on gh. RED now — the script is
# gh-only and detects no forge, so a gitlab repo still hits gh. gh comes from
# the existing fixture mock (copied so real git is not shadowed); glab is an
# inline mock logging its argv. Both log; assertions compare which was used.

E_TMP="$(mktemp -d)"
E_LABELS="$E_TMP/labels.yml"
printf '%s' "$ONE_LABEL_YML" > "$E_LABELS"

E_MOCK="$E_TMP/mock"
mkdir -p "$E_MOCK"
export GLAB_MOCK_LABEL_LOG="$E_TMP/glab.log"
export GH_MOCK_LABEL_LOG="$E_TMP/gh.log"
# glab mock: sync-labels uses `glab api` REST for GitLab. Each arm logs a
# normalized `label list/create/edit/delete` token so e_glab_* helpers work
# unchanged (CPR-ORTH). GLAB_MOCK_LABEL_LIST is pre-TSV (jq bypassed in mock).
cat > "$E_MOCK/glab" <<'GLABEOF'
#!/bin/bash
case "$*" in
    "api "*"/labels --paginate "*)
        printf 'label list\n' >> "$GLAB_MOCK_LABEL_LOG"
        if [ "${GLAB_MOCK_LABEL_LIST_FAIL:-0}" = "1" ]; then
            echo "glab: label list API error" >&2; exit 1
        fi
        [ -n "${GLAB_MOCK_LABEL_LIST:-}" ] && printf '%s\n' "$GLAB_MOCK_LABEL_LIST"
        exit 0 ;;
    "api "*"/labels -X POST "*)
        NAME=$(printf '%s' "$*" | sed 's/.*-f name=\([^ ]*\).*/\1/')
        printf 'label create %s\n' "$NAME" >> "$GLAB_MOCK_LABEL_LOG"
        exit 0 ;;
    "api "*"/labels/"*"-X PUT "*)
        ENC=$(printf '%s' "$*" | sed 's|.*labels/\([^ ]*\).*|\1|')
        NAME=$(printf '%s' "$ENC" | sed 's/%3A/:/g; s/%3a/:/g; s/%20/ /g')
        printf 'label edit %s\n' "$NAME" >> "$GLAB_MOCK_LABEL_LOG"
        exit 0 ;;
    "api "*"/labels/"*"-X DELETE"*)
        ENC=$(printf '%s' "$*" | sed 's|.*labels/\([^ ]*\).*|\1|')
        NAME=$(printf '%s' "$ENC" | sed 's/%3A/:/g; s/%3a/:/g; s/%20/ /g')
        printf 'label delete %s\n' "$NAME" >> "$GLAB_MOCK_LABEL_LOG"
        exit 0 ;;
    "label list"*"--json"*)
        printf 'label list\n' >> "$GLAB_MOCK_LABEL_LOG"
        if [ "${GLAB_MOCK_LABEL_LIST_FAIL:-0}" = "1" ]; then
            echo "glab: label list API error" >&2; exit 1
        fi
        [ -n "${GLAB_MOCK_LABEL_LIST:-}" ] && printf '%s\n' "$GLAB_MOCK_LABEL_LIST"
        exit 0 ;;
    "label create"*|"label delete"*|"label edit"*)
        printf '%s\n' "$*" >> "$GLAB_MOCK_LABEL_LOG"; exit 0 ;;
    *"--json"*) echo "[]" ; exit 0 ;;
    *) echo "" ; exit 0 ;;
esac
GLABEOF
chmod +x "$E_MOCK/glab"
cp "$MOCK_DIR/gh" "$E_MOCK/gh" 2>/dev/null || true
chmod +x "$E_MOCK/gh" 2>/dev/null || true
unset GH_MOCK_LABEL_LIST GH_MOCK_LABEL_LIST_FAIL GLAB_MOCK_LABEL_LIST GLAB_MOCK_LABEL_LIST_FAIL

make_forge_repo() {
    local url="$1"
    local repo="$E_TMP/repo-$RANDOM$RANDOM"
    mkdir -p "$repo"
    "$REAL_GIT" -C "$repo" init -q
    "$REAL_GIT" -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    "$REAL_GIT" -C "$repo" config user.email "test@example.com"
    "$REAL_GIT" -C "$repo" config user.name "Test"
    "$REAL_GIT" -C "$repo" remote add origin "$url"
    printf '%s' "$repo"
}

e_reset() { : > "$GH_MOCK_LABEL_LOG"; : > "$GLAB_MOCK_LABEL_LOG"; }
# Count EXACT subcommands, not any "label" token — a bare-count accepts an
# unrelated `glab label list` and calls the routing "green" without a real op.
e_glab_create() { grep -c 'label create' "$GLAB_MOCK_LABEL_LOG" 2>/dev/null; true; }
e_glab_edit() { grep -c 'label edit' "$GLAB_MOCK_LABEL_LOG" 2>/dev/null; true; }
e_glab_list() { grep -c 'label list' "$GLAB_MOCK_LABEL_LOG" 2>/dev/null; true; }
e_glab_delete_of() { grep -c "label delete.*$1" "$GLAB_MOCK_LABEL_LOG" 2>/dev/null; true; }
e_gh_created() { grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true; }
e_gh_used() { grep -c 'label' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true; }

REPO_GL_E="$(make_forge_repo 'git@gitlab.com:acme/widgets.git')"
REPO_GH_E="$(make_forge_repo 'git@github.com:acme/widgets.git')"
REPO_UNK_E="$(make_forge_repo 'git@bitbucket.org:acme/widgets.git')"

# --- E1: gitlab repo with AGENTS_CONFIG_DIR UNSET → glab path via SCRIPT_DIR
# fallback. Empty remote (no GLAB_MOCK_LABEL_LIST) → type:task is CREATED via a
# `glab label create`, `glab label list` is queried first, gh is untouched, and
# the script exits 0. RED now. Verifying exit status + exact subcommands closes
# the C11 gap (a bare "label" token would pass on a no-op list alone).
e_reset
( cd "$REPO_GL_E" && unset AGENTS_CONFIG_DIR GLAB_MOCK_LABEL_LIST
  PATH="$E_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
E1_RC=$?
if [ "$E1_RC" -eq 0 ] && [ "$(e_glab_list)" -ge 1 ] && [ "$(e_glab_create)" -ge 1 ] \
   && [ "$(e_gh_used)" -eq 0 ]; then
    pass "E1: gitlab repo, AGENTS_CONFIG_DIR unset → glab list+create, no gh, exit 0"
else
    fail "E1: expected exit 0 + glab list>=1 + glab create>=1 + no gh (rc=$E1_RC glab_list=$(e_glab_list) glab_create=$(e_glab_create) gh_used=$(e_gh_used))"
fi

# --- E2: gitlab repo with AGENTS_CONFIG_DIR set → glab create for type:task,
# gh label create NOT called, exit 0. RED now (gh-only script).
e_reset
( cd "$REPO_GL_E" && export AGENTS_CONFIG_DIR="$AGENTS_DIR" && unset GLAB_MOCK_LABEL_LIST
  PATH="$E_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
E2_RC=$?
if [ "$E2_RC" -eq 0 ] && [ "$(e_glab_create)" -ge 1 ] && [ "$(e_gh_created)" -eq 0 ]; then
    pass "E2: gitlab repo → glab label create, gh label create NOT called, exit 0"
else
    fail "E2: expected exit 0 + glab create + no gh create (rc=$E2_RC glab_create=$(e_glab_create) gh_created=$(e_gh_created))"
fi

# --- E-update (C11): gitlab repo, remote type:task color differs from labels.yml
# → the three-way UPDATE arm fires on the glab path via `glab label edit` (the
# glab analogue of gh's `label create --force`). glab create must NOT be used for
# an existing label, and gh must stay untouched. This is the GitLab twin of S3;
# without it a regression in the glab update path goes undetected. RED now.
e_reset
( cd "$REPO_GL_E" && export AGENTS_CONFIG_DIR="$AGENTS_DIR" \
    GLAB_MOCK_LABEL_LIST=$'type:task\tff0000\tNormal work item.'
  PATH="$E_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
EUP_RC=$?
if [ "$EUP_RC" -eq 0 ] && [ "$(e_glab_edit)" -ge 1 ] && [ "$(e_glab_create)" -eq 0 ] \
   && [ "$(e_gh_used)" -eq 0 ]; then
    pass "E-update: gitlab color-diff → glab label edit (not create), gh untouched, exit 0"
else
    fail "E-update: expected exit 0 + glab edit>=1 + no glab create + no gh (rc=$EUP_RC glab_edit=$(e_glab_edit) glab_create=$(e_glab_create) gh_used=$(e_gh_used) glab-log=[$(cat "$GLAB_MOCK_LABEL_LOG" 2>/dev/null | tr '\n' ';')])"
fi

# --- E-unchanged (C11): gitlab repo, remote matches labels.yml EXACTLY → no-op.
# `glab label list` is queried (to compute the diff) but NO mutating call fires:
# no create, no edit, no delete. gh stays untouched. GitLab twin of S2; guards
# against a glab path that re-writes labels on every run. RED now.
e_reset
( cd "$REPO_GL_E" && export AGENTS_CONFIG_DIR="$AGENTS_DIR" \
    GLAB_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.'
  PATH="$E_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
EUN_RC=$?
if [ "$EUN_RC" -eq 0 ] && [ "$(e_glab_list)" -ge 1 ] && [ "$(e_glab_create)" -eq 0 ] \
   && [ "$(e_glab_edit)" -eq 0 ] && [ "$(e_glab_delete_of type:task)" -eq 0 ] \
   && [ "$(e_gh_used)" -eq 0 ]; then
    pass "E-unchanged: gitlab exact-match → glab list only, no create/edit/delete, gh untouched, exit 0"
else
    fail "E-unchanged: expected exit 0 + glab list>=1 + no create/edit/delete + no gh (rc=$EUN_RC glab_list=$(e_glab_list) glab_create=$(e_glab_create) glab_edit=$(e_glab_edit) gh_used=$(e_gh_used) glab-log=[$(cat "$GLAB_MOCK_LABEL_LOG" 2>/dev/null | tr '\n' ';')])"
fi

# --- E3: CONTROL — github repo → gh label path unchanged, glab NOT called.
# GREEN now and after #2308 (regression pin).
e_reset
( cd "$REPO_GH_E" && export AGENTS_CONFIG_DIR="$AGENTS_DIR"
  PATH="$E_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
E3_RC=$?
if [ "$E3_RC" -eq 0 ] && [ "$(e_gh_created)" -ge 1 ] && [ "$(e_glab_create)" -eq 0 ] \
   && [ "$(e_glab_list)" -eq 0 ]; then
    pass "E3: github repo → gh label path unchanged, glab NOT called"
else
    fail "E3: expected gh create + no glab (rc=$E3_RC gh_created=$(e_gh_created) glab_create=$(e_glab_create) glab_list=$(e_glab_list))"
fi

# --- E4 (C11): protected label no-op. A gitlab repo whose remote carries a
# protected label ('bug') plus an orphan ('old:stale') must NOT delete the
# protected one; the orphan may be deleted. Proves the protected guard is honored
# on the glab path (not a false-green from an empty remote where no delete would
# ever fire). RED now.
E4_LABELS="$E_TMP/labels-protected.yml"
printf '%s' '- name: "type:task"
  color: "0e8a16"
  description: "Normal work item."

protected:
  - bug
' > "$E4_LABELS"
e_reset
( cd "$REPO_GL_E" && export AGENTS_CONFIG_DIR="$AGENTS_DIR" \
    GLAB_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.\nbug\tee0701\tSomething is not working.\nold:stale\taaaaaa\tStale label.'
  PATH="$E_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E4_LABELS" ) >/dev/null 2>&1
E4_RC=$?
if [ "$E4_RC" -eq 0 ] && [ "$(e_glab_delete_of bug)" -eq 0 ] \
   && [ "$(e_glab_delete_of 'old:stale')" -ge 1 ] && [ "$(e_gh_used)" -eq 0 ]; then
    pass "E4: gitlab protected 'bug' kept, orphan 'old:stale' deleted, gh untouched, exit 0"
else
    fail "E4: expected exit 0 + no delete bug + delete old:stale + no gh (rc=$E4_RC bug_deleted=$(e_glab_delete_of bug) stale_deleted=$(e_glab_delete_of 'old:stale') gh_used=$(e_gh_used) glab-log=[$(cat "$GLAB_MOCK_LABEL_LOG" 2>/dev/null | tr '\n' ';')])"
fi

# --- E5 (C13): unknown-forge guard. A bitbucket (unknown) origin must be
# rejected safely — NEITHER gh NOR glab called, exit non-zero. RED now: the
# gh-only script detects no forge and still hits `gh label list`. GREEN once
# #2308 classifies the forge up front and rejects an unknown one.
e_reset
( cd "$REPO_UNK_E" && export AGENTS_CONFIG_DIR="$AGENTS_DIR"
  PATH="$E_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
E5_RC=$?
if [ "$E5_RC" -ne 0 ] && [ "$(e_gh_used)" -eq 0 ] && [ ! -s "$GLAB_MOCK_LABEL_LOG" ]; then
    pass "E5: unknown-forge repo → rejected (rc!=0), neither gh nor glab called"
else
    fail "E5: expected rc!=0 + no gh + no glab (rc=$E5_RC gh_used=$(e_gh_used) glab-log=[$(cat "$GLAB_MOCK_LABEL_LOG" 2>/dev/null | tr '\n' ';')])"
fi

# E-sub series (C11): subgroup/subpath namespace %2F-encoding asserted here.
# glab api addresses a project by its URL-encoded FULL path, so every "/" must
# arrive as "%2F" (and the label name's ":" as "%3A"); a bare slash would hit the
# wrong or a nonexistent project endpoint. Source: bin/github-issues/sync-labels.sh.
ES_MOCK="$E_TMP/es-mock"
mkdir -p "$ES_MOCK"
export GLAB_RAW_LOG="$E_TMP/glab-raw.log"
: > "$GLAB_RAW_LOG"
cat > "$ES_MOCK/glab" <<'GLABRAW'
#!/bin/bash
printf '%s\n' "$*" >> "$GLAB_RAW_LOG"
case "$*" in
    "api "*"/labels --paginate "*)
        [ -n "${GLAB_SUB_LIST:-}" ] && printf '%s\n' "$GLAB_SUB_LIST"
        exit 0 ;;
    "api "*"/labels -X POST "*) exit 0 ;;
    "api "*"/labels/"*"-X PUT "*) exit 0 ;;
    "api "*"/labels/"*"-X DELETE"*) exit 0 ;;
    *) echo "" ; exit 0 ;;
esac
GLABRAW
chmod +x "$ES_MOCK/glab"
cp "$MOCK_DIR/gh" "$ES_MOCK/gh" 2>/dev/null || true
chmod +x "$ES_MOCK/gh" 2>/dev/null || true

REPO_SUB="$(make_forge_repo 'git@gitlab.com:group/sub/proj.git')"
REPO_SUB_DEEP="$(make_forge_repo 'git@gitlab.com:group/team/sub/proj.git')"
es_grep() { grep -c "$1" "$GLAB_RAW_LOG" 2>/dev/null; true; }

# --- E-sub1: 3-level namespace create → project path fully %2F-encoded, never a bare slash.
: > "$GLAB_RAW_LOG"
( cd "$REPO_SUB" && export AGENTS_CONFIG_DIR="$AGENTS_DIR" && unset GLAB_SUB_LIST
  PATH="$ES_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
ES1_RC=$?
if [ "$ES1_RC" -eq 0 ] && [ "$(es_grep 'projects/group%2Fsub%2Fproj/labels')" -ge 1 ] \
   && [ "$(es_grep 'projects/group/sub/proj/labels')" -eq 0 ]; then
    pass "E-sub1: subgroup origin → glab api uses %2F-encoded project path (group%2Fsub%2Fproj), no bare slashes"
else
    fail "E-sub1: expected exit 0 + %2F-encoded path + no bare-slash path (rc=$ES1_RC enc=$(es_grep 'projects/group%2Fsub%2Fproj/labels') bare=$(es_grep 'projects/group/sub/proj/labels') raw=[$(tr '\n' ';' < "$GLAB_RAW_LOG" 2>/dev/null)])"
fi

# --- E-sub2: subgroup UPDATE → PUT url encodes BOTH the project path (%2F) and the label name (%3A).
: > "$GLAB_RAW_LOG"
( cd "$REPO_SUB" && export AGENTS_CONFIG_DIR="$AGENTS_DIR" \
    GLAB_SUB_LIST=$'type:task\tff0000\tNormal work item.'
  PATH="$ES_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
ES2_RC=$?
if [ "$ES2_RC" -eq 0 ] && [ "$(es_grep 'projects/group%2Fsub%2Fproj/labels/type%3Atask')" -ge 1 ]; then
    pass "E-sub2: subgroup update → glab PUT encodes project path (%2F) and label name (%3A)"
else
    fail "E-sub2: expected exit 0 + encoded PUT url projects/group%2Fsub%2Fproj/labels/type%3Atask (rc=$ES2_RC hit=$(es_grep 'projects/group%2Fsub%2Fproj/labels/type%3Atask') raw=[$(tr '\n' ';' < "$GLAB_RAW_LOG" 2>/dev/null)])"
fi

# --- E-sub3: deeper 4-level namespace → every separator encoded.
: > "$GLAB_RAW_LOG"
( cd "$REPO_SUB_DEEP" && export AGENTS_CONFIG_DIR="$AGENTS_DIR" && unset GLAB_SUB_LIST
  PATH="$ES_MOCK:$PATH" run_with_timeout 30 bash "$SYNC_SCRIPT" "$E_LABELS" ) >/dev/null 2>&1
ES3_RC=$?
if [ "$ES3_RC" -eq 0 ] && [ "$(es_grep 'projects/group%2Fteam%2Fsub%2Fproj/labels')" -ge 1 ] \
   && [ "$(es_grep 'projects/group/team/sub/proj/labels')" -eq 0 ]; then
    pass "E-sub3: 4-level namespace → glab api uses fully %2F-encoded path (group%2Fteam%2Fsub%2Fproj)"
else
    fail "E-sub3: expected exit 0 + fully %2F-encoded 4-level path (rc=$ES3_RC enc=$(es_grep 'projects/group%2Fteam%2Fsub%2Fproj/labels') bare=$(es_grep 'projects/group/team/sub/proj/labels') raw=[$(tr '\n' ';' < "$GLAB_RAW_LOG" 2>/dev/null)])"
fi

unset GLAB_RAW_LOG GLAB_SUB_LIST

rm -rf "$E_TMP" 2>/dev/null || true
unset GLAB_MOCK_LABEL_LOG GH_MOCK_LABEL_LOG GLAB_MOCK_LABEL_LIST GLAB_MOCK_LABEL_LIST_FAIL
