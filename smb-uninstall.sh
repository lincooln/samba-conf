#!/bin/bash
# smb-uninstall.sh - Удаление Samba и восстановление системы
# Версия 2.1

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Функции для цветного вывода
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Определение дистрибутива
detect_distro() {
    if [ -f /etc/altlinux-release ]; then
        echo "altlinux"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ] || [ -f /etc/fedora-release ]; then
        echo "redhat"
    else
        echo "unknown"
    fi
}

# Получение директории скрипта
get_script_dir() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

SCRIPT_DIR=$(get_script_dir)
BACKUP_DIR="$SCRIPT_DIR/backups"
DISTRO=$(detect_distro)

# Проверка подтверждения
confirm_uninstall() {
    echo "=== Удаление Samba и восстановление системы ==="
    echo "Дистрибутив: $DISTRO"
    echo ""
    echo "Это действие:"
    echo "  - Удалит пакеты Samba"
    echo "  - Удалит правила sudo"
    echo "  - Отключит автозагрузку"
    echo "  - Восстановит оригинальный smb.conf"
    echo "  - Удалит пользователя из базы Samba"
    echo ""
    read -p "Вы уверены, что хотите удалить Samba и восстановить систему? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Удаление отменено"
        exit 0
    fi
}

# Удаление правил sudo
remove_sudo_rules() {
    local sudo_file="/etc/sudoers.d/samba-admin"

    print_info "Удаление правил sudo..."

    if [ -f "$sudo_file" ]; then
        if sudo rm -f "$sudo_file"; then
            print_info "Правила sudo удалены"
        else
            print_error "Не удалось удалить правила sudo"
        fi
    else
        print_info "Правила sudo не найдены"
    fi
}

# Отключение автозагрузки
disable_autostart() {
    local service_file="$HOME/.config/systemd/user/smb-mount.service"

    print_info "Отключение автозагрузки..."

    # Отключаем user service
    if systemctl --user is-enabled smb-mount.service >/dev/null 2>&1; then
        if systemctl --user disable smb-mount.service 2>/dev/null; then
            print_info "Автозагрузка отключена"
        else
            print_warn "Не удалось отключить автозагрузку"
        fi
    fi

    # Останавливаем службу если запущена
    if systemctl --user is-active smb-mount.service >/dev/null 2>&1; then
        systemctl --user stop smb-mount.service 2>/dev/null || true
    fi

    # Удаляем service файл
    if [ -f "$service_file" ]; then
        if rm -f "$service_file"; then
            print_info "Service файл удален"
        else
            print_warn "Не удалось удалить service файл"
        fi
    fi

    # Перезагружаем демон
    systemctl --user daemon-reload 2>/dev/null || true

    # Отключаем лингерание если было включено
    if command -v loginctl >/dev/null 2>&1; then
        if loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
            print_info "Отключение лингерания..."
            sudo loginctl disable-linger "$USER" 2>/dev/null || print_warn "Не удалось отключить лингерание"
        fi
    fi
}

# Остановка служб Samba
stop_samba_services() {
    print_info "Остановка служб Samba..."

    local services=()
    case $DISTRO in
        "altlinux")
            services=("smb" "nmb")
            ;;
        "debian")
            services=("smbd" "nmbd")
            ;;
        *)
            services=("smbd" "nmbd")
            ;;
    esac

    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            if sudo systemctl stop "$service" 2>/dev/null; then
                print_info "Служба $service остановлена"
            else
                print_warn "Не удалось остановить службу $service"
            fi
        fi
    done
}

# Удаление пользователя из базы Samba
remove_user_from_samba() {
    local user="$USER"

    print_info "Удаление пользователя $user из базы Samba..."

    if sudo pdbedit -L | grep -q "^$user:"; then
        if sudo smbpasswd -L -x "$user" 2>/dev/null; then
            print_info "Пользователь $user удален из базы Samba"
        elif sudo pdbedit -x -u "$user" 2>/dev/null; then
            print_info "Пользователь $user удален из базы Samba (через pdbedit)"
        else
            print_warn "Не удалось удалить пользователя $user из базы Samba"
        fi
    else
        print_info "Пользователь не найден в базе Samba"
    fi
}

# Восстановление оригинального smb.conf
restore_smb_config() {
    local original_backup="$BACKUP_DIR/smb.conf.original"
    local smb_conf="/etc/samba/smb.conf"

    print_info "Восстановление оригинального smb.conf..."

    if [ -f "$original_backup" ]; then
        if sudo cp "$original_backup" "$smb_conf"; then
            print_info "Конфигурация восстановлена"

            # Удаляем бэкап после восстановления
            if rm -f "$original_backup"; then
                print_info "Резервная копия удалена"
            else
                print_warn "Не удалось удалить резервную копию (можно удалить вручную: $original_backup)"
            fi
        else
            print_error "Не удалось восстановить конфигурацию"
        fi
    else
        print_info "Резервная копия не найдена, оставляем текущую конфигурацию"
    fi

    # Удаляем директорию бэкапов если пуста
    if [ -d "$BACKUP_DIR" ] && [ -z "$(ls -A "$BACKUP_DIR")" ]; then
        rmdir "$BACKUP_DIR" 2>/dev/null && print_info "Директория бэкапов удалена" || true
    fi
}

# Удаление пакетов Samba
remove_samba_packages() {
    print_info "Удаление пакетов Samba..."

    local packages=()
    local package_manager=""

    case $DISTRO in
        "altlinux")
            package_manager="apt-get"
            packages=("samba" "samba-client" "cifs-utils" "expect")
            ;;
        "debian")
            package_manager="apt"
            packages=("samba" "samba-common-bin" "smbclient" "cifs-utils" "expect")
            ;;
        "redhat")
            package_manager="dnf"
            packages=("samba" "samba-client" "cifs-utils" "expect")
            ;;
        *)
            print_error "Неизвестный дистрибутив"
            return 1
            ;;
    esac

    # Удаляем пакеты
    if sudo $package_manager remove -y "${packages[@]}" 2>/dev/null; then
        print_info "Пакеты Samba удалены"
    else
        print_error "Не удалось удалить пакеты Samba"
        return 1
    fi

    # Очищаем зависимости
    case $DISTRO in
        "altlinux"|"debian")
            sudo $package_manager autoremove -y 2>/dev/null || true
            ;;
        "redhat")
            sudo $package_manager autoremove -y 2>/dev/null || true
            ;;
    esac

    return 0
}

# Основная функция
main() {
    confirm_uninstall

    # Выполняем все этапы удаления
    remove_sudo_rules
    disable_autostart
    stop_samba_services
    remove_user_from_samba
    restore_smb_config
    remove_samba_packages

    echo ""
    print_info "=== Удаление завершено успешно! ==="
    echo "Система восстановлена к состоянию до установки."
    echo ""
    echo "Что было сделано:"
    echo "  - Удалены пакеты Samba"
    echo "  - Удалены правила sudo"
    echo "  - Отключена автозагрузка"
    echo "  - Остановлены службы Samba"
    echo "  - Удален пользователь из базы Samba"
    echo "  - Восстановлена оригинальная конфигурация"
}

# Обработка прерывания
trap 'echo ""; print_warn "Прерывание выполнения..."; exit 1' INT TERM

main "$@"
