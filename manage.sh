#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Загружаем переменные из .env если файл существует
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Функция для отправки в Telegram
send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST \
            -H 'Content-Type: application/json' \
            -d "{\"chat_id\": \"$TELEGRAM_CHAT_ID\", \"text\": \"$message\", \"parse_mode\": \"HTML\"}" \
            "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" > /dev/null
    fi
}

# Функция для отправки конфигурации в Telegram
send_config_to_telegram() {
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        print_error "🚫 Telegram не настроен"
        return 1
    fi

    print_info "📤 Отправка конфигурации в Telegram..."
    
    # Формируем сообщение с конфигурацией
    local config_message="🔧 <b>Конфигурация Docker окружения</b>\n\n"
    
    # Основная конфигурация
    config_message+="<b>🌐 Основные настройки:</b>\n"
    config_message+="Домен:порт <code>${DOMAIN:-localhost}:${HTTP_PORT:-8080}</code>\n"
    config_message+="SSL: <b>${SSL_ENABLED:-нет}</b>\n"
    config_message+="Автозапуск: <b>${AUTOSTART_ENABLED:-нет}</b>\n\n"
    
    # База данных MySQL
    config_message+="<b>🗃️ База данных MySQL:</b>\n"
    config_message+="Хост: mysql (внутри Docker)\n"
    config_message+="Порт: 3306 (внутренний)\n"
    config_message+="База данных: <code>${MYSQL_DATABASE:-app_db}</code>\n"
    config_message+="Пользователь: <code>${MYSQL_USER:-app_user}</code>\n"
    config_message+="Пароль пользователя: <code>${MYSQL_PASSWORD:-не установлен}</code>\n"
    config_message+="Root пароль: <code>${MYSQL_ROOT_PASSWORD:-не установлен}</code>\n\n"
    
    # Доступ к MySQL
    if [ "$MYSQL_EXPOSED" = "y" ]; then
        config_message+="<b>🔓 Внешний доступ к MySQL:</b>\n"
        config_message+="Хост: <code>${VPS_IP:-ваш_IP}</code>\n"
    else
        config_message+="<b>🔒 MySQL доступен только внутри Docker</b>\n\n"
    fi
    
    # Xdebug
    if [ "$XDEBUG_ENABLED" = "y" ]; then
        config_message+="<b>🐛 Xdebug:</b>\n"
        config_message+="Хост: <code>${XDEBUG_HOST}</code>\n"
        config_message+="Порт: <code>${XDEBUG_PORT:-9003}</code>\n"
        config_message+="IDE Key: <code>${XDEBUG_IDEKEY:-PHPSTORM}</code>\n\n"
    else
        config_message+="<b>🐛 Xdebug: отключен</b>\n\n"
    fi
    
    # Telegram Bot API
    if [ "$TELEGRAM_API_ENABLED" = "y" ]; then
        config_message+="<b>🤖 Telegram Bot API:</b>\n"
        config_message+="API ID: <code>${TELEGRAM_API_ID}</code>\n"
        config_message+="API HASH: <code>secret</code>\n"
        config_message+="Stat порт: <code>${TELEGRAM_STAT_PORT:-8082} (внутренний)</code>\n"
        config_message+="HTTP порт: <code>${TELEGRAM_HTTP_PORT:-8081} (внутренний)</code>\n\n"
    else
        config_message+="<b>🤖 Telegram Bot API: отключен</b>\n\n"
    fi
    
    # GitHub
    if [ -n "$GITHUB_REPO" ]; then
        config_message+="<b>📥 GitHub репозиторий:</b>\n"
        config_message+="<code>${GITHUB_REPO}</code>\n\n"
    else
        config_message+="<b>📥 GitHub: не используется</b>\n\n"
    fi
    
    # Отправляем сообщение
    if send_telegram "$config_message"; then
        print_success "✅ Конфигурация отправлена в Telegram"
        

    else
        print_error "❌ Ошибка отправки конфигурации в Telegram"
        return 1
    fi
}

