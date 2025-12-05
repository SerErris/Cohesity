#!/bin/bash

# ==============================================================================
# MariaDB Backup Script (Wrapper for mariadb-backup)
# ==============================================================================
#
# DESCRIPTION:
#   Creates Full, Incremental, and Binlog backups of MariaDB.
#   Supports single database backup via '-d dbname' or full instance backup via '-d all'.
#   Automatically manages base directories for incremental backups.
#   Includes pruning capability to delete old backups respecting dependency chains.
#   Supports mounting an NFS share temporarily for the backup duration.
#   Prevents concurrent execution using a lock file.
#
#   NOTE: mariadb-backup does not support writing to multiple target directories/mountpoints
#   simultaneously. A single unified target path is required.
#
# PREREQUISITES:
#   1. mariadb-backup must be installed.
#   2. The user executing the script needs 'sudo' privileges (NOPASSWD recommended) for:
#      - mount, umount, mkdir, cp, rm, touch
#      - mariadb-backup, mysql, mysqlbinlog, mysqladmin, find, timeout, flock
#      - writing to /var/log/mariadb_backup.log
#   3. Using a ~/.my.cnf file (usually in /root/.my.cnf) for authentication is recommended.
#
# LICENSE & WARRANTY DISCLAIMER:
#   This script is provided under the MIT License.
#   ⚠️ Disclaimer:
#   This script is provided as-is, without any warranty of any kind.
#   Use at your own risk. The author(s) are not liable for any loss, data 
#   corruption, or system failure resulting from its use.
#
# EXIT CODES:
#   0  - Success
#   
#   Parameter & Input Errors (10-19):
#   10 - Invalid arguments / Missing parameters
#   11 - Unknown backup mode provided
#   12 - Invalid NFS share format
#   13 - Invalid Database name format
#
#   Dependency & Perm Errors (20-29):
#   20 - 'mariadb-backup' tool missing
#   21 - 'mysql' client missing
#   22 - 'mysqlbinlog' tool missing
#   23 - Sudo check failed (insufficient privileges)
#   24 - Required system tool missing (timeout, findmnt, flock)
#   25 - Script is already running (Lock file active)
#   26 - Log file is not writable
#
#   Database & Access Errors (30-39):
#   30 - Database does not exist or access denied
#   31 - Binary Logging is disabled (SHOW BINARY LOGS failed)
#   32 - No Binary Logs found (SHOW BINARY LOGS returned empty)
#   33 - MariaDB Server is unreachable (ping failed)
#
#   File System & Structure Errors (40-49):
#   40 - Missing checkpoint file (cannot perform incremental)
#   41 - Base backup directory missing (broken chain)
#   42 - Write permission test failed on target
#
#   Execution Errors (50-59):
#   50 - Full backup execution failed
#   51 - Incremental backup execution failed
#   52 - Transaction log backup execution failed
#
#   Mount/Network Errors (60-69):
#   60 - NFS Mount failed (or timed out)
#   61 - NFS Unmount failed
#
# USAGE:
#   ./mariadb_backup.sh -d <db_name|all> -t <target_dir> -m <full|inc|log> -n <nfs_share> [-p <days>] [-u] [-v]
#
# ==============================================================================
# VERSION: 0.9.5
#
# HISTORY:
#   v0.9.5 - Added concurrency locking, server ping check, strict log check, and extended dependency checks.
#   v0.9.4 - Added License & Warranty Disclaimer.
#   v0.9.3 - Added -v (Debug) option. Redirects output to stdout+log in debug mode, or log-only otherwise.
#   v0.9.2 - Added detailed comments to Main Logic for better readability.
#   v0.9.1 - Added function header comments for better documentation.
#   v0.9.0 - Added specific error codes (31, 32) for binary logging issues.
#   v0.8.5 - Improved 'log' mode: Directory creation moved after validation checks to avoid empty folders on error.
#   v0.8.4 - Fixed 'log' mode: Removed 'LIMIT 1' from 'SHOW BINARY LOGS' query to ensure compatibility with older MariaDB versions.
#   v0.8.3 - Improved 'log' mode: Explicit check for binary logging status before attempting backup.
#   v0.8.2 - Fixed 'log' mode: Auto-detect start binlog file using 'SHOW BINARY LOGS'.
#   v0.8.1 - Fixed 'log' mode: Removed invalid flag --all-databases from mysqlbinlog command.
#   v0.8.0 - Redirected mariadb-backup STDERR to STDOUT (2>&1) for better visibility in automation tools.
#   v0.7.0 - Added --history flag to record backup metadata in the database.
#   v0.6.0 - Shortened modes to full, inc, log. Added NFS format check, write test, sudo pre-check, and timeouts.
#   v0.5.3 - Cleaned up unused variable MOUNTED_BY_SCRIPT
#   v0.5.2 - Changed cleanup logic: Unmount only happens if -u is explicitly set
#   v0.5.1 - Added -u option to force unmount at the end
#   v0.5.0 - Refactored to run as non-privileged user with explicit sudo calls
#   v0.4.0 - Added NFS mount support (-n), log copying, and sudo mount/umount handling
#   v0.3.0 - Added -p (prune) option
#   v0.1.0 - Added strict error codes

