#!/bin/bash
# tests/bin/feature-1340-issue-setup/_mock-ensure-project-ready.sh — file-specific gh mock
# Tests: bin/github-issues/lib/ensure-project-ready.sh
# Tags: github-issues, issue-setup, ensure-project-ready, scope:issue-specific
#
# Entrypoint-private helper (file-split.md Pattern A): write_epr_gh_mock <dest> writes a gh mock.
# Knobs: GH_MOCK_AUTH_HAS_PROJECT 0 (no 'project' scope), GH_MOCK_PROJECT_EXISTS 1,
# GH_MOCK_PROJECT_LIST_FAIL 1, GH_MOCK_STATUS_FIELD_EXISTS 1, GH_MOCK_SESSION_ID_FIELD_EXISTS 1,
# GH_MOCK_SESSION_ID_CREATE_FAIL 1, GH_MOCK_LINK_FAILS 1. Field lists, the TEXT create and view
# calls go to tests/lib/gh-projectv2-fields-mock.sh, so its knobs (GH_MOCK_SID_FIELD, ...) apply.

if [ -n "${_EPR_MOCK_LIB_SOURCED:-}" ]; then
    return 0
fi
_EPR_MOCK_LIB_SOURCED=1
_EPR_FIELDS_MODEL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/gh-projectv2-fields-mock.sh"

write_epr_gh_mock() {
    local dest="$1"
    printf '#!/bin/bash\nFIELDS_MODEL=%q\n' "$_EPR_FIELDS_MODEL" > "$dest"
    cat >> "$dest" <<'MOCK_EOF'
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  auth\ status*)
    if [ "${GH_MOCK_AUTH_HAS_PROJECT:-1}" = "0" ]; then
        echo "Logged in to github.com as testuser (oauth_token)"
        echo "Token scopes: 'repo', 'read:org'"
        exit 0
    fi
    echo "Logged in to github.com as testuser (oauth_token)"
    echo "Token scopes: 'repo', 'project', 'read:org'"
    exit 0
    ;;
  project\ list*)
    if [ "${GH_MOCK_PROJECT_LIST_FAIL:-0}" = "1" ]; then
        echo "error: gh project list failed (simulated)" >&2
        exit 1
    fi
    if [ "${GH_MOCK_PROJECT_EXISTS:-1}" = "1" ]; then
        printf '{"projects":[{"number":1,"title":"testowner/testrepo — Issue Timeline","id":"PVT_existing"}]}\n'
    else
        printf '{"projects":[]}\n'
    fi
    exit 0
    ;;
  api\ repos/*)
    # Repo node-id lookup (`gh api repos/<o>/<r> --jq .node_id`): prints the raw extracted value.
    printf '%s\n' "R_kgDOmockrepo"
    exit 0
    ;;
  api\ graphql*)
    case "$ARGS" in
      *linkProjectV2ToRepository*)
        # Head of the inner case: the mutation body also carries `projectId`.
        if [ "${GH_MOCK_LINK_FAILS:-0}" = "1" ]; then
            echo "error: linkProjectV2ToRepository failed (simulated)" >&2
            exit 1
        fi
        printf '{"data":{"linkProjectV2ToRepository":{"repository":{"id":"R_kgDOmockrepo"}}}}\n'
        exit 0
        ;;
      *createProjectV2Field*SINGLE_SELECT*)
        printf '{"data":{"createProjectV2Field":{"projectV2Field":{"id":"PVTF_new_status"}}}}\n'
        exit 0
        ;;
      *updateProjectV2Field*singleSelectOptions*)
        printf '{"data":{"updateProjectV2Field":{"projectV2Field":{"id":"PVTF_new_status","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_inprog","name":"In Progress"},{"id":"opt_done","name":"Done"}]}}}}\n'
        exit 0
        ;;
      *createProjectV2Field*DATE*)
        printf '{"data":{"createProjectV2Field":{"projectV2Field":{"id":"PVTF_new_date"}}}}\n'
        exit 0
        ;;
      *createProjectV2Field*|*updateProjectV2Field*|*updateProjectV2View*|*"fields("*|*"views("*)
        # Shared field model; the legacy knobs map onto its field state.
        st=absent; [ "${GH_MOCK_STATUS_FIELD_EXISTS:-0}" = "1" ] && st=present
        sid=absent; [ "${GH_MOCK_SESSION_ID_FIELD_EXISTS:-0}" = "1" ] && sid=present
        fl=""; [ "${GH_MOCK_SESSION_ID_CREATE_FAIL:-0}" = "1" ] && fl=create-field
        exec env GH_MOCK_STATUS_FIELD="$st" GH_MOCK_SID_FIELD="${GH_MOCK_SID_FIELD:-$sid}" \
            GH_MOCK_FAIL="${GH_MOCK_FAIL:-$fl}" GH_MOCK_STATUS_FIELD_ID=PVTF_existing_status \
            GH_MOCK_OPT_TODO=opt_todo GH_MOCK_OPT_INPROG=opt_inprog GH_MOCK_OPT_DONE=opt_done \
            GH_MOCK_SID_FIELD_ID="${GH_MOCK_SID_FIELD_ID:-PVTF_existing_sid}" \
            GH_MOCK_NEW_FIELD_ID="${GH_MOCK_NEW_FIELD_ID:-PVTF_new_sid}" bash "$FIELDS_MODEL" "$@"
        ;;
      *createProjectV2*)
        # Board-creation mutation (createProjectV2Field is handled above).
        printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_new","number":2,"owner":{"login":"testowner"}}}}}\n'
        exit 0
        ;;
      *viewer*|*"user(login"*|*"organization(login"*)
        printf '%s\n' "U_mockowner"
        exit 0
        ;;
      *)
        printf '{"data":{}}\n'; exit 0
        ;;
    esac
    ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2; exit 2
    ;;
esac
MOCK_EOF
    chmod +x "$dest"
}
