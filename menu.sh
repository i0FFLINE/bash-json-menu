#!/bin/bash

# ============================================
# CONFIGURATION
# ============================================
SCAN_DIR="${SCAN_DIR:-modules}"
MENU_EXIT_BEHAVIOR="${MENU_EXIT_BEHAVIOR:-console}"
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
# MODULE REFERENCE RESOLUTION
# ============================================
find_project_root() {
    local current_dir="$1"
    if [ -d "$current_dir/$SCAN_DIR" ]; then
        echo "$current_dir"
        return
    fi
    if [ -d "$current_dir/../$SCAN_DIR" ]; then
        echo "$(cd "$current_dir/.." && pwd)"
        return
    fi
    if [ -d "$current_dir/../../$SCAN_DIR" ]; then
        echo "$(cd "$current_dir/../.." && pwd)"
        return
    fi
    echo "$current_dir"
}

resolve_module_reference() {
    local ref="$1"
    local project_root=$(find_project_root "$PWD")
    if [[ "$ref" == @*:* ]]; then
        local module="${ref#@}"
        module="${module%%:*}"
        local item="${ref#*:}"
        if [ "$module" = "root" ]; then
            echo "root|$project_root/menu.json|$item"
        else
            echo "module|$project_root/$SCAN_DIR/$module/menu.json|$item"
        fi
    else
        echo "local||$ref"
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
# TRIGGER ITEM FINDER
# ============================================
find_trigger_item() {
    local cmd="$1"
    local search_files=("${BASE_MENU:-menu.json}")
    if [ -n "$ROOT_MENU" ] && [ "$ROOT_MENU" != "$BASE_MENU" ]; then
        search_files+=("$ROOT_MENU")
    fi
    for file in "${search_files[@]}"; do
        # Search in .menu
        local menu_path=".menu.\"${cmd}\""
        local value=$(jq -r "${menu_path} // empty" "$file" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "${file}|${menu_path}"
            return 0
        fi
        # Search in ._system._before
        local before_path="._system._before.\"${cmd}\""
        value=$(jq -r "${before_path} // empty" "$file" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "${file}|${before_path}"
            return 0
        fi
        # Search in ._system._after
        local after_path="._system._after.\"${cmd}\""
        value=$(jq -r "${after_path} // empty" "$file" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "${file}|${after_path}"
            return 0
        fi
    done
    return 1
}

# ============================================
# UNIFIED ITEM EXECUTION
# ============================================

execute_item() {
    local json_file="$1"
    local json_path="$2"
    local from_trigger="${3:-false}"
    local choice="$4"

    # Корректное ветвление пути: для корня "." всегда использовать ".\"$choice\""
    local value_path
    if [ "$from_trigger" = "true" ]; then
        value_path="$json_path"
    elif [ "$json_path" = "." ]; then
        value_path=".\"$choice\""
    else
        value_path="$json_path"
    fi

    local item_type=$(jq -r "$value_path | type" "$json_file" 2>/dev/null)

    case "$item_type" in
        "string")
            local value=$(jq -r "$value_path" "$json_file" 2>/dev/null)
            if [ "$value" != "null" ] && [ -n "$value" ]; then
                echo -e "\033[0m"
                tput cnorm
                eval "$value"
                echo -e "\033[0m"
            fi
            ;;
        "object")
            local has_before=$(jq -r "$value_path._before | length // 0" "$json_file" 2>/dev/null)
            if [ "$has_before" -gt 0 ] 2>/dev/null; then
                local before_items
                before_items=$(jq -r "$value_path._before[]?" "$json_file" 2>/dev/null)
                echo "$before_items" | while IFS= read -r before_cmd; do
                    if [ -n "$before_cmd" ]; then
                        local resolved=$(resolve_module_reference "$before_cmd")
                        local ref_type=$(echo "$resolved" | cut -d'|' -f1)
                        case "$ref_type" in
                            "local")
                                local found=$(find_trigger_item "$before_cmd")
                                if [ $? -eq 0 ]; then
                                    local found_file=$(echo "$found" | cut -d'|' -f1)
                                    local found_path=$(echo "$found" | cut -d'|' -f2)
                                    execute_item "$found_file" "$found_path" "true" ""
                                else
                                    echo "Error: Trigger item not found: $before_cmd"
                                fi
                                ;;
                            "root"|"module")
                                local target_json=$(echo "$resolved" | cut -d'|' -f2)
                                local target_item=$(echo "$resolved" | cut -d'|' -f3)
                                if [ -f "$target_json" ]; then
                                    local target_path=".menu.\"$target_item\""
                                    execute_item "$target_json" "$target_path" "true" ""
                                else
                                    echo "Error: Module file not found: $target_json"
                                fi
                                ;;
                            *)
                                eval "$before_cmd"
                                ;;
                        esac
                    fi
                done
            fi

            local has_commands=$(jq -r "$value_path._commands | length // 0" "$json_file" 2>/dev/null)
            if [ "$has_commands" -gt 0 ] 2>/dev/null; then
                local commands
                commands=$(jq -r "$value_path._commands[]?" "$json_file" 2>/dev/null)
                echo -e "\033[0m"
                tput cnorm
                echo "$commands" | while IFS= read -r cmd; do
                    if [ -n "$cmd" ]; then
                        eval "$cmd"
                    fi
                done
                echo -e "\033[0m"
            fi

            local has_then=$(jq -r "$value_path._then | length // 0" "$json_file" 2>/dev/null)
            if [ "$has_then" -gt 0 ] 2>/dev/null; then
                local then_items
                then_items=$(jq -r "$value_path._then[]?" "$json_file" 2>/dev/null)
                echo "$then_items" | while IFS= read -r then_cmd; do
                    if [ -n "$then_cmd" ]; then
                        local resolved=$(resolve_module_reference "$then_cmd")
                        local ref_type=$(echo "$resolved" | cut -d'|' -f1)
                        case "$ref_type" in
                            "local")
                                local found=$(find_trigger_item "$then_cmd")
                                if [ $? -eq 0 ]; then
                                    local found_file=$(echo "$found" | cut -d'|' -f1)
                                    local found_path=$(echo "$found" | cut -d'|' -f2)
                                    local result=$(execute_item "$found_file" "$found_path" "true" "")
                                    if [[ "$result" == "2" ]]; then
                                        return 2
                                    fi
                                else
                                    echo "Error: Trigger item not found: $then_cmd"
                                fi
                                ;;
                            "root"|"module")
                                local target_json=$(echo "$resolved" | cut -d'|' -f2)
                                local target_item=$(echo "$resolved" | cut -d'|' -f3)
                                if [ -f "$target_json" ]; then
                                    local target_path=".menu.\"$target_item\""
                                    local result=$(execute_item "$target_json" "$target_path" "true" "")
                                    if [[ "$result" == "2" ]]; then
                                        return 2
                                    fi
                                else
                                    echo "Error: Module file not found: $target_json"
                                fi
                                ;;
                            *)
                                eval "$then_cmd"
                                ;;
                        esac
                    fi
                done
            fi
            ;;
        *)
            echo "Unknown type: $item_type"
            ;;
    esac

    if [ "$from_trigger" != "true" ]; then
        case "$MENU_EXIT_BEHAVIOR" in
            "console") exit 0 ;;
            "root") return 2 ;;
            "menu") return 0 ;;
        esac
    fi
}

