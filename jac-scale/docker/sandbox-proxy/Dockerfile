FROM python:3.12-slim

RUN pip install --no-cache-dir aiohttp kubernetes_asyncio

COPY proxy.py /app/proxy.py
WORKDIR /app

EXPOSE 8080

CMD ["python", "proxy.py"]
