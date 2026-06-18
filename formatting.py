FROM python:3.12-slim

WORKDIR /app

COPY pyproject.toml .
COPY core.py watchlist.py formatting.py mcp_server.py app.py ./

RUN pip install --no-cache-dir ".[asgi]"

RUN mkdir -p /app/data
ENV WATCHLIST_STORE_PATH=/app/data/watchlist.json

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
