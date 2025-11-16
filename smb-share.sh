#!/bin/bash
# smb_share_from_config.sh - Скрипт для расшаривания папок из файла конфигурации
# Версия 1.8

# Настройки
DEFAULT_CONFIG="smb-share.conf"
SMB_CONFIG="/etc/samba/smb.conf"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Функции для цветного вывода
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Функция для поиска файла конфигурации
find_config_file() {
    local config_file="$1"
    
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        echo "$config_file"
        return 0
    fi
    
    if [ -f "./$DEFAULT_CONFIG" ]; then
        echo "./$DEFAULT_CONFIG"
        return 0
    fi
    
    local script_dir="$(dirname "$(readlink -f "$0")")"
    if [ -f "$script_dir/$DEFAULT_CONFIG" ]; then
        echo "$script_dir/$DEFAULT_CONFIG"
        return 0
    fi
    
    if [ -f "$HOME/$DEFAULT_CONFIG" ]; then
        echo "$HOME/$DEFAULT_CONFIG"
        return 0
    fi
    
    return 1
}

# минимальная проверка конфига:
validate_config() {
    if ! grep -q "path=" "$CONFIG_FILE"; then
        print_error "В конфиге не найдено ни одной папки (path=)"
        exit 1
    fi
}

# Проверка прав
if [ "$EUID" -ne 0 ]; then
    echo "Требуются права root. Запускаю с sudo..."
    exec sudo "$0" "$@"
fi

# Поиск файла конфигурации
CONFIG_FILE=$(find_config_file "$1")

if [ -z "$CONFIG_FILE" ]; then
    echo "Файл конфигурации не найден!"
    echo "Использование: $0 [путь_к_файлу_конфигурации]"
    exit 1
fi

print_info "Используется файл конфигурации: $CONFIG_FILE"

# Функция для расширения пути с ~
expand_path() {
    local path="$1"
    if [[ "$path" == ~* ]]; then
        path="${path/#\~/$HOME}"
    fi
    echo "$path"
}

# Парсинг конфигурации
process_share() {
    local path="$1" guest="$2" user="$3" pass="$4" mode="$5"
    
    [ -z "$path" ] && return
    
    # Расширяем путь
    path=$(expand_path "$path")
    share_name=$(basename "$path")
    print_info "Настройка шары: $share_name (путь: $path)"
    
    # Создаем папку
    mkdir -p "$path" 2>/dev/null || {
        print_error "Не удалось создать папку $path"
        return 1
    }
    
    # Устанавливаем права
    local actual_mode="${mode:-777}"
    if ! chmod "$actual_mode" "$path" 2>/dev/null; then
        print_error "Неверные права доступа mode=$actual_mode для $path"
        return 1
    fi
    
    # Устанавливаем владельца
    chown "$SUDO_USER:$SUDO_USER" "$path" 2>/dev/null || true
    
    # Добавляем в конфиг
    cat >> "$TEMP_CONFIG" << EOF

[$share_name]
    comment = Samba Share
    path = $path
    browseable = Yes
    writable = yes
    writeable = Yes
    public = yes
    create mode = 0777
    directory mode = 0777
EOF

    # Логика доступа (ИСПРАВЛЕННАЯ - учитываем guest=false)
    if [ "$guest" = "true" ]; then
        cat >> "$TEMP_CONFIG" << EOF
    guest ok = yes
    read only = no
EOF
        print_info "  - Гостевой доступ: РАЗРЕШЕН"
    else
        cat >> "$TEMP_CONFIG" << EOF
    guest ok = no
    read only = no
EOF
        print_info "  - Гостевой доступ: ЗАПРЕЩЕН"
        if [ -n "$user" ]; then
            cat >> "$TEMP_CONFIG" << EOF
    valid users = $user
EOF
            print_info "  - Доступ для пользователя: $user"
        fi
    fi
    
    return 0
}

# === Тут начинается основное тело скрипта ===

# минимально проверяем конфиг файл.
validate_config

