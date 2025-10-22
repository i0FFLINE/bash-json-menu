#!/bin/bash

# ============================================
# CONFIGURATION
# ============================================

SCAN_DIR="${SCAN_DIR:-modules}"
MENU_EXIT_BEHAVIOR="${MENU_EXIT_BEHAVIOR:-console}"

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

    if [ -f "$base_menu" ]; then
        local before_keys=$(jq -r '._system._before // {} | keys_unsorted[]' "$base_menu" 2>/dev/null)
        if [ -n "$before_keys" ]; then
            while IFS= read -r key; do
                local value=$(jq -c "._system._before.\"$key\"" "$base_menu")
                [ "$first" = false ] && echo "," >> "$temp_menu"
                echo "  \"$key\": $value" >> "$temp_menu"
                first=false
            done <<< "$before_keys"
        fi
    fi

    if [ -f "$base_menu" ]; then
        local menu_keys=$(jq -r '.menu // {} | keys_unsorted[]' "$base_menu" 2>/dev/null)
        if [ -n "$menu_keys" ]; then
            while IFS= read -r key; do
                local value=$(jq -c ".menu.\"$key\"" "$base_menu")
                [ "$first" = false ] && echo "," >> "$temp_menu"
                echo "  \"$key\": $value" >> "$temp_menu"
                first=false
            done <<< "$menu_keys"
        fi
    fi

    local scan_pattern="*/"
    if [ "$mode" = "root" ]; then
        scan_pattern="$SCAN_DIR/*/"
    fi

    for subdir in $scan_pattern; do
        subdir="${subdir%/}"

        if [ -d "$subdir" ] && [ -f "$subdir/menu.json" ]; then
            local dir_name=$(basename "$subdir")
            local display_name=$(echo "$dir_name" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')

            if [ "$mode" = "root" ]; then
                display_name="Shared $display_name"
            fi

            [ "$first" = false ] && echo "," >> "$temp_menu"
            echo "  \"$display_name\": {}" >> "$temp_menu"
            first=false
        fi
    done

    if [ -f "$base_menu" ]; then
        local after_keys=$(jq -r '._system._after // {} | keys_unsorted[]' "$base_menu" 2>/dev/null)
        if [ -n "$after_keys" ]; then
            while IFS= read -r key; do
                local value=$(jq -c "._system._after.\"$key\"" "$base_menu")
                [ "$first" = false ] && echo "," >> "$temp_menu"
                echo "  \"$key\": $value" >> "$temp_menu"
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
    
    # Если есть ROOT_MENU - добавляем в поиск
    if [ -n "$ROOT_MENU" ] && [ "$ROOT_MENU" != "$BASE_MENU" ]; then
        search_files+=("$ROOT_MENU")
    fi
    
    for file in "${search_files[@]}"; do
        # Поиск в .menu
        local menu_path=".menu.\"${cmd}\""
        local value=$(jq -r "${menu_path} // empty" "$file" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "${file}|${menu_path}"
            return 0
        fi
        
        # Поиск в ._system._before
        local before_path="._system._before.\"${cmd}\""
        value=$(jq -r "${before_path} // empty" "$file" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "${file}|${before_path}"
            return 0
        fi
        
        # Поиск в ._system._after
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
# COMMAND EXECUTION
# ============================================

execute_simple_command() {
    local json_file="$1"
    local json_path="$2"
    local choice="$3"
    local from_trigger="${4:-false}"
    local value

    if [ "$from_trigger" = "true" ]; then
        value=$(jq -r "${json_path}" "$json_file" 2>/dev/null)
    else
        if [ "$json_path" = "." ]; then
            value=$(jq -r ".\"${choice}\"" "$json_file")
        else
            value=$(jq -r "${json_path} | .\"${choice}\"" "$json_file")
        fi
    fi

    # Проверяем тип значения
    local value_type=$(jq -r "${json_path} | type" "$json_file" 2>/dev/null)
    
    if [ "$value_type" = "object" ]; then
        # Это объект с возможными триггерами
        execute_trigger "$json_file" "$json_path" "_before"
        execute_commands "$json_file" "$json_path"
        execute_trigger "$json_file" "$json_path" "_then"
        return
    fi

    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo -e "\033[0m"
        tput cnorm
        eval "$value"
        echo -e "\033[0m"
    fi

    if [ "$from_trigger" != "true" ]; then
        case "$MENU_EXIT_BEHAVIOR" in
            "console")
                exit 0
                ;;
            "root")
                return 2
                ;;
            "menu")
                return 0
                ;;
        esac
    fi
}