set -e # Exit script if a command fails

# --- Version & Constants ---
VERSION="0.9.5"

# Error Code Definitions
readonly E_SUCCESS=0
readonly E_INVALID_ARGS=10
readonly E_UNKNOWN_MODE=11
readonly E_INVALID_NFS=12
readonly E_INVALID_DBNAME=13
readonly E_MISSING_DEP_BACKUP=20
readonly E_MISSING_DEP_CLIENT=21
readonly E_MISSING_DEP_BINLOG=22
readonly E_SUDO_FAILED=23
readonly E_MISSING_DEP_SYS=24
readonly E_SCRIPT_RUNNING=25
readonly E_LOG_NOT_WRITABLE=26
readonly E_DB_ACCESS=30
readonly E_BINLOG_DISABLED=31
readonly E_NO_BINLOGS_FOUND=32
readonly E_SERVER_UNREACHABLE=33
readonly E_NO_CHECKPOINT=40
readonly E_BASE_MISSING=41
readonly E_WRITE_TEST_FAILED=42
readonly E_BACKUP_FAILED_FULL=50
readonly E_BACKUP_FAILED_INC=51
readonly E_BACKUP_FAILED_BINLOG=52
readonly E_MOUNT_FAILED=60
readonly E_UMOUNT_FAILED=61

# --- Default Values ---
DATE_STAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG_FILE="/var/log/mariadb_backup.log"
LOCK_FILE="/tmp/mariadb_backup.lock"
PRUNE_DAYS=""
NFS_SHARE=""
FORCE_UNMOUNT=0
DEBUG=0

# --- Helper Functions ---

#######################################
# Prints usage information and exits the script with an error code.
# Globals:
#   VERSION
#   E_INVALID_ARGS
# Arguments:
#   None
#######################################
usage() {
    echo "MariaDB Backup Wrapper v$VERSION"
    echo "Usage: $0 -d <Database|all> -t <TargetDir> -m <Mode> -n <NfsShare> [-p <Days>] [-u] [-v]"
    echo ""
    echo "Parameters:"
    echo "  -d  Name of the database to backup, or 'all' for full instance"
    echo "  -t  Path to the local directory where backups will be stored (Mount point)"
    echo "  -m  Backup Mode: 'full', 'inc', 'log'"
    echo "  -n  NFS Share to mount (Required) (Format: IP:/share/path)"
    echo "  -p  (Optional) Prune/Delete backups older than N days"
    echo "  -u  (Optional) Force unmount of the target directory at the end"
    echo "  -v  (Optional) Enable Debug mode (Output to console + log). Default: Log only."
    exit $E_INVALID_ARGS
}

#######################################
# Logs a message with a timestamp to stdout and a log file via sudo.
# Globals:
#   VERSION
#   LOG_FILE
# Arguments:
#   $1 - The message string to log.
#######################################
log() {
    # Using sudo tee to write to restricted log file /var/log/mariadb_backup.log
    # If tee fails, we fallback to stdout to avoid infinite loop
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [v$VERSION] $1"
    echo "$msg"
    echo "$msg" | sudo tee -a "$LOG_FILE" > /dev/null 2>&1 || true
}

#######################################
# Executes a command and handles output redirection based on DEBUG mode.
# - Debug Mode: Output goes to STDOUT and LOG_FILE.
# - Normal Mode: Output goes to LOG_FILE only (Silent on console).
# Uses 'pipefail' to capture the exit code of the actual command, not tee.
# Globals:
#   DEBUG
#   LOG_FILE
# Arguments:
#   The command and its arguments to execute.
#######################################
execute_and_log() {
    # Enable pipefail so we get the exit code of the command, not tee
    set -o pipefail
    
    if [[ $DEBUG -eq 1 ]]; then
        # Debug: Print to stdout AND append to log
        "$@" 2>&1 | sudo tee -a "$LOG_FILE"
    else
        # Normal: Append to log ONLY, suppress stdout
        "$@" 2>&1 | sudo tee -a "$LOG_FILE" > /dev/null
    fi
    
    local status=$?
    set +o pipefail # Reset pipefail just in case
    return $status
}

