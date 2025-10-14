#!/bin/bash

set -e

PROJECT_ROOT="$(pwd)"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для цветного вывода
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Функция проверки и установки Docker
check_and_install_docker() {
    # Проверяем, установлен ли Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker не установлен"
        print_info "Начинаю установку Docker..."
        
        # Установка Docker
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        
        # Даем время на установку
        sleep 5
    else
        print_success "Docker уже установлен"
    fi
    
    # Проверяем, установлен ли Docker Compose
    if ! command -v docker-compose &> /dev/null && ! command -v docker compose &> /dev/null; then
        print_warning "Docker Compose не установлен"
        print_info "Устанавливаем Docker Compose..."
        
        # Установка Docker Compose
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        
        # Создаем симлинк для старой версии
        if [ ! -f "/usr/bin/docker-compose" ]; then
            sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
        fi
    else
        print_success "Docker Compose уже установлен"
    fi
    
    # Улучшенная проверка Docker демона
    check_docker_daemon() {
        # Пробуем разные способы проверки
        if timeout 5 docker info > /dev/null 2>&1; then
            return 0
        fi
        
        # Пробуем запустить через systemd
        if sudo systemctl is-active --quiet docker 2>/dev/null; then
            return 0
        fi
        
        # Пробуем запустить напрямую
        if pgrep -f dockerd > /dev/null; then
            return 0
        fi
        
        return 1
    }
    
    # Проверяем Docker демон
    if ! check_docker_daemon; then
        print_warning "Docker демон не запущен"
        print_info "Пытаемся запустить Docker демон..."
        
        # Пробуем разные способы запуска
        
        # Способ 1: systemd (если доступен)
        if command -v systemctl &> /dev/null && [ -f "/lib/systemd/system/docker.service" ]; then
            sudo systemctl start docker
            sudo systemctl enable docker
            sleep 3
        fi
        
        # Способ 2: Прямой запуск dockerd
        if ! check_docker_daemon; then
            print_info "Запускаем Docker демон напрямую..."
            sudo nohup dockerd > /var/log/dockerd.log 2>&1 &
            sleep 5
        fi
        
        # Способ 3: Проверяем через socket
        if ! check_docker_daemon; then
            print_info "Проверяем Docker socket..."
            if [ -S "/var/run/docker.sock" ]; then
                sudo chmod 666 /var/run/docker.sock
            fi
        fi
        
        # Финальная проверка
        if ! check_docker_daemon; then
            print_error "Не удалось запустить Docker демон"
            print_info "Попробуйте выполнить вручную: sudo dockerd &"
            print_info "Или переустановите Docker: curl -fsSL https://get.docker.com | sh"
            exit 1
        fi
    fi
    
    # Проверяем, что можем выполнять docker команды
    if ! docker ps > /dev/null 2>&1; then
        print_error "Нет доступа к Docker демону"
        print_info "Добавляем пользователя в группу docker..."
        sudo usermod -aG docker $USER
        print_warning "Требуется перезапуск сессии"
        print_info "Выполните: newgrp docker"
        print_info "Или перезапустите терминал"
        exit 1
    fi
    
    print_success "Docker готов к работе"
}

# Проверяем и устанавливаем Docker в самом начале
print_info "Проверка Docker..."
check_and_install_docker

# Функция для загрузки переменных из .env
load_env() {
    if [ -f .env ]; then
        set -a
        source .env
        set +a
        print_success "Переменные из .env загружены"
    else
        print_warning "Файл .env не найден, будет создан новый"
    fi
}

# Функция для сохранения переменных в .env
save_env() {
    local env_file=".env"
    
    # Создаем или очищаем файл
    > "$env_file"
    
    # Сохраняем все переданные переменные
    for var in "$@"; do
        eval "echo \"$var=\${$var}\"" >> "$env_file"
    done
    
    print_success "Конфигурация сохранена в .env"
}