execute_trigger() {
    local json_file="$1"
    local json_path="$2"
    local trigger_type="$3"

    local commands=$(jq -r "${json_path}.${trigger_type} // empty | .[]?" "$json_file" 2>/dev/null)

    if [ -z "$commands" ]; then
        return
    fi

    echo "$commands" | while IFS= read -r cmd; do
        local resolved=$(resolve_module_reference "$cmd")
        local ref_type=$(echo "$resolved" | cut -d'|' -f1)
        local target_json=$(echo "$resolved" | cut -d'|' -f2)
        local target_item=$(echo "$resolved" | cut -d'|' -f3)

        case "$ref_type" in
            "local")
                # Используем find_trigger_item для поиска
                local found=$(find_trigger_item "$cmd")
                
                if [ $? -eq 0 ]; then
                    local found_file=$(echo "$found" | cut -d'|' -f1)
                    local found_path=$(echo "$found" | cut -d'|' -f2)
                    execute_simple_command "$found_file" "$found_path" "" "true"
                else
                    echo "Error: Trigger item not found: $cmd"
                    return 1
                fi
                ;;
            "root"|"module")
                if [ -f "$target_json" ]; then
                    if [[ "$target_item" == *.* ]]; then
                        local target_path=$(echo "$target_item" | sed 's/\./\" | .\"/g')
                        target_path=".menu.\"${target_path}\""
                    else
                        target_path=".menu.\"${target_item}\""
                    fi
                    execute_simple_command "$target_json" "$target_path" "" "true"
                else
                    echo "Error: Module file not found: $target_json"
                    return 1
                fi
                ;;
        esac
    done
}

execute_commands() {
    local json_file="$1"
    local json_path="$2"

    local commands=$(jq -r "${json_path}._commands // empty | .[]?" "$json_file" 2>/dev/null)

    if [ -z "$commands" ]; then
        return
    fi

    echo -e "\033[0m"
    tput cnorm
    echo "$commands" | while IFS= read -r cmd; do
        eval "$cmd"
    done
    echo -e "\033[0m"
}

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

    local next_path
    if [ "$json_path" = "." ]; then
        next_path=".\"${choice}\""
    else
        next_path="${json_path}.\"${choice}\""
    fi

    local value_type=$(jq -r "${next_path} | type" "$json_file" 2>/dev/null)

    case "$value_type" in
        "object")
            local has_before=$(jq -r "${next_path}._before // empty" "$json_file" 2>/dev/null)
            local has_commands=$(jq -r "${next_path}._commands // empty" "$json_file" 2>/dev/null)
            local has_then=$(jq -r "${next_path}._then // empty" "$json_file" 2>/dev/null)
            local is_empty=$(jq -r "${next_path} | length" "$json_file" 2>/dev/null)

            if [ -n "$has_before" ] || [ -n "$has_commands" ] || [ -n "$has_then" ]; then
                execute_trigger "$json_file" "$next_path" "_before"
                execute_commands "$json_file" "$next_path"
                execute_trigger "$json_file" "$next_path" "_then"

                case "$MENU_EXIT_BEHAVIOR" in
                    "console")
                        read -p "Press Enter to exit..."
                        exit 0
                        ;;
                    "root")
                        read -p "Press Enter to continue..."
                        return 2
                        ;;
                    "menu")
                        read -p "Press Enter to continue..."
                        ;;
                esac
            elif [ "$is_empty" = "0" ]; then
                 local module_dir=$(echo "$choice" | sed 's/Shared //' | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

                if [ "$mode" = "root" ]; then
                    module_dir="$SCAN_DIR/$module_dir"
                fi

                if [ -f "$module_dir/menu.sh" ] && [ -f "$module_dir/menu.json" ]; then
                    (cd "$module_dir" && exec bash menu.sh)
                else
                    whiptail --title "Error" --msgbox "Module not found: $module_dir" 10 50
                fi
            else
                show_menu "$json_file" "$next_path" "$choice" "$mode"
            fi
            ;;
        "string")
            execute_simple_command "$json_file" "$json_path" "$choice"
            local exit_code=$?

            if [ $exit_code -eq 2 ]; then
                return 2
            fi

            case "$MENU_EXIT_BEHAVIOR" in
                "console")
                    read -p "Press Enter to exit..."
                    exit 0
                    ;;
                "menu")
                    read -p "Press Enter to continue..."
                    ;;
                "root")
                    read -p "Press Enter to continue..."
                    return 2
                    ;;
            esac
            ;;
        *)
            whiptail --title "Error" --msgbox "Unknown menu type: $value_type" 10 50
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
    
    # Устанавливаем ROOT_MENU для fallback поиска
    if [ "$MODE" = "local" ]; then
        PROJECT_ROOT=$(find_project_root "$PWD")
        ROOT_MENU="$PROJECT_ROOT/menu.json"
    fi

    MENU_FILE=$(generate_dynamic_menu "$BASE_MENU" "$MODE")
    trap "rm -f '$MENU_FILE'; cleanup" EXIT INT TERM

    if [ "$MODE" = "root" ]; then
        TITLE="Main Menu"
    else
        TITLE=$(basename "$PWD" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')" Menu"
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
