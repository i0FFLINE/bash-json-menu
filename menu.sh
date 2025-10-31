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
DEBUG="${DEBUG:-false}"

# ============================================
# DEBUG UTILITIES
# ============================================
debug() {
    if [ "$DEBUG" = "true" ]; then
        echo "DEBUG: $1" >&2
    fi
}

debug_section() {
    if [ "$DEBUG" = "true" ]; then
        echo "=== DEBUG: $1 ===" >&2
    fi
}

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
    debug_section "MODE DETECTION"
    debug "SCAN_DIR: $SCAN_DIR"
    if [ -d "$SCAN_DIR" ]; then
        debug "Mode: root"
        echo "root"
    else
        debug "Mode: local"
        echo "local"
    fi
}

# ============================================
# DYNAMIC MENU GENERATION
# ============================================
generate_dynamic_menu() {
    local base_menu="$1"
    local mode="$2"
    debug_section "DYNAMIC MENU GENERATION"
    debug "Base menu: $base_menu"
    debug "Mode: $mode"
    
    local temp_menu="/tmp/menu_$$_$(date +%s).json"
    echo "{" > "$temp_menu"
    local first=true

    # System before items
    if [ -f "$base_menu" ]; then
        debug "Loading _system._before items"
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
        debug "Loading menu items"
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
    debug "Scanning for modules: $scan_pattern"
    for subdir in $scan_pattern; do
        if [ -d "$subdir" ] && [ -f "$subdir/menu.json" ]; then
            local dir_name=$(basename "$subdir")
            local display_name=$(echo "$dir_name" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
            if [ "$mode" = "root" ]; then
                display_name="> $display_name"
            fi
            debug "Found module: $dir_name -> $display_name"
            [ "$first" = false ] && echo "," >> "$temp_menu"
            echo " \"$display_name\": {}" >> "$temp_menu"
            first=false
        fi
    done

    # System after items
    if [ -f "$base_menu" ]; then
        debug "Loading _system._after items"
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
    debug "Generated temp menu: $temp_menu"
    echo "$temp_menu"
}

# ============================================
# MENU DISPLAY
# ============================================
show_menu() {
    local json_file="$1"
    local json_path="${2:-.}"
    local title="${3:-Main Menu}"
    local mode="${4:-}"

    debug_section "SHOW MENU"
    debug "JSON file: $json_file"
    debug "JSON path: $json_path"
    debug "Title: $title"
    debug "Mode: $mode"

    local keys=$(jq -r "${json_path} | keys_unsorted[]" "$json_file" 2>/dev/null)
    if [ -z "$keys" ]; then
        debug "No menu items found"
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
        debug "User cancelled menu"
        return 1
    fi
    debug "User choice: $choice"

    local jq_path
    if [ "$json_path" = "." ]; then
        jq_path=".\"$choice\""
    else
        jq_path="$json_path.\"$choice\""
    fi
    debug "JQ path: $jq_path"

    local value_type=$(jq -r "$jq_path | type" "$json_file" 2>/dev/null)
    debug "Value type: $value_type"

    case "$value_type" in
        "object")
            local has_triggers=$(jq -r "$jq_path | ._before // ._commands // ._then // empty" "$json_file" 2>/dev/null)
            debug "Has triggers: $has_triggers"

            local child_keys=$(jq -r "$jq_path | keys_unsorted[]" "$json_file" 2>/dev/null | grep -v '^_before$' | grep -v '^_commands$' | grep -v '^_then$' | head -1)
            debug "Child keys: $child_keys"

            if [ -n "$has_triggers" ]; then
                debug "Executing item with triggers"
                execute_item "$json_file" "$jq_path" "false" ""
                exit 0
            elif [ -n "$child_keys" ]; then
                debug "Showing submenu"
                show_menu "$json_file" "$jq_path" "$title - $choice" "$mode"
                return
            else
                local module_dir=$(echo "$choice" | sed 's/> //' | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
                if [ "$mode" = "root" ]; then
                    module_dir="$SCAN_DIR/$module_dir"
                fi
                debug "Module directory: $module_dir"
                if [ -f "$module_dir/menu.sh" ] && [ -f "$module_dir/menu.json" ]; then
                    debug "Launching module: $module_dir"
                    (cd "$module_dir" && bash menu.sh)
                    exit 0
                else
                    debug "Module not found: $module_dir"
                    whiptail --title "Error" --msgbox "Module not found: $module_dir" 10 50
                    return 1
                fi
            fi
            ;;
        "string")
            debug "Executing string command"
            execute_item "$json_file" "$jq_path" "false" ""
            exit 0
            ;;
        *)
            debug "Unknown menu type: $value_type"
            whiptail --title "Error" --msgbox "Unknown menu type: $value_type for '$choice'" 10 50
            return 1
            ;;
    esac
}

# ============================================
# MAIN
# ============================================
main() {
    debug_section "SCRIPT START"
    check_dependencies
    MODE=$(detect_mode)
    BASE_MENU="menu.json"
    if [ "$MODE" = "local" ]; then
        PROJECT_ROOT=$(find_project_root "$PWD")
        ROOT_MENU="$PROJECT_ROOT/menu.json"
        debug "Local mode - Project root: $PROJECT_ROOT"
    fi
    MENU_FILE=$(generate_dynamic_menu "$BASE_MENU" "$MODE")
    trap "rm -f '$MENU_FILE'; cleanup" EXIT INT TERM
    if [ "$MODE" = "root" ]; then
        TITLE="Main Menu"
    else
        TITLE="$(basename "$PWD" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1') Menu"
    fi
    debug "Final title: $TITLE"
    
    while true; do
        show_menu "$MENU_FILE" "." "$TITLE" "$MODE"
        local menu_result=$?
        debug "Menu result: $menu_result"
        if [ $menu_result -eq 1 ]; then
            debug "Exiting main loop"
            break
        fi
    done
    cleanup
}

main "$@"
