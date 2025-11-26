#!/bin/bash
# smb-install.sh - Установка и настройка Samba для ALT Linux/Debian
# Версия 4.4

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

# === ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ===

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

get_script_dir() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

# === ФУНКЦИИ УСТАНОВКИ ===

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
            sudo $package_manager update || print_warn "Не удалось обновить список пакетов"
            sudo $package_manager install -y "${to_install[@]}" || {
                print_error "Не удалось установить пакеты Samba"
                return 1
            }
            ;;
        "redhat")
            sudo $package_manager install -y "${to_install[@]}" || {
                print_error "Не удалось установить пакеты Samba"
                return 1
            }
            ;;
    esac

    print_info "Пакеты Samba успешно установлены"
    return 0
}

backup_smb_config() {
    if [ "$BACKUP_ORIGINAL_CONFIG" != "true" ]; then
        print_info "Резервное копирование конфигурации отключено в настройках"
        return 0
    fi

    local smb_conf="/etc/samba/smb.conf"
    local backup_dir="$BACKUP_DIR"

    print_info "Создание резервной копии конфигурации Samba..."

    mkdir -p "$backup_dir"
    [ -f "$smb_conf" ] || {
        print_info "Файл конфигурации $smb_conf будет создан после установки Samba"
        return 0
    }

    local backup_file="$backup_dir/smb.conf.original"
    print_info "Копирование $smb_conf в $backup_file"

    sudo cp "$smb_conf" "$backup_file" || {
        print_error "Не удалось создать резервную копию конфигурации"
        return 1
    }

    sudo chown "$USER:$USER" "$backup_file" 2>/dev/null && \
        print_info "Права на бэкап установлены" || \
        print_warn "Не удалось изменить права на бэкап (но файл создан)"

    print_info "Резервная копия создана: $backup_file"
    return 0
}

# === ФУНКЦИИ НАСТРОЙКИ SAMBA ===

add_user_to_samba_db() {
    print_info "Добавление пользователя $SAMBASHARE_USER в базу Samba..."

    print_info "Установка пароля через expect..."
    expect << EOF > /dev/null 2>&1
spawn sudo smbpasswd -L -a $SAMBASHARE_USER
expect "New SMB password:"
send "$SAMBASHARE_PASSWORD\r"
expect "Retype new SMB password:"
send "$SAMBASHARE_PASSWORD\r"
expect eof
EOF

    [ $? -eq 0 ] && {
        print_info "Пользователь $SAMBASHARE_USER добавлен в базу Samba"
        return 0
    }

    print_info "Пробуем альтернативный метод..."
    (echo "$SAMBASHARE_PASSWORD"; echo "$SAMBASHARE_PASSWORD") | sudo smbpasswd -L -s -a "$SAMBASHARE_USER" 2>/dev/null && {
        print_info "Пользователь $SAMBASHARE_USER добавлен в базу Samba (через stdin)"
        return 0
    }

    command -v pdbedit &> /dev/null && {
        print_info "Пробуем через pdbedit..."
        sudo pdbedit -a -u "$SAMBASHARE_USER" <<< "$SAMBASHARE_PASSWORD" 2>/dev/null && {
            print_info "Пользователь $SAMBASHARE_USER добавлен в базу Samba через pdbedit"
            return 0
        }
    }

    print_warn "Не удалось добавить пользователя $SAMBASHARE_USER в базу Samba автоматически"
    print_warn "Выполните вручную:"
    echo "  sudo smbpasswd -a $SAMBASHARE_USER"
    echo "  (введите пароль: $SAMBASHARE_PASSWORD)"
    return 1
}

enable_samba_services() {
    print_info "Запуск и включение служб Samba для $DISTRO..."

    local potential_services=()
    case $DISTRO in
        "altlinux") potential_services=("smb" "nmb") ;;
        "debian")
            potential_services=("smbd" "nmbd")
            systemctl list-unit-files | grep -q "smb.service" && potential_services+=("smb")
            ;;
        *) potential_services=("smb" "nmb") ;;
    esac

    local available_services=()
    for service in "${potential_services[@]}"; do
        systemctl list-unit-files | grep -q "$service.service" && {
            available_services+=("$service")
            print_info "Найдена служба: $service"
        } || print_warn "Служба $service не найдена, пропускаем"
    done

    [ ${#available_services[@]} -eq 0 ] && {
        print_error "Не найдено ни одной службы Samba"
        return 1
    }

    for service in "${available_services[@]}"; do
        print_info "Включение службы $service..."
        sudo systemctl enable "$service" 2>/dev/null && \
            print_info "Служба $service включена" || \
            print_warn "Не удалось включить $service (возможно уже включена)"

        print_info "Запуск службы $service..."
        sudo systemctl start "$service" 2>/dev/null && \
            print_info "Служба $service запущена" || \
            print_warn "Не удалось запустить $service (возможно уже запущена)"
    done

    print_info "Проверка статуса служб Samba..."
    local running=false
    for service in "${available_services[@]}"; do
        sudo systemctl is-active --quiet "$service" 2>/dev/null && {
            print_info "✓ Служба $service запущена"
            running=true
        } || print_warn "✗ Служба $service не запущена"
    done

    print_info "Подробный статус служб:"
    for service in "${available_services[@]}"; do
        local enabled_status=$(systemctl is-enabled "$service" 2>/dev/null || echo "unknown")
        local active_status=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
        print_info "  $service: enabled=$enabled_status, active=$active_status"
    done

    $running && {
        sleep 2
        add_user_to_samba_db
    } || print_warn "Службы Samba не запущены, пользователь будет добавлен позже"

    return 0
}

