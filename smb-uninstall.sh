#!/bin/bash
# smb-uninstall.sh - Удаление Samba и восстановление системы
# Версия 1.0

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Получение директории скрипта
get_script_dir() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

SCRIPT_DIR=$(get_script_dir)
BACKUP_DIR="$SCRIPT_DIR/backups"

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

DISTRO=$(detect_distro)

# Проверка sudo
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        print_info "Требуется ввод пароля sudo..."
        if ! sudo true; then
            print_error "Неверный пароль sudo"
            exit 1
        fi
    fi
}

# Удаление правил sudo
remove_sudo_rules() {
    local sudo_file="/etc/sudoers.d/samba-admin"

    if [ -f "$sudo_file" ]; then
        print_info "Удаление правил sudo..."
        sudo rm -f "$sudo_file"
        print_info "Правила sudo удалены"
    else
        print_info "Правила sudo не найдены"
    fi
}

# Отключение автозагрузки
disable_autostart() {
    local service_file="$HOME/.config/systemd/user/smb-mount.service"

    if [ -f "$service_file" ]; then
        print_info "Отключение автозагрузки..."
        systemctl --user disable smb-mount.service 2>/dev/null || true
        systemctl --user stop smb-mount.service 2>/dev/null || true
        rm -f "$service_file"
        systemctl --user daemon-reload 2>/dev/null || true
        print_info "Автозагрузка отключена"
    else
        print_info "Служба автозагрузки не найдена"
    fi
}

# Восстановление оригинального конфига
restore_smb_config() {
    local original_conf="$BACKUP_DIR/smb.conf.original"
    local current_conf="/etc/samba/smb.conf"

    if [ -f "$original_conf" ]; then
        print_info "Восстановление оригинального smb.conf..."
        sudo cp "$original_conf" "$current_conf"
        print_info "Конфигурация восстановлена"

        # Удаляем бэкап
        rm -f "$original_conf"
    else
        print_info "Резервная копия конфигурации не найдена"
    fi
}

# Удаление пользователя из Samba
remove_samba_user() {
    local user="$USER"

    if sudo pdbedit -L | grep -q "^$user:"; then
        print_info "Удаление пользователя $user из базы Samba..."
        sudo smbpasswd -x "$user" 2>/dev/null || true
        sudo pdbedit -x -u "$user" 2>/dev/null || true
        print_info "Пользователь удален из базы Samba"
    else
        print_info "Пользователь не найден в базе Samba"
    fi
}

# Удаление пакетов Samba
remove_samba_packages() {
    print_info "Удаление пакетов Samba..."

    case $DISTRO in
        "altlinux")
            sudo apt-get remove -y samba samba-client cifs-utils expect 2>/dev/null || true
            ;;
        "debian")
            sudo apt remove -y samba samba-common-bin smbclient cifs-utils expect 2>/dev/null || true
            ;;
        "redhat")
            sudo dnf remove -y samba samba-client cifs-utils expect 2>/dev/null || true
            ;;
    esac

    print_info "Пакеты Samba удалены"
}

# Остановка служб Samba
stop_samba_services() {
    print_info "Остановка служб Samba..."

    local services=()
    case $DISTRO in
        "altlinux") services=("smb" "nmb") ;;
        "debian") services=("smbd" "nmbd" "smb") ;;
        *) services=("smb" "nmb") ;;
    esac

    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            sudo systemctl stop "$service" 2>/dev/null || true
            sudo systemctl disable "$service" 2>/dev/null || true
        fi
    done

    print_info "Службы Samba остановлены"
}

# Основная функция
main() {
    echo "=== Удаление Samba и восстановление системы ==="
    echo "Дистрибутив: $DISTRO"
    echo ""

    read -p "Вы уверены, что хотите удалить Samba и восстановить систему? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Удаление отменено"
        exit 0
    fi

    check_sudo

    # Выполняем в обратном порядке установке
    remove_sudo_rules
    disable_autostart
    stop_samba_services
    remove_samba_user
    restore_smb_config
    remove_samba_packages

    # Очистка бэкап директории
    if [ -d "$BACKUP_DIR" ] && [ -z "$(ls -A "$BACKUP_DIR")" ]; then
        rmdir "$BACKUP_DIR"
    fi

    echo ""
    print_info "=== Удаление завершено успешно! ==="
    echo "Система восстановлена к состоянию до установки."
}

main "$@"
