# Переменные
INSTALL_DIR = /opt/test-monitoring
CONFIG_DIR = /etc/monitoring
LOG_DIR = /var/log/test-monitoring
SERVICE_USER = monitoring-user

# Определяем путь к python3 один раз
PYTHON_BIN := $(shell command -v python3 2>/dev/null)

.PHONY: all install uninstall check-deps

all:
	@echo "Доступные команды:"
	@echo "  make install   - Установить сервис и мониторинг"
	@echo "  make uninstall - Удалить все компоненты"

# Отдельный таргет для проверки зависимостей (вызывается перед install)
check-deps:
	@echo "Проверка зависимостей..."
	@command -v curl >/dev/null 2>&1 || { echo "ERROR: 'curl' не найден. Установите его вручную."; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "ERROR: 'python3' не найден. Установите его вручную."; exit 1; }
	@echo "Зависимости OK."

install: check-deps
	@echo "=== Начало установки ==="
	
	# 1. Безопасность: Создаем пользователя (если нет)
	@getent passwd $(SERVICE_USER) >/dev/null 2>&1 || \
		(useradd -r -s /bin/false $(SERVICE_USER) && echo "Пользователь $(SERVICE_USER) создан")
	
	# 2. Структура
	mkdir -p $(INSTALL_DIR)
	mkdir -p $(CONFIG_DIR)
	mkdir -p $(LOG_DIR)
	
	# 3. Копирование файлов
	# ВАЖНО: Убедись, что локальный файл называется app.py или webapp.py
	cp app.py $(INSTALL_DIR)/
	cp monitor.sh $(INSTALL_DIR)/
	cp config.env $(CONFIG_DIR)/
	
	# 4. Права доступа
	chmod +x $(INSTALL_DIR)/*.py $(INSTALL_DIR)/*.sh
	chown -R $(SERVICE_USER):$(SERVICE_USER) $(INSTALL_DIR)
	chown -R $(SERVICE_USER):$(SERVICE_USER) $(LOG_DIR)
	
	# 5. Logrotate (используем printf для надежности переноса строк)
	@printf "$(LOG_DIR)/*.log {\n  daily\n  rotate 7\n  compress\n  missingok\n  notifempty\n  create 0640 $(SERVICE_USER) $(SERVICE_USER)\n}\n" > /etc/logrotate.d/test-monitoring
	
	# 6. Создание сервисов Systemd
	# Сервис приложения (перенаправляем stdout/stderr в лог-файл мониторинга)
	@printf "[Unit]\nDescription=Simple Hello World App\nAfter=network.target\n\n[Service]\nExecStart=$(PYTHON_BIN) $(INSTALL_DIR)/app.py\nEnvironmentFile=$(CONFIG_DIR)/config.env\nUser=$(SERVICE_USER)\nRestart=on-failure\nStandardOutput=append:$(LOG_DIR)/monitor.log\nStandardError=append:$(LOG_DIR)/monitor.log\n\n[Install]\nWantedBy=multi-user.target\n" > /etc/systemd/system/test-app.service
	
	# Сервис мониторинга
	@printf "[Unit]\nDescription=Monitor for Web App\nAfter=test-app.service\n\n[Service]\nExecStart=$(INSTALL_DIR)/monitor.sh\nEnvironmentFile=$(CONFIG_DIR)/config.env\nUser=root\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n" > /etc/systemd/system/test-monitor.service
	
	# 7. Запуск и применение
	systemctl daemon-reload
	systemctl enable test-app test-monitor
	systemctl restart test-app test-monitor
	
	@echo "=== Установка завершена ==="
	@echo "Статус: systemctl status test-monitor"

uninstall:
	@echo "=== Удаление системы ==="
	systemctl stop test-app test-monitor || true
	systemctl disable test-app test-monitor || true
	
	rm -f /etc/systemd/system/test-app.service
	rm -f /etc/systemd/system/test-monitor.service
	rm -f /etc/logrotate.d/test-monitoring
	
	systemctl daemon-reload
	
	rm -rf $(INSTALL_DIR)
	rm -rf $(CONFIG_DIR)
	rm -rf $(LOG_DIR)
	
	userdel $(SERVICE_USER) || true
	@echo "=== Система очищена ==="