# Функция для генерации случайного пароля
generate_password() {
    local length=${1:-16}
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

# Функция проверки доступности порта
check_port_available() {
    local port=$1
    
    # Проверяем, что порт является числом
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 2
    fi
    
    # Проверяем диапазон порта
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 2
    fi
    
    # Пробуем разные методы проверки порта
    local port_in_use=0
    
    # Метод 1: Используем ss (самый быстрый и надежный)
    if command -v ss &> /dev/null; then
        if ss -tulpn | grep -q ":${port}[[:space:]]"; then
            port_in_use=1
        fi
    # Метод 2: Используем netstat (альтернатива)
    elif command -v netstat &> /dev/null; then
        if netstat -tulpn 2>/dev/null | grep -q ":${port}[[:space:]]"; then
            port_in_use=1
        fi
    # Метод 3: Используем lsof
    elif command -v lsof &> /dev/null; then
        if lsof -i :"$port" &> /dev/null; then
            port_in_use=1
        fi
    # Метод 4: Пробуем bind к порту (универсальный, но медленнее)
    else
        if timeout 2 bash -c "echo > /dev/tcp/localhost/$port" 2>/dev/null; then
            port_in_use=1
        else
            # Если команда завершилась с ошибкой, порт скорее всего свободен
            port_in_use=0
        fi
    fi
    
    return $port_in_use
}

# Загружаем существующие переменные если есть
load_env

# Функция для настройки автозапуска
setup_autostart() {
    local enable_autostart="$1"
    
    if [[ "$enable_autostart" =~ ^[Yy]$ ]]; then
        print_info "Настройка автозапуска при загрузке системы..."
        
        # Создаем systemd сервис
        sudo tee /etc/systemd/system/docker-compose-app.service > /dev/null << EOF
[Unit]
Description=Docker Compose Application Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$(pwd)
ExecStart=$(which docker-compose) up -d
ExecStop=$(which docker-compose) down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

        # Даем права на сервис
        sudo chmod 644 /etc/systemd/system/docker-compose-app.service
        
        # Включаем сервис
        sudo systemctl daemon-reload
        sudo systemctl enable docker-compose-app.service
        
        print_success "Автозапуск включен. Сервис будет запускаться при загрузке системы."
        
        # Сохраняем статус автозапуска
        echo "AUTOSTART_ENABLED=true" >> .env
    else
        # Отключаем автозапуск если был включен
        if systemctl is-enabled docker-compose-app.service 2>/dev/null | grep -q enabled; then
            sudo systemctl disable docker-compose-app.service
            print_success "Автозапуск отключен"
        fi
        echo "AUTOSTART_ENABLED=false" >> .env
        print_info "Автозапуск отключен"
    fi
}

# Проверка зависимостей
check_dependencies() {
    local deps=("docker" "docker-compose" "git" "curl")
    local needs_install=()  # Массив для зависимостей, требующих установки
    local failed_installs=()  # Для сбойных установок

    # Функция для определения менеджера пакетов и ОС
    detect_package_manager() {
        if command -v apt &> /dev/null; then
            echo "apt"
        elif command -v dnf &> /dev/null; then
            echo "dnf"
        elif command -v yum &> /dev/null; then
            echo "yum"
        elif command -v pacman &> /dev/null; then
            echo "pacman"
        elif command -v brew &> /dev/null; then
            echo "brew"
        else
            echo "unknown"
        fi
    }

    local pkg_manager=$(detect_package_manager)
    local install_cmd=""

    # Определить команду установки в зависимости от менеджера
    case $pkg_manager in
        apt)
            install_cmd="sudo apt update && sudo apt install -y"
            ;;
        dnf)
            install_cmd="sudo dnf install -y"
            ;;
        yum)
            install_cmd="sudo yum install -y"
            ;;
        pacman)
            install_cmd="sudo pacman -S --noconfirm"
            ;;
        brew)
            install_cmd="brew install"
            ;;
        *)
            print_error "Автоматическая установка не поддерживается для вашего дистрибутива. Пожалуйста, установите зависимости вручную."
            return 1
            ;;
    esac

    # Проверка и сбор отсутствующих зависимостей
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            needs_install+=("$dep")
        fi
    done

    # Если всё установлено, выход с успехом
    if [ ${#needs_install[@]} -eq 0 ]; then
        print_success "Все зависимости установлены"
        return 0
    fi

    # Для каждого отсутствующего dep: спросить и установить
    for dep in "${needs_install[@]}"; do
        print_error "Необходима установка: $dep"
        read -p "Установить? (y/n): " -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            echo "Попытка установить $dep..."
            if eval "$install_cmd $dep"; then
                print_success "$dep успешно установлен"
            else
                print_error "Не удалось установить $dep"
                failed_installs+=("$dep")
            fi
        else
            print_error "Установка $dep пропущена пользователем"
            failed_installs+=("$dep")
        fi
    done

    # Итоговый отчёт
    if [ ${#failed_installs[@]} -eq 0 ]; then
        print_success "Все зависимости установлены"
        return 0
    else
        print_error "Не удалось установить следующие зависимости: ${failed_installs[*]}. Проверьте вручную."
        return 1
    fi
}

print_info "Проверка зависимостей..."
check_dependencies || exit 1

# Функция для отправки сообщений в Telegram
send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        # Экранируем специальные символы для JSON
        local escaped_message=$(echo "$message" | sed 's/"/\\"/g' | sed 's/\\$/\\\\$/g')
        
        # Временный файл для полного ответа
        local response_file=$(mktemp)
        trap 'rm -f "$response_file"' EXIT
        
        print_info "Отправка сообщения в Telegram..."
        
        # Выполняем запрос с полным выводом
        local result=$(curl -s -w "\n%{http_code}" -X POST \
            -H 'Content-Type: application/json' \
            -d "{\"chat_id\": \"$TELEGRAM_CHAT_ID\", \"text\": \"$escaped_message\", \"parse_mode\": \"HTML\"}" \
            "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" 2>&1)
        
        local http_code=$(echo "$result" | tail -1)
        local response_body=$(echo "$result" | head -n -1)
        
        if [ "$http_code" -eq 200 ]; then
            print_success "✅ Сообщение отправлено в Telegram"
        else
            print_error "❌ Ошибка Telegram API (код: $http_code)"
            if [ -n "$response_body" ]; then
                print_info "Ответ: $response_body"
            fi
            
            # Распространенные ошибки
            case $http_code in
                400) print_error "Некорректный запрос - проверьте формат сообщения" ;;
                401) print_error "Неавторизован - проверьте TELEGRAM_BOT_TOKEN" ;;
                403) print_error "Запрещено - бот заблокирован пользователем" ;;
                404) print_error "Не найден - проверьте TELEGRAM_CHAT_ID" ;;
                429) print_error "Слишком много запросов - превышен лимит" ;;
            esac
        fi
    else
        print_warning "⚠️  Telegram не настроен"
    fi
}

