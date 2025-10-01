#!/bin/bash
set -e

echo "Нужно создать подпапку для проекта? (или оставьте пустым, если проект будет в текущей папке):"
read PROJECT_DIR
if [ -n "$GIT_REPO" ]; then
    echo "Ok"
else
    echo "Понял, это текущая папка"
    PROJECT_DIR="."
fi


ABS_PROJECT_DIR=$(realpath "$PROJECT_DIR")

echo "Создаю структуру проекта в папке: $ABS_PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
mkdir -p nginx php mysql wwwroot
USER_ID=$(id -u)
GROUP_ID=$(id -g)



# Проверка и установка git
echo "Проверка установки Git....."
if ! command -v git &> /dev/null; then
    echo "       ..Git не установлен. Устанавливаю..."
    sudo apt-get update && sudo apt-get install -y git
else
    echo "       ..Git установлен)"
fi
# Проверка и установка Docker
echo "Проверка установки Docker"
if ! command -v docker &> /dev/null; then
    echo "       ..Docker не установлен. Устанавливаю Docker..."
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl start docker
    sudo systemctl enable docker
    echo "       ..Docker установлен теперь."
else
    echo "       ..Docker установлен"
fi
# Проверка и установка docker-compose
echo "Проверка установки docker-compose"
if ! command -v docker-compose &> /dev/null; then
    echo "       ..docker-compose не установлен. Устанавливаю docker-compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    echo "       ..docker-compose установлен теперь."
else
    echo "       ..Docker-compose установлен"
fi






