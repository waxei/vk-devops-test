#!/bin/bash

# Останавливаем скрипт, если используем необъявленные переменные
set -u

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

log "INFO" "Monitoring started. Target: $TARGET_URL"

# Функция ожидания готовности сервиса при старте (без логирования ошибок)
wait_for_service() {
    local wait_seconds=5  # Ждем 5 секунд
    local elapsed=0
    
    while [ $elapsed -lt $wait_seconds ]; do
        if http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$TARGET_URL" 2>/dev/null) && [ "$http_code" -eq 200 ]; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    
    # Если не дождались, логируем предупреждение и продолжаем
    log "WARN" "Service not ready after $wait_seconds seconds. Starting monitoring anyway."
    return 1
}

# Ждем готовности сервиса перед началом мониторинга
wait_for_service

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
            # При нормальной работе не спамим в логи, если необходима запись в логи, то используем log "INFO" "Service healthy"
        else
            # Код ответа не 200
            ((FAIL_COUNT++))
            log "WARN" "Bad response: $http_code. Attempt $FAIL_COUNT/$MAX_RETRIES"
        fi
    else
        # Curl вернул ошибку исполнения (например, connection refused)
        ((FAIL_COUNT++))
        log "WARN" "Connection error. Attempt $FAIL_COUNT/$MAX_RETRIES"
    fi

    # Проверка порога ошибок
    if [ "$FAIL_COUNT" -ge "$MAX_RETRIES" ]; then
        log "ERROR" "Error limit reached ($FAIL_COUNT). Restarting service $SERVICE_NAME..."
        
        # Перезапуск через systemctl
        if systemctl restart "$SERVICE_NAME"; then
            log "INFO" "Restart command executed."
            
            # Даем сервису время на старт
            sleep 5
            
            # Проверяем успешность рестарта: статус сервиса должен быть active
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                # Дополнительная проверка: health-check должен отвечать
                if http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$TARGET_URL") && [ "$http_code" -eq 200 ]; then
                    log "INFO" "Service successfully restarted and responding to requests."
                    FAIL_COUNT=0
                else
                    log "WARN" "Service started, but health-check is not responding (code: ${http_code:-N/A}). Continuing monitoring."
                    # Не сбрасываем счетчик, чтобы не зациклиться на перезапусках
                    FAIL_COUNT=$((MAX_RETRIES - 1))
                fi
            else
                log "CRITICAL" "Service did not start after restart! Status: $(systemctl is-active $SERVICE_NAME 2>/dev/null || echo 'unknown')"
                # Не сбрасываем счетчик, чтобы попробовать еще раз
                FAIL_COUNT=$((MAX_RETRIES - 1))
            fi
        else
            log "CRITICAL" "Failed to execute restart command! Check access permissions."
            # Не сбрасываем счетчик, чтобы попробовать еще раз
            FAIL_COUNT=$((MAX_RETRIES - 1))
        fi
    fi

    sleep "$CHECK_INTERVAL"
done