# ClickHouse Disaster Recovery Application

A comprehensive disaster recovery solution for ClickHouse databases, supporting both on-premises installations and Kubernetes deployments.

## Features

- **Flexible Backup & Restore**: Support for both on-premises and Kubernetes environments
- **Multiple Storage Options**: Local filesystem or S3-compatible storage
- **Incremental Backups**: Support for differential backups to minimize storage requirements
- **Retention Policies**: Automated management of backup retention
- **Scheduling**: Built-in scheduling for regular backups
- **Monitoring**: Health checks and logging for operational visibility
- **Security**: Secure credential management for ClickHouse and S3 access

## Quick Start

### On-Premises Deployment with Docker

1. **Clone the Repository**

```bash
git clone https://github.com/your-repo/clickhouse-dr
cd clickhouse-dr
```

2. **Configure Environment Variables**

Create a `.env` file with your ClickHouse and S3 details:

```
CLICKHOUSE_HOST=your-clickhouse-host
CLICKHOUSE_PORT=9000
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=your-password
S3_ACCESS_KEY=your-access-key
S3_SECRET_KEY=your-secret-key
S3_REGION=us-east-1
S3_BUCKET=your-bucket
S3_PATH=clickhouse/backups
BACKUP_ON_START=false
```

3. **Start the Service**

```bash
docker-compose up -d
```

4. **Verify Deployment**

```bash
curl http://localhost:8080  # Should return "Healthy"
docker logs clickhouse-dr
```

### Kubernetes Deployment

1. **Update Configuration**

Edit the `clickhouse-dr-k8s.yaml` file to update:
- S3 credentials in the Secret
- ClickHouse connection details in the ConfigMap
- Backup schedule in the CronJob

2. **Deploy to Kubernetes**

```bash
# Create the namespace if it doesn't exist
kubectl create namespace clickhouse

# Deploy the application
kubectl apply -f clickhouse-dr-k8s.yaml

# Load the script
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: load-clickhouse-dr-script
  namespace: clickhouse
spec:
  template:
    spec:
      containers:
      - name: script-loader
        image: busybox:latest
        command: ["/bin/sh", "/config/load-script.sh"]
        volumeMounts:
        - name: config-volume
          mountPath: /config
        - name: scripts-volume
          mountPath: /scripts
      restartPolicy: OnFailure
      volumes:
      - name: config-volume
        configMap:
          name: clickhouse-dr-script-loader
          defaultMode: 0755
      - name: scripts-volume
        emptyDir: {}
EOF
```

3. **Verify Deployment**

```bash
kubectl get pods -n clickhouse
kubectl logs -n clickhouse -l app=clickhouse-dr
```

## Manual Operations

### On-Premises Manual Operations

You can interact with the Docker container directly:

```bash
# Create a manual backup
docker exec clickhouse-dr /app/scripts/ch-dr.sh --config /app/config/ch-dr-config.yaml --onprem backup

# List available backups
docker exec clickhouse-dr /app/scripts/ch-dr.sh --config /app/config/ch-dr-config.yaml --onprem list

# Restore from a backup
docker exec clickhouse-dr /app/scripts/ch-dr.sh --config /app/config/ch-dr-config.yaml --onprem restore clickhouse_backup_20250101_120000.tar.gz
```

### Kubernetes Manual Operations

You can use kubectl to interact with the deployment:

```bash
# Get the pod name
CLICKHOUSE_DR_POD=$(kubectl get pods -n clickhouse -l app=clickhouse-dr -o jsonpath="{.items[0].metadata.name}")

# Create a manual backup
kubectl exec -n clickhouse $CLICKHOUSE_DR_POD -- /scripts/ch-dr.sh --config /config/ch-dr-config.yaml --k8s backup

# List available backups
kubectl exec -n clickhouse $CLICKHOUSE_DR_POD -- /scripts/ch-dr.sh --config /config/ch-dr-config.yaml --k8s list

# Restore from a backup
kubectl exec -n clickhouse $CLICKHOUSE_DR_POD -- /scripts/ch-dr.sh --config /config/ch-dr-config.yaml --k8s restore clickhouse_k8s_backup_20250101_120000.tar.gz
```

## Configuration Options

The config file (`ch-dr-config.yaml`) supports the following options:

### Common Settings

```yaml
# ClickHouse Connection Settings
host: localhost
port: 9000
user: default
password: ""

# Backup Settings
backup_dir: /backups
retention_days: 7

# Databases to backup (leave empty to backup all)
databases:
  - db1
  - db2

# S3 Settings
use_s3: true
s3_bucket: your-bucket
s3_path: clickhouse/backups
```

### Kubernetes-Specific Settings

```yaml
# Kubernetes Settings
namespace: clickhouse
pod_prefix: clickhouse
```

