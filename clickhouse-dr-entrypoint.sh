#!/bin/bash
# Entrypoint script for ClickHouse DR Docker container

set -e

# Create logs directory if it doesn't exist
mkdir -p /app/logs

# Check if config file exists
if [ ! -f /app/config/ch-dr-config.yaml ]; then
    echo "Configuration file not found. Creating sample configuration..."
    /app/scripts/ch-dr.sh --onprem create-config /app/config/ch-dr-config.yaml
    echo "Please update the configuration file at /app/config/ch-dr-config.yaml"
fi

# Configure S3 if environment variables are provided
if [ ! -z "$S3_ACCESS_KEY" ] && [ ! -z "$S3_SECRET_KEY" ]; then
    echo "Configuring S3 credentials..."
    s3cmd --configure --access_key="$S3_ACCESS_KEY" --secret_key="$S3_SECRET_KEY" \
    --region="$S3_REGION" --bucket-location="$S3_REGION" \
    --use-https --dump-config > /root/.s3cfg

    # Update config file
    sed -i "s/use_s3: false/use_s3: true/" /app/config/ch-dr-config.yaml
    
    if [ ! -z "$S3_BUCKET" ]; then
        sed -i "s/s3_bucket: your-bucket/s3_bucket: $S3_BUCKET/" /app/config/ch-dr-config.yaml
    fi
    
    if [ ! -z "$S3_PATH" ]; then
        sed -i "s|s3_path: clickhouse/backups|s3_path: $S3_PATH|" /app/config/ch-dr-config.yaml
    fi
fi

# Update ClickHouse connection details if provided
if [ ! -z "$CLICKHOUSE_HOST" ]; then
    sed -i "s/host: localhost/host: $CLICKHOUSE_HOST/" /app/config/ch-dr-config.yaml
fi

if [ ! -z "$CLICKHOUSE_PORT" ]; then
    sed -i "s/port: 9000/port: $CLICKHOUSE_PORT/" /app/config/ch-dr-config.yaml
fi

if [ ! -z "$CLICKHOUSE_USER" ]; then
    sed -i "s/user: default/user: $CLICKHOUSE_USER/" /app/config/ch-dr-config.yaml
fi

if [ ! -z "$CLICKHOUSE_PASSWORD" ]; then
    sed -i "s/password: \"\"/password: \"$CLICKHOUSE_PASSWORD\"/" /app/config/ch-dr-config.yaml
fi

# Set up a simple health check endpoint
(
  while true; do
    echo -e "HTTP/1.1 200 OK\n\nHealthy" | nc -l -p 8080 -q 1
  done
) &

# Test connection to ClickHouse
echo "Testing connection to ClickHouse..."
if /app/scripts/ch-dr.sh --config /app/config/ch-dr-config.yaml --onprem verify; then
    echo "ClickHouse connection successful!"
else
    echo "WARNING: Could not connect to ClickHouse. Please check your configuration."
    # Continue anyway, because the configuration might be updated later
fi

# Create a backup now if requested
if [ "$BACKUP_ON_START" = "true" ]; then
    echo "Creating initial backup..."
    /app/scripts/ch-dr.sh --config /app/config/ch-dr-config.yaml --onprem backup
fi

# Execute the command passed to docker run
exec "$@"