# Функция для отправки файла в Telegram
send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && [ -f "$file_path" ]; then
        curl -s -F "chat_id=$TELEGRAM_CHAT_ID" \
            -F "document=@$file_path" \
            -F "caption=$caption" \
            "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" > /dev/null 2>&1
    fi
}



# Создаем необходимые директории
echo ""

print_info "Создание структуры директорий..."

# Проверяем текущую директорию
CURRENT_DIR=$(pwd)
print_info "Текущая директория: $CURRENT_DIR"

# Создаем директории по одной с проверкой
for dir in php tdlib wwwdata logs logs/tdlib mysql nginx nginx/conf.d; do
    if mkdir -p "$dir"; then
        print_success "Создана директория: $dir"
    else
        print_error "Не удалось создать директорию: $dir"
        exit 1
    fi
done

echo -e "${BLUE}🐳 Настройка Docker окружения: PHP 8.4 + Nginx + MySQL + Local Telegram Bot API Server${NC}"

# Настройка Telegram уведомлений
echo ""
print_info "Настройка Telegram уведомлений"
read -p "Токен бота Telegram (Enter чтобы пропустить): " TELEGRAM_BOT_TOKEN

if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    read -p "ID чата/пользователя Telegram: " TELEGRAM_CHAT_ID
    if [ -n "$TELEGRAM_CHAT_ID" ]; then
        print_success "Telegram уведомления активированы"
    else
        print_warning "ID чата не указан - Telegram уведомления отключены"
        TELEGRAM_BOT_TOKEN=""
    fi
else
    print_info "Telegram уведомления отключены"
fi

# Настройка автозапуска
echo ""
print_info "Настройка автозапуска при перезагрузке сервера"
read -p "Включить автозапуск при загрузке системы? (Y/n , ENTER - нет): " enable_autostart
enable_autostart=${enable_autostart:-y}

# Настройка Telegram Bot API
echo ""
print_info "Настройка Local Telegram Bot API server(aiogram)"
read -p "TELEGRAM_API_ID (нажмите Enter чтобы пропустить установку): " TELEGRAM_API_ID
if [ -n "$TELEGRAM_API_ID" ]; then
    read -p "TELEGRAM_API_HASH: " TELEGRAM_API_HASH
        if [ -n "$TELEGRAM_API_HASH" ]; then
        print_success "Telegram Bot API будет установлен"
        install_telegram_api="y"
        TELEGRAM_STAT_PORT="8082"
        TELEGRAM_HTTP_PORT="8081"
    else
        print_error "API HASH обязателен для установки Telegram Bot API"
        install_telegram_api="n"
    fi
else
    print_info "Установка Telegram Bot API пропущена"
    install_telegram_api="n"
fi

# Настройка GitHub
echo ""
print_info "Настройка доступа к GitHub"
read -p "URL репозитория GitHub (Enter чтобы пропустить): " GITHUB_REPO

# Запрос доменного имени и SSL
read -p "Доменное имя (пусто = localhost): " domain_name
domain_name=${domain_name:-localhost}

read -p "Включить SSL? (y/N): " enable_ssl
enable_ssl=${enable_ssl:-n}

# Запрос порта для приложения
read -p "Порт для HTTP приложения (пусто = 8080): " http_port
http_port=${http_port:-8080}

# Валидация порта
print_info "Валидация порта"
while ! [[ "$http_port" =~ ^[0-9]+$ ]] || [ "$http_port" -lt 1 ] || [ "$http_port" -gt 65535 ]; do
    print_error "Некорректный порт: $http_port"
    read -p "Введите порт (1-65535): " http_port
done

# Проверка что порт свободен
print_info "Проверка что порт свободен"
if ! check_port_available "$http_port"; then
    print_warning "Порт $http_port уже занят"
    read -p "Продолжить? (может привести к конфликту) (y/N): " continue_with_used_port
    if [[ ! "$continue_with_used_port" =~ ^[Yy]$ ]]; then
        print_error "Прервано пользователем"
        exit 1
    fi
