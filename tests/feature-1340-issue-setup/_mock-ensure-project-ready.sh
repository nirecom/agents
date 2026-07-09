#!/bin/bash
# tests/feature-1340-issue-setup/_mock-ensure-project-ready.sh — file-specific gh mock
#
# Entrypoint-private helper for ensure-project-ready.sh (file-split.md Pattern A).
# Provides write_epr_gh_mock <dest>, which writes an executable gh mock to <dest>.
# The mock dispatches on args and honors these knobs (read at gh-invocation time):
#   GH_MOCK_AUTH_HAS_PROJECT       0 → auth status omits 'project' scope
#   GH_MOCK_PROJECT_EXISTS         1 → gh project list returns an existing board
#   GH_MOCK_PROJECT_LIST_FAIL      1 → gh project list exits non-zero
#   GH_MOCK_STATUS_FIELD_EXISTS    1 → discovery reports Status field present
#   GH_MOCK_FINGERPRINT_FIELD_EXISTS 1 → discovery reports fingerprint present
#   GH_MOCK_FINGERPRINT_CREATE_FAIL 1 → createProjectV2Field TEXT mutation fails
#
# Idempotent — guarded against double-sourcing.

if [ -n "${_EPR_MOCK_LIB_SOURCED:-}" ]; then
    return 0
fi
_EPR_MOCK_LIB_SOURCED=1

write_epr_gh_mock() {
    local dest="$1"
    cat > "$dest" <<'MOCK_EOF'
#!/bin/bash
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
  api\ graphql*)
    case "$ARGS" in
      *createProjectV2Field*SINGLE_SELECT*)
        # NB: already logged once at the top of the mock — do NOT log again here
        # (would double-count mutation invocations in grep -c assertions).
        printf '{"data":{"createProjectV2Field":{"projectV2Field":{"id":"PVTF_new_status"}}}}\n'
        exit 0
        ;;
      *updateProjectV2Field*singleSelectOptions*)
        printf '{"data":{"updateProjectV2Field":{"projectV2Field":{"id":"PVTF_new_status","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_inprog","name":"In Progress"},{"id":"opt_done","name":"Done"}]}}}}\n'
        exit 0
        ;;
      *createProjectV2Field*TEXT*)
        # Fingerprint (TEXT) field creation can be forced to fail to exercise
        # the partial-failure idempotency-retry path.
        if [ "${GH_MOCK_FINGERPRINT_CREATE_FAIL:-0}" = "1" ]; then
            echo "error: createProjectV2Field TEXT failed (simulated)" >&2
            exit 1
        fi
        printf '{"data":{"createProjectV2Field":{"projectV2Field":{"id":"PVTF_new_finger"}}}}\n'
        exit 0
        ;;
      *"createProjectV2(input"*)
        # Board-creation mutation (distinct from createProjectV2Field).
        printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_new","number":2,"owner":{"login":"testowner"}}}}}\n'
        exit 0
        ;;
      *createProjectV2*)
        printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_new","number":2,"owner":{"login":"testowner"}}}}}\n'
        exit 0
        ;;
      *fields*|*projectId*)
        # Discovery query for existing fields.
        if [ "${GH_MOCK_STATUS_FIELD_EXISTS:-0}" = "1" ] && [ "${GH_MOCK_FINGERPRINT_FIELD_EXISTS:-0}" = "1" ]; then
            printf '{"data":{"node":{"fields":{"nodes":[{"id":"PVTF_existing_status","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_inprog","name":"In Progress"},{"id":"opt_done","name":"Done"}]},{"id":"PVTF_existing_finger","name":"session-fingerprint","dataType":"TEXT"}]}}}}\n'
        elif [ "${GH_MOCK_STATUS_FIELD_EXISTS:-0}" = "1" ]; then
            printf '{"data":{"node":{"fields":{"nodes":[{"id":"PVTF_existing_status","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_inprog","name":"In Progress"},{"id":"opt_done","name":"Done"}]}]}}}}\n'
        elif [ "${GH_MOCK_FINGERPRINT_FIELD_EXISTS:-0}" = "1" ]; then
            printf '{"data":{"node":{"fields":{"nodes":[{"id":"PVTF_existing_finger","name":"session-fingerprint","dataType":"TEXT"}]}}}}\n'
        else
            printf '{"data":{"node":{"fields":{"nodes":[]}}}}\n'
        fi
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
