#!/bin/bash
# smb-umount.sh - Размонтирование SMB ресурсов
# Версия 3.3

# === Настройки ===
CONFIG_FILE="smb-mount.conf"
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

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Функции для цветного вывода
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Функция для создания пути монтирования (такая же как в smb-mount.sh)
create_mount_path() {
    local host="$1"
    local share="$2"
    local custom_base_path="$3"

    local base_path="$SMB_MOUNT_BASE_DIR"
    if [ -n "$custom_base_path" ] && [ "$custom_base_path" != "#" ]; then
        base_path="$custom_base_path"
    fi

    # Если это IP - создаем путь из последних двух октетов
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local octet3=$(echo "$host" | cut -d. -f3)
        local octet4=$(echo "$host" | cut -d. -f4)
        echo "$base_path/${octet3}.${octet4}/$share"
    else
        # Если hostname - используем его
        echo "$base_path/$host/$share"
    fi
}

# Функция размонтирования конкретной точки монтирования
unmount_share() {
    local mount_path="$1"
    local host="$2"
    local share="$3"

    if mountpoint -q "$mount_path" 2>/dev/null; then
        print_info "Размонтирование: //$host/$share"

        if sudo umount "$mount_path" 2>/dev/null; then
            print_info "Успешно размонтировано: //$host/$share"
            return 0
        else
            print_error "Не удалось размонтировать: //$host/$share"
            return 1
        fi
    else
        print_warn "Не смонтировано: //$host/$share"
        return 0
    fi
}

# Функция очистки пустых директорий
cleanup_directories() {
    local base_path="$1"
    local host="$2"

    # Путь к директории сервера
    local server_dir=""
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local octet3=$(echo "$host" | cut -d. -f3)
        local octet4=$(echo "$host" | cut -d. -f4)
        server_dir="$base_path/${octet3}.${octet4}"
    else
        server_dir="$base_path/$host"
    fi

    # Если директория сервера существует, удаляем все пустые поддиректории
    if [ -d "$server_dir" ]; then
        # Удаляем все поддиректории первого уровня (шары) если они пусты
        find "$server_dir" -maxdepth 1 -type d ! -path "$server_dir" -exec rmdir {} \; 2>/dev/null || true

        # Удаляем саму директорию сервера если она пуста
        rmdir "$server_dir" 2>/dev/null || true

        # Удаляем базовую директорию если она пуста (только если это не домашняя директория)
        if [ "$base_path" != "$HOME" ] && [ "$base_path" != "/" ]; then
            rmdir "$base_path" 2>/dev/null || true
        fi
    fi
}

# Отключаем автозапуск монтирования при загрузке
disable_autostart() {
    local service_file="$HOME/.config/systemd/user/smb-mount.service"

    # Работаем только если сервис существует
    if [ -f "$service_file" ]; then
        print_info "Отключение автозагрузки..."
        systemctl --user disable smb-mount.service 2>/dev/null || true
        systemctl --user stop smb-mount.service 2>/dev/null || true
        print_info "Автозагрузка отключена"

        # НЕ УДАЛЯЕМ ФАЙЛ! Только отключаем
    else
        print_info "Служба автозагрузки не настроена"
    fi
}

# Основная функция
main() {
    echo "=== Размонтирование SMB ресурсов ==="

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Файл конфигурации $CONFIG_FILE не найден"
        exit 1
    fi

    # Если передан аргумент - используем его как файл конфигурации
    if [ $# -eq 1 ]; then
        CONFIG_FILE="$1"
    fi

    local unmount_count=0
    local error_count=0

    # Парсинг конфигурационного файла
    local current_host=""
    local current_base_path=""
    local processed_hosts=()

    while IFS= read -r line || [ -n "$line" ]; do
        # Убираем комментарии и лишние пробелы
        line_clean=$(echo "$line" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Пропускаем пустые строки
        [[ -z "$line_clean" ]] && continue

        # Обрабатываем параметры
        if [[ $line_clean =~ ^ip= ]]; then
            current_host="${line_clean#ip=}"
            current_base_path=""

        elif [[ $line_clean =~ ^base_path= ]]; then
            current_base_path="${line_clean#base_path=}"

            # Если есть host и base_path - обрабатываем
            if [ -n "$current_host" ] && [[ ! " ${processed_hosts[@]} " =~ " ${current_host}:${current_base_path} " ]]; then
                process_server "$current_host" "$current_base_path"
                processed_hosts+=("${current_host}:${current_base_path}")
            fi
        fi
    done < "$CONFIG_FILE"

    # Обрабатываем оставшиеся хосты без base_path
    while IFS= read -r line || [ -n "$line" ]; do
        line_clean=$(echo "$line" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ $line_clean =~ ^ip= ]]; then
            local host="${line_clean#ip=}"
            if [[ ! " ${processed_hosts[@]} " =~ " ${host}: " ]]; then
                process_server "$host" ""
                processed_hosts+=("${host}:")
            fi
        fi
    done < "$CONFIG_FILE"

    # Отключаем автозагрузку
        disable_autostart

    echo ""
    if [ $unmount_count -gt 0 ]; then
        print_info "Успешно размонтировано ресурсов: $unmount_count"
    else
        print_info "Нет ресурсов для размонтирования"
    fi
    if [ $error_count -gt 0 ]; then
        print_error "Ошибок при размонтировании: $error_count"
    fi
}

# Функция обработки сервера
process_server() {
    local host="$1"
    local base_path="$2"

    echo ""
    print_info "Сервер: $host"

    # Определяем базовый путь
    local actual_base_path="$SMB_MOUNT_BASE_DIR"
    if [ -n "$base_path" ]; then
        actual_base_path="$base_path"
    fi

    # Путь к директории сервера
    local server_dir=""
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local octet3=$(echo "$host" | cut -d. -f3)
        local octet4=$(echo "$host" | cut -d. -f4)
        server_dir="$actual_base_path/${octet3}.${octet4}"
    else
        server_dir="$actual_base_path/$host"
    fi

    # Если директория сервера существует, размонтируем все поддиректории
    if [ -d "$server_dir" ]; then
        local server_unmount_count=0
        local server_error_count=0

        # Ищем все поддиректории первого уровня (это наши шары)
        for mount_path in "$server_dir"/*; do
            if [ -d "$mount_path" ]; then
                local share=$(basename "$mount_path")

                if unmount_share "$mount_path" "$host" "$share"; then
                    ((unmount_count++))
                    ((server_unmount_count++))
                else
                    ((error_count++))
                    ((server_error_count++))
                fi
            fi
        done

        if [ $server_unmount_count -gt 0 ]; then
            print_info "Размонтировано: $server_unmount_count ресурсов"
        fi

        # Очищаем директории после размонтирования
        cleanup_directories "$actual_base_path" "$host"
    else
        print_warn "Нет смонтированных ресурсов для $host"
    fi
}

# Обработка сигналов для корректного завершения
trap 'echo ""; print_warn "Прерывание выполнения..."; exit 1' INT TERM

main "$@"
