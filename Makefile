# Переменные установки
INSTALL_DIR = /opt/test-monitoring
CONFIG_DIR = /etc/monitoring
LOG_DIR = /var/log/test-monitoring
SERVICE_USER = monitoring-user

.PHONY: all install uninstall

all:
	@echo "Доступные команды:"
	@echo "  make install   - Установить приложение и мониторинг"
	@echo "  make uninstall - Удалить все компоненты"

install:
	@echo "=== Начало установки ==="
	
	# 0. Зависимости: Проверяем и устанавливаем curl (необходим для мониторинга)
	@if ! command -v curl &> /dev/null; then \
		echo "curl не найден, устанавливаем..."; \
		if command -v apt-get &> /dev/null; then \
			apt-get update && apt-get install -y curl; \
		elif command -v yum &> /dev/null; then \
			yum install -y curl; \
		elif command -v dnf &> /dev/null; then \
			dnf install -y curl; \
		else \
			echo "ERROR: Не удалось определить менеджер пакетов. Установите curl вручную."; \
			exit 1; \
		fi; \
	else \
		echo "curl уже установлен"; \
	fi
	
	# 1. Безопасность: Создаем системного пользователя без домашней папки
	@id -u $(SERVICE_USER) &>/dev/null || useradd -r -s /bin/false $(SERVICE_USER)
	
	# 2. Структура: Создаем директории
	mkdir -p $(INSTALL_DIR)
	mkdir -p $(CONFIG_DIR)
	mkdir -p $(LOG_DIR)
	
	# 3. Файлы: Копируем скрипты и конфиг
	cp app.py $(INSTALL_DIR)/
	cp monitor.sh $(INSTALL_DIR)/
	cp config.env $(CONFIG_DIR)/
	
	# 4. Права: Настраиваем владельцев и права исполнения
	chmod +x $(INSTALL_DIR)/*.py $(INSTALL_DIR)/*.sh
	chown -R $(SERVICE_USER):$(SERVICE_USER) $(INSTALL_DIR)
	chown -R $(SERVICE_USER):$(SERVICE_USER) $(LOG_DIR)
	
	# 5. Logrotate: Создаем конфиг ротации логов (чтобы диск не переполнился)
	@echo "$(LOG_DIR)/*.log {\n  daily\n  rotate 7\n  compress\n  missingok\n  notifempty\n  create 0640 $(SERVICE_USER) $(SERVICE_USER)\n}" > /etc/logrotate.d/test-monitoring
	
	# 6. Systemd: Генерируем сервис приложения
	@echo "[Unit]\nDescription=Simple Hello World App\nAfter=network.target\n\n[Service]\nExecStart=/usr/bin/python3 $(INSTALL_DIR)/app.py\nEnvironmentFile=$(CONFIG_DIR)/config.env\nUser=$(SERVICE_USER)\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target" > /etc/systemd/system/test-app.service
	
	# 7. Systemd: Генерируем сервис мониторинга
	# Запускаем от root, так как ему нужно право делать systemctl restart другого сервиса
	@echo "[Unit]\nDescription=Monitor for Web App\nAfter=test-app.service\n\n[Service]\nExecStart=$(INSTALL_DIR)/monitor.sh\nEnvironmentFile=$(CONFIG_DIR)/config.env\nUser=root\nRestart=always\n\n[Install]\nWantedBy=multi-user.target" > /etc/systemd/system/test-monitor.service
	
	# 8. Запуск: Перечитываем конфиги и стартуем
	systemctl daemon-reload
	systemctl enable test-app test-monitor
	systemctl restart test-app test-monitor
	
	@echo "=== Установка/Обновление завершено ==="
	@echo "Проверка статуса: systemctl status test-monitor"

uninstall:
	@echo "=== Удаление системы ==="
	systemctl stop test-app test-monitor || true
	systemctl disable test-app test-monitor || true
	rm -f /etc/systemd/system/test-app.service
	rm -f /etc/systemd/system/test-monitor.service
	rm -f /etc/logrotate.d/test-monitoring
	rm -rf $(INSTALL_DIR)
	# Конфиги и логи опционально можно оставить, но для чистоты удалим
	rm -rf $(CONFIG_DIR)
	rm -rf $(LOG_DIR)
	systemctl daemon-reload
	@echo "=== Система удалена ==="