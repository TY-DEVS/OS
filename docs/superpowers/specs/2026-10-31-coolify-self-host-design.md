# Specification: Self-Hosting Macro OS on Coolify

**Date**: 2026-10-31  
**Target Environment**: Coolify v4 (`pt0gmchbegaheyxaqbg45caa`)  
**Target Domain**: `https://macro.ty-dev.site`  
**Compose Location**: `docker/docker-compose.coolify.yml`  

---

## 1. Problem Statement & Objectives

Macro OS is an enterprise document and collaboration platform with a Rust backend, Cloudflare Worker microservices, and a React/Vite web application. 

Currently, the repository only includes:
1. `docker/docker-compose.yml`: Intended solely for host-based development via `just run_local`, which relies on `include:` directives, pre-existing external Docker networks (`databases`, `auth`), external volumes, host-run Vite dev servers, and host-driven migration scripts.
2. Coolify cannot deploy this local compose setup directly because Coolify does not parse compose `include:` blocks from Git builds, fails on missing external networks/volumes, and has no web frontend container or ingress routing.

### Objectives
- Provide a completely self-contained, standalone Docker Compose file (`docker/docker-compose.coolify.yml`).
- Include an automated Web Frontend build container and a unified Caddy Gateway that fronts all SPA pages and backend API/WebSocket routes under a single origin (`https://macro.ty-dev.site`).
- Include an automated **Init Container** that runs on stack startup to execute `sqlx` database migrations and create LocalStack S3 buckets and SQS queues.
- Ensure all persistent state (PostgreSQL, Redis, Kafka, OpenSearch, FusionAuth, LocalStack, Sync Service state) is preserved across container restarts and redeployments using named Docker volumes.
- Expose labels for Coolify's Traefik reverse proxy to route HTTPS with automatic Let's Encrypt certificates to the unified Gateway.

---

## 2. Architecture & Ingress Flow

```
                      [ Client Browser ]
                              │
                              │ HTTPS (443)
                              ▼
                [ Coolify Host: Traefik Proxy ]
              (macro.ty-dev.site / Let's Encrypt)
                              │
                              │ HTTP (Port 80)
                              ▼
             ┌─────────────────────────────────┐
             │     Macro Gateway (Caddy)       │
             │   - Serves /app/* (Static SPA)  │
             │   - Redirects / -> /app/        │
             │   - Routes /api/*               │
             │   - Routes /sync/* (WebSockets) │
             │   - Routes /static-file/*       │
             │   - Routes /mailpit/*           │
             └────────────────┬────────────────┘
                              │
       ┌──────────────────────┼──────────────────────┐
       │                      │                      │
       ▼                      ▼                      ▼
[ Web App SPA ]      [ Core Rust APIs ]     [ Worker Services ]
(Built static dist)   - auth (8080)          - sync-service (8787)
                      - doc-storage (8080)   - lexical-service (8096)
                      - email (8080)         - ai-editing (8933)
                      - contacts (8080)      - analytics-proxy (8098)
                      - notification (8080)  - websocket-service (6969)
                      - calendar (8080)
                      - static-file (8080)
                              │
                              ▼
                [ Stateful Infrastructure ]
                - PostgreSQL (pgvector:pg18)
                - Redis Stack
                - Apache Kafka (KRaft)
                - OpenSearch
                - LocalStack (S3 & SQS)
                - FusionAuth (Auth & IAM)
                - Mailpit (Dev email capture)
```

---

## 3. Services Inventory & Configuration

### A. Ingress & Frontend
1. **`gateway` (Caddy)**:
   - Image: Built from `docker/gateway.Dockerfile`.
   - Multi-stage:
     - Stage 1 builds `apps/web` with Bun (`bun run build`).
     - Stage 2 copies the compiled static distribution into a Caddy alpine image.
   - Configured with `docker/caddy/Caddyfile.coolify`.
   - Labels for Coolify Traefik:
     - `coolify.managed=true`
     - `traefik.enable=true`
     - `traefik.http.routers.<app-name>.rule=Host("macro.ty-dev.site")`
     - `traefik.http.routers.<app-name>.entrypoints=https`
     - `traefik.http.routers.<app-name>.tls=true`
     - `traefik.http.routers.<app-name>.tls.certresolver=letsencrypt`

### B. Core Stateful Infrastructure
1. **`postgres`**:
   - Image: `pgvector/pgvector:pg18`
   - Volume: `macro_pg_data:/var/lib/postgresql`
   - Database: `macrodb`, User: `user`, Password: `password`
   - Command: `postgres -c max_connections=500 -c shared_preload_libraries=pg_stat_statements`