# Функция для управления автозапуском
manage_autostart() {
    local action="$1"
    
    case "$action" in
        "enable")
            print_info "🔄 Включение автозапуска..."
            if [ -f /etc/systemd/system/docker-compose-app.service ]; then
                sudo systemctl enable docker-compose-app.service
                sudo systemctl start docker-compose-app.service
                print_success "🎯 Автозапуск включен"
                
                # Обновляем .env
                if [ -f .env ]; then
                    grep -v "AUTOSTART_ENABLED" .env > .env.tmp
                    echo "AUTOSTART_ENABLED=true" >> .env.tmp
                    mv .env.tmp .env
                fi
            else
                print_error "🚫 Сервис автозапуска не найден. Запустите setup.sh для настройки."
            fi
            ;;
        "disable")
            print_info "🔄 Отключение автозапуска..."
            if systemctl is-enabled docker-compose-app.service 2>/dev/null | grep -q enabled; then
                sudo systemctl disable docker-compose-app.service
                sudo systemctl stop docker-compose-app.service
                print_success "🎯 Автозапуск отключен"
                
                # Обновляем .env
                if [ -f .env ]; then
                    grep -v "AUTOSTART_ENABLED" .env > .env.tmp
                    echo "AUTOSTART_ENABLED=false" >> .env.tmp
                    mv .env.tmp .env
                fi
            else
                print_info "ℹ️ Автозапуск уже отключен"
            fi
            ;;
        "status")
            print_info "📊 Статус автозапуска:"
            if systemctl is-enabled docker-compose-app.service 2>/dev/null | grep -q enabled; then
                print_success "🎯 Автозапуск: ВКЛЮЧЕН"
                echo "   📝 Сервис будет запускаться при загрузке системы"
            else
                print_warning "🚫 Автозапуск: ОТКЛЮЧЕН"
                echo "   📝 Сервис не будет запускаться автоматически"
            fi
            
            # Показываем статус сервиса
            if systemctl is-active docker-compose-app.service 2>/dev/null | grep -q active; then
                print_success "🟢 Сервис: ЗАПУЩЕН"
            else
                print_warning "🟡 Сервис: ОСТАНОВЛЕН"
            fi
            ;;
        "restart")
            print_info "🔄 Перезапуск сервиса автозапуска..."
            if systemctl is-enabled docker-compose-app.service 2>/dev/null | grep -q enabled; then
                sudo systemctl restart docker-compose-app.service
                print_success "✅ Сервис автозапуска перезапущен"
            else
                print_error "🚫 Сервис автозапуска не активен"
            fi
            ;;
        *)
            print_error "🚫 Неизвестное действие: $action"
            echo "📖 Использование: $0 autostart {enable|disable|status|restart}"
            exit 1
            ;;
    esac
}

# Функция для управления SSL
manage_ssl() {
    local action="$1"
    
    case "$action" in
        "renew")
            print_info "🔄 Обновление SSL сертификатов..."
            if sudo certbot renew; then
                print_success "✅ SSL сертификаты обновлены"
                sudo systemctl reload nginx
            else
                print_error "❌ Ошибка при обновлении SSL сертификатов"
            fi
            ;;
        "status")
            print_info "📊 Статус SSL сертификатов:"
            if [ -n "$SSL_DOMAIN" ] && [ -f "/etc/letsencrypt/live/$SSL_DOMAIN/fullchain.pem" ]; then
                print_success "🔐 SSL: АКТИВЕН"
                echo "   🌐 Домен: $SSL_DOMAIN"
                echo "   📅 Срок действия:"
                sudo certbot certificates | grep "Expiry" | head -1
            else
                print_warning "🚫 SSL: НЕ АКТИВЕН"
            fi
            ;;
        "test")
            if [ -n "$SSL_DOMAIN" ]; then
                print_info "🧪 Тестирование SSL для $SSL_DOMAIN..."
                if curl -I "https://$SSL_DOMAIN" > /dev/null 2>&1; then
                    print_success "✅ SSL работает корректно"
                else
                    print_error "❌ Ошибка SSL соединения"
                fi
            else
                print_error "🚫 SSL домен не настроен"
            fi
            ;;
        *)
            print_error "🚫 Неизвестное действие: $action"
            echo "📖 Использование: $0 ssl {renew|status|test}"
            exit 1
            ;;
    esac
}