# Запрос URL репозитория
echo "Введите URL репозитория GitHub (или оставьте пустым, если клонирование не нужно):"
read GIT_REPO
# Если репозиторий задан, создаём пользователя github и генерируем ключ
if [ -n "$GIT_REPO" ]; then
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

    echo ""
    echo "Добавьте этот публичный SSH-ключ в ваш GitHub аккаунт:"
    echo "Settings > SSH and GPG keys > New SSH key."
    echo "Вставьте ключ: $PUBLIC_KEY"
    echo "После добавления ключа нажмите Enter для продолжения клонирования репозитория..."
    read



    echo "Получаю список веток из репозитория $GIT_REPO..."
    # Получаем список веток с помощью git ls-remote (без клонирования)
    #branches=$(sudo -u github git ls-remote --heads "$GIT_REPO" | awk '{print \$2}' | sed 's|refs/heads/||')
    branches=$(sudo -u github git ls-remote --heads "$GIT_REPO" 2>&1 | awk '{print $2}' | sed 's|refs/heads/||')
    if [ -z "$branches" ]; then
        echo "Ошибка: В репозитории $GIT_REPO нет веток или он недоступен."
        exit 1
    fi
    echo "Доступные ветки:"
    echo "$branches"
    # Создаем массив веток для select
    IFS=$'\n' read -r -a branch_array <<< "$branches"


    echo ""
    echo "Выберите ветку для клонирования (введите номер или 'q' для выхода):"

    select branch in "${branch_array[@]}"; do
        if [ -n "$branch" ]; then
            echo "Выбрана ветка: $branch"
            break
        elif [ "$REPLY" = "q" ]; then
            echo "Выход."
            exit 0
        else
            echo "Неверный выбор. Попробуйте снова (или 'q' для выхода)."
        fi
    done

    echo "Клонирую репозиторий $GIT_REPO, ветка $branch, во временную папку от имени пользователя github..."
    mkdir temp_repo
    chmod 777 temp_repo

    sudo -u github git clone --branch "$branch" "$GIT_REPO" temp_repo
    if [ $? -ne 0 ]; then
        echo "Ошибка при клонировании ветки $branch."
        exit 1
    fi
    echo "Переношу файлы в папку wwwroot и удаляю временную папку..."
    rm -rf wwwroot/*
    mv temp_repo/* wwwroot/ 2>/dev/null || true
    rm -rf temp_repo

    echo "Готово! Ветка $branch клонирована в wwwroot."



fi

echo "Введите TELEGRAM_API_ID (получите на https://my.telegram.org/auth):"
read TELEGRAM_API_ID

echo "Введите TELEGRAM_API_HASH (получите на https://my.telegram.org/auth):"
read TELEGRAM_API_HASH

echo "Введите пароль для root MySQL (оставьте пустым для генерации случайного):"
read MYSQL_ROOT_PASSWORD
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
    MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)
    echo "    .... Сгенерирован случайный пароль для root MySQL: $MYSQL_ROOT_PASSWORD"
fi
echo "Введите имя пользователя MySQL (оставьте пустым для user):"
read MYSQL_USER
if [ -z "$MYSQL_USER" ]; then
    MYSQL_USER=user
fi
echo "Введите пароль для пользователя $MYSQL_USER:"
read MYSQL_PASSWORD
if [ -z "$MYSQL_PASSWORD" ]; then
    MYSQL_PASSWORD=$(openssl rand -base64 12)
    echo "   ....Сгенерирован случайный пароль для пользователя $MYSQL_USER: $MYSQL_PASSWORD"
fi
echo "Введите название базы данных (оставьте пустым для mydb):"
read MYSQL_DATABASE
if [ -z "$MYSQL_DATABASE" ]; then
    MYSQL_DATABASE=mydb
fi


echo "Установить Xdebug для отладки PHP? (y/n, по умолчанию n - просто нажмите Enter):"
echo "        Если да (y), введите адрес и порт Xdebug в формате ip:port (например, host.docker.internal:9003)."
echo "        Если нет (n или Enter), Xdebug не будет установлен."
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
elif [[ "$ADDRESS" =~ ^[0-9.]+$ ]]; then
    IS_LOCAL=true
fi



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
    echo "Домен выбран не локальный, добавляем SSL-сервер.."
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
FROM php:8.4-fpm-alpine

# Установка расширений (без apk, так как зависимости не нужны)
RUN docker-php-ext-install pdo pdo_mysql
#Если вдруг понадобятся системные пакеты (например, для MySQL-клиента), 
#добавьте apk update && apk add --no-cache <пакеты> перед docker-php-ext-install
EOF

if [[ "$INSTALL_XDEBUG" == "y" || "$INSTALL_XDEBUG" == "Y" ]]; then
    cat >> php/Dockerfile <<EOF

RUN pecl install xdebug-3.1.5 \\
    && docker-php-ext-enable xdebug

COPY xdebug.ini /usr/local/etc/php/conf.d/xdebug.ini
EOF
fi

cat >> php/Dockerfile <<EOF

# Для Alpine:
RUN apk add --no-cache shadow
RUN usermod -u 0 www-data && groupmod -g 0 www-data
# Для Ubuntu/Debian:
# RUN apt-get update && apt-get install -y passwd
# RUN usermod -u 0 www-data && groupmod -g 0 www-data
EOF

if [[ "$INSTALL_XDEBUG" == "y" || "$INSTALL_XDEBUG" == "Y" ]]; then
    cat > php/xdebug.ini <<EOF
zend_extension=xdebug

[xdebug]
xdebug.mode=debug
xdebug.start_with_request=yes
xdebug.client_host=$XDEBUG_HOST
xdebug.client_port=$XDEBUG_PORT
xdebug.idekey=PHPSTORM
EOF
fi

cat > docker-compose.yml <<EOF
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
      - ./wwwroot:/var/www/html
EOF

if [ "$IS_LOCAL" = false ]; then
    cat >> docker-compose.yml <<EOF
      - /etc/letsencrypt:/etc/letsencrypt
EOF
fi

cat >> docker-compose.yml <<'EOF'
    depends_on:
      - php
    restart: unless-stopped

  php:
    build: ./php
    volumes:
      - ./wwwroot:/var/www/html
    depends_on:
      - mysql
    restart: unless-stopped

  mysql:
    image: mysql:8.0
    environment:
        MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
        MYSQL_DATABASE: ${MYSQL_DATABASE}
        MYSQL_USER: ${MYSQL_USER}
        MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    restart: unless-stopped

  telegram-bot-api:
    image: aiogram/telegram-bot-api:latest
    environment:
      TELEGRAM_API_ID: ${TELEGRAM_API_ID}
      TELEGRAM_API_HASH: ${TELEGRAM_API_HASH}
    volumes:
      - telegram_data:/var/lib/telegram-bot-api
    restart: unless-stopped

volumes:
  mysql_data:
  telegram_data:
EOF

cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD=$MYSQL_PASSWORD
TELEGRAM_API_ID=$TELEGRAM_API_ID
TELEGRAM_API_HASH=$TELEGRAM_API_HASH
EOF

mkdir -p wwwroot/public
if [ ! -f "wwwroot/public/index.php" ]; then
    cat > wwwroot/public/index.php <<EOF
<?php
echo "Hello from Docker with PHP!";
?>
EOF
fi

chown -R $USER_ID:$GROUP_ID wwwroot


# Если не локальный домен, установить Certbot и выпустить сертификат
if [ "$IS_LOCAL" = false ]; then
    echo "Устанавливаю Certbot для Let's Encrypt..."
    sudo apt-get update && sudo apt-get install -y certbot

    echo "Выпускаю сертификат для $ADDRESS..."
    sudo certbot certonly --webroot -w "$ABS_PROJECT_DIR/wwwroot" -d "$ADDRESS" --agree-tos --email "$CERTBOT_EMAIL" --non-interactive

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
echo "Запускаю контейнеры..."
docker-compose up -d

# Отчёт
echo ""
echo "=== Отчёт по настройке ==="
echo "Проект создан в: $ABS_PROJECT_DIR"
if [ -n "$GIT_REPO" ]; then
    echo "Репозиторий клонирован: $GIT_REPO"
    echo "SSH-ключ сохранён в: $ABS_PROJECT_DIR/github-public.key"
fi
echo "Адрес сайта: $ADDRESS:$PORT"
if [ "$IS_LOCAL" = false ]; then
    echo "HTTPS настроен с сертификатом Let's Encrypt для $ADDRESS"
    echo "Автообновление сертификата: каждый день в 12:00"
fi
echo "Пароль root MySQL: $MYSQL_ROOT_PASSWORD"
echo "Название базы: $MYSQL_DATABASE"
echo "Обычный пользователь: $MYSQL_USER"
echo "Пароль для $MYSQL_USER: $MYSQL_PASSWORD"
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