# === ФУНКЦИИ SUDO И АВТОЗАГРУЗКИ ===

create_sudo_rules() {
    [ "$ENABLE_SUDO_RULES" != "true" ] && {
        print_info "Создание правил sudo отключено в настройках"
        return 0
    }

    local sudo_file="/etc/sudoers.d/samba-admin"
    local script_path="$SCRIPT_DIR/smb-share.sh"

    print_info "Создание правил sudo для управления Samba..."

    local service_commands=""
    local mount_commands="/bin/mount, /bin/umount, /usr/bin/mount.cifs, /usr/bin/umount.cifs"

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

    [ -f "$sudo_file" ] && {
        print_info "Правило sudo уже существует: $sudo_file"
        print_info "Проверка текущих правил..."

        sudo grep -q "NOPASSWD:.*mount" "$sudo_file" 2>/dev/null && \
            print_info "✓ Правила монтирования уже настроены" || \
            print_warn "⚠ Правила монтирования отсутствуют, обновляем..."

        sudo grep -q "NOPASSWD:.*systemctl.*smb" "$sudo_file" 2>/dev/null && \
            print_info "✓ Правила управления службами уже настроены" || \
            print_warn "⚠ Правила управления службами отсутствуют, обновляем..."

        sudo grep -q "$script_path" "$sudo_file" 2>/dev/null && \
            print_info "✓ Правило для скрипта расшаривания уже настроено" || \
            print_warn "⚠ Правило для скрипта расшаривания отсутствует, добавляем..."

        local backup_file="${sudo_file}.backup.$(date +%Y%m%d_%H%M%S)"
        sudo cp "$sudo_file" "$backup_file" 2>/dev/null && \
            print_info "Создана резервная копия: $backup_file"
    }

    print_info "Создание правил sudo..."
    sudo tee "$sudo_file" > /dev/null << EOF
# Правила для управления Samba (создано smb-install.sh)
# Дата создания: $(date)
# Дистрибутив: $DISTRO

# Управление службами Samba
$USER ALL=(ALL) NOPASSWD: $service_commands

# Монтирование/размонтирование SMB ресурсов
$USER ALL=(ALL) NOPASSWD: $mount_commands

# Запуск скрипта расшаривания папок
$USER ALL=(ALL) NOPASSWD: $script_path
EOF

    [ $? -ne 0 ] && {
        print_error "Не удалось создать правило sudo"
        return 1
    }

    sudo chmod 440 "$sudo_file"

    print_info "Проверка синтаксиса sudoers..."
    sudo visudo -c -f "$sudo_file" >/dev/null 2>&1 || {
        print_error "Ошибка синтаксиса в файле sudoers!"
        [ -f "$backup_file" ] && sudo mv "$backup_file" "$sudo_file"
        return 1
    }

    print_info "✓ Правила sudo успешно созданы: $sudo_file"
    print_info "✓ Разрешено управление службами Samba без пароля"
    print_info "✓ Разрешено монтирование SMB ресурсов без пароля"
    print_info "✓ Разрешено выполнение скрипта расшаривания без пароля"

    echo ""
    print_info "Разрешенные команды:"
    echo "  - systemctl restart smbd/nmbd/smb"
    echo "  - systemctl status smbd/nmbd/smb"
    echo "  - mount/umount/mount.cifs/umount.cifs"
    echo "  - $script_path"

    return 0
}