#######################################
# Checks if required system dependencies (tools and sudo access) are met.
# Exits the script if dependencies are missing.
# Globals:
#   E_MISSING_DEP_BACKUP
#   E_MISSING_DEP_CLIENT
#   E_SUDO_FAILED
#   E_MISSING_DEP_SYS
# Arguments:
#   None
#######################################
check_dependencies() {
    # 1. Check DB tools
    if ! command -v mariadb-backup &> /dev/null; then
        echo "Error: 'mariadb-backup' is not installed or not in PATH."
        exit $E_MISSING_DEP_BACKUP
    fi
    
    if ! command -v mysql &> /dev/null; then
        echo "Error: 'mysql' client is not installed."
        exit $E_MISSING_DEP_CLIENT
    fi

    # 2. Check System tools (timeout, findmnt, flock)
    for tool in timeout findmnt flock; do
        if ! command -v "$tool" &> /dev/null; then
            echo "Error: System utility '$tool' is missing."
            exit $E_MISSING_DEP_SYS
        fi
    done

    # 3. Check Sudo Access
    # We test if we can run a harmless command with sudo without password
    if ! sudo -n true 2>/dev/null; then
        echo "Error: Sudo access failed. Please configure sudoers for NOPASSWD or check permissions."
        exit $E_SUDO_FAILED
    fi
}

#######################################
# Validates input parameters for format correctness.
# Exits the script if formats (DB Name, NFS path) are invalid.
# Globals:
#   DB_NAME
#   NFS_SHARE
#   E_INVALID_DBNAME
#   E_INVALID_NFS
# Arguments:
#   None
#######################################
check_input_validity() {
    # 1. Sanitize DB Name (Alphanumeric, underscores, dashes only)
    if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ "$DB_NAME" != "all" ]]; then
        log "ERROR: Invalid characters in database name '$DB_NAME'. Only a-z, 0-9, _ and - are allowed."
        exit $E_INVALID_DBNAME
    fi

    # 2. Validate NFS Format (Server:/Path)
    if [[ ! "$NFS_SHARE" =~ ^.+:.+$ ]]; then
        log "ERROR: NFS Share '$NFS_SHARE' is invalid. Expected format: Server:/Path"
        exit $E_INVALID_NFS
    fi
}

#######################################
# Checks connectivity to the MariaDB server.
# Globals:
#   E_SERVER_UNREACHABLE
# Arguments:
#   None
#######################################
check_server_status() {
    # Uses mysqladmin ping to check if server is responsive.
    if ! sudo mysqladmin ping --silent >/dev/null 2>&1; then
        log "CRITICAL ERROR: MariaDB Server is unreachable (ping failed)."
        exit $E_SERVER_UNREACHABLE
    fi
}

#######################################
# Checks if the specified database exists on the server.
# Skipped if DB_NAME is 'all'.
# Globals:
#   DB_NAME
#   E_DB_ACCESS
# Arguments:
#   None
#######################################
check_db_exists() {
    if [[ "$DB_NAME" == "all" ]]; then
        return 0
    fi
    # Use sudo to use root's credentials in /root/.my.cnf
    if ! sudo mysql --batch --skip-column-names -e "USE \`$DB_NAME\`" 2>/dev/null; then
        log "ERROR: Database '$DB_NAME' does not exist or access denied."
        exit $E_DB_ACCESS
    fi
}

# --- NFS Functions ---