# Функция для управления Telegram Bot API
manage_telegram() {
    local action="$1"
    
    if [ "$TELEGRAM_API_ENABLED" != "y" ]; then
        print_error "🚫 Telegram Bot API не настроен"
        exit 1
    fi
    
    case "$action" in
        "stats")
            print_info "📊 Получение статистики Telegram Bot API..."
            if curl -s "http://localhost:$TELEGRAM_HTTP_PORT" > /dev/null 2>&1; then
                print_success "🤖 Telegram Bot API доступен"
                
                # Получаем статистику
                stats=$(docker-compose exec -T telegram-api curl -s "http://localhost:$TELEGRAM_STAT_PORT")
                if [ -n "$stats" ]; then
                    echo "📈 Статистика Telegram Bot API:"
                    echo "$stats"
                else
                    print_warning "⚠️ Не удалось получить статистику"
                fi
            else
                print_error "❌ Telegram Bot API недоступен"
            fi
            ;;
        "logs")
            print_info "📋 Логи Telegram Bot API:"
            docker-compose logs telegram-api --tail=50
            ;;
        "restart")
            print_info "🔄 Перезапуск Telegram Bot API..."
            docker-compose restart telegram-api
            print_success "✅ Telegram Bot API перезапущен"
            ;;
        "status")
            print_info "📊 Статус Telegram Bot API:"
            if docker-compose ps telegram-api | grep -q "Up"; then
                print_success "🤖 Telegram Bot API: ЗАПУЩЕН"
                echo "   🔌 Stat порт: $TELEGRAM_STAT_PORT (внутренний)"
                echo "   🌐 HTTP порт: $TELEGRAM_HTTP_PORT (внутренний)"
                echo "   📁 Файлы TDLib: ./tdlib/"
                
                # Проверяем доступность
                if curl -s "http://localhost:$TELEGRAM_HTTP_PORT" > /dev/null 2>&1; then
                    print_success "   🟢 API доступен"
                else
                    print_warning "   🟡 API временно недоступен"
                fi
            else
                print_error "❌ Telegram Bot API: ОСТАНОВЛЕН"
            fi
            ;;
        "files")
            print_info "📁 Файлы TDLib:"
            if [ -d "./tdlib" ]; then
                ls -la ./tdlib/
                echo ""
                echo "💾 Общий размер: $(du -sh ./tdlib/ | cut -f1)"
            else
                print_warning "⚠️ Папка tdlib не существует"
            fi
            ;;
        *)
            print_error "🚫 Неизвестное действие: $action"
            echo "📖 Использование: $0 telegram {stats|logs|restart|status|files}"
            exit 1
            ;;
    esac
}

# Функция для пересборки Docker
rebuild_docker() {
    local service="$1"
    
    print_info "🔨 Пересборка Docker контейнеров..."
    
    if [ -n "$service" ]; then
        # Пересборка конкретного сервиса
        print_info "🔄 Пересборка сервиса: $service"
        if docker-compose build --no-cache "$service"; then
            print_success "✅ Сервис $service пересобран"
            print_info "🔄 Перезапуск сервиса..."
            docker-compose up -d --force-recreate "$service"
            print_success "✅ Сервис $service перезапущен"
        else
            print_error "❌ Ошибка пересборки сервиса $service"
            exit 1
        fi
    else
        # Полная пересборка всех сервисов
        print_info "🔄 Полная пересборка всех сервисов"
        if docker-compose build --no-cache; then
            print_success "✅ Все сервисы пересобраны"
            print_info "🔄 Перезапуск всех сервисов..."
            docker-compose up -d --force-recreate
            print_success "✅ Все сервисы перезапущены"
        else
            print_error "❌ Ошибка пересборки контейнеров"
            exit 1
        fi
    fi
    
    # Показываем статус после пересборки
    echo ""
    print_info "📊 Статус после пересборки:"
    docker-compose ps
}

