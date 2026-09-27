# syntax=docker/dockerfile:1.7

# ---- build ----
FROM node:24-alpine AS build
ENV PNPM_HOME=/pnpm PATH=/pnpm:$PATH
RUN corepack enable
WORKDIR /app

# Lockfile-only layer: dependency download is cached until pnpm-lock.yaml changes
COPY package.json pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm fetch --store-dir /pnpm/store
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --offline --frozen-lockfile --store-dir /pnpm/store

COPY . .
ARG VITE_API_URL=http://localhost/api
ENV VITE_API_URL=$VITE_API_URL
RUN pnpm build

# ---- runtime: static files only, non-root nginx on :8080 ----
FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY <<'EOF' /etc/nginx/conf.d/default.conf
# Vite emits content-hashed filenames under /assets; index.html must always revalidate.
# (map + one server-level add_header: a location-level add_header would drop the others)
map $uri $cache_control {
    ~^/assets/ "public, max-age=31536000, immutable";
    default    "no-cache";
}

server {
    listen 8080;
    root /usr/share/nginx/html;
    server_tokens off;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Cache-Control $cache_control always;

    location /assets/ {
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/ >/dev/null || exit 1
