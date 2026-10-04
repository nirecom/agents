=== bin/check-table-driven.sh
    local compliant=0
    case "$test_file" in
        *.sh)
            has_table_driven_sh "$test_file" && compliant=1
            ;;
        *.js)
            has_table_driven_js "$test_file" && compliant=1
            ;;
        *)
            has_table_driven_sh "$test_file" && compliant=1
            ;;
    esac
