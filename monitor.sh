#!/bin/bash

# Останавливаем скрипт, если используем необъявленные переменные
set -u

# Проверка наличия curl (необходим для проверки доступности)
if ! command -v curl &> /dev/null; then
    echo "ERROR: curl не установлен. Установите: apt-get install curl (или yum/dnf)" >&2
    exit 1
fi

# Путь к конфигу по умолчанию (можно переопределить через ENV)
CONFIG_PATH="${CONFIG_PATH:-/etc/monitoring/config.env}"

# Проверка наличия конфига
if [ -f "$CONFIG_PATH" ]; then
    source "$CONFIG_PATH"
else
    echo "CRITICAL: Config not found at $CONFIG_PATH" >&2
    exit 1
fi

# Счетчик ошибок
FAIL_COUNT=0

# Функция логирования с timestamp
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

log "INFO" "Мониторинг запущен. Target: $TARGET_URL"

# Бесконечный цикл проверки
while true; do
    # curl: -s (silent), -o /dev/null (без тела), -w (код ответа), таймаут 5 сек
    if http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$TARGET_URL"); then
        
        if [ "$http_code" -eq 200 ]; then
            # Успех: сбрасываем счетчик ошибок, если он был > 0
            if [ "$FAIL_COUNT" -gt 0 ]; then
                log "INFO" "Сервис восстановился после $FAIL_COUNT сбоев."
                FAIL_COUNT=0
            fi
            # При нормальной работе не спамим в логи (или можно писать INFO редко)
        else
            # Код ответа не 200
            ((FAIL_COUNT++))
            log "WARN" "Плохой ответ: $http_code. Попытка $FAIL_COUNT/$MAX_RETRIES"
        fi
    else
        # Curl вернул ошибку исполнения (например, connection refused)
        ((FAIL_COUNT++))
        log "WARN" "Ошибка соединения. Попытка $FAIL_COUNT/$MAX_RETRIES"
    fi

    # Проверка порога ошибок
    if [ "$FAIL_COUNT" -ge "$MAX_RETRIES" ]; then
        log "ERROR" "Достигнут лимит ошибок ($FAIL_COUNT). Перезапуск сервиса $SERVICE_NAME..."
        
        # Перезапуск через systemctl
        if systemctl restart "$SERVICE_NAME"; then
            log "INFO" "Команда перезапуска выполнена."
            
            # Даем сервису время на старт
            sleep 5
            
            # Проверяем успешность рестарта: статус сервиса должен быть active
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                # Дополнительная проверка: health-check должен отвечать
                if http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$TARGET_URL") && [ "$http_code" -eq 200 ]; then
                    log "INFO" "Сервис успешно перезапущен и отвечает на запросы."
                    FAIL_COUNT=0
                else
                    log "WARN" "Сервис запущен, но health-check не отвечает (код: ${http_code:-N/A}). Продолжаем мониторинг."
                    # Не сбрасываем счетчик, чтобы не зациклиться на перезапусках
                    FAIL_COUNT=$((MAX_RETRIES - 1))
                fi
            else
                log "CRITICAL" "Сервис не запустился после перезапуска! Статус: $(systemctl is-active $SERVICE_NAME 2>/dev/null || echo 'unknown')"
                # Не сбрасываем счетчик, чтобы попробовать еще раз
                FAIL_COUNT=$((MAX_RETRIES - 1))
            fi
        else
            log "CRITICAL" "Не удалось выполнить команду перезапуска! Проверьте права доступа."
            # Не сбрасываем счетчик, чтобы попробовать еще раз
            FAIL_COUNT=$((MAX_RETRIES - 1))
        fi
    fi

    sleep "$CHECK_INTERVAL"
done