setup_autostart() {
    [ "$ENABLE_AUTOSTART" != "true" ] && {
        print_info "Настройка автозагрузки отключена в настройках"
        return 0
    }

    local service_file="$HOME/.config/systemd/user/smb-mount.service"
    local script_path="$SCRIPT_DIR/smb-mount.sh"
    local config_path="$SCRIPT_DIR/smb-mount.conf"

    print_info "Настройка автозагрузки SMB-монтирования..."

    [ ! -f "$script_path" ] && {
        print_error "Скрипт монтирования не найден: $script_path"
        return 1
    }

    chmod +x "$script_path"
    mkdir -p "$(dirname "$service_file")"

    cat > "$service_file" << EOF
[Unit]
Description=Mount SMB shares on user login
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$script_path
WorkingDirectory=$SCRIPT_DIR
Environment=CONFIG_FILE=$config_path
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF

    [ $? -ne 0 ] && {
        print_error "Не удалось создать service файл"
        return 1
    }

    systemctl --user daemon-reload 2>/dev/null || {
        print_error "Не удалось перезагрузить демон systemd"
        return 1
    }

    systemctl --user enable smb-mount.service 2>/dev/null || {
        print_error "Не удалось включить автозагрузку"
        return 1
    }

    print_info "Автозагрузка настроена: $service_file"
    enable_linger_if_available
    check_autostart_status
    return 0
}

enable_linger_if_available() {
    command -v loginctl >/dev/null 2>&1 || {
        print_warn "loginctl не найден, используем стандартную автозагрузку user service"
        return 0
    }

    loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=no" && {
        print_info "Обнаружен loginctl, включаем лингерание для надежной автозагрузки..."
        sudo loginctl enable-linger "$USER" 2>/dev/null && \
            print_info "Лингерание включено (Linger=yes)" || \
            print_warn "Не удалось включить лингерание, но служба будет работать после логина"
        return 0
    }

    loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes" && \
        print_info "Лингерание уже включено (Linger=yes)"
}

check_autostart_status() {
    print_info "Проверка статуса автозагрузки..."

    systemctl --user is-enabled smb-mount.service >/dev/null 2>&1 && \
        print_info "✓ Служба автозагрузки включена" || {
        print_error "✗ Служба автозагрузки не включена"
        return 1
    }

    command -v loginctl >/dev/null 2>&1 && {
        local linger_status=$(loginctl show-user "$USER" 2>/dev/null | grep "Linger=" | cut -d= -f2)
        [ "$linger_status" = "yes" ] && \
            print_info "✓ Лингерание включено - автозагрузка при старте системы" || \
            print_warn "⚠ Лингерание отключено - автозагрузка только после логина пользователя"
    }

    systemctl --user list-dependencies smb-mount.service --reverse >/dev/null 2>&1 && \
        print_info "✓ Зависимости службы настроены корректно"

    return 0
}

diagnose_autostart() {
    print_info "=== ДИАГНОСТИКА АВТОЗАГРУЗКИ ==="

    local service_file="$HOME/.config/systemd/user/smb-mount.service"
    [ -f "$service_file" ] && \
        print_info "✓ Service файл существует: $service_file" || \
        print_error "✗ Service файл не существует"

    systemctl --user is-enabled smb-mount.service >/dev/null 2>&1 && \
        print_info "✓ Служба включена в автозагрузку" || \
        print_error "✗ Служба не включена в автозагрузку"

    command -v loginctl >/dev/null 2>&1 && {
        local linger_status=$(loginctl show-user "$USER" 2>/dev/null | grep "Linger=" | cut -d= -f2 || echo "unknown")
        print_info "Лингерание: $linger_status"
    }

    echo ""
    print_info "Рекомендации:"
    echo "  - Перезагрузите систему для проверки автозагрузки"
    echo "  - После перезагрузки выполните: ./smb-mount.sh"
    echo "  - Если скажет 'Уже смонтировано' - автозагрузка работает"
}

# === ОСНОВНАЯ ФУНКЦИЯ ===

main() {
    # Инициализация
    SCRIPT_DIR=$(get_script_dir)
    BACKUP_DIR="$SCRIPT_DIR/backups"
    DISTRO=$(detect_distro)

    # Заголовок
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

    # Основной процесс
    check_sudo
    install_samba_packages
    backup_smb_config
    create_sudo_rules
    enable_samba_services
    setup_autostart

    # Итоги
    echo ""
    print_info "=== Установка завершена успешно! ==="
    echo ""
    echo "Что было сделано:"
    echo "  - Установлены пакеты Samba"
    [ "$BACKUP_ORIGINAL_CONFIG" = "true" ] && \
        echo "  - Создана резервная копия: $BACKUP_DIR/smb.conf.original"
    [ "$ENABLE_SUDO_RULES" = "true" ] && \
        echo "  - Добавлены правила sudo для монтирования без пароля"
    [ "$ENABLE_AUTOSTART" = "true" ] && \
        echo "  - Настроена автозагрузка монтирования"
    echo "  - Запущены службы Samba"
    echo ""
    echo "Следующие шаги:"
    echo "  1. Отредактируйте smb-mount.conf для настройки монтирования"
    echo "  2. Для монтирования: ./smb-mount.sh"
    echo "  3. Для размонтирования: ./smb-umount.sh"
    echo ""
    print_info "Не забудьте настроить smb-mount.conf перед использованием!"

    # Диагностика в самом конце
    diagnose_autostart
}

# === ТОЧКА ВХОДА ===
main "$@"
