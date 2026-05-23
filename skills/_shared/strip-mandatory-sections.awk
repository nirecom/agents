# strip-mandatory-sections.awk
# Removes mandatory H2 sections and all H1 lines from a planner-output markdown file.
# Used by assemble-mandatory.sh to eliminate planner-authored duplicates.
#
# Usage: awk -v names="Issue|Class members|Accepted Tradeoffs" -f strip-mandatory-sections.awk <file>
#
# Fence-aware: lines inside ``` or ~~~ fences are never treated as section boundaries.

BEGIN {
    inside_mandatory = 0
    in_fence = 0
    n = split(names, section_names, "|")
}

# Toggle fence state on backtick or tilde fences
/^```/ || /^~~~/ {
    in_fence = !in_fence
    # Print fence lines only when not inside a stripped section
    if (!inside_mandatory) print
    next
}

# H1 lines: drop them (all occurrences) when not in a fence
!in_fence && /^# [^#]/ {
    inside_mandatory = 0
    next
}

# H2 lines: check if this is a mandatory section boundary (when not in fence)
!in_fence && /^## / {
    hdr = $0
    sub(/^## /, "", hdr)
    sub(/[[:space:]]+$/, "", hdr)

    matched = 0
    for (i = 1; i <= n; i++) {
        if (hdr == section_names[i]) {
            matched = 1
            break
        }
    }
    if (matched) {
        inside_mandatory = 1
        next
    } else {
        inside_mandatory = 0
        print
        next
    }
}

# Skip lines inside a mandatory section
inside_mandatory { next }

# Print all other lines
{ print }
