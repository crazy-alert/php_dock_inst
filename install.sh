#!/bin/bash
set -e

PROJECT_DIR="."
ABS_PROJECT_DIR=$(realpath "$PROJECT_DIR")

# --- Telegram report setup ---
SEND_REPORT=false
echo "Отправлять отчёт в Telegram? (y/n, по умолчанию n):"
read SEND_REPORT_ANSWER
if [[ "$SEND_REPORT_ANSWER" == "y" || "$SEND_REPORT_ANSWER" == "Y" ]]; then
    SEND_REPORT=true
    echo "Введите токен Telegram бота:"
    read TELEGRAM_BOT_TOKEN
    echo "Введите ID чата для отправки отчёта:"
    read TELEGRAM_CHAT_ID
fi

echo "Создаю структуру проекта в папке: $ABS_PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

USER_ID=$(id -u)
GROUP_ID=$(id -g)

# Запрос URL репозитория
echo "Введите URL репозитория GitHub (или оставьте пустым, если клонирование не нужно):"
read GIT_REPO

# Проверка и установка git (если нужно и репозиторий задан)
if [ -n "$GIT_REPO" ] && ! command -v git &> /dev/null; then
    echo "Git не установлен. Устанавливаю..."
    sudo apt-get update && sudo apt-get install -y git
fi

