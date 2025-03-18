#!/bin/bash
# ClickHouse Disaster Recovery Application
# For both on-premises and Kubernetes environments
# Version 1.0

set -e

# Configuration file
CONFIG_FILE="./ch-dr-config.yaml"
LOG_FILE="./ch-dr.log"
BACKUP_DIR="/var/backups/clickhouse"
RETENTION_DAYS=7
K8S_NAMESPACE="clickhouse"
CLICKHOUSE_POD_PREFIX="clickhouse"
ENV_TYPE=""  # "onprem" or "k8s"

# Function to log messages
log() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" | tee -a "$LOG_FILE"
}

# Function to check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    if [[ "$ENV_TYPE" == "onprem" ]]; then
        # Check for ClickHouse client
        if ! command -v clickhouse-client &> /dev/null; then
            log "ERROR" "clickhouse-client is not installed. Please install it first."
            exit 1
        fi
        
        # Check for s3cmd if S3 is configured
        if [[ -n "$USE_S3" && "$USE_S3" == "true" ]]; then
            if ! command -v s3cmd &> /dev/null; then
                log "ERROR" "s3cmd is not installed. Please install it first."
                exit 1
            fi
        fi
    elif [[ "$ENV_TYPE" == "k8s" ]]; then
        # Check for kubectl
        if ! command -v kubectl &> /dev/null; then
            log "ERROR" "kubectl is not installed. Please install it first."
            exit 1
        fi
        
        # Check for K8s access
        if ! kubectl get namespace "$K8S_NAMESPACE" &> /dev/null; then
            log "ERROR" "Cannot access namespace '$K8S_NAMESPACE'. Please check your Kubernetes configuration."
            exit 1
        fi
    else
        log "ERROR" "Invalid environment type. Use --onprem or --k8s"
        exit 1
    fi
    
    # Create backup directory if it doesn't exist
    if [[ "$ENV_TYPE" == "onprem" ]]; then
        mkdir -p "$BACKUP_DIR"
    fi
    
    log "INFO" "Prerequisites check completed."
}

# Function to load configuration
load_config() {
    log "INFO" "Loading configuration from $CONFIG_FILE"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR" "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Parse YAML configuration (simple version)
    # In production, use a proper YAML parser
    CLICKHOUSE_HOST=$(grep 'host:' "$CONFIG_FILE" | awk '{print $2}')
    CLICKHOUSE_PORT=$(grep 'port:' "$CONFIG_FILE" | awk '{print $2}')
    CLICKHOUSE_USER=$(grep 'user:' "$CONFIG_FILE" | awk '{print $2}')
    CLICKHOUSE_PASSWORD=$(grep 'password:' "$CONFIG_FILE" | awk '{print $2}')
    BACKUP_DATABASES=$(grep 'databases:' "$CONFIG_FILE" -A 10 | grep -v 'databases:' | grep -v '^$' | grep '^\s*-' | awk '{print $2}')
    USE_S3=$(grep 'use_s3:' "$CONFIG_FILE" | awk '{print $2}')
    S3_BUCKET=$(grep 's3_bucket:' "$CONFIG_FILE" | awk '{print $2}')
    S3_PATH=$(grep 's3_path:' "$CONFIG_FILE" | awk '{print $2}')
    
    if [[ "$ENV_TYPE" == "k8s" ]]; then
        K8S_NAMESPACE=$(grep 'namespace:' "$CONFIG_FILE" | awk '{print $2}')
        CLICKHOUSE_POD_PREFIX=$(grep 'pod_prefix:' "$CONFIG_FILE" | awk '{print $2}')
    fi
    
    log "INFO" "Configuration loaded successfully."
}