2. **`redis`**:
   - Image: `redis/redis-stack:latest`
   - Volume: `macro_redis_data:/data`
3. **`kafka`**:
   - Image: `apache/kafka:3.9.1` (KRaft single node mode)
   - Volume: `macro_kafka_data:/var/lib/kafka/data`
4. **`opensearch`**:
   - Image: `macro-local-opensearch:dev` (built from `infra/local/opensearch`)
   - Volume: `macro_opensearch_data:/usr/share/opensearch/data`
5. **`localstack`**:
   - Image: `localstack/localstack:4`
   - Services: S3, SQS, DynamoDB
   - Volume: `macro_localstack_data:/var/lib/localstack`
6. **`fusionauth-db`**:
   - Image: `postgres:16.0-bookworm`
   - Volume: `macro_fusionauth_db_data:/var/lib/postgresql/data`
7. **`fusionauth`**:
   - Image: `fusionauth/fusionauth-app:1.62.1`
   - Volume: `macro_fusionauth_config:/usr/local/fusionauth/config`
   - Mounted Kickstart: `./infra/stacks/fusionauth-instance/kickstart:/usr/local/fusionauth/kickstart:ro`
8. **`mailpit`**:
   - Image: `axllent/mailpit:v1.20`
   - Captures transactional emails for viewing magic links at `/mailpit/`.

### C. Stack Bootstrap (`init-stack`)
- Image: Built from `docker/init.Dockerfile` (Alpine/Debian with `sqlx-cli`, `awscli`, `curl`, `jq`).
- Actions:
  1. Polls until `postgres` and `localstack` are healthy.
  2. Runs `sqlx migrate run` from `crates/macro_db_client/migrations`.
  3. Provisions S3 buckets: `doc-storage`, `static-file-storage`, `macro-email-attachments`, `bulk-upload-staging`, `agent-session-changes`, `github-pull-request-patches`.
  4. Provisions SQS queues: `delete-chat-handler-queue`, `contacts-queue`, `convert-service-queue`, `delete-document-handler-queue`, `email-service-scheduled-queue`, `notification-queue`, `document-upload-finalizer-queue`, etc.
  5. Exits cleanly with status 0 (`restart: "no"`).

### D. Rust Application Services
All Rust services utilize the shared image built from `docker/Dockerfile.dev` (`services_bundle`):
- `authentication-service` (port 8080)
- `connection_gateway` (port 8080)
- `contacts_service` (port 8080)
- `document_storage_service` (port 8080)
- `email_service` (port 8080)
- `email_pubsub_workers` (background worker)
- `calendar_service` (port 8080)
- `notification_service` (port 8080)
- `search_processing_service` (port 8080)
- `static_file_service` (port 8080)
- `unfurl_service` (port 8080)
- `image_proxy_service` (port 8080)
- `document_upload_finalizer` (background SQS consumer)

### E. Microservices & Emulated Workers
- `sync_service`: Built from `docker/sync-service.Dockerfile` (port 8787).
- `lexical_service`: Built from `docker/lexical-service.Dockerfile` (port 8096).
- `ai_editing_worker`: Built from `docker/ai-editing-worker.Dockerfile` (port 8933).
- `analytics_proxy`: Built from `docker/analytics-proxy.Dockerfile` (port 8098).
- `websocket_service`: Built from `docker/websocket-service.Dockerfile` (port 6969).

---

## 4. Volume Persistence & Network Topography

### Networks
- `macro_network`: Single internal bridge network spanning all services, databases, and the Gateway.

### Named Volumes
- `macro_pg_data`
- `macro_redis_data`
- `macro_kafka_data`
- `macro_opensearch_data`
- `macro_fusionauth_db_data`
- `macro_fusionauth_config`
- `macro_localstack_data`
- `macro_sync_state`

---

## 5. Security & Environment Variables

A `.env.coolify.example` will define all default secrets, service URLs, and tokens required for runtime, with sensible standalone defaults that can be overridden directly in Coolify's Environment Variables manager.

---

## 6. Verification & Acceptance Criteria
1. `docker/docker-compose.coolify.yml` is syntactically valid and contains no `include:` or `external: true` dependencies.
2. The Gateway container serves the frontend SPA at `/app/` and handles reverse proxying for all microservices.
3. The `init` container successfully provisions database tables, S3 buckets, and SQS queues.
4. Coolify application `pt0gmchbegaheyxaqbg45caa` is updated to point to the new Compose location and FQDN.