#######################################
# Mounts the NFS share to the backup root directory.
# Verifies mount success and write permissions.
# Globals:
#   NFS_SHARE
#   BACKUP_ROOT
#   E_MOUNT_FAILED
#   E_WRITE_TEST_FAILED
# Arguments:
#   None
#######################################
mount_nfs() {
    log "Preparing to mount NFS share: $NFS_SHARE -> $BACKUP_ROOT"

    # Ensure mount point exists
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        log "Creating mount point directory: $BACKUP_ROOT"
        sudo mkdir -p "$BACKUP_ROOT"
    fi

    # Check if something is already mounted there
    if mountpoint -q "$BACKUP_ROOT"; then
        # Get the actual source of the current mount
        local current_source
        current_source=$(sudo findmnt -n -o SOURCE "$BACKUP_ROOT")
        
        local clean_share="${NFS_SHARE%/}"
        local clean_source="${current_source%/}"

        if [[ "$clean_source" != "$clean_share" ]]; then
            log "ERROR: Mountpoint mismatch! '$BACKUP_ROOT' is mounted from '$current_source', but '$NFS_SHARE' was requested."
            exit $E_MOUNT_FAILED
        else
            log "WARNING: '$BACKUP_ROOT' is already mounted with correct share. Proceeding."
        fi
    else
        log "Mounting NFS share (Timeout: 15s)..."
        # Added timeout to prevent hanging if NFS server is down
        if sudo timeout 15 mount -t nfs "$NFS_SHARE" "$BACKUP_ROOT"; then
            log "Mount successful."
        else
            log "ERROR: Failed to mount NFS share (or timed out)."
            exit $E_MOUNT_FAILED
        fi
    fi

    # Post-Mount Write Test
    local test_file="$BACKUP_ROOT/.write_test_$$"
    if ! sudo touch "$test_file" 2>/dev/null; then
        log "ERROR: Mount successful, but CANNOT WRITE to '$BACKUP_ROOT'. Check NFS permissions."
        exit $E_WRITE_TEST_FAILED
    else
        sudo rm -f "$test_file"
    fi
}

#######################################
# Cleanup handler executed on script exit.
# Copies the log file to the backup destination and unmounts the NFS share if requested.
# Globals:
#   BACKUP_ROOT
#   LOG_FILE
#   FORCE_UNMOUNT
# Arguments:
#   None
#######################################
cleanup() {
    local exit_code=$?
    
    # 1. Copy Log File
    if [[ -d "$BACKUP_ROOT" ]] && mountpoint -q "$BACKUP_ROOT"; then
        local dest_log="$BACKUP_ROOT/mariadb_backup_$(hostname).log"
        # We use a subshell and check for file existence to handle copy errors gracefully
        if ! sudo cp "$LOG_FILE" "$dest_log" 2>/dev/null; then
             # Silent fail or echo to stderr, log function might trigger loop if log file unavailable
             echo "WARNING: Could not copy log file to backup target." >&2
        fi
    fi

    # 2. Unmount Logic
    if [[ "$FORCE_UNMOUNT" -eq 1 ]]; then
        if mountpoint -q "$BACKUP_ROOT"; then
            log "Unmounting NFS share..."
            if sudo umount "$BACKUP_ROOT"; then
                log "Unmount successful."
            else
                log "ERROR: Failed to unmount '$BACKUP_ROOT'. Please check manually."
            fi
        fi
    fi
    
    exit $exit_code
}

#######################################
# Prunes old backups based on a retention period in days.
# Respects incremental backup chains (keeps full backups if incrementals depend on them).
# Globals:
#   None (Uses arguments and local context)
# Arguments:
#   $1 - target_dir: The directory containing the backups.
#   $2 - days: The number of days to retain backups.
#######################################
prune_backups() {
    local target_dir="$1"
    local days="$2"
    
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        log "WARNING: Prune argument '$days' is not an integer. Skipping prune."
        return
    fi

    log "Starting Prune process: Removing backups older than $days days in $target_dir"
    
    if ! cd "$target_dir"; then
        log "WARNING: Could not access $target_dir for pruning."
        return
    fi

    # 1. Prune Binlogs
    sudo find . -maxdepth 1 -name "binlog_*" -type d -mtime +$days -print0 | while IFS= read -r -d '' f; do 
        log "  Deleting expired binlog: $f"
        sudo rm -rf "$f"
    done

    # 2. Prune Chains
    local full_backups=($(sudo ls -d full_* 2>/dev/null | sort))
    
    for ((i=0; i<${#full_backups[@]}; i++)); do
        local current_full="${full_backups[$i]}"
        local next_full="${full_backups[$i+1]}" 
        
        local chain_members=("$current_full")
        local incs=()
        
        if [[ -z "$next_full" ]]; then
            incs=($(sudo ls -d inc_* 2>/dev/null | awk -v start="$current_full" '$0 > start'))
        else
            incs=($(sudo ls -d inc_* 2>/dev/null | awk -v start="$current_full" -v end="$next_full" '$0 > start && $0 < end'))
        fi
        
        chain_members+=("${incs[@]}")
        
        local keep_chain=0
        for member in "${chain_members[@]}"; do
            if [[ -n "$(sudo find "$member" -maxdepth 0 -mtime -$days 2>/dev/null)" ]]; then
                keep_chain=1
                break 
            fi
        done
        
        if [[ $keep_chain -eq 0 ]]; then
            log "  Pruning expired chain starting with $current_full (${#chain_members[@]} items)..."
            for member in "${chain_members[@]}"; do
                sudo rm -rf "$member"
                log "    Deleted: $member"
            done
            
            # Checkpoint Cleanup
            if [[ -f "last_checkpoint" ]]; then
                local last_cp_path
                last_cp_path=$(sudo cat "last_checkpoint")
                if [[ ! -d "$last_cp_path" ]]; then
                    sudo rm -f "last_checkpoint"
                fi
            fi
        fi
    done
    
    cd - > /dev/null
}

# --- Parameter Parsing ---

while getopts "d:t:m:p:n:uv" opt; do
    case $opt in
        d) DB_NAME="$OPTARG" ;;
        t) BACKUP_ROOT="$OPTARG" ;;
        m) MODE="$OPTARG" ;;
        p) PRUNE_DAYS="$OPTARG" ;;
        n) NFS_SHARE="$OPTARG" ;;
        u) FORCE_UNMOUNT=1 ;;
        v) DEBUG=1 ;;
        *) usage ;;
    esac
