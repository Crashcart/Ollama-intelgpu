# Docker Image Optimization Guide

Reduce Docker image size from GB to MB using proven techniques. Target: 90%+ size reduction.

## Quick Wins

| Technique | Impact | Effort |
|-----------|--------|--------|
| Multi-stage builds | 50-80% | Medium |
| Alpine base image | 30-50% | Low |
| Remove build tools | 20-40% | Low |
| Clean caches | 10-30% | Low |
| .dockerignore | 5-20% | Low |

---

## 1. Use Lightweight Base Images

### Alpine Linux (5MB)
```dockerfile
FROM alpine:3.19
```
- 95% smaller than ubuntu
- Ideal for most applications

### Distroless (10-50MB)
```dockerfile
FROM gcr.io/distroless/base
```
- No shell, no package manager
- Maximum security and minimal size

---

## 2. Multi-Stage Builds

### Before (500MB)
```dockerfile
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y gcc make cmake
COPY . /app
WORKDIR /app
RUN make build
CMD ["./app"]
```

### After (25MB)
```dockerfile
# Stage 1: Build
FROM ubuntu:22.04 AS builder
RUN apt-get update && apt-get install -y gcc make cmake
COPY . /app
WORKDIR /app
RUN make build

# Stage 2: Runtime
FROM alpine:3.19
COPY --from=builder /app/app /app/app
CMD ["/app/app"]
```

**Result:** 95% size reduction.

---

## 3. Remove Build Dependencies

```dockerfile
RUN apk add --no-cache gcc make && \
    apk del gcc make && \
    rm -rf /root/.cache /var/cache/apk/*
```

---

## 4. Create .dockerignore

```
node_modules/
.git/
.github/
README.md
*.md
.env
.vscode/
dist/
build/
coverage/
```

**Impact:** 50%+ reduction in build context.

---

## 5. Layer Ordering

Put frequently-changing code LAST.

```dockerfile
FROM alpine:3.19

# Static dependencies first
RUN apk add --no-cache python3 py3-pip

# Copy requirements (occasional changes)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy code last (frequent changes)
COPY . /app
WORKDIR /app
CMD ["python3", "app.py"]
```

---

## 6. Language Examples

### Node.js
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY . .
CMD ["node", "index.js"]
```

### Python
```dockerfile
FROM python:3.11-alpine AS builder
RUN apk add --no-cache gcc musl-dev
COPY requirements.txt .
RUN pip install --user --no-cache-dir -r requirements.txt

FROM python:3.11-alpine
COPY --from=builder /root/.local /root/.local
COPY . /app
WORKDIR /app
ENV PATH=/root/.local/bin:$PATH
CMD ["python", "app.py"]
```

### Go
```dockerfile
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY . .
RUN go build -ldflags="-s -w" -o app

FROM alpine:3.19
COPY --from=builder /app/app /app
CMD ["/app"]
```

---

## 7. Scratch for Binaries

```dockerfile
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o app

FROM scratch
COPY --from=builder /app/app /app
ENTRYPOINT ["/app"]
```

**Result:** 10-50MB instead of 300MB+

---

## 8. Verification

### Check Size
```bash
docker images | grep your-image
```

### Analyze Layers
```bash
docker history your-image
```

### Dive Analysis
```bash
dive your-image
```

---

## Real-World Results

- **Python Flask:** 850MB → 85MB (90%)
- **Node.js:** 450MB → 45MB (90%)
- **Go:** 300MB → 15MB (95%)
- **Java:** 650MB → 180MB (72%)

---

## Checklist

- [ ] Lightweight base image?
- [ ] Multi-stage build?
- [ ] Build tools removed?
- [ ] .dockerignore created?
- [ ] Caches cleaned?
- [ ] Temp files removed?
- [ ] Layers ordered?
- [ ] Specific versions (not :latest)?
- [ ] Binary stripped?

---

## References

- [My Docker Image Was 2.4GB. I Cut It to 24MB](https://medium.com/engineering-playbook/my-docker-image-was-2-4gb-i-cut-it-to-24mb-heres-every-optimization-that-actually-worked-46792bd23da4)
- [Docker Best Practices](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
- [Dive - Image Analysis](https://github.com/wagoodman/dive)