## Architecture

### On-Premises Architecture

1. **Backup Process**:
   - Connects to ClickHouse using clickhouse-client
   - Extracts table schemas and data
   - Creates compressed archive
   - Uploads to S3 (if configured)
   - Applies retention policy

2. **Restore Process**:
   - Downloads backup from S3 (if necessary)
   - Extracts backup archive
   - Recreates databases and tables
   - Restores data

### Kubernetes Architecture

1. **Components**:
   - Deployment for running the DR tool
   - CronJob for scheduled backups
   - ConfigMap for configuration
   - Secret for credentials
   - PersistentVolumeClaim for local storage
   - ServiceAccount with appropriate RBAC

2. **Backup Process**:
   - Accesses ClickHouse running in pods
   - Uses kubectl exec to run commands
   - Creates backups and stores in PVC or S3
   - Manages retention policy

## Monitoring and Logging

- **Health Endpoint**: HTTP endpoint on port 8080
- **Logs**: Available in `/app/logs` for Docker, or via `kubectl logs` for Kubernetes
- **Status Checks**: Use the `verify` command to check connectivity

## Security Considerations

- Store credentials securely using Docker secrets or Kubernetes secrets
- Use IAM roles where possible instead of access keys
- Encrypt backups at rest and in transit
- Use network policies to restrict access to the ClickHouse DR service

## Advanced Usage

### Custom Backup Scripts

You can extend the functionality by modifying the `ch-dr.sh` script or creating plugins.

### Integration with Monitoring Systems

The health endpoint can be integrated with Prometheus, Nagios, or other monitoring systems.

### Disaster Recovery Testing

Regularly test the disaster recovery process by restoring to a test environment.

```bash
# For Docker
docker exec clickhouse-dr /app/scripts/ch-dr.sh --config /app/config/test-restore-config.yaml --onprem restore backup_file.tar.gz

# For Kubernetes
kubectl exec -n clickhouse $CLICKHOUSE_DR_POD -- /scripts/ch-dr.sh --config /config/test-restore-config.yaml --k8s restore backup_file.tar.gz
```

## Troubleshooting

### Common Issues

1. **Connection Issues**
   
   If you're having trouble connecting to ClickHouse:
   
   ```bash
   # Verify connectivity
   /app/scripts/ch-dr.sh --config /app/config/ch-dr-config.yaml --onprem verify
   
   # Check ClickHouse is running
   clickhouse-client --host=<your-host> --port=<your-port> --user=<your-user> --password=<your-password> --query="SELECT 1"
   ```

2. **S3 Access Issues**
   
   For S3 connectivity problems:
   
   ```bash
   # Test S3 access
   s3cmd ls s3://<your-bucket>/<your-path>/
   
   # Check S3 configuration
   cat ~/.s3cfg
   ```

3. **Kubernetes Permission Issues**
   
   If you encounter permission issues in Kubernetes:
   
   ```bash
   # Check service account permissions
   kubectl auth can-i get pods --as=system:serviceaccount:clickhouse:clickhouse-dr-sa -n clickhouse
   kubectl auth can-i exec pods --as=system:serviceaccount:clickhouse:clickhouse-dr-sa -n clickhouse
   ```

### Logs

Check the logs for more detailed error information:

```bash
# Docker logs
docker logs clickhouse-dr
cat /app/logs/backup.log

# Kubernetes logs
kubectl logs -n clickhouse deployment/clickhouse-dr
kubectl logs -n clickhouse job/clickhouse-dr-backup-<job-id>
```

## Performance Considerations

### Optimizing Backup Performance

1. **Database Selection**: Backup only necessary databases
   ```yaml
   databases:
     - critical_db
     - important_metrics
   ```

2. **Compression Settings**: Adjust compression level
   ```bash
   # In the script, modify the tar command:
   tar -czf -> tar -cf  # No compression, faster but larger
   tar -czf -> tar -cJf  # XZ compression, slower but smaller
   ```

3. **Parallel Processing**: Enable parallel backups
   ```bash
   # Modify the script to use xargs for parallel processing
   echo "$TABLES" | xargs -P 4 -I {} bash -c 'backup_table "$DB" "{}"'
   ```

### Resource Allocation

For Kubernetes deployments, ensure adequate resources:

```yaml
resources:
  requests:
    memory: "1Gi"
    cpu: "500m"
  limits:
    memory: "2Gi"
    cpu: "1"
```

## Roadmap

- [ ] Support for incremental backups
- [ ] Integration with cloud-native backup solutions
- [ ] Web UI for backup management
- [ ] Enhanced monitoring and alerting
- [ ] Multi-cluster support

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- ClickHouse team for their excellent database
- Open-source community for backup and recovery tools
- Contributors to the S3 and Kubernetes ecosystems
