# Menu System Documentation

Динамическая система меню с поддержкой триггеров, модульности и иерархической структуры.

## Оглавление

- [Структура menu.json](#структура-menujson)
  - [Базовая структура](#базовая-структура)
  - [Порядок элементов](#порядок-элементов)
  - [Пример полной структуры](#пример-полной-структуры)
- [Триггеры (_before, _then)](#триггеры-_before-_then)
  - [Порядок выполнения](#порядок-выполнения)
  - [Алгоритм поиска триггерных команд](#алгоритм-поиска-триггерных-команд)
  - [Рекурсивные триггеры](#рекурсивные-триггеры)
  - [Примеры использования](#примеры-использования-триггеров)
- [Модульные ссылки](#модульные-ссылки)
  - [Типы ссылок](#типы-ссылок)
  - [Примеры](#примеры-модульных-ссылок)
- [Конфигурация](#конфигурация)
  - [Переменные окружения](#переменные-окружения)
  - [Режимы работы](#режимы-работы)
- [Внутренняя архитектура](#внутренняя-архитектура)
  - [Ключевые функции](#ключевые-функции)

---

## Структура menu.json

### Базовая структура

```json
{
  "_system": {
    "_before": {
      "Пункт до меню": "команда или объект"
    },
    "_after": {
      "Пункт после меню": "команда или объект"
    }
  },
  "menu": {
    "Основной пункт": "команда",
    "Сложный пункт": {
      "_before": ["Команда1", "Команда2"],
      "_commands": ["команда1", "команда2"],
      "_then": ["Команда3"]
    },
    "Подменю": {
      "Пункт 1": "команда",
      "Пункт 2": "команда"
    }
  }
}
```

### Порядок элементов

Скрипт сохраняет порядок элементов из JSON благодаря использованию `keys_unsorted[]`. 

**Итоговый порядок в меню:**

1. Элементы из `_system._before`
2. Элементы из `menu`
3. Динамически найденные модули (из `docker/*/`)
4. Элементы из `_system._after`

**Пример:**

```json
{
  "_system": {
    "_before": {
      "List all": { "_commands": [...] }
    },
    "_after": {
      "Prune": "docker system prune -f",
      "Выход": "exit 0"
    }
  },
  "menu": {
    "Rebuild": {...},
    "Build": "docker build ...",
    "Remove": "docker rmi ..."
  }
}
```

**Отображается как:**
1. List all
2. Rebuild
3. Build
4. Remove
5. [Динамические модули]
6. Prune
7. Выход

### Пример полной структуры

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
      "Выход": "exit 0"
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

## Триггеры (_before, _then)

### Порядок выполнения

Для пункта с триггерами выполнение происходит в следующем порядке:

1. `_before` — команды, выполняемые **до** основных команд
2. `_commands` — основные команды
3. `_then` — команды, выполняемые **после** основных команд

### Алгоритм поиска триггерных команд

При обработке триггера (например, `"Remove Image"`) поиск происходит последовательно:

**1. Локальный menu.json:**
   - `.menu."Remove Image"`
   - `._system._before."Remove Image"`
   - `._system._after."Remove Image"`

**2. Корневой menu.json** (если текущий файл в модуле):
   - `.menu."Remove Image"`
   - `._system._before."Remove Image"`
   - `._system._after."Remove Image"`

**3. Ошибка** — если команда не найдена

**Важно:** Поиск происходит **профилактически** перед выполнением команд, что позволяет обнаружить ошибки до начала выполнения.

### Рекурсивные триггеры

Триггеры поддерживают **вложенность**. Если триггерная команда сама содержит `_before`/`_commands`/`_then`, они выполнятся рекурсивно.

**Пример цепочки:**

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

**При выборе "Remove Image":**
1. Выполнит `_before: ["Remove Container"]`
   - Выполнит `"Remove Container"._before: ["Stop Container"]`
     - Выполнит `"Stop Container"` → `docker stop container`
   - Выполнит `"Remove Container"._commands` → `docker rm container`
2. Выполнит `"Remove Image"._commands` → `docker rmi image`

### Примеры использования триггеров

#### Простой триггер

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

**При выборе "Rebuild":**
1. `Remove` (из `.menu`)
2. `Prune` (из `._system._after`)
3. `Build` (из `.menu`)
4. `Prune` (из `._system._after`)

#### Триггер с массивом команд

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

## Модульные ссылки

### Типы ссылок

**1. Локальная ссылка** — `"Command"`
   - Поиск в текущем `menu.json`
   - Fallback в корневой `menu.json`

**2. Ссылка на root** — `"@root:Command"`
   - Прямая ссылка на команду в корневом `menu.json`

**3. Ссылка на модуль** — `"@modulename:Command"`
   - Прямая ссылка на команду в `docker/modulename/menu.json`

### Примеры модульных ссылок

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

## Конфигурация

### Переменные окружения

| Переменная | По умолчанию | Описание |
|-----------|--------------|----------|
| `SCAN_DIR` | `docker` | Директория с модулями |
| `MENU_EXIT_BEHAVIOR` | `console` | Поведение после выполнения команды |
| `BASE_MENU` | `menu.json` | Текущий файл меню |
| `ROOT_MENU` | (авто) | Корневой `menu.json` для fallback |

### Режимы работы

**MENU_EXIT_BEHAVIOR:**

- `console` — выход в консоль после выполнения
- `menu` — возврат в текущее меню
- `root` — возврат в корневое меню

**Пример:**

```bash
export MENU_EXIT_BEHAVIOR="menu"
./menu.sh
```

---

## Внутренняя архитектура

### Ключевые функции

**`generate_dynamic_menu(base_menu, mode)`**
- Создаёт динамическое меню из `_system._before`, `menu`, модулей и `_system._after`
- Использует `keys_unsorted[]` для сохранения порядка

**`find_trigger_item(cmd)`**
- Ищет команду в локальном и корневом JSON
- Проверяет `.menu`, `._system._before`, `._system._after`
- Возвращает `file|path` при нахождении

**`execute_trigger(file, path, type)`**
- Выполняет триггеры `_before` или `_then`
- Поддерживает локальные ссылки и модульные ссылки
- Рекурсивно обрабатывает вложенные триггеры

**`execute_simple_command(file, path, choice, from_trigger)`**
- Выполняет команду или объект с триггерами
- Определяет тип значения (string/object)
- Для объектов рекурсивно вызывает `_before` → `_commands` → `_then`

**`execute_commands(file, path)`**
- Выполняет массив команд из `_commands`

**`resolve_module_reference(ref)`**
- Разбирает ссылки вида `@root:Command` или `@module:Command`
- Возвращает тип ссылки и путь к файлу

---

## Зависимости

- `bash` (4.0+)
- `jq` — обработка JSON
- `whiptail` — отображение меню

**Установка:**

```bash
# Debian/Ubuntu
apt-get install jq whiptail

# RHEL/CentOS
yum install jq newt
```

---

## Примеры использования

### Корневое меню

```bash
cd /path/to/project
./menu.sh
```

### Модульное меню

```bash
cd /path/to/project/docker/nginx
./menu.sh
```

### С переменной окружения

```bash
MENU_EXIT_BEHAVIOR="menu" ./menu.sh
```

---

## Отладка

Для отладки триггеров добавьте в скрипт:

```bash
set -x  # Включить трассировку
```

Или запустите:

```bash
bash -x ./menu.sh
```

# ЛИЦЕНЗИЯ MIT
