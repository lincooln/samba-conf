#!/bin/bash
# smb-install.sh - Установка и настройка Samba для ALT Linux/Debian
# Версия 3.1 (улучшенная)

# === НАСТРОЙКИ ===
SAMBASHARE_PASSWORD="123"           # Пароль для пользователя Samba
SAMBASHARE_USER="$USER"             # Используем текущего пользователя

# Опциональные функции (true/false)
ENABLE_SUDO_RULES="true"            # Создавать правила sudo для монтирования без пароля
ENABLE_AUTOSTART="true"             # Настраивать автозагрузку монтирования
BACKUP_ORIGINAL_CONFIG="true"       # Создавать резервную копию smb.conf

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

# Проверка наличия sudo
check_sudo() {
    if ! command -v sudo &> /dev/null; then
        print_error "sudo не установлен."
        if [ "$DISTRO" = "altlinux" ]; then
            print_info "Установите sudo: su -c 'apt-get install sudo'"
        elif [ "$DISTRO" = "debian" ]; then
            print_info "Установите sudo: su -c 'apt install sudo'"
        fi
        exit 1
    fi

    if ! sudo -n true 2>/dev/null; then
        print_info "Требуется ввод пароля sudo для продолжения..."
        if ! sudo true; then
            print_error "Неверный пароль sudo или нет прав"
            exit 1
        fi
    fi
}

# Установка пакетов Samba
install_samba_packages() {
    print_info "Установка пакетов Samba для $DISTRO..."

    local packages=""
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

    local to_install=()

    for package in "${packages[@]}"; do
        if ! rpm -q "$package" &>/dev/null && ! dpkg -l | grep -q "^ii  $package " 2>/dev/null; then
            to_install+=("$package")
        fi
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        print_info "Все необходимые пакеты уже установлены"
        return 0
    fi

    print_info "Установка пакетов: ${to_install[*]}"

    case $DISTRO in
        "altlinux"|"debian")
            if ! sudo $package_manager update; then
                print_warn "Не удалось обновить список пакетов, продолжаем..."
            fi

            if ! sudo $package_manager install -y "${to_install[@]}"; then
                print_error "Не удалось установить пакеты Samba"
                return 1
            fi
            ;;
        "redhat")
            if ! sudo $package_manager install -y "${to_install[@]}"; then
                print_error "Не удалось установить пакеты Samba"
                return 1
            fi
            ;;
    esac

    print_info "Пакеты Samba успешно установлены"
    return 0
}

# Добавление пользователя в базу Samba
add_user_to_samba_db() {
    print_info "Добавление пользователя $SAMBASHARE_USER в базу Samba..."

    # Метод 1: Используем expect для автоматизации smbpasswd
    print_info "Установка пароля через expect..."
    expect << EOF > /dev/null 2>&1
spawn sudo smbpasswd -L -a $SAMBASHARE_USER
expect "New SMB password:"
send "$SAMBASHARE_PASSWORD\r"
expect "Retype new SMB password:"
send "$SAMBASHARE_PASSWORD\r"
expect eof
EOF

    if [ $? -eq 0 ]; then
        print_info "Пользователь $SAMBASHARE_USER добавлен в базу Samba"
        return 0
    fi

    # Метод 2: Пробуем smbpasswd с stdin
    print_info "Пробуем альтернативный метод..."
    if (echo "$SAMBASHARE_PASSWORD"; echo "$SAMBASHARE_PASSWORD") | sudo smbpasswd -L -s -a "$SAMBASHARE_USER" 2>/dev/null; then
        print_info "Пользователь $SAMBASHARE_USER добавлен в базу Samba (через stdin)"
        return 0
    fi

    # Метод 3: Используем pdbedit если доступен
    if command -v pdbedit &> /dev/null; then
        print_info "Пробуем через pdbedit..."
        if sudo pdbedit -a -u "$SAMBASHARE_USER" <<< "$SAMBASHARE_PASSWORD" 2>/dev/null; then
            print_info "Пользователь $SAMBASHARE_USER добавлен в базу Samba через pdbedit"
            return 0
        fi
    fi

    print_warn "Не удалось добавить пользователя $SAMBASHARE_USER в базу Samba автоматически"
    print_warn "Выполните вручную:"
    echo "  sudo smbpasswd -a $SAMBASHARE_USER"
    echo "  (введите пароль: $SAMBASHARE_PASSWORD)"
    return 1
}