else
    print_success "Порт $http_port свободен"
fi

# Запрос установки Xdebug
read -p "Установить Xdebug? (y/N): " install_xdebug
install_xdebug=${install_xdebug:-n}

# Если Xdebug устанавливается, запрашиваем IP для отладки
if [[ "$install_xdebug" =~ ^[Yy]$ ]]; then
    install_xdebug="y" 
    echo ""
    print_info "Настройка Xdebug для удаленной отладки"
    echo "   Для локальной разработки: 127.0.0.1 или localhost"
    echo "   Для удаленной IDE: IP вашего компьютера"
    echo "   Для отключения отладки: 0.0.0.0"
    
    read -p "   IP для отладки Xdebug (пусто = host.docker.internal): " xdebug_host
    xdebug_host=${xdebug_host:-host.docker.internal}
    
    read -p "Порт Xdebug (пусто = 9003): " xdebug_port
    xdebug_port=${xdebug_port:-9003}
    
    read -p "IDE Key (пусто = PHPSTORM): " xdebug_idekey
    xdebug_idekey=${xdebug_idekey:-PHPSTORM}
    
    print_info "Xdebug будет подключаться к: $xdebug_host:$xdebug_port"
else
    install_xdebug="n"
fi

# Запрос о выставлении порта MySQL наружу
read -p "Выставить порт MySQL наружу? (y/N): " expose_mysql
expose_mysql=${expose_mysql:-n}

# Запрос пароля MySQL
read -p "Пароль для MySQL root пользователя (пусто = сгенерировать автоматически): " mysql_root_password
if [ -z "$mysql_root_password" ]; then
    mysql_root_password=$(generate_password 16)
    print_success "Сгенерирован пароль MySQL root (сохранен в .env)"
fi

# Запрос названия базы данных
read -p "Название базы данных (пусто = app_db): " mysql_database
mysql_database=${mysql_database:-app_db}

read -p "Имя пользователя MySQL (пусто = app_user): " mysql_user
mysql_user=${mysql_user:-app_user}

read -p "Пароль пользователя MySQL (пусто = сгенерировать автоматически): " mysql_password
if [ -z "$mysql_password" ]; then
    mysql_password=$(generate_password 16)
    print_success "Сгенерирован пароль пользователя MySQL (сохранен в .env)"
fi

# Получаем IP VPS
vps_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "неизвестно")

# СОХРАНЯЕМ ВСЕ ПЕРЕМЕННЫЕ В .env СЕЙЧАС ЖЕ
print_info "Сохранение конфигурации в .env..."
save_env \
    "PROJECT_ROOT" \
    "TELEGRAM_BOT_TOKEN" \
    "TELEGRAM_CHAT_ID" \
    "enable_autostart" \
    "install_telegram_api" \
    "TELEGRAM_API_ID" \
    "TELEGRAM_API_HASH" \
    "TELEGRAM_STAT_PORT" \
    "TELEGRAM_HTTP_PORT" \
    "GITHUB_REPO" \
    "domain_name" \
    "enable_ssl" \
    "http_port" \
    "install_xdebug" \
    "xdebug_host" \
    "xdebug_port" \
    "xdebug_idekey" \
    "expose_mysql" \
    "mysql_root_password" \
    "mysql_database" \
    "mysql_user" \
    "mysql_password" \
    "vps_ip"

# Перезагружаем переменные из .env
load_env

