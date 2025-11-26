#!/bin/bash
# smb-mount.sh - Монтирование SMB ресурсов из файла конфигурации
# Версия 4.3

# === Настройки ===
CONFIG_FILE="smb-mount.conf"

# команда монтирования
MOUNT_OPTIONS="vers=3.0,uid=$(id -u),gid=$(id -g),file_mode=0755,dir_mode=0755"
# MOUNT_OPTIONS="vers=2.0,uid=$(id -u),gid=$(id -g),file_mode=0755,dir_mode=0755"
# MOUNT_OPTIONS="vers=1.1,uid=$(id -u),gid=$(id -g),file_mode=0755,dir_mode=0755"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DEFAULT_SMB_MOUNT_BASE_DIR="$HOME/smb-mnt"

# чтение BASE_PATH из конфига
SMB_MOUNT_BASE_DIR="$DEFAULT_SMB_MOUNT_BASE_DIR"
if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # Убираем комментарии и лишние пробелы
        line_clean=$(echo "$line" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Пропускаем пустые строки
        [[ -z "$line_clean" ]] && continue

        # Ищем base_path
        if [[ $line_clean =~ ^base_path= ]]; then
            SMB_MOUNT_BASE_DIR="${line_clean#base_path=}"
            # Проверка что путь абсолютный
            if [[ ! "$SMB_MOUNT_BASE_DIR" =~ ^/ ]]; then
                echo "Ошибка: base_path должен быть абсолютным путем (начинаться с /)"
                exit 1
            fi
            break
        fi
    done < "$CONFIG_FILE"
fi


# Функции для цветного вывода
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Функция проверки служебного ресурса (по символу $ в конце)
is_excluded_share() {
    local share="$1"
    # Исключаем ресурсы, заканчивающиеся на $ (служебные)
    if [[ "$share" == *"$" ]]; then
        return 0
    fi
    return 1
}

# Функция проверки доступности шары
is_share_accessible() {
    local host="$1"
    local share="$2"
    local user="$3"
    local pass="$4"

    local smbclient_cmd="smbclient -N //$host/$share -c 'exit'"

    if [ -n "$user" ] && [ -n "$pass" ]; then
        smbclient_cmd="smbclient -U $user%$pass //$host/$share -c 'exit'"
    fi

    if $smbclient_cmd >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Функция для получения списка расшаренных папок
get_shared_folders() {
    local host="$1"
    local user="$2"
    local pass="$3"

    local smbclient_cmd="smbclient -L //$host -N"

    # Если указаны учетные данные, используем их
    if [ -n "$user" ] && [ -n "$pass" ]; then
        smbclient_cmd="smbclient -L //$host -U $user%$pass"
    fi

    # Получаем список шаров
    $smbclient_cmd 2>/dev/null | \
        grep -E '^[[:space:]]*[A-Za-z0-9_\-]+[[:space:]]*' | \
        awk '{print $1}' | \
        grep -v '^$' | \
        while read -r share; do
            # Пропускаем служебные ресурсы (оканчивающиеся на $)
            if is_excluded_share "$share"; then
                continue
            fi

            # Проверяем доступность шары
            if is_share_accessible "$host" "$share" "$user" "$pass"; then
                echo "$share"
            fi
        done | \
        sort -u
}

# Функция для создания пути монтирования
create_mount_path() {
    local host="$1"
    local share="$2"

    # Если это IP - создаем путь из последних двух октетов
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local octet3=$(echo "$host" | cut -d. -f3)
        local octet4=$(echo "$host" | cut -d. -f4)
        echo "$SMB_MOUNT_BASE_DIR/${octet3}.${octet4}/$share"
    else
        # Если hostname - используем его
        echo "$SMB_MOUNT_BASE_DIR/$host/$share"
    fi
}

# Функция создания директории с правильными правами
create_directory_with_permissions() {
    local path="$1"

    # Создаем директорию рекурсивно
    if ! mkdir -p "$path" 2>/dev/null; then
        print_error "Не удалось создать директорию $path"
        return 1
    fi

    return 0
}

# Функция проверки доступности хоста через IP (быстрая)
is_ip_accessible() {
    local ip="$1"

    # Для IP проверяем ping (быстро)
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Функция проверки доступности хоста через hostname (медленная)
is_hostname_accessible() {
    local hostname="$1"

    # Пробуем разные методы для hostname
    # 1. Проверяем разрешение имени
    if getent hosts "$hostname" >/dev/null 2>&1; then
        return 0
    fi

    # 2. Пробуем добавить .local (для mDNS)
    if getent hosts "$hostname.local" >/dev/null 2>&1; then
        return 0
    fi

    # 3. Проверяем через smbclient
    if smbclient -N -L //"$hostname" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Функция получения IP по hostname
get_host_ip() {
    local host="$1"

    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$host"
        return 0
    fi

    # Пробуем разные методы разрешения имени
    local ip=""

    # 1. Стандартное DNS разрешение
    ip=$(getent ahosts "$host" 2>/dev/null | awk '{print $1; exit}')
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    # 2. mDNS разрешение (.local)
    ip=$(getent ahosts "$host.local" 2>/dev/null | awk '{print $1; exit}')
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    # 3. NMBLookup (для NetBIOS имен)
    ip=$(nmblookup "$host" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    echo "$host"  # Возвращаем оригинальный hostname если не удалось разрешить
}

# Функция монтирования с оптимизацией для hostname
mount_share() {
    local original_host="$1"
    local share="$2"
    local user="$3"
    local pass="$4"
    local mount_path="$5"
    local resolved_ip="$6"  # IP для монтирования

    # Создаем директорию для монтирования с правильными правами
    if ! create_directory_with_permissions "$mount_path"; then
        return 1
    fi

    # Проверяем, не смонтировано ли уже
    if mountpoint -q "$mount_path"; then
        print_warn "Уже смонтирован: //$original_host/$share"
        return 0
    fi

    local credentials=""
    if [ -n "$user" ] && [ -n "$pass" ]; then
        credentials="username=$user,password=$pass"
    else
        credentials="username=anonymous,password="
    fi

    # Если у нас есть resolved IP (и это не оригинальный hostname) - монтируем через IP
    if [ -n "$resolved_ip" ] && [[ "$resolved_ip" != "$original_host" ]]; then
        if sudo mount -t cifs "//$resolved_ip/$share" "$mount_path" -o "$credentials,$MOUNT_OPTIONS" 2>/dev/null; then
            print_info "Смонтирован: //$original_host/$share → $mount_path"
            return 0
        else
            print_warn "Не удалось смонтировать через IP $resolved_ip, пробуем через hostname..."
        fi
    fi

    # Если не получилось через IP или IP нет, пробуем через оригинальный hostname
    if sudo mount -t cifs "//$original_host/$share" "$mount_path" -o "$credentials,$MOUNT_OPTIONS" 2>/dev/null; then
        print_info "Смонтирован: //$original_host/$share → $mount_path"
        return 0
    else
        print_error "Ошибка: //$original_host/$share"
        # Удаляем пустую директорию при ошибке
        rmdir "$mount_path" 2>/dev/null || true
        return 1
    fi
}

# перезапускаем автозагрузку монтирования
check_and_restart_autostart() {
    local service_file="$HOME/.config/systemd/user/smb-mount.service"

    # Работаем только если сервис существует
    if [ -f "$service_file" ]; then
        # Если отключен - включаем
        if ! systemctl --user is-enabled smb-mount.service &>/dev/null; then
            print_info "Включение автозагрузки..."
            systemctl --user enable smb-mount.service 2>/dev/null && \
            print_info "Автозагрузка включена" || \
            print_warn "Не удалось включить автозагрузку"
        fi

        # Перезагружаем демон (на всякий случай)
        systemctl --user daemon-reload 2>/dev/null || true
    fi

    # Если сервиса нет - ничего не делаем (пользователь не хочет автозагрузку)
    # Но всё равно проверяем и явно сообщаем о статусе автозагрузки
    print_info "Проверка статуса автозагрузки..."
    if systemctl --user is-enabled smb-mount.service &>/dev/null; then
        print_info "✓ Автозагрузка активна"
    else
        print_warn "⚠ Автозагрузка отключена - монтирования не будут восстанавливаться после перезагрузки"
    fi
}

# Основная функция
main() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Файл конфигурации $CONFIG_FILE не найден"
        exit 1
    fi

    # Если передан аргумент - используем его как файл конфигурации
    if [ $# -eq 1 ]; then
        CONFIG_FILE="$1"
    fi

    echo "=== Монтирование SMB ресурсов ==="

    # Создаем базовую директорию с правильными правами
    if ! create_directory_with_permissions "$SMB_MOUNT_BASE_DIR"; then
        print_error "Не удалось создать базовую директорию"
        exit 1
    fi

    # Парсинг конфигурационного файла
    local current_host=""
    local current_user=""
    local current_pass=""
    local mount_count=0
    local error_count=0

    while IFS= read -r line || [ -n "$line" ]; do
        # Убираем комментарии и лишние пробелы
        line_clean=$(echo "$line" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Пропускаем пустые строки
        [[ -z "$line_clean" ]] && continue

        # Обрабатываем параметры
        if [[ $line_clean =~ ^ip= ]]; then
            # Если уже есть собранные данные - обрабатываем предыдущий сервер
            if [ -n "$current_host" ]; then
                process_server
            fi

            # Начинаем новую секцию
            current_host="${line_clean#ip=}"
            current_user=""
            current_pass=""

        elif [[ $line_clean =~ ^user= ]]; then
            current_user="${line_clean#user=}"
        elif [[ $line_clean =~ ^pass= ]]; then
            current_pass="${line_clean#pass=}"
        fi
    done < "$CONFIG_FILE"

    # Обрабатываем последний сервер
    if [ -n "$current_host" ]; then
        process_server
    fi
    # Вызываем функцию обновления systemd.service автозагрузка монтирования
    check_and_restart_autostart

    # Вывод итогов
    echo ""
    if [ $error_count -gt 0 ]; then
        print_error "Ошибок монтирования: $error_count"
    fi
}

# Функция обработки сервера
process_server() {
    echo ""
    print_info "Сервер: $current_host"

    local resolved_ip=""
    local host_accessible=false
    local use_ip_for_mount=false

    # Для hostname определяем IP для оптимизации монтирования
    if [[ ! "$current_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_warn "Определение IP для hostname может занять продолжительное время..."

        # Вызываем функцию разрешения
        resolved_ip=$(get_host_ip "$current_host")
        if [[ "$resolved_ip" != "$current_host" ]]; then
            print_warn "Для '$current_host' определён IP: $resolved_ip"
            echo "  Для ускорения монтирования данного ресурса в будущем"
            echo "  замените '$current_host' на '$resolved_ip' в вашем $CONFIG_FILE"

            # Проверяем доступность через IP (быстро)
            if is_ip_accessible "$resolved_ip"; then
                host_accessible=true
                use_ip_for_mount=true
                print_info "Используется быстрое монтирование через IP"
            else
                print_warn "IP недоступен, пробуем через hostname..."
            fi
        else
            print_warn "Не удалось определить IP для '$current_host'"
        fi
    else
        # Для IP используем его же как resolved_ip
        resolved_ip="$current_host"
        if is_ip_accessible "$resolved_ip"; then
            host_accessible=true
            use_ip_for_mount=true
        fi
    fi

    # Если через IP не доступен, пробуем через hostname (для hostname только)
    if [ "$host_accessible" = false ] && [[ ! "$current_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if is_hostname_accessible "$current_host"; then
            host_accessible=true
            print_warn "Используется медленное монтирование через hostname"
        fi
    fi

    # Если хост недоступен ни одним способом
    if [ "$host_accessible" = false ]; then
        print_error "Хост недоступен: $current_host"
        ((error_count++))
        return
    fi

    # Получаем список доступных расшаренных папок
    # Используем resolved_ip если доступен, иначе оригинальный hostname
    local actual_host="$resolved_ip"
    if [ "$use_ip_for_mount" = false ] || [ -z "$resolved_ip" ] || [[ "$resolved_ip" == "$current_host" ]]; then
        actual_host="$current_host"
    fi

    local shares=$(get_shared_folders "$actual_host" "$current_user" "$current_pass")

    if [ -z "$shares" ]; then
        print_error "Нет доступных ресурсов"
        ((error_count++))
        return
    fi

    local server_mount_count=0
    local server_error_count=0

    while IFS= read -r share; do
        if [ -n "$share" ]; then
            local mount_path=$(create_mount_path "$current_host" "$share")

            if mount_share "$current_host" "$share" "$current_user" "$current_pass" "$mount_path" "$resolved_ip"; then
                ((mount_count++))
                ((server_mount_count++))
            else
                ((error_count++))
                ((server_error_count++))
            fi
        fi
    done <<< "$shares"
}

# Обработка сигналов для корректного завершения
trap 'echo ""; print_warn "Прерывание выполнения..."; exit 1' INT TERM

main "$@"