# Создание правила sudo
create_sudo_rules() {
    if [ "$ENABLE_SUDO_RULES" != "true" ]; then
        print_info "Создание правил sudo отключено в настройках"
        return 0
    fi

    local sudo_file="/etc/sudoers.d/samba-admin"

    print_info "Создание правил sudo для монтирования без пароля..."

    if [ ! -f "$sudo_file" ]; then
        # Определяем имена служб в зависимости от дистрибутива
        local service_commands=""
        case $DISTRO in
            "altlinux")
                service_commands="/bin/systemctl restart smb, /bin/systemctl restart nmb, /bin/systemctl status smb, /bin/systemctl status nmb"
                ;;
            "debian")
                service_commands="/bin/systemctl restart smbd, /bin/systemctl restart nmbd, /bin/systemctl restart smb, /bin/systemctl status smbd, /bin/systemctl status nmbd, /bin/systemctl status smb"
                ;;
            *)
                service_commands="/bin/systemctl restart smb, /bin/systemctl restart nmb, /bin/systemctl status smb, /bin/systemctl status nmb"
                ;;
        esac

        sudo tee "$sudo_file" > /dev/null << EOF
# Правила для управления Samba и монтирования
$USER ALL=(ALL) NOPASSWD: $service_commands
$USER ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/mount.cifs, /usr/bin/umount.cifs
EOF

        if [ $? -ne 0 ]; then
            print_error "Не удалось создать правило sudo"
            return 1
        fi

        # Устанавливаем правильные права на файл sudoers
        sudo chmod 440 "$sudo_file"

        print_info "Правило sudo создано: $sudo_file"
        print_info "Теперь монтирование не будет запрашивать пароль sudo"
    else
        print_info "Правило sudo уже существует"
    fi

    return 0
}

# Создание резервной копии конфигурации Samba
backup_smb_config() {
    if [ "$BACKUP_ORIGINAL_CONFIG" != "true" ]; then
        print_info "Резервное копирование конфигурации отключено в настройках"
        return 0
    fi

    local smb_conf="/etc/samba/smb.conf"
    local backup_dir="$BACKUP_DIR"

    print_info "Создание резервной копии конфигурации Samba..."

    if [ ! -d "$backup_dir" ]; then
        print_info "Создание директории для бэкапов: $backup_dir"
        mkdir -p "$backup_dir"
    fi

    if [ -f "$smb_conf" ]; then
        local backup_file="$backup_dir/smb.conf.original"
        print_info "Копирование $smb_conf в $backup_file"

        if ! sudo cp "$smb_conf" "$backup_file"; then
            print_error "Не удалось создать резервную копию конфигурации"
            return 1
        fi

        # Устанавливаем владельца бэкапа на текущего пользователя
        sudo chown "$USER:$USER" "$backup_file"

        print_info "Резервная копия создана: $backup_file"
    else
        print_info "Файл конфигурации $smb_conf будет создан после установки Samba"
    fi

    return 0
}