# Если репозиторий задан, создаём пользователя github и генерируем ключ
if [ -n "$GIT_REPO" ]; then
    BRANCH_CLONED="не клонировано"
    if ! id -u github > /dev/null 2>&1; then
        echo "Пользователь github не существует. Создаю..."
        sudo useradd -m -s /bin/bash github
        echo "Генерирую SSH-ключ Ed25519 для пользователя github..."
        sudo -u github ssh-keygen -t ed25519 -C "github@github-docker-project" -f /home/github/.ssh/id_ed25519 -N "" -q
        PUBLIC_KEY=$(sudo cat /home/github/.ssh/id_ed25519.pub)
        echo "Пользователь github создан. Публичный SSH-ключ:"
        echo "$PUBLIC_KEY"
        echo "$PUBLIC_KEY" > "$ABS_PROJECT_DIR/github-public.key"
    else
        echo "Пользователь github уже существует."
        if [ -f /home/github/.ssh/id_ed25519.pub ]; then
            PUBLIC_KEY=$(sudo cat /home/github/.ssh/id_ed25519.pub)
            echo "Публичный SSH-ключ пользователя github:"
            echo "$PUBLIC_KEY"
            echo "$PUBLIC_KEY" > "$ABS_PROJECT_DIR/github-public.key"
        else
            echo "SSH-ключ не найден. Генерирую новый..."
            sudo -u github ssh-keygen -t ed25519 -C "github@github-docker-project" -f /home/github/.ssh/id_ed25519 -N "" -q
            PUBLIC_KEY=$(sudo cat /home/github/.ssh/id_ed25519.pub)
            echo "Ключ сгенерирован. Публичный SSH-ключ:"
            echo "$PUBLIC_KEY"
            echo "$PUBLIC_KEY" > "$ABS_PROJECT_DIR/github-public.key"
        fi
    fi

    # Отправка публичного ключа в Telegram
    if [ "$SEND_REPORT" = true ]; then
        echo "Отправка ключа тебе в телегу..."
        SERVER_NAME=$(hostname)
        KEY_MESSAGE="Публичный ключ пользователя github сервера $SERVER_NAME: <code>$PUBLIC_KEY</code>"
        curl -s -X POST https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage \
            -d chat_id=$TELEGRAM_CHAT_ID \
            -d text="$KEY_MESSAGE" \
            -d parse_mode=HTML > /dev/null
    fi

    echo ""
    echo "Добавьте этот публичный SSH-ключ в ваш GitHub аккаунт:"
    echo "Settings > SSH and GPG keys > New SSH key."
    echo "Вставьте ключ: $PUBLIC_KEY"
    echo "После добавления ключа нажмите Enter для продолжения клонирования репозитория..."
    read

    echo "Получаю список веток из репозитория $GIT_REPO..."
    BRANCHES_RAW=$(sudo -u github git ls-remote --heads "$GIT_REPO")

    if [ -z "$BRANCHES_RAW" ]; then
        echo "Не удалось получить список веток или репозиторий пуст."
        echo "Клонирую репозиторий по умолчанию (master/main)..."
        BRANCH_CLONED="default (master/main)"
        sudo -u github git clone "$GIT_REPO" temp_repo
    else
        echo "Доступные ветки:"
        # Выводим только имена веток
        BRANCHES=()
        while read -r line; do
            branch_name=$(echo "$line" | awk '{print $2}' | sed 's|refs/heads/||')
            BRANCHES+=("$branch_name")
        done <<< "$BRANCHES_RAW"

        for i in "${!BRANCHES[@]}"; do
            echo "  $((i+1))) ${BRANCHES[$i]}"
        done

        # Предлагаем выбрать ветку
        DEFAULT_BRANCH="main"
        if [[ ! " ${BRANCHES[@]} " =~ " $DEFAULT_BRANCH " ]]; then
            DEFAULT_BRANCH="master"
        fi

        echo "Введите номер ветки для клонирования (по умолчанию $DEFAULT_BRANCH):"
        read BRANCH_CHOICE

        if [[ -z "$BRANCH_CHOICE" ]]; then
            SELECTED_BRANCH="$DEFAULT_BRANCH"
        elif [[ "$BRANCH_CHOICE" =~ ^[0-9]+$ ]] && [ "$BRANCH_CHOICE" -ge 1 ] && [ "$BRANCH_CHOICE" -le "${#BRANCHES[@]}" ]; then
            SELECTED_BRANCH="${BRANCHES[$((BRANCH_CHOICE-1))]}"
        else
            echo "Неверный ввод, будет выбрана ветка по умолчанию: $DEFAULT_BRANCH"
            SELECTED_BRANCH="$DEFAULT_BRANCH"
        fi

        BRANCH_CLONED="$SELECTED_BRANCH"
        echo "Клонирую ветку '$SELECTED_BRANCH' из $GIT_REPO во временную папку..."
        sudo -u github git clone --branch "$SELECTED_BRANCH" --single-branch "$GIT_REPO" temp_repo
    fi

    echo "Переношу файлы в папку app и удаляю временную папку..."
    rm -rf app/*
    mv temp_repo/* app/ 2>/dev/null || true
    rm -rf temp_repo
fi

echo "Введите TELEGRAM_API_ID (получите на https://my.telegram.org/auth):"
read TELEGRAM_API_ID

echo "Введите TELEGRAM_API_HASH (получите на https://my.telegram.org/auth):"
read TELEGRAM_API_HASH

echo "Введите пароль для root MySQL (оставьте пустым для генерации случайного):"
read MYSQL_ROOT_PASSWORD
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
    MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)
    echo "Сгенерирован случайный пароль для root MySQL: $MYSQL_ROOT_PASSWORD"
fi

echo "Установить Xdebug для отладки PHP? (y/n, по умолчанию n - просто нажмите Enter):"
echo "Если да (y), введите адрес и порт Xdebug в формате ip:port (например, host.docker.internal:9003)."
echo "Если нет (n или Enter), Xdebug не будет установлен."
read INSTALL_XDEBUG

if [[ "$INSTALL_XDEBUG" == "y" || "$INSTALL_XDEBUG" == "Y" ]]; then
    echo "Введите адрес и порт Xdebug (ip:port), например host.docker.internal:9003:"
    read XDEBUG_ADDR_PORT

    # Разбор ip и порта
    if [[ "$XDEBUG_ADDR_PORT" =~ ^([^:]+):([0-9]+)$ ]]; then
        XDEBUG_HOST="${BASH_REMATCH[1]}"
        XDEBUG_PORT="${BASH_REMATCH[2]}"
    else
        echo "Неверный формат, ожидается ip:port. Xdebug не будет установлен."
        INSTALL_XDEBUG="n"
    fi
else
    INSTALL_XDEBUG="n"
fi

# Запрос адреса и порта для веб-сервера в формате ip:port
while true; do
    echo "Введите адрес и порт для доступа к сайту в формате ip:port (по умолчанию 0.0.0.0:8080, просто нажмите Enter)."
    echo "Если укажете домен (не *.local), будет настроен HTTPS с Let's Encrypt сертификатом и автообновлением."
    read INPUT
    if [ -z "$INPUT" ]; then
        ADDRESS="0.0.0.0"
        PORT="8080"
        break
    elif [[ "$INPUT" =~ ^([^:]+):([0-9]+)$ ]]; then
        ADDRESS="${BASH_REMATCH[1]}"
        PORT="${BASH_REMATCH[2]}"
        break
    else
        echo "Неверный формат. Ожидается address:port, где port - число. Попробуйте снова."
    fi
done

# Проверка, является ли ADDRESS локальным доменом (*.local)
IS_LOCAL=false
if [[ "$ADDRESS" == *.local ]]; then
    IS_LOCAL=true
fi

# Если не локальный домен, запрос email для Certbot
if [ "$IS_LOCAL" = false ]; then
    echo "Адрес не является локальным (*.local). Будет настроен HTTPS с Let's Encrypt."
    echo "Введите ваш email для Let's Encrypt сертификата:"
    read CERTBOT_EMAIL
    if [ -z "$CERTBOT_EMAIL" ]; then
        echo "Email обязателен для сертификата. Пропускаю настройку HTTPS."
        IS_LOCAL=true
    fi
fi

mkdir -p nginx php mysql app

# Создание nginx.conf
cat > nginx/nginx.conf <<EOF
server {
    listen 80;
    server_name $ADDRESS;

    root /var/www/html/public;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass php-fpm:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }
}
EOF

# Если не локальный домен, добавить SSL-сервер
if [ "$IS_LOCAL" = false ]; then
    cat >> nginx/nginx.conf <<EOF

server {
    listen 443 ssl;
    server_name $ADDRESS;

    ssl_certificate /etc/letsencrypt/live/$ADDRESS/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADDRESS/privkey.pem;

    root /var/www/html/public;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass php-fpm:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
fi

cat > php/Dockerfile <<EOF
FROM php:8.4-fpm

RUN apt-get update && apt-get install -y \\
    libpng-dev \\
    libjpeg-dev \\
    libfreetype6-dev \\
    && docker-php-ext-configure gd --with-freetype --with-jpeg \\
    && docker-php-ext-install gd pdo pdo_mysql
EOF

if [[ "$INSTALL_XDEBUG" == "y" || "$INSTALL_XDEBUG" == "Y" ]]; then
    cat >> php/Dockerfile <<EOF

RUN pecl install xdebug-3.1.5 \\
    && docker-php-ext-enable xdebug

COPY xdebug.ini /usr/local/etc/php/conf.d/xdebug.ini
EOF
fi

cat >> php/Dockerfile <<EOF

#RUN usermod -u $USER_ID www-data && groupmod -g $GROUP_ID www-data
EOF

if [[ "$INSTALL_XDEBUG" == "y" || "$INSTALL_XDEBUG" == "Y" ]]; then
    cat > php/xdebug.ini <<EOF
zend_extension=xdebug

[xdebug]
xdebug.mode=debug
xdebug.start_with_request=yes
xdebug.client_host=$XDEBUG_HOST
xdebug.client_port=$XDEBUG_PORT
xdebug.idekey=VSCODE
EOF
fi

cat > docker-compose.yml <<EOF
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    ports:
      - "$ADDRESS:$PORT:80"
EOF

if [ "$IS_LOCAL" = false ]; then
    cat >> docker-compose.yml <<EOF
      - "$ADDRESS:443:443"
EOF
fi

cat >> docker-compose.yml <<EOF
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf
      - ./app:/var/www/html
EOF

if [ "$IS_LOCAL" = false ]; then
    cat >> docker-compose.yml <<EOF
      - /etc/letsencrypt:/etc/letsencrypt
EOF
fi

cat >> docker-compose.yml <<EOF
    depends_on:
      - php
    restart: unless-stopped

  php:
    build: ./php
    volumes:
      - ./app:/var/www/html
    depends_on:
      - mysql
    restart: unless-stopped

  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_DATABASE: mydb
      MYSQL_USER: user
      MYSQL_PASSWORD: password
    volumes:
      - mysql_data:/var/lib/mysql
    ports:
      - "3306:3306"
    restart: unless-stopped

  telegram-bot-api:
    image: aiogram/telegram-bot-api:latest
    ports:
      - "8081:8081"
    environment:
      TELEGRAM_API_ID: $TELEGRAM_API_ID
      TELEGRAM_API_HASH: $TELEGRAM_API_HASH
    volumes:
      - telegram_data:/var/lib/telegram-bot-api
    restart: unless-stopped

volumes:
  mysql_data:
  telegram_data:
EOF

cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_DATABASE=mydb
MYSQL_USER=user
MYSQL_PASSWORD=password
EOF

mkdir -p app/public
if [ ! -f "app/public/index.php" ]; then
    cat > app/public/index.php <<EOF
<?php
echo "Hello from Docker with PHP!";
?>
EOF
fi

# chown -R $USER_ID:$GROUP_ID app

# Проверка и установка Docker
if ! command -v docker &> /dev/null; then
    echo "Docker не установлен. Устанавливаю Docker..."
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl start docker
    sudo systemctl enable docker
    echo "Docker установлен."
fi

# Проверка и установка docker-compose
if ! command -v docker-compose &> /dev/null; then
    echo "docker-compose не установлен. Устанавливаю docker-compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    echo "docker-compose установлен."
fi

# Если не локальный домен, установить Certbot и выпустить сертификат
if [ "$IS_LOCAL" = false ]; then
    echo "Устанавливаю Certbot для Let's Encrypt..."
    sudo apt-get update && sudo apt-get install -y certbot

    echo "Выпускаю сертификат для $ADDRESS..."
    sudo certbot certonly --webroot -w "$ABS_PROJECT_DIR/app" -d "$ADDRESS" --agree-tos --email "$CERTBOT_EMAIL" --non-interactive

    echo "Добавляю cron-job для автоматического обновления сертификата..."
    (crontab -l ; echo "0 12 * * * /usr/bin/certbot renew --quiet && sudo docker-compose restart nginx") | crontab -
    echo "Cron-job добавлен: обновление каждый день в 12:00."
fi

# Создание systemd-сервиса для автоматического запуска контейнеров при перезагрузке сервера
SERVICE_NAME="docker-compose-app"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "Создаю systemd-сервис для автоматического запуска контейнеров при перезагрузке сервера..."
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Docker Compose Application
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ABS_PROJECT_DIR
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"

# Запуск контейнеров
echo "Запускаю контейнеры:"
echo "docker-compose up -d...."
docker-compose up -d

# Подготовка отчёта
REPORT_TEXT="<b>Отчёт по настройке Docker-проекта</b>\n\n"
REPORT_TEXT+="Проект создан в: <code>$ABS_PROJECT_DIR</code>\n"
if [ -n "$GIT_REPO" ]; then
    REPORT_TEXT+="Репозиторий клонирован: <code>$GIT_REPO</code>\n"
    REPORT_TEXT+="Ветка клонирована: <code>$BRANCH_CLONED</code>\n"
    REPORT_TEXT+="SSH-ключ сохранён в: <code>$ABS_PROJECT_DIR/github-public.key</code>\n"
fi
REPORT_TEXT+="Адрес сайта: <code>$ADDRESS:$PORT</code>\n"
if [ "$IS_LOCAL" = false ]; then
    REPORT_TEXT+="HTTPS настроен с сертификатом Let's Encrypt для <code>$ADDRESS</code>\n"
    REPORT_TEXT+="Автообновление сертификата: каждый день в 12:00\n"
fi
REPORT_TEXT+="Пароль root MySQL: <code>$MYSQL_ROOT_PASSWORD</code>\n"
if [[ "$INSTALL_XDEBUG" == "y" || "$INSTALL_XDEBUG" == "Y" ]]; then
    REPORT_TEXT+="Xdebug установлен с настройками: <code>$XDEBUG_HOST:$XDEBUG_PORT</code>\n"
fi
REPORT_TEXT+="Telegram Bot API запущен на порту <code>8081</code>\n"
REPORT_TEXT+="systemd-сервис создан: <code>$SERVICE_NAME</code>\n"
REPORT_TEXT+="Для запуска: <code>sudo systemctl start $SERVICE_NAME</code>\n"
REPORT_TEXT+="Для остановки: <code>sudo systemctl stop $SERVICE_NAME</code>\n"
REPORT_TEXT+="Для перезапуска: <code>sudo systemctl restart $SERVICE_NAME</code>\n"
REPORT_TEXT+="Для просмотра логов: <code>docker-compose logs -f</code>\n"

# Отправка отчёта в Telegram
if [ "$SEND_REPORT" = true ]; then
    curl -s -X POST https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage \
        -d chat_id=$TELEGRAM_CHAT_ID \
        -d text="$REPORT_TEXT" \
        -d parse_mode=HTML > /dev/null
    echo "Отчёт отправлен в Telegram."
fi

# Вывод отчёта в консоль
echo ""
echo "=== Отчёт по настройке ==="
echo "Проект создан в: $ABS_PROJECT_DIR"
if [ -n "$GIT_REPO" ]; then
    echo "Репозиторий клонирован: $GIT_REPO"
    echo "Ветка клонирована: $BRANCH_CLONED"
    echo "SSH-ключ сохранён в: $ABS_PROJECT_DIR/github-public.key"
fi
echo "Адрес сайта: $ADDRESS:$PORT"
if [ "$IS_LOCAL" = false ]; then
    echo "HTTPS настроен с сертификатом Let's Encrypt для $ADDRESS"
    echo "Автообновление сертификата: каждый день в 12:00"
fi
echo "Пароль root MySQL: $MYSQL_ROOT_PASSWORD"
if [[ "$INSTALL_XDEBUG" == "y" || "$INSTALL_XDEBUG" == "Y" ]]; then
    echo "Xdebug установлен с настройками: $XDEBUG_HOST:$XDEBUG_PORT"
fi
echo "Telegram Bot API запущен на порту 8081"
echo "systemd-сервис создан: $SERVICE_NAME"
echo "Для запуска: sudo systemctl start $SERVICE_NAME"
echo "Для остановки: sudo systemctl stop $SERVICE_NAME"
echo "Для перезапуска: sudo systemctl restart $SERVICE_NAME"
echo "Для просмотра логов: docker-compose logs -f"
echo "=== Конец отчёта ==="