if [ -n "$GITHUB_REPO" ]; then
    # Проверяем или создаем пользователя github
    if id "github" &>/dev/null; then
        print_success "Пользователь 'github' уже существует"
    else
        print_info "Создание пользователя 'github'"
        if sudo useradd -m -s /bin/bash github; then
            print_success "Пользователь 'github' создан"
        else
            print_error "Не удалось создать пользователя 'github'"
            exit 1
        fi
    fi
    
    # Теперь настраиваем права (ПОСЛЕ создания пользователя)
    print_info "Настройка прав доступа для пользователя github..."
    sudo chown -R github:github "$PROJECT_ROOT/wwwdata/" 
    sudo chown -R github:github "$PROJECT_ROOT/tdlib/"
    sudo chown -R github:github "$PROJECT_ROOT/logs/"
    sudo chmod -R 755 "$PROJECT_ROOT/wwwdata/" "$PROJECT_ROOT/tdlib/" "$PROJECT_ROOT/logs/"
    print_success "Права доступа для пользователя github настроены"
    
    # Переключаемся на пользователя github
    sudo -u github mkdir -p /home/github/.ssh
    SSH_KEY_PATH="/home/github/.ssh/id_rsa"
    PUB_KEY_PATH="/home/github/.ssh/id_rsa.pub"
    
    # Проверяем или создаем SSH ключ
    if [ ! -f "$SSH_KEY_PATH" ]; then
        print_info "Создание SSH ключа для пользователя github"
        sudo -u github ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
        print_success "SSH ключ создан"
    else
        print_success "SSH ключ уже существует"
    fi
    
    # Показываем публичный ключ
    echo ""
    print_warning "ДОБАВЬТЕ ЭТОТ SSH КЛЮЧ В VАШ GitHub АККАУНТ:"
    echo "=========================================="
    sudo cat "$PUB_KEY_PATH"
    echo "=========================================="
    echo ""
    
    # Отправляем ключ в Telegram если настроено
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        print_info "Отправка SSH ключа в Telegram..."
        
        # Читаем публичный ключ
        PUB_KEY_CONTENT=$(sudo cat "$PUB_KEY_PATH")
        
        # Формируем сообщение с ключом внутри тега <code>
        TELEGRAM_MESSAGE="🔑 <b>SSH ключ для GitHub</b>\n\n"
        TELEGRAM_MESSAGE+="Добавьте этот ключ в ваш GitHub аккаунт:\n"
        TELEGRAM_MESSAGE+="Settings → SSH and GPG keys → New SSH key\n\n"
        TELEGRAM_MESSAGE+="<code>$PUB_KEY_CONTENT</code>\n\n"
        TELEGRAM_MESSAGE+="💡 <i>Скопируйте содержимое выше и вставьте в GitHub</i>"
        
        # Отправляем сообщение
        send_telegram "$TELEGRAM_MESSAGE"
        print_success "SSH ключ отправлен в Telegram в виде текста"
    fi
    
    read -p "Нажмите Enter после добавления ключа в GitHub..."
    
    # Клонируем репозиторий
    print_info "Клонирование репозитория: $GITHUB_REPO"
    TEMP_CLONE_DIR="/tmp/github_clone_$$"

    # Добавляем временную директорию в безопасные для Git
    sudo -u github git config --global --add safe.directory "$TEMP_CLONE_DIR"
    git config --global --add safe.directory "$TEMP_CLONE_DIR"

    # Пробуем клонировать с SSH
    print_info "Попытка клонирования через SSH..."
    echo "Текущая директория: $(pwd)"
    if sudo -u github git clone --progress "$GITHUB_REPO" "$TEMP_CLONE_DIR"; then
        print_success "Репозиторий успешно клонирован через SSH"
    else
        print_warning "SSH клонирование не удалось, пробуем HTTPS..."
        # Если SSH не работает, пробуем HTTPS
        if git clone --progress "$GITHUB_REPO" "$TEMP_CLONE_DIR"; then
            print_success "Репозиторий клонирован через HTTPS"
        else
            print_error "Не удалось клонировать репозиторий"
            exit 1
        fi
    fi
    
    # Проверка успешности клонирования
    if [ ! -d "$TEMP_CLONE_DIR" ] || [ -z "$(ls -A "$TEMP_CLONE_DIR" 2>/dev/null)" ]; then
        print_error "Не удалось клонировать репозиторий или репозиторий пуст"
        exit 1
    fi
    
    # Получаем список веток
    cd "$TEMP_CLONE_DIR"
    BRANCHES=$(git branch -r | grep -v HEAD | sed 's/origin\///' | tr -d ' ')
    
    echo ""
    print_info "Доступные ветки:"
    echo "$BRANCHES" | nl -w2 -s'. '
    echo ""
    
    read -p "Выберите ветку (номер или имя, пусто = main): " branch_choice
    
    if [ -n "$branch_choice" ]; then
        if [[ "$branch_choice" =~ ^[0-9]+$ ]]; then
            # Выбор по номеру
            BRANCH_NAME=$(echo "$BRANCHES" | sed -n "${branch_choice}p")
        else
            # Выбор по имени
            BRANCH_NAME="$branch_choice"
        fi
    else
        BRANCH_NAME="main"
    fi
    
    # Переключаемся на выбранную ветку
    if git checkout "$BRANCH_NAME" 2>/dev/null || git checkout -b "$BRANCH_NAME" "origin/$BRANCH_NAME" 2>/dev/null; then
        print_success "Переключено на ветку: $BRANCH_NAME"
    else
        print_warning "Не удалось переключиться на ветку $BRANCH_NAME, используется текущая"
    fi
    
    # Копируем файлы в папку приложения
    print_info "Копирование файлов в папку приложения..."

    cd "$PROJECT_ROOT"
    cp -r "$TEMP_CLONE_DIR"/* wwwdata/ 2>/dev/null || true
    cp -r "$TEMP_CLONE_DIR"/.* wwwdata/ 2>/dev/null || true
    
    # Очищаем временные файлы
    rm -rf "$TEMP_CLONE_DIR"
    print_success "Файлы проекта скопированы в папку wwwdata"
else
    print_info "Используется стандартная структура приложения"
    cd "$PROJECT_ROOT"
    mkdir -p wwwdata/public
fi









# Создаем конфигурацию nginx
print_info "Создание конфигурации nginx..."

cat > nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Gzip Settings
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # Включаем файлы конфигурации
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/snippets/*.conf;
}
EOF

cat > nginx/conf.d/app.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/public;
    index index.php index.html;

    access_log /var/log/nginx/app.access.log;
    error_log /var/log/nginx/app.error.log;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }
}
EOF

print_success "Конфигурация nginx создана"

# Создаем Dockerfile для PHP 8.4
print_info "Создание Dockerfile для PHP..."

cat > php/Dockerfile << 'EOF'
FROM php:8.4-fpm

# Системные зависимости
RUN apt-get update && apt-get install -y \
    git curl libpng-dev libonig-dev libxml2-dev \
    zip unzip libzip-dev default-mysql-client \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# PHP расширения
RUN docker-php-ext-install \
    pdo_mysql mbstring exif pcntl bcmath gd zip sockets

# Условная установка Xdebug
ARG INSTALL_XDEBUG=false
RUN if [ "$INSTALL_XDEBUG" = "true" ]; then \
    pecl install xdebug && \
    docker-php-ext-enable xdebug && \
    echo "xdebug.mode=debug" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
    echo "xdebug.client_host=host.docker.internal" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
    echo "xdebug.client_port=9003" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini; \
    echo " .... ....  Xdebug YCTAHOBLEH и активирован .... ....  "; \
else \
    echo " .... ....  Xdebug HE устанавливается .... ....  "; \
    fi

WORKDIR /var/www
RUN chown -R www-data:www-data /var/www && \
    usermod -u 1000 www-data

CMD ["php-fpm"]
EOF

# Добавляем Xdebug конфигурацию если нужно
if [[ "$install_xdebug" =~ ^[Yy]$ ]]; then
    print_info "Добавление Xdebug в Dockerfile..."
    cat > php/xdebug.ini << EOF
zend_extension=xdebug

; Основные настройки - АКТИВАЦИЯ ПРИ КАЖДОМ ЗАПРОСЕ
xdebug.mode=develop, profile, trace, coverage, gcstats, debug 
xdebug.start_with_request=yes
xdebug.discover_client_host=0

; Подключение к IDE
xdebug.client_host=$xdebug_host
xdebug.client_port=$xdebug_port
xdebug.idekey=$xdebug_idekey

; Настройки для отладки
xdebug.log=/var/log/xdebug.log
xdebug.log_level=12

; Оптимизация производительности
xdebug.max_nesting_level=512
xdebug.var_display_max_children=128
xdebug.var_display_max_data=512
xdebug.var_display_max_depth=5
EOF

    # Добавляем копирование xdebug.ini в Dockerfile
    cat >> php/Dockerfile << EOF

# Копирование конфигурации Xdebug
COPY xdebug.ini /usr/local/etc/php/conf.d/xdebug.ini
EOF

    print_success "Xdebug настроен для автозапуска при каждом запросе"
else
    rm -f php/xdebug.ini
    print_info "Xdebug не будет установлен"
fi

# Создаем docker-compose.yml с подгрузкой переменных из .env
print_info "Создание docker-compose.yml..."

# Настройка портов MySQL
mysql_ports=""
if [[ "$expose_mysql" =~ ^[Yy]$ ]]; then
    mysql_ports="    ports:
      - \"3306:3306\""
    print_warning "Порт MySQL будет открыт наружу"
else
    print_info "Порт MySQL будет закрыт (доступ только внутри Docker сети)"
fi

# Базовый docker-compose.yml с переменными окружения
cat > docker-compose.yml << 'EOF'
services:
  nginx:
    image: nginx:alpine
    container_name: php_nginx
    ports:
      - "${http_port}:80"
    volumes:
      - ./wwwdata:/var/www
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d/:/etc/nginx/conf.d/:ro
      - ./logs/nginx:/var/log/nginx
EOF

# Добавляем SSL volumes если нужно
if [[ "$enable_ssl" =~ ^[Yy]$ ]]; then
    cat >> docker-compose.yml << EOF
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF
fi

cat >> docker-compose.yml << 'EOF'
    depends_on:
      - php
    networks:
      - app-network
    env_file:
      - .env

  php:
    build: 
      context: ./php
      args:
        - PROJECT_ROOT=${PROJECT_ROOT}
        - INSTALL_XDEBUG=${install_xdebug}
    container_name: php_app
    networks:
      - app-network
    volumes:
      - ./wwwdata:/var/www
      - ./logs/php:/var/log/
      - ./tdlib:/var/www/.tdlib
EOF

if [[ "$install_xdebug" =~ ^[Yy]$ ]]; then
    cat >> docker-compose.yml << EOF
      - ./php/xdebug.ini:/usr/local/etc/php/conf.d/xdebug.ini
    environment:
      - PHP_IDE_CONFIG=serverName=Docker
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
fi

# Добавляем Telegram Bot API если нужно
if [[ "$install_telegram_api" =~ ^[Yy]$ ]]; then
    cat >> docker-compose.yml << 'EOF'

  telegram-api:
    image: aiogram/telegram-bot-api:latest
    container_name: telegram_bot_api
    environment:
      - TELEGRAM_API_ID=${TELEGRAM_API_ID}
      - TELEGRAM_API_HASH=${TELEGRAM_API_HASH}
      - TELEGRAM_STAT_PORT=${TELEGRAM_STAT_PORT}
      - TELEGRAM_HTTP_PORT=${TELEGRAM_HTTP_PORT}
      - TELEGRAM_VERBOSITY=9
      - TELEGRAM_LOG=./tdlib-log.txt
    volumes:
      - ./tdlib:/var/telegram-bot-api
    networks:
      - app-network
    restart: unless-stopped
    env_file:
      - .env
EOF
fi

cat >> docker-compose.yml << EOF
    
  mysql:
    image: mysql:8.0
    container_name: php_mysql
    command: --default-authentication-plugin=mysql_native_password
    environment:
      MYSQL_ROOT_PASSWORD: \${mysql_root_password}
      MYSQL_DATABASE: \${mysql_database}
      MYSQL_USER: \${mysql_user}
      MYSQL_PASSWORD: \${mysql_password}
$mysql_ports
    volumes:
      - mysql_data:/var/lib/mysql
      - ./mysql/:/docker-entrypoint-initdb.d/
    networks:
      - app-network
    env_file:
      - .env

volumes:
  mysql_data:

networks:
  app-network:
    driver: bridge
EOF

# Создаем базовое приложение если не было клонирования с GitHub
if [ -z "$GITHUB_REPO" ]; then
    print_info "Создание базовой структуры приложения..."
    mkdir -p wwwdata/public
    
    cat > wwwdata/public/index.php << EOF
<?php
echo "<h1>🚀 Приложение запущено!</h1>";
echo "<p>Доменное имя: <strong>$domain_name</strong></p>";

// Проверка Xdebug
if (function_exists('xdebug_info')) {
    echo "<h2 style='color: green;'>✅ Xdebug активен!</h2>";
} else {
    echo "<h2 style='color: orange;'>⚠️ Xdebug не активен</h2>";
}

// Тест подключения к MySQL
try {
    \$pdo = new PDO(
        'mysql:host=mysql;dbname=$mysql_database',
        '$mysql_user',
        '$mysql_password'
    );
    echo "<h2 style='color: green;'>✅ Подключение к MySQL успешно!</h2>";
} catch (PDOException \$e) {
    echo "<h2 style='color: red;'>❌ Ошибка подключения к MySQL: " . \$e->getMessage() . "</h2>";
}

// Проверка доступа к Telegram Bot API
if (file_exists('/var/www/.tdlib/tdlib-log.txt')) {
    echo "<h2 style='color: green;'>✅ Telegram Bot API доступен</h2>";
    echo "<p>Файлы TDLib находятся в: /var/www/.tdlib/</p>";
} else {
    echo "<h2 style='color: orange;'>⚠️ Telegram Bot API не настроен</h2>";
}
?>
EOF

    # Создаем пример использования Telegram Bot API
    cat > wwwdata/public/telegram_example.php << 'EOF'
<?php
// Пример работы с Telegram Bot API через PHP
$telegramStatUrl = "http://telegram-api:8082";
$telegramApiUrl = "http://telegram-api:8081";

echo "<h1>📱 Telegram Bot API Example</h1>";

// Попытка получить статистику
$context = stream_context_create(['http' => ['timeout' => 5]]);
$stats = @file_get_contents($telegramStatUrl, false, $context);

if ($stats !== false) {
    echo "<h2 style='color: green;'>✅ Статистика Telegram Bot API:</h2>";
    echo "<pre>" . htmlspecialchars($stats) . "</pre>";
} else {
    echo "<h2 style='color: orange;'>⚠️ Не удалось получить статистику</h2>";
    echo "<p>Проверьте что сервис telegram-api запущен</p>";
}

// Проверка наличия файлов TDLib
$tdlibPath = '/var/www/.tdlib';
if (is_dir($tdlibPath)) {
    echo "<h2>📁 Файлы TDLib:</h2>";
    $files = scandir($tdlibPath);
    echo "<ul>";
    foreach ($files as $file) {
        if ($file !== '.' && $file !== '..') {
            $filePath = $tdlibPath . '/' . $file;
            $fileSize = is_file($filePath) ? filesize($filePath) : 'dir';
            echo "<li>$file ($fileSize)</li>";
    }
    }
    echo "</ul>";
}
?>
EOF
fi

# Даем права на tdlib папку
chmod -R 755 tdlib
chmod -R 755 logs

print_info "Сборка и запуск контейнеров..."
docker-compose down 2>/dev/null || true

# Умная сборка с кешированием
if [ ! -f ".built" ] || [ php/Dockerfile -nt .built ]; then
    docker-compose build
    touch .built
else
    print_success "Используется кеш сборки"
fi

docker-compose up -d

print_info "Ожидание запуска сервисов..."
sleep 10

# Проверка здоровья сервисов
print_info "Проверка здоровья сервисов..."
if ! docker-compose ps | grep -q "Up"; then
    print_error "Не все контейнеры запустились"
    docker-compose logs
    exit 1
fi

# Проверка доступности nginx
if curl -s -f "http://localhost:$http_port" > /dev/null; then
    print_success "Nginx отвечает на порту $http_port"
else
    print_warning "Nginx пока не отвечает (возможно еще запускается)"
fi

# Настраиваем автозапуск
setup_autostart "$enable_autostart"

# Проверяем статус
print_info "Проверка статуса контейнеров..."
docker-compose ps

# Обновляем .env с дополнительными переменными
cat >> .env << EOF
AUTOSTART_ENABLED=$([ "$enable_autostart" = [yY] ] && echo "true" || echo "false")
SSL_ENABLED=$([ "$enable_ssl" = [yY] ] && echo "true" || echo "false")
SSL_DOMAIN=$domain_name
XDEBUG_ENABLED=$install_xdebug
MYSQL_EXPOSED=$expose_mysql
TELEGRAM_API_ENABLED=$install_telegram_api
EOF

# Формируем отчет
REPORT_FILE="/tmp/docker_setup_report_$$.txt"
cat > "$REPORT_FILE" << EOF
🎉 НАСТРОЙКА ЗАВЕРШЕНА

📊 КОНФИГУРАЦИЯ:
🌐 Доменное имя: $domain_name
🔗 HTTP порт приложения: $http_port
🔐 SSL: $([ "$enable_ssl" = [yY] ] && echo "включен (Let's Encrypt)" || echo "отключен")

🗃️ MYSQL:
   База данных: $mysql_database
   Пользователь: $mysql_user
   Пароль пользователя: $mysql_password
   Root пароль: $mysql_root_password
   Порт: $([ "$expose_mysql" = [yY] ] && echo "открыт (3306)" || echo "закрыт")

🐛 XDEBUG: $([[ $install_xdebug = [yY] ]] && echo "активен ($xdebug_host:$xdebug_port)" || echo "не активен")

🤖 TELEGRAM BOT API: $([[ $install_telegram_api = [yY] ]] && echo "УСТАНОВЛЕН" || echo "НЕ установлен")
   $([[ $install_telegram_api = [yY] ]]  && echo "   Stat порт: $TELEGRAM_STAT_PORT (внутренний)" || "")
   $([[ $install_telegram_api = [yY] ]]  && echo "   HTTP порт: $TELEGRAM_HTTP_PORT (внутренний)" || "")
   $([ "$install_telegram_api" = [yY] ] && echo "   Файлы TDLib: ./tdlib/" || "")

📥 GITHUB: $([ -n "$GITHUB_REPO" ] && echo "клонирован ($GITHUB_REPO)" || echo "не использовался")

🔧 АВТОЗАПУСК: $([ "$enable_autostart" = [yY] ] && echo "включен ✅" || echo "отключен ❌")

🔗 ДОСТУП:
   HTTP: http://$domain_name
   $([ "$enable_ssl" = [yY] ] && echo "HTTPS: https://$domain_name" || "")
   $([ "$install_telegram_api" = [yY] ] && echo "   Telegram API Example: http://$domain_name/telegram_example.php" || "")

⚙️ УПРАВЛЕНИЕ:
   Запуск: docker-compose up -d
   Остановка: docker-compose down
   Логи: docker-compose logs -f
   Статус: docker-compose ps
   Пересборка: docker-compose build --no-cache

📁 ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ:
   Все настройки сохранены в файле .env
   Для изменения конфигурации отредактируйте .env и перезапустите контейнеры

🔍 ДИАГНОСТИКА:
   Логи nginx: docker-compose logs nginx
   Логи php: docker-compose logs php
   Логи mysql: docker-compose logs mysql
   Логи telegram: docker-compose logs telegram-api
EOF

# Выводим отчет
echo ""
cat "$REPORT_FILE"

# Отправляем отчет в Telegram
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    print_info "Отправка отчета в Telegram..."
    send_telegram_file "$REPORT_FILE" "🎉 <b>Docker окружение настроено!</b>"
    print_success "Отчет отправлен в Telegram"
fi

# Очищаем временные файлы
rm -f "$REPORT_FILE"

print_success "Настройка завершена!"
echo ""
print_info "Для управления используйте: docker-compose [up|down|logs|ps]"
print_info "Файл конфигурации: .env"