# Настройка автозагрузки через systemd
setup_autostart() {
    if [ "$ENABLE_AUTOSTART" != "true" ]; then
        print_info "Настройка автозагрузки отключена в настройках"
        return 0
    fi

    local service_file="$HOME/.config/systemd/user/smb-mount.service"
    local script_path="$SCRIPT_DIR/smb-mount.sh"

    print_info "Настройка автозагрузки SMB-монтирования..."

    # Создаем директорию для пользовательских служб
    mkdir -p "$(dirname "$service_file")"

    # Создаем службу systemd
    cat > "$service_file" << EOF
[Unit]
Description=Mount SMB shares on boot
After=network.target

[Service]
Type=oneshot
ExecStart=$script_path
RemainAfterExit=yes
WorkingDirectory=$SCRIPT_DIR

[Install]
WantedBy=default.target
EOF

    # Перезагружаем демон systemd пользователя
    systemctl --user daemon-reload 2>/dev/null || true

    # Включаем службу
    if systemctl --user enable smb-mount.service 2>/dev/null; then
        print_info "Автозагрузка настроена: $service_file"
        print_info "Монтирование будет выполняться автоматически при загрузке"
    else
        print_warn "Не удалось включить автозагрузку"
    fi
}

# Запуск и включение служб Samba
enable_samba_services() {
    print_info "Запуск и включение служб Samba для $DISTRO..."

    local services=()

    case $DISTRO in
        "altlinux")
            services=("smb" "nmb")
            ;;
        "debian")
            services=("smbd" "nmbd" "smb")
            ;;
        *)
            services=("smb" "nmb")
            ;;
    esac

    for service in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "$service.service"; then
            print_info "Включение службы $service..."
            sudo systemctl enable "$service" 2>/dev/null || print_warn "Не удалось включить $service"
            sudo systemctl start "$service" 2>/dev/null || print_warn "Не удалось запустить $service"
        fi
    done

    # Проверка статуса
    print_info "Проверка статуса служб Samba..."
    local running=false
    for service in "${services[@]}"; do
        if sudo systemctl is-active --quiet "$service" 2>/dev/null; then
            print_info "Служба $service запущена"
            running=true
        fi
    done

    if [ "$running" = true ]; then
        # Даем службам время на запуск
        sleep 2
        add_user_to_samba_db
    else
        print_warn "Службы Samba не запущены, пользователь будет добавлен позже"
    fi

    return 0
}

# Основная функция
main() {
    echo "=== Установка и настройка Samba ==="
    echo "Дистрибутив: $DISTRO"
    echo "Пользователь Samba: $SAMBASHARE_USER"
    echo "Пароль Samba: $SAMBASHARE_PASSWORD"
    echo "Директория скриптов: $SCRIPT_DIR"
    echo ""
    echo "Опциональные функции:"
    echo "  - Правила sudo: $ENABLE_SUDO_RULES"
    echo "  - Автозагрузка: $ENABLE_AUTOSTART"
    echo "  - Бэкап конфига: $BACKUP_ORIGINAL_CONFIG"
    echo ""

    # Выполняем все этапы
    check_sudo
    install_samba_packages || exit 1
    backup_smb_config || exit 1
    create_sudo_rules || exit 1
    enable_samba_services || exit 1
    setup_autostart || exit 1

    echo ""
    print_info "=== Установка завершена успешно! ==="
    echo ""
    echo "Что было сделано:"
    echo "  - Установлены пакеты Samba"
    if [ "$BACKUP_ORIGINAL_CONFIG" = "true" ]; then
        echo "  - Создана резервная копия: $BACKUP_DIR/smb.conf.original"
    fi
    if [ "$ENABLE_SUDO_RULES" = "true" ]; then
        echo "  - Добавлены правила sudo для монтирования без пароля"
    fi
    if [ "$ENABLE_AUTOSTART" = "true" ]; then
        echo "  - Настроена автозагрузка монтирования"
    fi
    echo "  - Запущены службы Samba"
    echo ""
    echo "Следующие шаги:"
    echo "  1. Отредактируйте smb-mount.conf для настройки монтирования"
    echo "  2. Для монтирования: ./smb-mount.sh"
    echo "  3. Для размонтирования: ./smb-umount.sh"
    echo ""
    print_info "Не забудьте настроить smb-mount.conf перед использованием!"
}

main "$@"
