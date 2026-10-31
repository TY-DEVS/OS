# Gateway & Frontend Multi-Stage Dockerfile
FROM oven/bun:1.2 AS web-builder

WORKDIR /app

# Copy root configuration, workspace files and manifests
COPY package.json bun.lock* ./
COPY apps/web/package.json ./apps/web/
COPY apps/web/patches ./apps/web/patches/
COPY packages ./packages/
COPY services/ai-editing-worker/package.json ./services/ai-editing-worker/
COPY services/lexical-service/package.json ./services/lexical-service/

# Install dependencies for the monorepo workspace
RUN bun install --frozen-lockfile || bun install

# Copy application sources
COPY apps/web ./apps/web/

WORKDIR /app/apps/web

# Build static production bundle
ENV NODE_ENV=production
ENV MODE=development
ENV VITE_LOCAL_SERVERS=ALL
ENV VITE_LOCAL_BACKEND_ORIGIN=same-origin
ENV VITE_AI_EDITING_WORKER_URL=/ai-editing

RUN bun run build || bunx --bun vite build -c vite.config.ts --base /app

# Runtime Caddy Gateway
FROM caddy:2-alpine AS runtime

COPY --from=web-builder /app/apps/web/dist /srv/frontend
COPY docker/caddy/Caddyfile.coolify /etc/caddy/Caddyfile

EXPOSE 80

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
