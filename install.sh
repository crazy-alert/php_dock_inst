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


# Добавить после цветовых функций:
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
        
        rm -f "$response_file"
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
for dir in  php mysql wwwdata logs/nginx tdlib; do
    if mkdir -p "$dir"; then
        print_success "Создана директория: $dir"
    else
        print_error "Не удалось создать директорию: $dir"
        exit 1
    fi
done

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

# Функция для настройки SSL с Certbot
setup_ssl() {
    local domain="$1"
    local enable_ssl="$2"
    
    if [[ "$enable_ssl" =~ ^[Yy]$ ]]; then
        print_info "Настройка SSL с Let's Encrypt..."
        
        # Устанавливаем certbot если не установлен
        if ! command -v certbot &> /dev/null; then
            print_info "Установка Certbot..."
            sudo apt update
            sudo apt install -y certbot python3-certbot-nginx
        fi
        
        # Проверяем, что домен указывает на сервер
        print_warning "Убедитесь, что домен $domain указывает на IP этого сервера"
        read -p "Нажмите Enter после настройки DNS записей..."
        
        # Получаем сертификат
        print_info "Получение SSL сертификата для $domain..."
        if sudo certbot --nginx -d "$domain" --non-interactive --agree-tos --email admin@$domain 2>/dev/null; then
            print_success "SSL сертификат успешно получен и установлен"
            
            # Настраиваем автоматическое обновление сертификатов
            print_info "Настройка автоматического обновления сертификатов..."
            (sudo crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | sudo crontab -
            print_success "Автообновление сертификатов настроено"
            
            # Создаем конфигурацию nginx с SSL
            create_nginx_ssl_config "$domain"
            
            echo "SSL_ENABLED=true" >> .env
            echo "SSL_DOMAIN=$domain" >> .env
        else
            print_error "Не удалось получить SSL сертификат"
            print_info "Продолжаем без SSL"
            create_nginx_config "$domain" "http"
            echo "SSL_ENABLED=false" >> .env
        fi
    else
        print_info "SSL отключен"
        create_nginx_config "$domain" "http"
        echo "SSL_ENABLED=false" >> .env
    fi
}

# Функция для создания конфигурации nginx
create_nginx_config() {
    local domain="$1"
    local protocol="$2"
    
    print_info "Создание конфигурации Nginx для $domain..."
    cat > nginx/default.conf << 'EOF'
server {
    listen 80;
    server_name $domain;
    root /var/www/public;
    index index.php index.html;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffering off;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Проверяем что файл создан
if [ ! -f "nginx/default.conf" ]; then
    print_error "Не удалось создать nginx/default.conf"
    exit 1
fi

print_success "Конфигурация Nginx создана"
#     if [ "$protocol" = "https" ]; then
#         sudo tee /etc/nginx/sites-available/$domain > /dev/null << EOF
# server {
#     listen 80;
#     server_name $domain;
#     return 301 https://\$server_name\$request_uri;
# }

# server {
#     listen 443 ssl;
#     server_name $domain;
    
#     ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
#     ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
#     ssl_protocols TLSv1.2 TLSv1.3;
#     ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
#     ssl_prefer_server_ciphers off;
    
#     location / {
#         proxy_pass http://127.0.0.1:$http_port;
#         proxy_set_header Host \$host;
#         proxy_set_header X-Real-IP \$remote_addr;
#         proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
#         proxy_set_header X-Forwarded-Proto \$scheme;
#         proxy_buffering off;
#     }
    
#     access_log /var/log/nginx/${domain}_access.log;
#     error_log /var/log/nginx/${domain}_error.log;
# }
# EOF
#     else
#         sudo tee /etc/nginx/sites-available/$domain > /dev/null << EOF
# server {
#     listen 80;
#     server_name $domain;
    
#     location / {
#         proxy_pass http://127.0.0.1:$http_port;
#         proxy_set_header Host \$host;
#         proxy_set_header X-Real-IP \$remote_addr;
#         proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
#         proxy_set_header X-Forwarded-Proto \$scheme;
#         proxy_buffering off;
#     }
    
#     access_log /var/log/nginx/${domain}_access.log;
#     error_log /var/log/nginx/${domain}_error.log;
# }
# EOF
#     fi
    
    # Активируем сайт
    sudo ln -sf /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/
    
    # Проверяем конфигурацию и перезапускаем nginx
    if sudo nginx -t; then
        sudo systemctl reload nginx
        print_success "Nginx сконфигурирован для домена $domain"
    else
        print_error "Ошибка в конфигурации nginx"
        exit 1
    fi
}

# Функция для создания конфигурации nginx с SSL (для docker-compose)
create_nginx_ssl_config() {
    local domain="$1"
    
    print_info "Создание конфигурации Nginx в контейнере с SSL..."
    
    cat > nginx/default.conf << EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name $domain;
    root /var/www/public;
    index index.php index.html;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \\$document_root\\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffering off;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
}

echo -e "${BLUE}🐳 Настройка Docker окружения: PHP 8.4 + Nginx + MySQL + Telegram Bot API${NC}"

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
read -p "Включить автозапуск при загрузке системы? (Y/n): " enable_autostart
enable_autostart=${enable_autostart:-y}

# Настройка Telegram Bot API
echo ""
print_info "Настройка Telegram Bot API (aiogram)"
read -p "Установить Telegram Bot API? (y/N): " install_telegram_api
install_telegram_api=${install_telegram_api:-n}

if [[ "$install_telegram_api" =~ ^[Yy]$ ]]; then
    read -p "TELEGRAM_API_ID: " TELEGRAM_API_ID
    read -p "TELEGRAM_API_HASH: " TELEGRAM_API_HASH
    
    if [ -n "$TELEGRAM_API_ID" ] && [ -n "$TELEGRAM_API_HASH" ]; then
        print_success "Telegram Bot API будет установлен"
        TELEGRAM_STAT_PORT="8082"
        TELEGRAM_HTTP_PORT="8081"
    else
        print_error "API ID и HASH обязательны для установки Telegram Bot API"
        install_telegram_api="n"
    fi
fi

# Настройка GitHub
echo ""
print_info "Настройка доступа к GitHub"
read -p "URL репозитория GitHub (Enter чтобы пропустить): " GITHUB_REPO

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
    sudo chown -R github:github wwwdata/ tdlib/ logs/
    sudo chmod -R 755 wwwdata/ tdlib/ logs/
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

# Проверяем, установлен ли Docker
if ! command -v docker &> /dev/null; then
    print_error "Docker не установлен. Установите Docker сначала."
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    print_error "Docker Compose не установлен. Установите Docker Compose сначала."
    exit 1
fi

# Установка и настройка хостового nginx
print_info "Установка и настройка Nginx на хостовой машине..."
if ! command -v nginx &> /dev/null; then
    sudo apt update
    sudo apt install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
    print_success "Nginx установлен и запущен"
else
    print_success "Nginx уже установлен"
fi

# Функция для генерации случайного пароля
generate_password() {
    local length=${1:-16}
    # Только буквы и цифры - 100% безопасно для YAML
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

# Запрос конфигурации Docker
echo ""
print_info "Настройка Docker конфигурации"

# Определяем домен/IP
read -p "Доменное имя или IP VPS (пусто = localhost): " domain_name
domain_name=${domain_name:-localhost}

# Настройка SSL
echo ""
read -p "Настроить SSL с Let's Encrypt? (y/N): " enable_ssl
enable_ssl=${enable_ssl:-n}

# Запрос порта для приложения
read -p "Порт для HTTP приложения (пусто = 8080): " http_port
http_port=${http_port:-8080}

# Проверка что порт свободен
if ss -tulpn | grep -q ":${http_port}[[:space:]]"; then
    print_warning "Порт $http_port уже занят"
    read -p "Продолжить? (может привести к конфликту) (y/N): " continue_with_used_port
    if [[ ! "$continue_with_used_port" =~ ^[Yy]$ ]]; then
        print_error "Прервано пользователем"
        exit 1
    fi
fi

# Запрос установки Xdebug
read -p "Установить Xdebug? (y/N): " install_xdebug
install_xdebug=${install_xdebug:-n}

# Если Xdebug устанавливается, запрашиваем IP для отладки
if [[ "$install_xdebug" =~ ^[Yy]$ ]]; then
    echo ""
    print_info "Настройка Xdebug для удаленной отладки"
    echo "   Для локальной разработки: 127.0.0.1 или localhost"
    echo "   Для удаленной IDE: IP вашего компьютера"
    echo "   Для отключения отладки: 0.0.0.0"
    
    read -p "IP для отладки Xdebug (пусто = host.docker.internal): " xdebug_host
    xdebug_host=${xdebug_host:-host.docker.internal}
    
    read -p "Порт Xdebug (пусто = 9003): " xdebug_port
    xdebug_port=${xdebug_port:-9003}
    
    read -p "IDE Key (пусто = PHPSTORM): " xdebug_idekey
    xdebug_idekey=${xdebug_idekey:-PHPSTORM}
    
    print_info "Xdebug будет подключаться к: $xdebug_host:$xdebug_port"
fi

# Запрос о выставлении порта MySQL наружу
read -p "Выставить порт MySQL наружу? (y/N): " expose_mysql
expose_mysql=${expose_mysql:-n}

# Запрос пароля MySQL
read -p "Пароль для MySQL root пользователя (пусто = сгенерировать автоматически): " mysql_root_password
if [ -z "$mysql_root_password" ]; then
    mysql_root_password=$(generate_password 16)
    print_success "Сгенерирован пароль MySQL root: $mysql_root_password"
fi

# Запрос названия базы данных
read -p "Название базы данных (пусто = app_db): " mysql_database
mysql_database=${mysql_database:-app_db}

read -p "Имя пользователя MySQL (пусто = app_user): " mysql_user
mysql_user=${mysql_user:-app_user}

read -p "Пароль пользователя MySQL (пусто = сгенерировать автоматически): " mysql_password
if [ -z "$mysql_password" ]; then
    mysql_password=$(generate_password 16)
    print_success "Сгенерирован пароль пользователя MySQL: $mysql_password"
fi

# Создаем Dockerfile для PHP 8.4
print_info "Создание Dockerfile для PHP..."
echo "Текущая директория: $(pwd)"
cat > php/Dockerfile << 'EOF'
FROM php:8.4-fpm

# Установка системных зависимостей
RUN apt-get update && apt-get install -y \
    git \
    curl \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    zip \
    unzip \
    libzip-dev \
    default-mysql-client

# Очистка кеша apt
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Установка PHP расширений
RUN docker-php-ext-install \
    pdo_mysql \
    mbstring \
    exif \
    pcntl \
    bcmath \
    gd \
    zip \
    sockets

# Создание рабочей директории
WORKDIR /var/www

# Настройка прав
RUN chown -R www-data:www-data /var/www
RUN usermod -u 1000 www-data

EXPOSE 9000

CMD ["php-fpm"]
EOF

# Добавляем Xdebug если нужно
if [[ "$install_xdebug" =~ ^[Yy]$ ]]; then
    print_info "Добавление Xdebug в Dockerfile..."
    cat >> php/Dockerfile << 'EOF'

# Установка Xdebug
RUN pecl install xdebug && \
    docker-php-ext-enable xdebug

# Копирование конфигурации Xdebug
COPY xdebug.ini /usr/local/etc/php/conf.d/xdebug.ini
EOF

    # Создаем конфигурацию Xdebug с автозапуском при каждом запросе
    print_info "Создание конфигурации Xdebug..."
    cat > php/xdebug.ini << EOF
zend_extension=xdebug

; Основные настройки - АКТИВАЦИЯ ПРИ КАЖДОМ ЗАПРОСЕ
xdebug.mode=develop,debug
xdebug.start_with_request=yes
xdebug.discover_client_host=0

; Подключение к IDE
xdebug.client_host=$xdebug_host
xdebug.client_port=$xdebug_port
xdebug.idekey=$xdebug_idekey

; Настройки для отладки
xdebug.log=/var/log/xdebug.log
xdebug.log_level=7

; Оптимизация производительности
xdebug.max_nesting_level=512
xdebug.var_display_max_children=128
xdebug.var_display_max_data=512
xdebug.var_display_max_depth=5
EOF

    print_success "Xdebug настроен для автозапуска при каждом запросе"
else
    rm -f php/xdebug.ini
    print_info "Xdebug не будет установлен"
fi

# Создаем docker-compose.yml
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

# Базовый docker-compose.yml
cat > docker-compose.yml << EOF
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    container_name: php_nginx
    ports:
      - "$http_port:80"
    volumes:
      - ./wwwdata:/var/www
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf
      - ./logs/nginx:/var/log/nginx
EOF

# Добавляем SSL volumes если нужно
if [[ "$enable_ssl" =~ ^[Yy]$ ]]; then
    cat >> docker-compose.yml << EOF
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF
fi

cat >> docker-compose.yml << EOF
    depends_on:
      - php
    networks:
      - app-network

  php:
    build: ./php
    container_name: php_app
    volumes:
      - ./wwwdata:/var/www
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
    cat >> docker-compose.yml << EOF

  telegram-api:
    image: aiogram/telegram-bot-api:latest
    container_name: telegram_bot_api
    environment:
      - TELEGRAM_API_ID=$TELEGRAM_API_ID
      - TELEGRAM_API_HASH=$TELEGRAM_API_HASH
      - TELEGRAM_STAT_PORT=$TELEGRAM_STAT_PORT
      - TELEGRAM_HTTP_PORT=$TELEGRAM_HTTP_PORT
      - TELEGRAM_VERBOSITY=9
      - TELEGRAM_LOG=./tdlib-log.txt
    volumes:
      - ./tdlib:/var/telegram-bot-api
    networks:
      - app-network
    restart: unless-stopped
EOF
fi

cat >> docker-compose.yml << EOF
    networks:
      - app-network

  mysql:
    image: mysql:8.0
    container_name: php_mysql
    command: --default-authentication-plugin=mysql_native_password
    environment:
      MYSQL_ROOT_PASSWORD: $mysql_root_password
      MYSQL_DATABASE: $mysql_database
      MYSQL_USER: $mysql_user
      MYSQL_PASSWORD: $mysql_password
    ports:
$mysql_ports
    volumes:
      - mysql_data:/var/lib/mysql
      - ./mysql/init.sql:/docker-entrypoint-initdb.d/init.sql
    networks:
      - app-network

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
docker-compose build --no-cache
docker-compose up -d

print_info "Ожидание запуска сервисов..."
sleep 30

# Настраиваем хостовой nginx и SSL
setup_ssl "$domain_name" "$enable_ssl"

# Настраиваем автозапуск
setup_autostart "$enable_autostart"

# Проверяем статус
print_info "Проверка статуса контейнеров..."
docker-compose ps

# Получаем IP VPS
vps_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "неизвестно")

# Сохраняем конфигурацию
cat > .env << EOF
# Docker Environment Configuration
DOMAIN=$domain_name
HTTP_PORT=$http_port
MYSQL_ROOT_PASSWORD=$mysql_root_password
MYSQL_DATABASE=$mysql_database
MYSQL_USER=$mysql_user
MYSQL_PASSWORD=$mysql_password
XDEBUG_ENABLED=$install_xdebug
XDEBUG_HOST=$xdebug_host
XDEBUG_PORT=$xdebug_port
XDEBUG_IDEKEY=$xdebug_idekey
MYSQL_EXPOSED=$expose_mysql
VPS_IP=$vps_ip
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
GITHUB_REPO=$GITHUB_REPO
TELEGRAM_API_ENABLED=$install_telegram_api
TELEGRAM_API_ID=$TELEGRAM_API_ID
TELEGRAM_API_HASH=$TELEGRAM_API_HASH
TELEGRAM_STAT_PORT=$TELEGRAM_STAT_PORT
TELEGRAM_HTTP_PORT=$TELEGRAM_HTTP_PORT
EOF

# Формируем отчет
REPORT_FILE="/tmp/docker_setup_report_$$.txt"
cat > "$REPORT_FILE" << EOF
🎉 НАСТРОЙКА ЗАВЕРШЕНА

📊 КОНФИГУРАЦИЯ:
🌐 Доменное имя: $domain_name
🔗 HTTP порт приложения: $http_port
🔐 SSL: $([ "$enable_ssl" = "y" ] && echo "включен (Let's Encrypt)" || echo "отключен")

🗃️ MYSQL:
   База данных: $mysql_database
   Пользователь: $mysql_user
   Пароль пользователя: $mysql_password
   Root пароль: $mysql_root_password
   Порт: $([ "$expose_mysql" = "y" ] && echo "открыт (3306)" || echo "закрыт")

🐛 XDEBUG: $([ "$install_xdebug" = "y" ] && echo "активен ($xdebug_host:$xdebug_port)" || echo "не активен")

🤖 TELEGRAM BOT API: $([ "$install_telegram_api" = "y" ] && echo "активен" || echo "не активен")
   $([ "$install_telegram_api" = "y" ] && echo "   Stat порт: $TELEGRAM_STAT_PORT (внутренний)" || "")
   $([ "$install_telegram_api" = "y" ] && echo "   HTTP порт: $TELEGRAM_HTTP_PORT (внутренний)" || "")
   $([ "$install_telegram_api" = "y" ] && echo "   Файлы TDLib: ./tdlib/" || "")

📥 GITHUB: $([ -n "$GITHUB_REPO" ] && echo "клонирован ($GITHUB_REPO)" || echo "не использовался")

🔧 АВТОЗАПУСК: $([ "$enable_autostart" = "y" ] && echo "включен ✅" || echo "отключен ❌")

🔗 ДОСТУП:
   HTTP: http://$domain_name
   $([ "$enable_ssl" = "y" ] && echo "HTTPS: https://$domain_name" || "")
   $([ "$install_telegram_api" = "y" ] && echo "   Telegram API Example: http://$domain_name/telegram_example.php" || "")

⚙️ УПРАВЛЕНИЕ:
   Запуск: ./manage.sh start
   Остановка: ./manage.sh stop
   Логи: ./manage.sh logs
   Статус: ./manage.sh status
   Автозапуск: ./manage.sh autostart [enable|disable|status]
   SSL: ./manage.sh ssl [renew|status]
   Telegram API: ./manage.sh telegram [stats|logs|restart]
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