case "$1" in
    "start")
        docker-compose up -d
        print_success "🚀 Контейнеры запущены"
        ;;
    "stop")
        docker-compose down
        print_success "🛑 Контейнеры остановлены"
        ;;
    "restart")
        docker-compose restart
        print_success "🔃 Контейнеры перезапущены"
        ;;
    "logs")
        if [ -n "$2" ]; then
            docker-compose logs "$2" -f
        else
            docker-compose logs -f
        fi
        ;;
    "build")
        rebuild_docker "$2"
        ;;
    "rebuild")
        rebuild_docker "$2"
        ;;
    "status")
        print_info "📊 Статус контейнеров:"
        docker-compose ps
        ;;
    "ssh-php")
        docker-compose exec php bash
        ;;
    "ssh-mysql")
        docker-compose exec mysql bash
        ;;
    "ssh-nginx")
        docker-compose exec nginx sh
        ;;
    "ssh-telegram")
        if [ "$TELEGRAM_API_ENABLED" = "y" ]; then
            docker-compose exec telegram-api sh
        else
            print_error "🚫 Telegram Bot API не настроен"
        fi
        ;;
    "mysql")
        if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
            docker-compose exec mysql mysql -u root -p"$MYSQL_ROOT_PASSWORD"
        else
            docker-compose exec mysql mysql -u root
        fi
        ;;
    "info")
        echo -e "${BLUE}📊 Текущая конфигурация:${NC}"
        echo "   🌐 HTTP порт: ${HTTP_PORT:-8080}"
        echo "   🏠 Домен: ${DOMAIN:-localhost}"
        echo "   🔐 SSL: ${SSL_ENABLED:-неизвестно}"
        echo "   🗃️ MySQL Database: ${MYSQL_DATABASE:-app_db}"
        echo "   👤 MySQL User: ${MYSQL_USER:-app_user}"
        echo "   🔓 MySQL Exposed: ${MYSQL_EXPOSED:-no}"
        echo "   🐛 Xdebug: ${XDEBUG_ENABLED:-no}"
        if [ "${XDEBUG_ENABLED}" = "y" ]; then
            echo "   📍 Xdebug Host: ${XDEBUG_HOST}"
            echo "   🔌 Xdebug Port: ${XDEBUG_PORT}"
        fi
        echo "   🤖 Telegram API: ${TELEGRAM_API_ENABLED:-no}"
        if [ "${TELEGRAM_API_ENABLED}" = "y" ]; then
            echo "   📊 Telegram Stat Port: ${TELEGRAM_STAT_PORT}"
            echo "   🌐 Telegram HTTP Port: ${TELEGRAM_HTTP_PORT}"
        fi
        if [ -n "${GITHUB_REPO}" ]; then
            echo "   📥 GitHub Repo: ${GITHUB_REPO}"
        fi
        echo "   🔧 Автозапуск: ${AUTOSTART_ENABLED:-неизвестно}"
        ;;
    "ports")
        print_info "🔓 Открытые порты:"
        netstat -tulpn | grep LISTEN | grep -E ":(80|443|${HTTP_PORT:-8080})" || echo "   📭 Нет открытых портов"
        ;;
    "telegram-test")
        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            send_telegram "🧪 <b>Тестовое сообщение</b>\n\nЕсли вы видите это сообщение, Telegram уведомления работают корректно!"
            print_success "✅ Тестовое сообщение отправлено"
        else
            print_error "🚫 Telegram не настроен"
        fi
        ;;
    "autostart")
        manage_autostart "$2"
        ;;
    "ssl")
        manage_ssl "$2"
        ;;
    "telegram")
        manage_telegram "$2"
        ;;
    "nginx")
        print_info "🔄 Перезагрузка Nginx..."
        sudo systemctl reload nginx
        print_success "✅ Nginx перезагружен"
        ;;
    "update")
        print_info "📥 Обновление кода из GitHub..."
        if [ -n "$GITHUB_REPO" ]; then
            cd wwwdata && git pull && cd ..
            print_success "✅ Код обновлен"
        else
            print_error "🚫 GitHub репозиторий не настроен"
        fi
        ;;
    "send-config")
        send_config_to_telegram
        ;;
    *)
        echo -e "${BLUE}🎯 Использование: $0 {команда}${NC}"
        echo ""
        echo "🔧 Основные команды:"
        echo "  $0 start                    🚀 Запуск всех сервисов"
        echo "  $0 stop                     🛑 Остановка всех сервисов"
        echo "  $0 restart                  🔃 Перезапуск всех сервисов"
        echo "  $0 rebuild [сервис]         🔨 Пересборка контейнеров (после изменений в docker-compose.yml)"
        echo "  $0 build [сервис]           🔨 Алиас для rebuild"
        echo "  $0 logs [сервис]            📋 Показать логи (в реальном времени с -f)"
        echo "  $0 status                   📊 Показать статус контейнеров"
        echo ""
        echo "🛠️ Сервисы:"
        echo "  $0 ssh-php                  💻 Войти в контейнер PHP"
        echo "  $0 ssh-mysql                🗃️ Войти в контейнер MySQL"
        echo "  $0 ssh-nginx                🌐 Войти в контейнер Nginx"
        echo "  $0 ssh-telegram             🤖 Войти в контейнер Telegram API"
        echo "  $0 mysql                    📊 Подключиться к MySQL"
        echo "  $0 nginx                    🔄 Перезагрузить хостовой Nginx"
        echo ""
        echo "📊 Информация:"
        echo "  $0 info                     ℹ️ Показать текущую конфигурацию"
        echo "  $0 ports                    🔓 Показать открытые порты"
        echo "  $0 telegram-test           🧪 Отправить тестовое сообщение в Telegram"
        echo "  $0 send-config              📤 Отправить конфигурацию в Telegram"
        echo ""
        echo "⚙️ Управление:"
        echo "  $0 autostart enable         🔧 Включить автозапуск при загрузке"
        echo "  $0 autostart disable        🔧 Отключить автозапуск"
        echo "  $0 autostart status         🔧 Показать статус автозапуска"
        echo "  $0 ssl renew                🔐 Обновить SSL сертификаты"
        echo "  $0 ssl status               🔐 Показать статус SSL"
        echo "  $0 telegram stats           📊 Получить статистику Telegram Bot API"
        echo "  $0 telegram logs            📋 Показать логи Telegram Bot API"
        echo "  $0 telegram status          📊 Показать статус Telegram Bot API"
        echo "  $0 telegram restart         🔄 Перезапустить Telegram Bot API"
        echo "  $0 telegram files           📁 Показать файлы TDLib"
        echo "  $0 update                   📥 Обновить код из GitHub (если настроен)"
        exit 1
esac
