# Dockerfile Patterns

These are BASE patterns — starting points, not copy-paste templates. You MUST adapt every Dockerfile to the actual project: use the real package manager, real build commands, real entry point, real Node/Python version. Read the project's package.json/requirements.txt/go.mod to get the exact details.

If the project already has a working Dockerfile, prefer keeping it over generating a new one.

## Table of Contents
- [Static Site / SPA (Astro, Vite, React, Vue, etc.)](#static-site--spa)
- [Node.js API (Fastify, Express, etc.)](#nodejs-api)
- [Node.js API with Prisma](#nodejs-api-with-prisma)
- [Python API (FastAPI, Flask, Django)](#python-api)
- [Go API](#go-api)
- [Fullstack (frontend + backend)](#fullstack)
- [.dockerignore](#dockerignore)

---

## Static Site / SPA

For projects that build to static files served by nginx (Astro, Vite React, Vue, etc.).

**Detect**: `astro.config.*`, `vite.config.*`, framework in package.json (`astro`, `@vitejs/plugin-react`, `vue`), build output to `dist/` or `build/`.

```dockerfile
# --- Stage 1: Build ---
FROM node:22-alpine AS build
WORKDIR /app

# Detect package manager: check for pnpm-lock.yaml, yarn.lock, or package-lock.json
# If pnpm:
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# If npm:
# COPY package.json package-lock.json ./
# RUN npm ci

# If yarn:
# COPY package.json yarn.lock ./
# RUN yarn install --frozen-lockfile

# Build args for frontend env vars (VITE_*, NEXT_PUBLIC_*, etc.)
# ARG VITE_API_BASE_URL
# ARG VITE_GOOGLE_CLIENT_ID

COPY . .
RUN pnpm build  # or npm run build / yarn build

# --- Stage 2: Serve ---
FROM nginx:alpine AS runtime
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
```

**Companion nginx.conf** (generate alongside if missing):
```nginx
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # SPA fallback
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache static assets
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Gzip
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
}
```

---

## Node.js API

For backend APIs without an ORM that needs migrations.

**Detect**: `express`, `fastify`, `koa`, `hapi` in package.json dependencies, `server.ts`/`server.js`/`index.ts`/`app.ts` as entry.

```dockerfile
FROM node:20-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-slim AS runtime
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./
EXPOSE 3000
CMD ["node", "dist/server.js"]
```

---

## Node.js API with Prisma

Same as above but includes Prisma ORM. The init container in K8s handles migrations.

**Detect**: `prisma` in devDependencies, `prisma/schema.prisma` file.

```dockerfile
FROM node:20-slim AS build
WORKDIR /app

# System deps for Prisma (openssl needed for Prisma client)
RUN apt-get update && apt-get install -y openssl ca-certificates && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npx prisma generate
RUN npm run build
RUN npm prune --omit=dev

FROM node:20-slim AS runtime
WORKDIR /app
RUN apt-get update && apt-get install -y openssl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./
COPY --from=build /app/prisma ./prisma
EXPOSE 3000
CMD ["node", "dist/server.js"]
```

Note: When this pattern is detected, the K8s deployment must include an initContainer that runs `npx prisma db push --skip-generate` (see k8s-patterns.md).

---

## Python API

For FastAPI, Flask, Django backends.

**Detect**: `requirements.txt` or `pyproject.toml`, `fastapi`/`flask`/`django` in dependencies.

```dockerfile
FROM python:3.12-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim AS runtime
WORKDIR /app
COPY --from=build /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=build /usr/local/bin /usr/local/bin
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Adjust CMD for Flask (`gunicorn`) or Django (`gunicorn myproject.wsgi`).

---

## Go API

For Go web servers (Gin, Echo, Fiber, Chi, net/http).

**Detect**: `go.mod` file, `main.go` or `cmd/` directory.

```dockerfile
FROM golang:1.22-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Adapt binary name and path to actual project structure
RUN CGO_ENABLED=0 GOOS=linux go build -o /app/server ./cmd/server

FROM alpine:3.19 AS runtime
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=build /app/server .
EXPOSE 8080
CMD ["./server"]
```

Adapt: check `go.mod` for Go version, check `main.go` location (could be `./`, `./cmd/api/`, `./cmd/server/`), check the default port in source code.

---

## Fullstack

For projects with separate `frontend/` and `backend/` directories.

Generate TWO Dockerfiles:
- `backend/Dockerfile` → Use the Node.js API or Python API pattern
- `frontend/Dockerfile` → Use the Static Site / SPA pattern

The frontend build needs build args for API URL:
```dockerfile
ARG VITE_API_BASE_URL
```

---

## .dockerignore

Always generate a `.dockerignore` if missing:

```
node_modules
dist
build
.git
.gitignore
.env
.env.*
*.md
.vscode
.idea
.DS_Store
docker-compose*.yml
k8s/
.gitea/
.github/
```
