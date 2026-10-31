#!/usr/bin/env bash
set -eo pipefail

echo "=== [INIT-STACK] Starting Macro OS initialization ==="

export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-test}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-test}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
export LOCAL_AWS_URL=${LOCAL_AWS_URL:-http://localstack:4566}
export DATABASE_URL=${DATABASE_URL:-postgres://user:password@postgres:5432/macrodb}

# 1. Wait for PostgreSQL
echo "Waiting for PostgreSQL at postgres:5432..."
until pg_isready -h postgres -p 5432 -U user; do
  echo "PostgreSQL not ready yet, sleeping 2s..."
  sleep 2
done
echo "PostgreSQL is ready!"

# 2. Run Database Migrations
echo "Running database migrations via macro_db_migrator..."
/app/macro_db_migrator
echo "Database migrations complete!"

# 3. Wait for LocalStack
echo "Waiting for LocalStack at $LOCAL_AWS_URL..."
until curl -fsS "$LOCAL_AWS_URL/_localstack/health" >/dev/null 2>&1 || curl -fsS "$LOCAL_AWS_URL" >/dev/null 2>&1; do
  echo "LocalStack not ready yet, sleeping 2s..."
  sleep 2
done
echo "LocalStack is ready!"

# 4. Create S3 Buckets
echo "Creating LocalStack S3 buckets..."
for bucket in macro-email-attachments doc-storage docx-upload static-file-storage bulk-upload-staging macro-call-recording-local agent-session-changes github-pull-request-patches; do
  aws --endpoint-url="$LOCAL_AWS_URL" s3 mb "s3://$bucket" 2>/dev/null || true
  aws --endpoint-url="$LOCAL_AWS_URL" s3api put-bucket-cors --bucket "$bucket" --cors-configuration '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","PUT","POST","DELETE","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["ETag"],"MaxAgeSeconds":3600}]}' 2>/dev/null || true
done
echo "S3 buckets created!"

# 5. Create SQS Queues
echo "Creating LocalStack SQS queues..."
QUEUES=(
  "notification-queue"
  "notification-ingress-queue"
  "push-delivery-queue"
  "email-service-backfill-queue"
  "email-service-crm-cleanup-queue"
  "delete-chat-handler-queue"
  "contacts-queue"
  "convert-service-queue"
  "delete-document-handler-queue"
  "document-upload-finalizer-queue"
  "document-text-extractor-lambda-queue"
  "email-service-scheduled-queue"
  "email-service-gmail-inbox-sync-queue"
  "email-service-gmail-inbox-retry-queue"
  "email-service-gmail-ops-queue"
  "email-service-gmail-ops-retry-queue"
  "email-service-refresh-queue"
  "search-event-queue"
  "ai-projection-queue"
  "email-sfs-delete-queue"
  "email-service-sfs-mapper-queue"
  "static-file-s3-event-notification-queue"
  "reminder-dispatch-queue"
  "calendar-reminder-dispatch-queue"
)

for q in "${QUEUES[@]}"; do
  aws --endpoint-url="$LOCAL_AWS_URL" sqs create-queue --queue-name "$q" 2>/dev/null || true
done

# Fifo Queue
aws --endpoint-url="$LOCAL_AWS_URL" sqs create-queue --queue-name "webhook-event-queue.fifo" --attributes FifoQueue=true 2>/dev/null || true
echo "SQS queues created!"

# 6. Create DynamoDB Tables
echo "Creating DynamoDB tables..."
aws --endpoint-url="$LOCAL_AWS_URL" dynamodb create-table \
  --table-name bulk-upload \
  --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[{"IndexName":"DocumentPkIndex","KeySchema":[{"AttributeName":"SK","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}]' 2>/dev/null || true

aws --endpoint-url="$LOCAL_AWS_URL" dynamodb create-table \
  --table-name connection-gateway-table \
  --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[{"IndexName":"ConnectionPkIndex","KeySchema":[{"AttributeName":"SK","KeyType":"HASH"},{"AttributeName":"PK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' 2>/dev/null || true

aws --endpoint-url="$LOCAL_AWS_URL" dynamodb create-table \
  --table-name static-file-metadata \
  --attribute-definitions AttributeName=file_id,AttributeType=S \
  --key-schema AttributeName=file_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST 2>/dev/null || true
echo "DynamoDB tables created!"

# 7. Configure S3 ObjectCreated Notifications to SQS
queue_url="$LOCAL_AWS_URL/000000000000/document-upload-finalizer-queue"
policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"sqs:SendMessage","Resource":"arn:aws:sqs:us-east-1:000000000000:document-upload-finalizer-queue","Condition":{"ArnEquals":{"aws:SourceArn":"arn:aws:s3:::doc-storage"}}}]}'
aws --endpoint-url="$LOCAL_AWS_URL" sqs set-queue-attributes --queue-url "$queue_url" --attributes "{\"Policy\": $(echo "$policy" | jq -R .)}" 2>/dev/null || true

cat <<'EOF' > /tmp/notification.json
{
  "QueueConfigurations": [
    {
      "QueueArn": "arn:aws:sqs:us-east-1:000000000000:document-upload-finalizer-queue",
      "Events": ["s3:ObjectCreated:*"]
    }
  ]
}
EOF
aws --endpoint-url="$LOCAL_AWS_URL" s3api put-bucket-notification-configuration --bucket doc-storage --notification-configuration file:///tmp/notification.json 2>/dev/null || true

echo "=== [INIT-STACK] Initialization completed successfully! ==="
