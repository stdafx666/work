# ============================================================
# FlyPass API — Dockerfile
# Python + FastAPI + все зависимости
# ============================================================

FROM python:3.11-slim

# Не создавать .pyc файлы и сразу выводить логи
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Системные зависимости
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev curl \
    && rm -rf /var/lib/apt/lists/*

# Зависимости Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Порт FastAPI
EXPOSE 8000

# Запуск с горячей перезагрузкой (в продакшне --reload убрать)
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
