# Menu System Documentation

Dynamic menu system with support for triggers, modularity, and hierarchical structure.

## Table of Contents

- [menu.json Structure](#menujson-structure)
  - [Basic Structure](#basic-structure)
  - [Element Ordering](#element-ordering)
  - [Complete Structure Example](#complete-structure-example)
- [Triggers (_before, _then)](#triggers-_before-_then)
  - [Execution Order](#execution-order)
  - [Trigger Command Search Algorithm](#trigger-command-search-algorithm)
  - [Recursive Triggers](#recursive-triggers)
  - [Trigger Usage Examples](#trigger-usage-examples)
- [Module References](#module-references)
  - [Reference Types](#reference-types)
  - [Examples](#module-reference-examples)
- [Configuration](#configuration)
  - [Environment Variables](#environment-variables)
  - [Operating Modes](#operating-modes)
- [Internal Architecture](#internal-architecture)
  - [Key Functions](#key-functions)

---

## menu.json Structure

### Basic Structure

```json
{
  "_system": {
    "_before": {
      "Item before menu": "command or object"
    },
    "_after": {
      "Item after menu": "command or object"
    }
  },
  "menu": {
    "Main item": "command",
    "Complex item": {
      "_before": ["Command1", "Command2"],
      "_commands": ["command1", "command2"],
      "_then": ["Command3"]
    },
    "Submenu": {
      "Item 1": "command",
      "Item 2": "command"
    }
  }
}
```

### Element Ordering

The script preserves element order from JSON using `keys_unsorted[]`.

**Final menu order:**

1. Elements from `_system._before`
2. Elements from `menu`
3. Dynamically discovered modules (from `docker/*/`)
4. Elements from `_system._after`

**Example:**

```json
{
  "_system": {
    "_before": {
      "1List all": { "_commands": [...] }
    },
    "_after": {
      "1Prune": "docker system prune -f",
      "Exit": "exit 0"
    }
  },
  "menu": {
    "Rebuild": {...},
    "Build": "docker build ...",
    "Remove": "docker rmi ..."
  }
}
```

**Displays as:**
1. 1List all
2. Rebuild
3. Build
4. Remove
5. [Dynamic modules]
6. 1Prune
7. Exit

### Complete Structure Example

```json
{
  "_system": {
    "_before": {
      "List all": {
        "_commands": [
          "echo && echo && echo ===== DOCKER STATUS =====",
          "docker images --format 'table {{.Repository}}\\\\t{{.Tag}}'",
          "docker ps -a --format 'table {{.Names}}\\\\t{{.Status}}'"
        ]
      }
    },
    "_after": {
      "Prune": "docker system prune -f",
      "Exit": "exit 0"
    }
  },
  "menu": {
    "Rebuild and Run": {
      "_before": ["Remove Image", "Prune"],
      "_then": ["Build Image", "Prune", "Run Container"]
    },
    "Build Image": "docker build --no-cache -t image:latest .",
    "Run Container": "docker run -d --name container image:latest",
    "Remove Image": {
      "_before": ["Remove Container"],
      "_commands": ["docker rmi image:latest || true"]
    },
    "Remove Container": {
      "_before": ["Stop Container"],
      "_commands": ["docker rm container || true"]
    },
    "Stop Container": "docker stop container || true"
  }
}
```

---

## Triggers (_before, _then)

### Execution Order

For items with triggers, execution happens in this order:

1. `_before` — commands executed **before** main commands
2. `_commands` — main commands
3. `_then` — commands executed **after** main commands

### Trigger Command Search Algorithm

When processing a trigger (e.g., `"Remove Image"`), search occurs sequentially:

**1. Local menu.json:**
   - `.menu."Remove Image"`
   - `._system._before."Remove Image"`
   - `._system._after."Remove Image"`

**2. Root menu.json** (if current file is in a module):
   - `.menu."Remove Image"`
   - `._system._before."Remove Image"`
   - `._system._after."Remove Image"`

**3. Error** — if command is not found

**Important:** Search happens **proactively** before command execution, allowing errors to be detected before execution begins.

### Recursive Triggers

Triggers support **nesting**. If a trigger command itself contains `_before`/`_commands`/`_then`, they will execute recursively.

**Chain example:**

```json
{
  "menu": {
    "Remove Image": {
      "_before": ["Remove Container"],
      "_commands": ["docker rmi image"]
    },
    "Remove Container": {
      "_before": ["Stop Container"],
      "_commands": ["docker rm container"]
    },
    "Stop Container": "docker stop container"
  }
}
```

**When selecting "Remove Image":**
1. Execute `_before: ["Remove Container"]`
   - Execute `"Remove Container"._before: ["Stop Container"]`
     - Execute `"Stop Container"` → `docker stop container`
   - Execute `"Remove Container"._commands` → `docker rm container`
2. Execute `"Remove Image"._commands` → `docker rmi image`

### Trigger Usage Examples

#### Simple Trigger

```json
{
  "menu": {
    "Rebuild": {
      "_before": ["Remove", "Prune"],
      "_then": ["Build", "Prune"]
    },
    "Remove": "docker rmi image:latest",
    "Build": "docker build -t image:latest ."
  },
  "_system": {
    "_after": {
      "Prune": "docker system prune -f"
    }
  }
}
```

**When selecting "Rebuild":**
1. `Remove` (from `.menu`)
2. `Prune` (from `._system._after`)
3. `Build` (from `.menu`)
4. `Prune` (from `._system._after`)

#### Trigger with Command Array

```json
{
  "menu": {
    "Status": {
      "_commands": [
        "echo === Images ===",
        "docker images",
        "echo === Containers ===",
        "docker ps -a"
      ]
    }
  }
}
```

---

## Module References

### Reference Types

**1. Local reference** — `"Command"`
   - Search in current `menu.json`
   - Fallback to root `menu.json`

**2. Root reference** — `"@root:Command"`
   - Direct reference to command in root `menu.json`

**3. Module reference** — `"@modulename:Command"`
   - Direct reference to command in `docker/modulename/menu.json`

### Module Reference Examples

```json
{
  "menu": {
    "Local command": "echo local",
    "Use root command": {
      "_before": ["@root:Prune"]
    },
    "Use module command": {
      "_before": ["@nginx:Restart"]
    }
  }
}
```

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SCAN_DIR` | `docker` | Directory containing modules |
| `MENU_EXIT_BEHAVIOR` | `console` | Behavior after command execution |
| `BASE_MENU` | `menu.json` | Current menu file |
| `ROOT_MENU` | (auto) | Root `menu.json` for fallback |

### Operating Modes

**MENU_EXIT_BEHAVIOR:**

- `console` — exit to console after execution
- `menu` — return to current menu
- `root` — return to root menu

**Example:**

```bash
export MENU_EXIT_BEHAVIOR="menu"
./menu.sh
```

---

## Internal Architecture

### Key Functions

**`generate_dynamic_menu(base_menu, mode)`**
- Creates dynamic menu from `_system._before`, `menu`, modules, and `_system._after`
- Uses `keys_unsorted[]` to preserve order

**`find_trigger_item(cmd)`**
- Searches for command in local and root JSON
- Checks `.menu`, `._system._before`, `._system._after`
- Returns `file|path` when found

**`execute_trigger(file, path, type)`**
- Executes `_before` or `_then` triggers
- Supports local and module references
- Recursively processes nested triggers

**`execute_simple_command(file, path, choice, from_trigger)`**
- Executes command or object with triggers
- Determines value type (string/object)
- For objects, recursively calls `_before` → `_commands` → `_then`

**`execute_commands(file, path)`**
- Executes command array from `_commands`

**`resolve_module_reference(ref)`**
- Parses references like `@root:Command` or `@module:Command`
- Returns reference type and file path

---

## Dependencies

- `bash` (4.0+)
- `jq` — JSON processing
- `whiptail` — menu display

**Installation:**

```bash
# Debian/Ubuntu
apt-get install jq whiptail

# RHEL/CentOS
yum install jq newt
```

---

## Usage Examples

### Root Menu

```bash
cd /path/to/project
./menu.sh
```

### Module Menu

```bash
cd /path/to/project/docker/nginx
./menu.sh
```

### With Environment Variable

```bash
MENU_EXIT_BEHAVIOR="menu" ./menu.sh
```

---

## Debugging

To debug triggers, add to script:

```bash
set -x  # Enable tracing
```

Or run:

```bash
bash -x ./menu.sh
```

# LICENSE MIT