# Создаем временный файл для нового конфига
TEMP_CONFIG=$(mktemp)

# Глобальные настройки (убираем проблемную строку с registry)
print_info "Создание чистой конфигурации..."
cat > "$TEMP_CONFIG" << 'EOF'
[global]
    security = user
    workgroup = WORKGROUP
    server string = Samba
    guest account = nobody
    map to guest = Bad User
    dns proxy = no
    log file = /var/log/samba/log.%m
    max log size = 50
    # Настройки для сетевого обнаружения
    local master = yes
    preferred master = yes
    os level = 20
EOF

# Основной парсинг
current_path=""
current_guest=""
current_user=""
current_pass=""
current_mode=""
has_errors=0

print_info "Чтение конфигурации..."
while IFS= read -r line || [ -n "$line" ]; do
    line_clean=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    [[ $line_clean =~ ^# ]] && continue
    [[ -z "$line_clean" ]] && continue
    
    if [[ $line_clean =~ ^path= ]]; then
        if ! process_share "$current_path" "$current_guest" "$current_user" "$current_pass" "$current_mode"; then
            has_errors=1
        fi
        current_path="${line_clean#path=}"
        current_guest=""
        current_user=""
        current_pass=""
        current_mode=""
    elif [[ $line_clean =~ ^guest= ]]; then
        current_guest="${line_clean#guest=}"
    elif [[ $line_clean =~ ^user= ]]; then
        current_user="${line_clean#user=}"
    elif [[ $line_clean =~ ^pass= ]]; then
        current_pass="${line_clean#pass=}"
    elif [[ $line_clean =~ ^mode= ]]; then
        current_mode="${line_clean#mode=}"
    fi
done < "$CONFIG_FILE"

# Последняя секция
if ! process_share "$current_path" "$current_guest" "$current_user" "$current_pass" "$current_mode"; then
    has_errors=1
fi

# Копируем временный конфиг в основной
if [ $has_errors -eq 0 ]; then
    print_info "Копируем конфигурацию в $SMB_CONFIG..."
    if ! cp "$TEMP_CONFIG" "$SMB_CONFIG"; then
        print_error "Не удалось записать конфигурацию Samba"
        has_errors=1
    fi
fi

rm -f "$TEMP_CONFIG"

if [ $has_errors -eq 1 ]; then
    print_error "Обнаружены ошибки в конфигурации. Samba не перезапущена."
    exit 1
fi

# Проверяем синтаксис
print_info "Проверка синтаксиса конфига..."
if testparm -s > /dev/null 2>&1; then
    print_info "Синтаксис конфига в порядке"
else
    print_error "Ошибка синтаксиса в конфиге!"
    exit 1
fi

# Перезапуск служб
print_info "Перезапуск служб Samba..."
if systemctl restart smbd nmbd; then
    print_info "Готово! Конфигурация применена из $CONFIG_FILE"
    
    echo ""
    print_info "Проверка доступных шар:"
    smbclient -L localhost -N 2>/dev/null | grep -A 100 "Sharename"
    
    echo ""
    print_info "Итоговые настройки доступа:"
    echo "smb-share: гостевой доступ $(grep -A 10 "\[smb-share\]" /etc/samba/smb.conf | grep "guest ok" | grep -q "yes" && echo "РАЗРЕШЕН" || echo "ЗАПРЕЩЕН")"
    echo "download: гостевой доступ $(grep -A 10 "\[download\]" /etc/samba/smb.conf | grep "guest ok" | grep -q "yes" && echo "РАЗРЕШЕН" || echo "ЗАПРЕЩЕН")"
else
    print_error "Не удалось перезапустить службы Samba"
    exit 1
fi

# итоговое резюме для пользователя

print_info "=== Настройка завершена ==="
echo "Доступ к шарам:"
echo "  Windows: \\\\$(hostname -I | awk '{print $1}')\\"
echo "  Linux: smb://$(hostname -I | awk '{print $1}')/"
echo ""
print_info "Папки доступны в сети!"