# Function to create backup for on-premises ClickHouse
backup_onprem() {
    log "INFO" "Starting on-premises ClickHouse backup..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/backup_$TIMESTAMP"
    mkdir -p "$BACKUP_PATH"
    
    # Get list of databases if not specified in config
    if [[ -z "$BACKUP_DATABASES" ]]; then
        log "INFO" "No specific databases configured, backing up all databases"
        BACKUP_DATABASES=$(clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" --query="SHOW DATABASES" | grep -v -E "^(system|information_schema|INFORMATION_SCHEMA)$")
    fi
    
    # Backup each database using clickhouse-client
    for DB in $BACKUP_DATABASES; do
        log "INFO" "Backing up database: $DB"
        
        # Create directory for database
        mkdir -p "$BACKUP_PATH/$DB"
        
        # Get list of tables
        TABLES=$(clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" --query="SHOW TABLES FROM $DB" 2>/dev/null || echo "")
        
        if [[ -z "$TABLES" ]]; then
            log "WARN" "No tables found in database $DB, skipping"
            continue
        fi
        
        # Backup table schemas
        log "INFO" "Backing up table schemas for database $DB"
        for TABLE in $TABLES; do
            log "INFO" "Getting schema for table $DB.$TABLE"
            clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" --query="SHOW CREATE TABLE $DB.$TABLE" > "$BACKUP_PATH/$DB/$TABLE.sql" 2>/dev/null || log "ERROR" "Failed to get schema for $DB.$TABLE"
        done
        
        # Backup data using clickhouse-backup if available or native backups otherwise
        if command -v clickhouse-backup &> /dev/null; then
            log "INFO" "Using clickhouse-backup tool for data backup"
            clickhouse-backup create "$DB-$TIMESTAMP" --tables="$DB.*" || log "ERROR" "clickhouse-backup failed for $DB"
            cp -r /var/lib/clickhouse/backup/latest/* "$BACKUP_PATH/$DB/" || log "ERROR" "Failed to copy clickhouse-backup data for $DB"
        else
            log "INFO" "Using native ClickHouse backup for data export"
            for TABLE in $TABLES; do
                log "INFO" "Backing up data for table $DB.$TABLE"
                clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" --query="SELECT * FROM $DB.$TABLE FORMAT Native" > "$BACKUP_PATH/$DB/$TABLE.native" 2>/dev/null || log "ERROR" "Failed to backup data for $DB.$TABLE"
            done
        fi
    done
    
    # Create compressed archive
    log "INFO" "Creating compressed archive of backup"
    tar -czf "$BACKUP_DIR/clickhouse_backup_$TIMESTAMP.tar.gz" -C "$BACKUP_DIR" "backup_$TIMESTAMP" || log "ERROR" "Failed to create compressed archive"
    
    # Upload to S3 if configured
    if [[ -n "$USE_S3" && "$USE_S3" == "true" ]]; then
        log "INFO" "Uploading backup to S3"
        s3cmd put "$BACKUP_DIR/clickhouse_backup_$TIMESTAMP.tar.gz" "s3://$S3_BUCKET/$S3_PATH/clickhouse_backup_$TIMESTAMP.tar.gz" || log "ERROR" "Failed to upload backup to S3"
    fi
    
    # Clean up
    log "INFO" "Cleaning up temporary backup files"
    rm -rf "$BACKUP_PATH"
    
    # Clean old backups according to retention policy
    clean_old_backups
    
    log "INFO" "On-premises ClickHouse backup completed: $BACKUP_DIR/clickhouse_backup_$TIMESTAMP.tar.gz"
}

# Function to create backup for Kubernetes ClickHouse
backup_k8s() {
    log "INFO" "Starting Kubernetes ClickHouse backup..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    # Get ClickHouse pod name
    CH_POD=$(kubectl get pods -n "$K8S_NAMESPACE" | grep "$CLICKHOUSE_POD_PREFIX" | grep Running | head -1 | awk '{print $1}')
    
    if [[ -z "$CH_POD" ]]; then
        log "ERROR" "No running ClickHouse pod found in namespace $K8S_NAMESPACE with prefix $CLICKHOUSE_POD_PREFIX"
        exit 1
    fi
    
    log "INFO" "Using ClickHouse pod: $CH_POD"
    
    # Get list of databases if not specified in config
    if [[ -z "$BACKUP_DATABASES" ]]; then
        log "INFO" "No specific databases configured, backing up all databases"
        BACKUP_DATABASES=$(kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="SHOW DATABASES" | grep -v -E "^(system|information_schema|INFORMATION_SCHEMA)$")
    fi
    
    # Create a temporary directory for the backup
    LOCAL_TEMP_DIR="/tmp/clickhouse_k8s_backup_$TIMESTAMP"
    mkdir -p "$LOCAL_TEMP_DIR"
    
    # Backup each database
    for DB in $BACKUP_DATABASES; do
        log "INFO" "Backing up database: $DB"
        
        # Create directory for database
        mkdir -p "$LOCAL_TEMP_DIR/$DB"
        
        # Get list of tables
        TABLES=$(kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="SHOW TABLES FROM $DB" 2>/dev/null || echo "")
        
        if [[ -z "$TABLES" ]]; then
            log "WARN" "No tables found in database $DB, skipping"
            continue
        fi
        
        # Backup table schemas
        log "INFO" "Backing up table schemas for database $DB"
        for TABLE in $TABLES; do
            log "INFO" "Getting schema for table $DB.$TABLE"
            kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="SHOW CREATE TABLE $DB.$TABLE" > "$LOCAL_TEMP_DIR/$DB/$TABLE.sql" 2>/dev/null || log "ERROR" "Failed to get schema for $DB.$TABLE"
        done
        
        # For Kubernetes, we'll use the built-in BACKUP command if the version supports it
        log "INFO" "Creating native backup for database $DB"
        kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="BACKUP DATABASE $DB TO Disk('backups', '$DB-$TIMESTAMP.zip')" 2>/dev/null || log "WARNING" "Native BACKUP command failed, falling back to table-by-table backup"
        
        # If native backup fails, fall back to table-by-table export
        if [[ $? -ne 0 ]]; then
            log "INFO" "Using table-by-table backup for $DB"
            for TABLE in $TABLES; do
                log "INFO" "Backing up data for table $DB.$TABLE"
                kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- sh -c "clickhouse-client --query=\"SELECT * FROM $DB.$TABLE FORMAT Native\" > /tmp/$DB-$TABLE.native" 2>/dev/null || log "ERROR" "Failed to backup data for $DB.$TABLE"
                kubectl cp "$K8S_NAMESPACE/$CH_POD:/tmp/$DB-$TABLE.native" "$LOCAL_TEMP_DIR/$DB/$TABLE.native" 2>/dev/null || log "ERROR" "Failed to copy backup data for $DB.$TABLE"
                kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- rm "/tmp/$DB-$TABLE.native" 2>/dev/null
            done
        else
            # Copy the native backup file
            TMP_BACKUP_PATH=$(kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- sh -c "find /var/lib/clickhouse/disks/backups -name '$DB-$TIMESTAMP.zip'" 2>/dev/null)
            if [[ -n "$TMP_BACKUP_PATH" ]]; then
                kubectl cp "$K8S_NAMESPACE/$CH_POD:$TMP_BACKUP_PATH" "$LOCAL_TEMP_DIR/$DB/backup.zip" 2>/dev/null || log "ERROR" "Failed to copy native backup for $DB"
            fi
        fi
    done
    
    # Create compressed archive
    log "INFO" "Creating compressed archive of backup"
    tar -czf "/tmp/clickhouse_k8s_backup_$TIMESTAMP.tar.gz" -C "/tmp" "clickhouse_k8s_backup_$TIMESTAMP" || log "ERROR" "Failed to create compressed archive"
    
    # Upload to S3 if configured
    if [[ -n "$USE_S3" && "$USE_S3" == "true" ]]; then
        log "INFO" "Uploading backup to S3"
        s3cmd put "/tmp/clickhouse_k8s_backup_$TIMESTAMP.tar.gz" "s3://$S3_BUCKET/$S3_PATH/clickhouse_k8s_backup_$TIMESTAMP.tar.gz" || log "ERROR" "Failed to upload backup to S3"
    else
        # Move to backup directory if S3 is not configured
        mkdir -p "$BACKUP_DIR"
        mv "/tmp/clickhouse_k8s_backup_$TIMESTAMP.tar.gz" "$BACKUP_DIR/" || log "ERROR" "Failed to move backup to $BACKUP_DIR"
    fi
    
    # Clean up
    log "INFO" "Cleaning up temporary backup files"
    rm -rf "$LOCAL_TEMP_DIR"
    
    # Clean old backups according to retention policy
    clean_old_backups
    
    log "INFO" "Kubernetes ClickHouse backup completed"
}

# Function to restore on-premises ClickHouse backup
restore_onprem() {
    local backup_file="$1"
    
    if [[ -z "$backup_file" ]]; then
        log "ERROR" "No backup file specified for restoration"
        exit 1
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        # Check if it's in S3
        if [[ -n "$USE_S3" && "$USE_S3" == "true" ]]; then
            log "INFO" "Backup file not found locally, checking S3"
            S3_PATH_FULL="s3://$S3_BUCKET/$S3_PATH/$backup_file"
            if s3cmd info "$S3_PATH_FULL" &> /dev/null; then
                log "INFO" "Found backup in S3, downloading"
                s3cmd get "$S3_PATH_FULL" "/tmp/$backup_file" || log "ERROR" "Failed to download backup from S3"
                backup_file="/tmp/$backup_file"
            else
                log "ERROR" "Backup file not found: $backup_file"
                exit 1
            fi
        else
            log "ERROR" "Backup file not found: $backup_file"
            exit 1
        fi
    fi
    
    log "INFO" "Starting restoration from backup: $backup_file"
    
    # Extract the backup
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    RESTORE_DIR="/tmp/clickhouse_restore_$TIMESTAMP"
    mkdir -p "$RESTORE_DIR"
    
    log "INFO" "Extracting backup archive"
    tar -xzf "$backup_file" -C "$RESTORE_DIR" || {
        log "ERROR" "Failed to extract backup archive"
        exit 1
    }
    
    # Find the actual backup directory inside
    BACKUP_DIR_EXTRACT=$(find "$RESTORE_DIR" -type d -name "backup_*" | head -1)
    
    if [[ -z "$BACKUP_DIR_EXTRACT" ]]; then
        log "ERROR" "Could not find backup directory in the archive"
        exit 1
    fi
    
    log "INFO" "Extracted backup to: $BACKUP_DIR_EXTRACT"
    
    # Get list of databases in the backup
    DATABASES=$(find "$BACKUP_DIR_EXTRACT" -maxdepth 1 -type d | grep -v "^$BACKUP_DIR_EXTRACT$" | xargs -n1 basename)
    
    for DB in $DATABASES; do
        log "INFO" "Restoring database: $DB"
        
        # Create database if it doesn't exist
        clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" --query="CREATE DATABASE IF NOT EXISTS $DB" || {
            log "ERROR" "Failed to create database $DB"
            continue
        }
        
        # Find all SQL schema files
        SCHEMA_FILES=$(find "$BACKUP_DIR_EXTRACT/$DB" -name "*.sql")
        
        for SCHEMA_FILE in $SCHEMA_FILES; do
            TABLE_NAME=$(basename "$SCHEMA_FILE" .sql)
            log "INFO" "Restoring table schema: $DB.$TABLE_NAME"
            
            # Drop table if it exists
            clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" --query="DROP TABLE IF EXISTS $DB.$TABLE_NAME" || log "WARN" "Failed to drop table $DB.$TABLE_NAME"
            
            # Create table
            clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" < "$SCHEMA_FILE" || {
                log "ERROR" "Failed to restore schema for $DB.$TABLE_NAME"
                continue
            }
            
            # Restore data if available
            NATIVE_FILE="$BACKUP_DIR_EXTRACT/$DB/$TABLE_NAME.native"
            if [[ -f "$NATIVE_FILE" ]]; then
                log "INFO" "Restoring data for table: $DB.$TABLE_NAME"
                cat "$NATIVE_FILE" | clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" --query="INSERT INTO $DB.$TABLE_NAME FORMAT Native" || log "ERROR" "Failed to restore data for $DB.$TABLE_NAME"
            else
                log "WARN" "No data file found for $DB.$TABLE_NAME"
            fi
        done
        
        # Check for clickhouse-backup files
        if [[ -d "$BACKUP_DIR_EXTRACT/$DB/shadow" ]]; then
            log "INFO" "Found clickhouse-backup format, attempting to use clickhouse-backup for restoration"
            if command -v clickhouse-backup &> /dev/null; then
                # Copy backup to clickhouse-backup directory
                BACKUP_NAME="$DB-restore-$TIMESTAMP"
                mkdir -p "/var/lib/clickhouse/backup/$BACKUP_NAME"
                cp -r "$BACKUP_DIR_EXTRACT/$DB"/* "/var/lib/clickhouse/backup/$BACKUP_NAME/" || log "ERROR" "Failed to copy backup files for clickhouse-backup"
                
                # Restore using clickhouse-backup
                clickhouse-backup restore "$BACKUP_NAME" --tables="$DB.*" || log "ERROR" "clickhouse-backup restore failed for $DB"
            else
                log "WARN" "clickhouse-backup format detected but tool not installed. Skipping this restore method."
            fi
        fi
    done
    
    # Clean up
    log "INFO" "Cleaning up temporary restore files"
    rm -rf "$RESTORE_DIR"
    
    log "INFO" "On-premises ClickHouse restoration completed"
}

# Function to restore Kubernetes ClickHouse backup
restore_k8s() {
    local backup_file="$1"
    
    if [[ -z "$backup_file" ]]; then
        log "ERROR" "No backup file specified for restoration"
        exit 1
    fi
    
    local local_backup_file=""
    
    # Check if the backup file exists locally
    if [[ -f "$backup_file" ]]; then
        local_backup_file="$backup_file"
    elif [[ -f "$BACKUP_DIR/$backup_file" ]]; then
        local_backup_file="$BACKUP_DIR/$backup_file"
    else
        # Check if it's in S3
        if [[ -n "$USE_S3" && "$USE_S3" == "true" ]]; then
            log "INFO" "Backup file not found locally, checking S3"
            S3_PATH_FULL="s3://$S3_BUCKET/$S3_PATH/$backup_file"
            if s3cmd info "$S3_PATH_FULL" &> /dev/null; then
                log "INFO" "Found backup in S3, downloading"
                s3cmd get "$S3_PATH_FULL" "/tmp/$backup_file" || log "ERROR" "Failed to download backup from S3"
                local_backup_file="/tmp/$backup_file"
            else
                log "ERROR" "Backup file not found: $backup_file"
                exit 1
            fi
        else
            log "ERROR" "Backup file not found: $backup_file"
            exit 1
        fi
    fi
    
    log "INFO" "Starting Kubernetes ClickHouse restoration from backup: $local_backup_file"
    
    # Extract the backup
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    RESTORE_DIR="/tmp/clickhouse_k8s_restore_$TIMESTAMP"
    mkdir -p "$RESTORE_DIR"
    
    log "INFO" "Extracting backup archive"
    tar -xzf "$local_backup_file" -C "$RESTORE_DIR" || {
        log "ERROR" "Failed to extract backup archive"
        exit 1
    }
    
    # Find the actual backup directory inside
    BACKUP_DIR_EXTRACT=$(find "$RESTORE_DIR" -maxdepth 1 -type d | grep -v "^$RESTORE_DIR$" | head -1)
    
    if [[ -z "$BACKUP_DIR_EXTRACT" ]]; then
        log "ERROR" "Could not find backup directory in the archive"
        exit 1
    }
    
    log "INFO" "Extracted backup to: $BACKUP_DIR_EXTRACT"
    
    # Get ClickHouse pod name
    CH_POD=$(kubectl get pods -n "$K8S_NAMESPACE" | grep "$CLICKHOUSE_POD_PREFIX" | grep Running | head -1 | awk '{print $1}')
    
    if [[ -z "$CH_POD" ]]; then
        log "ERROR" "No running ClickHouse pod found in namespace $K8S_NAMESPACE with prefix $CLICKHOUSE_POD_PREFIX"
        exit 1
    fi
    
    log "INFO" "Using ClickHouse pod: $CH_POD"
    
    # Get list of databases in the backup
    DATABASES=$(find "$BACKUP_DIR_EXTRACT" -maxdepth 1 -type d | grep -v "^$BACKUP_DIR_EXTRACT$" | xargs -n1 basename)
    
    for DB in $DATABASES; do
        log "INFO" "Restoring database: $DB"
        
        # Create database if it doesn't exist
        kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="CREATE DATABASE IF NOT EXISTS $DB" || {
            log "ERROR" "Failed to create database $DB"
            continue
        }
        
        # Check if there is a native backup.zip file
        if [[ -f "$BACKUP_DIR_EXTRACT/$DB/backup.zip" ]]; then
            log "INFO" "Found native backup for $DB, using RESTORE command"
            
            # Create a directory for backups on the pod if it doesn't exist
            kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- mkdir -p /tmp/backups
            
            # Copy the backup file to the pod
            kubectl cp "$BACKUP_DIR_EXTRACT/$DB/backup.zip" "$K8S_NAMESPACE/$CH_POD:/tmp/backups/$DB-backup.zip" || {
                log "ERROR" "Failed to copy backup file to pod"
                continue
            }
            
            # Ensure the backup disk exists
            kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="CREATE DISK IF NOT EXISTS backups TYPE local PATH '/tmp/backups'" || log "WARN" "Failed to create backup disk, it might already exist"
            
            # Restore from the backup
            kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="RESTORE DATABASE $DB FROM Disk('backups', '$DB-backup.zip')" || {
                log "ERROR" "Native RESTORE command failed for $DB, falling back to table-by-table restore"
            }
        else
            # Find all SQL schema files
            SCHEMA_FILES=$(find "$BACKUP_DIR_EXTRACT/$DB" -name "*.sql")
            
            for SCHEMA_FILE in $SCHEMA_FILES; do
                TABLE_NAME=$(basename "$SCHEMA_FILE" .sql)
                log "INFO" "Restoring table schema: $DB.$TABLE_NAME"
                
                # Drop table if it exists
                kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="DROP TABLE IF EXISTS $DB.$TABLE_NAME" || log "WARN" "Failed to drop table $DB.$TABLE_NAME"
                
                # Create temporary file with schema on the pod
                TMP_SCHEMA_FILE="/tmp/$DB-$TABLE_NAME-schema.sql"
                kubectl cp "$SCHEMA_FILE" "$K8S_NAMESPACE/$CH_POD:$TMP_SCHEMA_FILE" || {
                    log "ERROR" "Failed to copy schema file to pod"
                    continue
                }
                
                # Create table
                kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- sh -c "cat $TMP_SCHEMA_FILE | clickhouse-client" || {
                    log "ERROR" "Failed to restore schema for $DB.$TABLE_NAME"
                    continue
                }
                
                # Restore data if available
                NATIVE_FILE="$BACKUP_DIR_EXTRACT/$DB/$TABLE_NAME.native"
                if [[ -f "$NATIVE_FILE" ]]; then
                    log "INFO" "Restoring data for table: $DB.$TABLE_NAME"
                    
                    # Copy the native file to the pod
                    TMP_NATIVE_FILE="/tmp/$DB-$TABLE_NAME.native"
                    kubectl cp "$NATIVE_FILE" "$K8S_NAMESPACE/$CH_POD:$TMP_NATIVE_FILE" || {
                        log "ERROR" "Failed to copy data file to pod"
                        continue
                    }
                    
                    # Insert the data
                    kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- sh -c "cat $TMP_NATIVE_FILE | clickhouse-client --query=\"INSERT INTO $DB.$TABLE_NAME FORMAT Native\"" || log "ERROR" "Failed to restore data for $DB.$TABLE_NAME"
                    
                    # Clean up
                    kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- rm "$TMP_NATIVE_FILE" || log "WARN" "Failed to remove temporary native file from pod"
                else
                    log "WARN" "No data file found for $DB.$TABLE_NAME"
                fi
                
                # Clean up
                kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- rm "$TMP_SCHEMA_FILE" || log "WARN" "Failed to remove temporary schema file from pod"
            done
        fi
    done
    
    # Clean up
    log "INFO" "Cleaning up temporary restore files"
    rm -rf "$RESTORE_DIR"
    
    log "INFO" "Kubernetes ClickHouse restoration completed"
}

# Function to clean old backups
clean_old_backups() {
    log "INFO" "Cleaning up old backups (keeping the last $RETENTION_DAYS days)"
    
    if [[ "$ENV_TYPE" == "onprem" ]]; then
        # Remove local old backups
        find "$BACKUP_DIR" -name "clickhouse_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
    fi
    
    # Remove S3 old backups if configured
    if [[ -n "$USE_S3" && "$USE_S3" == "true" ]]; then
        log "INFO" "Cleaning old backups from S3"
        CUTOFF_DATE=$(date -d "$RETENTION_DAYS days ago" +%Y%m%d)
        
        # Get list of backups in S3
        S3_BACKUPS=$(s3cmd ls "s3://$S3_BUCKET/$S3_PATH/" | grep -E "clickhouse_(k8s_)?backup_[0-9]{8}_[0-9]{6}\.tar\.gz" || echo "")
        
        if [[ -n "$S3_BACKUPS" ]]; then
            echo "$S3_BACKUPS" | while read -r line; do
                BACKUP_FILE=$(echo "$line" | awk '{print $4}')
                BACKUP_DATE=$(echo "$BACKUP_FILE" | grep -oE "[0-9]{8}" | head -1)
                
                if [[ "$BACKUP_DATE" < "$CUTOFF_DATE" ]]; then
                    log "INFO" "Removing old S3 backup: $BACKUP_FILE"
                    s3cmd rm "$BACKUP_FILE" || log "ERROR" "Failed to remove S3 backup: $BACKUP_FILE"
                fi
            done
        fi
    fi
    
    log "INFO" "Backup cleanup completed"
}

# Function to verify connectivity
verify_connection() {
    log "INFO" "Verifying ClickHouse connectivity"
    
    if [[ "$ENV_TYPE" == "onprem" ]]; then
        clickhouse-client --host="$CLICKHOUSE_HOST" --port="$CLICKHOUSE_PORT" --user="$CLICKHOUSE_USER" --password="$CLICKHOUSE_PASSWORD" --query="SELECT 1" &> /dev/null
        
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Cannot connect to ClickHouse server at $CLICKHOUSE_HOST:$CLICKHOUSE_PORT"
            exit 1
        fi
    elif [[ "$ENV_TYPE" == "k8s" ]]; then
        CH_POD=$(kubectl get pods -n "$K8S_NAMESPACE" | grep "$CLICKHOUSE_POD_PREFIX" | grep Running | head -1 | awk '{print $1}')
        
        if [[ -z "$CH_POD" ]]; then
            log "ERROR" "No running ClickHouse pod found in namespace $K8S_NAMESPACE with prefix $CLICKHOUSE_POD_PREFIX"
            exit 1
        fi
        
        kubectl exec -n "$K8S_NAMESPACE" "$CH_POD" -- clickhouse-client --query="SELECT 1" &> /dev/null
        
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Cannot connect to ClickHouse server in pod $CH_POD"
            exit 1
        fi
    fi
    
    log "INFO" "ClickHouse connectivity verified successfully"
    return 0
}

# Function to list available backups
list_backups() {
    log "INFO" "Listing available backups"
    
    if [[ "$ENV_TYPE" == "onprem" ]]; then
        echo "Local backups:"
        find "$BACKUP_DIR" -name "clickhouse_backup_*.tar.gz" -type f | sort
    fi
    
    if [[ -n "$USE_S3" && "$USE_S3" == "true" ]]; then
        echo "S3 backups:"
        s3cmd ls "s3://$S3_BUCKET/$S3_PATH/" | grep -E "clickhouse_(k8s_)?backup_[0-9]{8}_[0-9]{6}\.tar\.gz" || echo "No backups found in S3"
    fi
}

# Function to create a sample configuration file
create_sample_config() {
    local config_path="$1"
    
    if [[ -z "$config_path" ]]; then
        config_path="./ch-dr-config.yaml.sample"
    fi
    
    log "INFO" "Creating sample configuration file at $config_path"
    
    cat > "$config_path" << EOF
# ClickHouse Disaster Recovery Configuration

# ClickHouse Connection Settings
host: localhost
port: 9000
user: default
password: ""

# Backup Settings
backup_dir: /var/backups/clickhouse
retention_days: 7

# Databases to backup (leave empty to backup all)
databases:
  - db1
  - db2

# S3 Settings
use_s3: false
s3_bucket: your-bucket
s3_path: clickhouse/backups

# Kubernetes Settings (for k8s mode only)
namespace: clickhouse
pod_prefix: clickhouse
EOF
    
    log "INFO" "Sample configuration created: $config_path"
}

# Function to display usage
usage() {
    echo "ClickHouse Disaster Recovery Tool"
    echo "Usage: $0 [OPTIONS] COMMAND"
    echo
    echo "Environment Options:"
    echo "  --onprem              Run in on-premises mode"
    echo "  --k8s                 Run in Kubernetes mode"
    echo
    echo "Commands:"
    echo "  backup                Create a new backup"
    echo "  restore BACKUP_FILE   Restore from a backup file"
    echo "  list                  List available backups"
    echo "  verify                Verify connectivity to ClickHouse"
    echo "  create-config [PATH]  Create a sample configuration file"
    echo
    echo "Options:"
    echo "  --config FILE         Specify configuration file (default: ./ch-dr-config.yaml)"
    echo "  --help                Display this help message"
    echo
    echo "Examples:"
    echo "  $0 --onprem backup"
    echo "  $0 --k8s restore clickhouse_k8s_backup_20230101_120000.tar.gz"
    echo "  $0 --config /path/to/config.yaml --onprem list"
}

# Main function
main() {
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
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            backup|restore|list|verify|create-config)
                COMMAND="$1"
                shift
                break
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Validate environment type
    if [[ -z "$ENV_TYPE" ]]; then
        echo "ERROR: Environment type not specified. Use --onprem or --k8s"
        usage
        exit 1
    fi
    
    # Process commands
    case "$COMMAND" in
        backup)
            load_config
            check_prerequisites
            verify_connection
            if [[ "$ENV_TYPE" == "onprem" ]]; then
                backup_onprem
            else
                backup_k8s
            fi
            ;;
        restore)
            if [[ -z "$1" ]]; then
                echo "ERROR: No backup file specified for restoration"
                usage
                exit 1
            fi
            BACKUP_FILE="$1"
            load_config
            check_prerequisites
            verify_connection
            if [[ "$ENV_TYPE" == "onprem" ]]; then
                restore_onprem "$BACKUP_FILE"
            else
                restore_k8s "$BACKUP_FILE"
            fi
            ;;
        list)
            load_config
            list_backups
            ;;
        verify)
            load_config
            verify_connection
            echo "Connection to ClickHouse successful!"
            ;;
        create-config)
            create_sample_config "$1"
            ;;
        *)
            echo "ERROR: No command specified"
            usage
            exit 1
            ;;
    esac
    
    exit 0
}

# Run the script
main "$@"