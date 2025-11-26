#!/usr/bin/env python3

import http.server
import socketserver
import os
import signal
import sys

# Получаем порт из окружения или ставим 8080
PORT = int(os.environ.get('APP_PORT', 8080))

class RequestHandler(http.server.BaseHTTPRequestHandler):
    """
    Обработчик запросов с разделением логики:
    GET /       -> Бизнес-логика (Hello World!)
    GET /health -> Технический мониторинг (200 OK)
    """
    
    def do_GET(self):
        if self.path == '/health':
            # Легковесная проверка: просто возвращаем 200
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
        elif self.path == '/':
            # Основная логика приложения
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Hello World!")
        else:
            self.send_error(404, "Not Found")
    
    # Мы используем свой внешний логгер (monitor.sh).
    def log_message(self, format, *args):
        return

# Функция для корректного завершения при SIGTERM (от systemd)
def signal_handler(sig, frame):
    sys.exit(0)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal_handler)
    try:
        # allow_reuse_address нужен для быстрого перезапуска без ошибки "Address already in use"
        socketserver.TCPServer.allow_reuse_address = True
        with socketserver.TCPServer(("", PORT), RequestHandler) as httpd:
            httpd.serve_forever()
    except KeyboardInterrupt:
        pass