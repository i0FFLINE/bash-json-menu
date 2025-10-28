#!/bin/bash

# Load environment variables from .env
if [ -f "../../.env" ]; then
    source ../../.env
elif [ -f "../.env" ]; then
    source ../.env
elif [ -f ".env" ]; then
    source .env
fi

# Load execution methods
if [ -f "../../menu.functions" ]; then
    source ../../menu.functions
elif [ -f "../menu.functions" ]; then
    source ../menu.functions
elif [ -f "menu.functions" ]; then
    source menu.functions
fi


# ============================================
# CONFIGURATION
# ============================================
SCAN_DIR="${SCAN_DIR:-modules}"
TITLE=${TITLE:-""}

# ============================================
# SETUP
# ============================================
clear

cleanup() {
    echo -e "\033[0m"
    tput cnorm
}

trap cleanup EXIT INT TERM

check_dependencies() {
    if ! command -v whiptail &> /dev/null; then
        echo "Error: whiptail is not installed."
        cleanup
        exit 1
    fi
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is not installed."
        cleanup
        exit 1
    fi
}

TITLE() {
    echo "# $1"
}

# ============================================
# MODE DETECTION
# ============================================
detect_mode() {
    if [ -d "$SCAN_DIR" ]; then
        echo "root"
    else
        echo "local"
    fi
}

# ============================================
# DYNAMIC MENU GENERATION
# ============================================
generate_dynamic_menu() {
    local base_menu="$1"
    local mode="$2"
    local temp_menu="/tmp/menu_$$_$(date +%s).json"
    echo "{" > "$temp_menu"
    local first=true

    # System before items
    if [ -f "$base_menu" ]; then
        local before_keys=$(jq -r '._system._before // {} | keys_unsorted[]' "$base_menu" 2>/dev/null)
        if [ -n "$before_keys" ]; then
            while IFS= read -r key; do
                local value=$(jq -c "._system._before.\"$key\"" "$base_menu")
                [ "$first" = false ] && echo "," >> "$temp_menu"
                echo " \"$key\": $value" >> "$temp_menu"
                first=false
            done <<< "$before_keys"
        fi
    fi

    # Menu items from base
    if [ -f "$base_menu" ]; then
        local menu_keys=$(jq -r '.menu // {} | keys_unsorted[]' "$base_menu" 2>/dev/null)
        if [ -n "$menu_keys" ]; then
            while IFS= read -r key; do
                local value=$(jq -c ".menu.\"$key\"" "$base_menu")
                [ "$first" = false ] && echo "," >> "$temp_menu"
                echo " \"$key\": $value" >> "$temp_menu"
                first=false
            done <<< "$menu_keys"
        fi
    fi

    # Scan for modules
    local scan_pattern="*"
    if [ "$mode" = "root" ]; then
        scan_pattern="$SCAN_DIR/*"
    fi
    for subdir in $scan_pattern; do
        if [ -d "$subdir" ] && [ -f "$subdir/menu.json" ]; then
            local dir_name=$(basename "$subdir")
            local display_name=$(echo "$dir_name" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
            if [ "$mode" = "root" ]; then
                display_name="Shared $display_name"
            fi
            [ "$first" = false ] && echo "," >> "$temp_menu"
            echo " \"$display_name\": {}" >> "$temp_menu"
            first=false
        fi
    done

    # System after items
    if [ -f "$base_menu" ]; then
        local after_keys=$(jq -r '._system._after // {} | keys_unsorted[]' "$base_menu" 2>/dev/null)
        if [ -n "$after_keys" ]; then
            while IFS= read -r key; do
                local value=$(jq -c "._system._after.\"$key\"" "$base_menu")
                [ "$first" = false ] && echo "," >> "$temp_menu"
                echo " \"$key\": $value" >> "$temp_menu"
                first=false
            done <<< "$after_keys"
        fi
    fi
    echo "}" >> "$temp_menu"
    echo "$temp_menu"
}

# ============================================
# MENU DISPLAY
# ============================================
# ============================================
# MENU DISPLAY
# ============================================
show_menu() {
    local json_file="$1"
    local json_path="${2:-.}"
    local title="${3:-Main Menu}"
    local mode="${4:-}"

    local keys=$(jq -r "${json_path} | keys_unsorted[]" "$json_file" 2>/dev/null)
    if [ -z "$keys" ]; then
        whiptail --title "Error" --msgbox "No menu items found" 10 50
        return 1
    fi
    local menu_items=()
    while IFS= read -r key; do
        menu_items+=("$key" "")
    done <<< "$keys"
    local choice
    choice=$(whiptail --title "$title" --menu "Choose an option:" 20 70 12 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        return 1
    fi

    local jq_path
    if [ "$json_path" = "." ]; then
        jq_path=".\"$choice\""
    else
        jq_path="$json_path.\"$choice\""
    fi

    local value_type=$(jq -r "$jq_path | type" "$json_file" 2>/dev/null)

    case "$value_type" in
        "object")
            local has_triggers=$(jq -r "$jq_path | ._before // ._commands // ._then // empty" "$json_file" 2>/dev/null)

            local child_keys=$(jq -r "$jq_path | keys_unsorted[]" "$json_file" 2>/dev/null | grep -v '^_before$' | grep -v '^_commands$' | grep -v '^_then$' | head -1)

            if [ -n "$has_triggers" ]; then
                execute_item "$json_file" "$jq_path" "false" ""
                return
            elif [ -n "$child_keys" ]; then
                show_menu "$json_file" "$jq_path" "$title - $choice" "$mode"
                return
            else
                local module_dir=$(echo "$choice" | sed 's/Shared //' | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
                if [ "$mode" = "root" ]; then
                    module_dir="$SCAN_DIR/$module_dir"
                fi
                if [ -f "$module_dir/menu.sh" ] && [ -f "$module_dir/menu.json" ]; then
                    (cd "$module_dir" && bash menu.sh)
                    exit 0
                else
                    whiptail --title "Error" --msgbox "Module not found: $module_dir" 10 50
                    return 1
                fi
            fi
            ;;
        "string")
            execute_item "$json_file" "$jq_path" "false" ""
            return
            ;;
        *)
            whiptail --title "Error" --msgbox "Unknown menu type: $value_type for '$choice'" 10 50
            return 1
            ;;
    esac
}

# ============================================
# MAIN
# ============================================
main() {
    check_dependencies
    MODE=$(detect_mode)
    BASE_MENU="menu.json"
    if [ "$MODE" = "local" ]; then
        PROJECT_ROOT=$(find_project_root "$PWD")
        ROOT_MENU="$PROJECT_ROOT/menu.json"
    fi
    MENU_FILE=$(generate_dynamic_menu "$BASE_MENU" "$MODE")
    trap "rm -f '$MENU_FILE'; cleanup" EXIT INT TERM
    if [ "$MODE" = "root" ]; then
        TITLE="Main Menu"
    else
        TITLE="$(basename "$PWD" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1') Menu"
    fi
    while true; do
        show_menu "$MENU_FILE" "." "$TITLE" "$MODE"
        local menu_result=$?
        if [ $menu_result -eq 1 ]; then
            break
        fi
    done
    cleanup
}

main "$@"