# ============================================
# MENU DISPLAY (ИСПРАВЛЕНО)
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

    # для корня - путь . (верхний уровень), для подменю - строим путь рекурсивно
    local jq_path="$json_path"
    if [ "$jq_path" = "." ]; then
        jq_path=".\"$choice\""
    else
        jq_path="$jq_path.\"$choice\""
    fi
    local value_type=$(jq -r "$jq_path | type" "$json_file" 2>/dev/null)

    case "$value_type" in
        "object")
            local has_triggers=$(jq -r "$jq_path._before // $jq_path._commands // $jq_path._then // empty" "$json_file" 2>/dev/null)
            local is_empty=$(jq -r "$jq_path | length" "$json_file" 2>/dev/null)
            if [ "$is_empty" -gt 0 ] && [ -z "$has_triggers" ]; then
                show_menu "$json_file" "$jq_path" "$title - $choice" "$mode"
                return
            elif [ "$is_empty" = "0" ]; then
                local module_dir=$(echo "$choice" | sed 's/Shared //' | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
                if [ "$mode" = "root" ]; then
                    module_dir="$SCAN_DIR/$module_dir"
                fi
                if [ -f "$module_dir/menu.sh" ] && [ -f "$module_dir/menu.json" ]; then
                    (cd "$module_dir" && bash menu.sh)
                    return
                else
                    whiptail --title "Error" --msgbox "Module not found: $module_dir" 10 50
                    return 1
                fi
            else
                execute_item "$json_file" "$jq_path" "false" ""
                return
            fi
            ;;
        "string")
            # Только для корня пунктов - путь всегда . (иначе вложенные строки выпадут)
            if [ "$json_path" = "." ]; then
                execute_item "$json_file" "." "false" "$choice"
            else
                execute_item "$json_file" "$jq_path" "false" ""
            fi
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
        elif [ $menu_result -eq 2 ]; then
            if [ "$MODE" = "local" ]; then
                exit 0
            fi
        fi
    done
    cleanup
}

main "$@"
