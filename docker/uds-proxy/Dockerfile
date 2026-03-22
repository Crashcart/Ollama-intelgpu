FROM python:3.11-alpine
WORKDIR /app
RUN mkdir -p /sockets
COPY proxy.py .
CMD ["python3", "-u", "proxy.py"]
