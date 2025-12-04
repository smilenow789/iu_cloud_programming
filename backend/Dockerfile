# Python Image
FROM python:3.10-slim

# Arbeitsverzeichnis im Container
WORKDIR /app

# Requirements
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Restlichen Code
COPY . .

# gunicorn als Webserver und $PORT ist 8080
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 main:app