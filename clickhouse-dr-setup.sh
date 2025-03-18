#!/bin/bash
# ClickHouse Disaster Recovery Setup Script
# This script helps set up the ClickHouse DR application
# in either on-premises or Kubernetes environments

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_TYPE=""

print_header() {
    echo "===================================================="
    echo "  ClickHouse Disaster Recovery Setup"
    echo "===================================================="
    echo
}

print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --onprem        Set up for on-premises environment with Docker"
    echo "  --k8s           Set up for Kubernetes environment"
    echo "  --help          Display this help message"
    echo
}

setup_onprem() {
    echo "Setting up for on-premises environment with Docker..."
    
    # Create directories
    mkdir -p "$SCRIPT_DIR/config" "$SCRIPT_DIR/backups" "$SCRIPT_DIR/logs"
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        echo "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        echo "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi
    
    # Copy files
    cp -f "$SCRIPT_DIR/ch-dr.sh" "$SCRIPT_DIR/ch-dr.sh"
    
    # Create config if it doesn't exist
    if [ ! -f "$SCRIPT_DIR/config/ch-dr-config.yaml" ]; then
        echo "Creating sample configuration..."
        "$SCRIPT_DIR/ch-dr.sh" --onprem create-config "$SCRIPT_DIR/config/ch-dr-config.yaml"
    fi
    
    # Create .env file
    if [ ! -f "$SCRIPT_DIR/.env" ]; then
        echo "Creating .env file..."
        cat > "$SCRIPT_DIR/.env" << EOF
CLICKHOUSE_HOST=clickhouse
CLICKHOUSE_PORT=9000
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=
S3_ACCESS_KEY=
S3_SECRET_KEY=
S3_REGION=us-east-1
S3_BUCKET=clickhouse-backups
S3_PATH=production
BACKUP_ON_START=false
EOF
    fi
    
    echo "Setup completed for on-premises environment!"
    echo
    echo "Next steps:"
    echo "1. Update configuration in config/ch-dr-config.yaml"
    echo "2. Update environment variables in .env file"
    echo "3. Run 'docker-compose up -d' to start the service"
    echo
}

setup_k8s() {
    echo "Setting up for Kubernetes environment..."
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        echo "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    
    # Create temporary directory
    TMP_DIR=$(mktemp -d)
    
    # Prepare the script loader
    cp -f "$SCRIPT_DIR/clickhouse-dr-k8s.yaml" "$TMP_DIR/clickhouse-dr-k8s.yaml"
    
    # Inject the script into the ConfigMap
    SCRIPT_CONTENT=$(cat "$SCRIPT_DIR/ch-dr.sh" | sed 's/$/\\n/g' | tr -d '\n')
    sed -i "s|# The script content will be injected here when you apply this ConfigMap|$SCRIPT_CONTENT|" "$TMP_DIR/clickhouse-dr-k8s.yaml"
    
    # Ask for namespace
    read -p "Enter Kubernetes namespace (default: clickhouse): " NAMESPACE
    NAMESPACE=${NAMESPACE:-clickhouse}
    
    # Update namespace in the file
    sed -i "s/namespace: clickhouse/namespace: $NAMESPACE/g" "$TMP_DIR/clickhouse-dr-k8s.yaml"
    
    # Ask for S3 credentials
    read -p "Enter S3 access key: " S3_ACCESS_KEY
    read -sp "Enter S3 secret key: " S3_SECRET_KEY
    echo
    read -p "Enter S3 bucket name (default: clickhouse-backups): " S3_BUCKET
    S3_BUCKET=${S3_BUCKET:-clickhouse-backups}
    
    # Update S3 credentials in the Secret
    sed -i "s/access_key = YOUR_ACCESS_KEY/access_key = $S3_ACCESS_KEY/" "$TMP_DIR/clickhouse-dr-k8s.yaml"
    sed -i "s/secret_key = YOUR_SECRET_KEY/secret_key = $S3_SECRET_KEY/" "$TMP_DIR/clickhouse-dr-k8s.yaml"
    sed -i "s/s3_bucket: clickhouse-backups/s3_bucket: $S3_BUCKET/" "$TMP_DIR/clickhouse-dr-k8s.yaml"
    
    # Ask for backup schedule
    read -p "Enter backup schedule (cron format, default: 0 2 * * *): " BACKUP_SCHEDULE
    BACKUP_SCHEDULE=${BACKUP_SCHEDULE:-"0 2 * * *"}
    
    # Update backup schedule
    sed -i "s/schedule: \"0 2 \* \* \*\"/schedule: \"$BACKUP_SCHEDULE\"/" "$TMP_DIR/clickhouse-dr-k8s.yaml"
    
    # Create namespace if it doesn't exist
    kubectl get namespace "$NAMESPACE" &> /dev/null || kubectl create namespace "$NAMESPACE"
    
    # Apply the Kubernetes resources
    kubectl apply -f "$TMP_DIR/clickhouse-dr-k8s.yaml"
    
    echo "Setup completed for Kubernetes environment!"
    echo
    echo "Next steps:"
    echo "1. Verify the deployment with 'kubectl get pods -n $NAMESPACE'"
    echo "2. Check the logs with 'kubectl logs -n $NAMESPACE deployment/clickhouse-dr'"
    echo "3. Run a manual backup with 'kubectl exec -n $NAMESPACE \$(kubectl get pods -n $NAMESPACE -l app=clickhouse-dr -o jsonpath=\"{.items[0].metadata.name}\") -- /scripts/ch-dr.sh --config /config/ch-dr-config.yaml --k8s backup'"
    echo
    
    # Clean up
    rm -rf "$TMP_DIR"
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --onprem)
            ENV_TYPE="onprem"
            shift
            ;;
        --k8s)
            ENV_TYPE="k8s"
            shift
            ;;
        --help)
            print_header
            print_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

# Validate environment type
if [[ -z "$ENV_TYPE" ]]; then
    print_header
    echo "Please specify an environment type: --onprem or --k8s"
    print_help
    exit 1
fi

print_header

# Run the appropriate setup
if [[ "$ENV_TYPE" == "onprem" ]]; then
    setup_onprem
else
    setup_k8s
fi

echo "Thank you for using ClickHouse Disaster Recovery!"
