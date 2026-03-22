FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir \
    fastapi==0.115.5 \
    "uvicorn[standard]==0.32.1" \
    httpx==0.28.1 \
    aiosqlite==0.20.0 \
    pydantic==2.10.3
RUN mkdir -p /data
COPY main.py .
COPY static/ static/
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