done

# Validate parameters
if [[ -z "$DB_NAME" || -z "$BACKUP_ROOT" || -z "$MODE" || -z "$NFS_SHARE" ]]; then
    echo "Error: Missing required parameters."
    usage
fi

# Remove trailing slash from BACKUP_ROOT
BACKUP_ROOT="${BACKUP_ROOT%/}"

# --- Concurrency Check (Locking) ---
# Acquire lock to prevent concurrent executions
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "ERROR: Script is already running (Lock file $LOCK_FILE active)."
    exit $E_SCRIPT_RUNNING
fi

# Setup Trap for cleanup (after lock is acquired)
trap cleanup EXIT INT TERM

# --- Main Logic ---

# 1. Verify all system requirements (Tools & Permissions)
#    Now includes check for timeout, findmnt, flock.
check_dependencies

# 2. Check if we can write to the log file (Fail fast)
if ! sudo touch "$LOG_FILE" 2>/dev/null; then
    echo "CRITICAL ERROR: Cannot write to log file $LOG_FILE."
    exit $E_LOG_NOT_WRITABLE
fi

# 3. Verify MariaDB Server is running (Ping)
#    Different from checking DB existence; fails if server process is dead.
check_server_status

# 4. Validate user inputs (DB Name format, NFS format)
check_input_validity

# 5. Mount the NFS share (Critical step, script fails if this fails)
mount_nfs

# Define critical path variables for the backup logic
CHECKPOINT_FILE="$BACKUP_ROOT/$DB_NAME/last_checkpoint"
DB_BACKUP_DIR="$BACKUP_ROOT/$DB_NAME"

# Ensure the directory exists (on the mounted share)
if [[ ! -d "$DB_BACKUP_DIR" ]]; then
    log "Creating backup directory structure: $DB_BACKUP_DIR"
    sudo mkdir -p "$DB_BACKUP_DIR"
fi

# Prepare extra arguments for mariadb-backup (e.g., where to store LSN info)
AUTH_ARGS="--extra-lsndir=$DB_BACKUP_DIR" 

# 6. Check if the requested database actually exists (skipped if 'all')
check_db_exists

# Configure arguments based on whether we backup a specific DB or everything
if [[ "$DB_NAME" == "all" ]]; then
    DB_ARGS=""  # No specific DB filter -> Backup everything
else
    DB_ARGS="--databases=$DB_NAME" # Filter for specific DB
fi

log "Starting backup for target: $DB_NAME | Mode: $MODE | Debug: $DEBUG"

