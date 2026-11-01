FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
	&& rm -rf /var/lib/apt/lists/*
RUN npm install -g bun

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /app

ARG GITHUB_PACKAGES_TOKEN
RUN if [ -n "${GITHUB_PACKAGES_TOKEN}" ]; then echo '[install.scopes]\nmacro-inc = { token = "'${GITHUB_PACKAGES_TOKEN}'", url = "https://npm.pkg.github.com" }' > /root/.bunfig.toml; fi

COPY . .
RUN bun install --frozen-lockfile || bun install

WORKDIR /app/services/ai-editing-worker
EXPOSE 8933

CMD ["sh", "-c", "\
  bun scripts/generate-sandbox.ts && \
  printf 'OPENAI_API_KEY=%s\\nANTHROPIC_API_KEY=%s\\nCEREBRAS_API_KEY=%s\\n' \
    \"${OPENAI_API_KEY}\" \
    \"${ANTHROPIC_API_KEY}\" \
    \"${CEREBRAS_API_KEY}\" \
    > .dev.vars && \
  npx wrangler dev \
    --env local \
    --ip 0.0.0.0 \
    --var SYNC_WS_BASE:ws://sync-service:8787\
"]
