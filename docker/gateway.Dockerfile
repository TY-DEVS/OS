# Gateway & Frontend Multi-Stage Dockerfile
FROM oven/bun:1.2 AS web-builder

WORKDIR /app

# Copy repository sources (excluding paths filtered by .dockerignore)
COPY . .

# Install dependencies for the monorepo workspace
RUN bun install --frozen-lockfile || bun install

WORKDIR /app/apps/web

# Build static production bundle
ENV NODE_ENV=production
ENV MODE=development
ENV VITE_LOCAL_SERVERS=ALL
ENV VITE_LOCAL_BACKEND_ORIGIN=same-origin
ENV VITE_AI_EDITING_WORKER_URL=/ai-editing

RUN bunx --bun vite build -c vite.config.ts --base /app \
    && mkdir -p ./dist \
    && echo "1.0.0" > ./dist/semver.txt \
    && (bun ./scripts/write-bundle-manifest.mjs || true)

# Runtime Caddy Gateway
FROM caddy:2-alpine AS runtime

COPY --from=web-builder /app/apps/web/dist /srv/frontend
COPY docker/caddy/Caddyfile.coolify /etc/caddy/Caddyfile

EXPOSE 80

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