# 7. Execute the requested backup mode
case "$MODE" in
    full)
        TARGET_DIR="$DB_BACKUP_DIR/full_$DATE_STAMP"
        
        log "Running FULL backup..."
        set +e
        # Using execute_and_log wrapper to handle output redirection logic
        # shellcheck disable=SC2086
        execute_and_log sudo mariadb-backup --backup \
            $AUTH_ARGS \
            $DB_ARGS \
            --history \
            --target-dir="$TARGET_DIR"
        EXIT_CODE=$?
        set -e

        if [[ $EXIT_CODE -eq 0 ]]; then
            log "Full backup successful: $TARGET_DIR"
            echo "$TARGET_DIR" | sudo tee "$CHECKPOINT_FILE" > /dev/null
            
            if [[ -n "$PRUNE_DAYS" ]]; then
                prune_backups "$DB_BACKUP_DIR" "$PRUNE_DAYS"
            fi
            exit $E_SUCCESS
        else
            log "ERROR during Full Backup! Exit Code: $EXIT_CODE"
            exit $E_BACKUP_FAILED_FULL
        fi
        ;;

    inc)
        TARGET_DIR="$DB_BACKUP_DIR/inc_$DATE_STAMP"

        if [[ ! -f "$CHECKPOINT_FILE" ]]; then
            log "ERROR: No previous backup found (checkpoint file missing). Please create a 'full' backup first."
            exit $E_NO_CHECKPOINT
        fi

        BASE_DIR=$(sudo cat "$CHECKPOINT_FILE")

        # Added check for empty variable to prevent confusing errors
        if [[ -z "$BASE_DIR" ]]; then
             log "ERROR: Checkpoint file exists but is empty/corrupt."
             exit $E_BASE_MISSING
        fi

        if [[ ! -d "$BASE_DIR" ]]; then
             log "ERROR: The base backup directory '$BASE_DIR' no longer exists."
             exit $E_BASE_MISSING
        fi

        log "Running INCREMENTAL backup (Based on: $BASE_DIR)..."
        
        set +e
        # Using execute_and_log wrapper to handle output redirection logic
        # shellcheck disable=SC2086
        execute_and_log sudo mariadb-backup --backup \
            $AUTH_ARGS \
            $DB_ARGS \
            --history \
            --target-dir="$TARGET_DIR" \
            --incremental-basedir="$BASE_DIR"
        EXIT_CODE=$?
        set -e

        if [[ $EXIT_CODE -eq 0 ]]; then
            log "Incremental backup successful: $TARGET_DIR"
            echo "$TARGET_DIR" | sudo tee "$CHECKPOINT_FILE" > /dev/null

            if [[ -n "$PRUNE_DAYS" ]]; then
                prune_backups "$DB_BACKUP_DIR" "$PRUNE_DAYS"
            fi
            exit $E_SUCCESS
        else
            log "ERROR during Incremental Backup! Exit Code: $EXIT_CODE"
            exit $E_BACKUP_FAILED_INC
        fi
        ;;

    log)
        TARGET_DIR="$DB_BACKUP_DIR/binlog_$DATE_STAMP"
        
        log "Backing up Binary Logs (Transaction Logs)..."
        
        if ! command -v mysqlbinlog &> /dev/null; then
            log "ERROR: mysqlbinlog is not installed."
            exit $E_MISSING_DEP_BINLOG
        fi
        
        # Check if binary logging is enabled and get the first log
        if ! BINLOG_OUTPUT=$(sudo mysql --batch --skip-column-names -e "SHOW BINARY LOGS" 2>&1); then
            log "ERROR: Check for binary logs failed. Binary logging is likely disabled."
            log "MySQL Output: $BINLOG_OUTPUT"
            exit $E_BINLOG_DISABLED
        fi
        
        FIRST_BINLOG=$(echo "$BINLOG_OUTPUT" | head -n 1 | awk '{print $1}')

        if [[ -z "$FIRST_BINLOG" ]]; then
            log "ERROR: Binary logging is enabled but no logs were found (Result empty)."
            exit $E_NO_BINLOGS_FOUND
        fi
        
        log "Found starting binlog: $FIRST_BINLOG"
        
        # Create directory only after validations passed
        sudo mkdir -p "$TARGET_DIR"

        set +e
        # Fetch logs using execute_and_log wrapper
        execute_and_log sudo mysqlbinlog --read-from-remote-server --raw --to-last-log --result-file="$TARGET_DIR/" "$FIRST_BINLOG"
        EXIT_CODE=$?
        set -e
        
        if [[ $EXIT_CODE -eq 0 ]]; then
            log "Transaction Log Backup successful in: $TARGET_DIR"
            
            if [[ -n "$PRUNE_DAYS" ]]; then
                prune_backups "$DB_BACKUP_DIR" "$PRUNE_DAYS"
            fi
            exit $E_SUCCESS
        else
            log "ERROR during Transaction Log Backup. Check permissions. Exit Code: $EXIT_CODE"
            exit $E_BACKUP_FAILED_BINLOG
        fi
        ;;

    *)
        echo "Unknown Mode: $MODE. Supported modes: full, inc, log"
        usage
        exit $E_UNKNOWN_MODE
        ;;
esac
