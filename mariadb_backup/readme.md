# **MariaDB Backup Script Documentation**

## **Introduction**

The **MariaDB Backup Script** (mariadb\_backup.sh) is a robust wrapper around the mariadb-backup tool. It is designed to automate Full, Incremental, and Binary Log backups for MariaDB instances.

Unlike standard backup one-liners, this script handles complex lifecycle management: it automatically manages backup dependency chains (linking incremental backups to their base), handles NFS mounting/unmounting for secure remote storage, prevents concurrent execution using locking, and includes intelligent pruning logic to remove old backups without breaking restoration chains.

## **Description**

This script provides a unified interface for database backups with the following key features:

* **Backup Modes**:  
  * **Full** (full): Creates a complete backup of the database or instance. Starts a new backup chain.  
  * **Incremental** (inc): Creates a backup containing only changes since the last backup. Automatically detects the base directory from the last\_checkpoint file.  
  * **Transaction Log** (log): Backs up binary logs for point-in-time recovery.  
* **Logging & Debugging**:  
  * **Standard**: Backup tool output is directed exclusively to the logfile (/var/log/mariadb\_backup.log) to keep the console clean for automation.  
  * **Debug (-v)**: Enables verbose output to both the console (stdout) and the logfile for troubleshooting.  
* **Safety & Validation**:  
  * **Concurrency Locking**: Prevents multiple instances of the script from running simultaneously using a lock file (/tmp/mariadb\_backup.lock).  
  * **Server Health Check**: Explicitly checks if the MariaDB server is reachable via mysqladmin ping before starting any operations.  
  * **Pre-flight Checks**: Verifies Sudo privileges, tool availability (including system tools like flock and timeout), and NFS string format before execution.  
  * **Explicit Binlog Checks**: Validates if binary logging is enabled and active before attempting a log backup.  
* **Target Flexibility**: Supports backing up a single specific database (-d dbname) or the entire instance (-d all).  
* **NFS Integration**: Automatically mounts a specified NFS share before the backup and can optionally unmount it afterwards to ensure backup isolation.  
* **Pruning**: Automated cleanup of old backups (-p days) that respects dependency chains.

## **Prerequisites**

### **1\. System Packages**

The following tools must be installed on the system:

* mariadb-backup  
* mariadb-client (provides mysql, mysqladmin, and mysqlbinlog)  
* nfs-common (required for mounting NFS shares)  
* coreutils (standard tools like timeout, date, etc.)  
* util-linux (provides flock, findmnt)

### **2\. Database Authentication**

The script relies on a password-less configuration for the root (or backup) user. It is recommended to use a .my.cnf file in the home directory of the user executing the script (or /root/.my.cnf if using sudo for mysql commands).

Example \~/.my.cnf:

\[client\]  
user=root  
password=your\_secure\_password

### **3\. Sudo Configuration (Minimum Privileges)**

The script runs as a standard user but requires sudo privileges for specific operations.

To allow the script to run without a password prompt, add the following configuration to /etc/sudoers or a new file in /etc/sudoers.d/mariadb\_backup.

**Replace your\_backup\_user with the actual username running the script.**

\# Alias for the backup user  
User\_Alias BACKUP\_USER \= your\_backup\_user

\# Command Aliases  
\# File System Operations (Includes flock for locking and timeout for safe mounts)  
Cmnd\_Alias FS\_OPS \= /usr/bin/mkdir, /usr/bin/rm, /usr/bin/cp, /usr/bin/ls, /usr/bin/cat, /usr/bin/tee, /usr/bin/touch, /usr/bin/timeout, /usr/bin/flock  
\# Mount Operations  
Cmnd\_Alias MOUNT\_OPS \= /usr/bin/mount, /usr/bin/umount, /usr/bin/findmnt  
\# Database Operations (Includes mysqladmin for ping checks)  
Cmnd\_Alias DB\_OPS \= /usr/bin/mariadb-backup, /usr/bin/mysql, /usr/bin/mysqlbinlog, /usr/bin/mysqladmin, /usr/bin/find

\# Grant privileges without password (including the harmless 'true' command for pre-checks)  
BACKUP\_USER ALL=(root) NOPASSWD: FS\_OPS, MOUNT\_OPS, DB\_OPS, /usr/bin/true

**Security Note**: The script requires rm \-rf via sudo to prune old backups. Ensure the target\_dir variable in the script is strictly controlled.

## **Usage**

Make the script executable:

chmod \+x mariadb\_backup.sh

### **Syntax**

./mariadb\_backup.sh \-d \<db\_name|all\> \-t \<target\_dir\> \-m \<full|inc|log\> \-n \<nfs\_share\> \[-p \<days\>\] \[-u\] \[-v\]

### **Parameters**

| Flag | Description | Required | Example |
| :---- | :---- | :---- | :---- |
| \-d | Database name or all for full instance. | Yes | \-d my\_app\_db or \-d all |
| \-t | Local mount point/target directory. | Yes | \-t /mnt/backup |
| \-m | Backup mode (full, inc, log). | Yes | \-m full |
| \-n | NFS Share path (Server:Path). | Yes | \-n 192.168.1.10:/backups |
| \-p | Prune backups older than N days. | No | \-p 30 |
| \-u | Force unmount of target after completion. | No | \-u |
| \-v | Enable Debug/Verbose mode (StdOut \+ Log). | No | \-v |

### **Examples**

1\. Full Instance Backup (Silent, Persistent Mount)  
Backs up all databases to /mnt/sql\_backups, keeping the share mounted afterwards. Output only goes to logfile.  
./mariadb\_backup.sh \-d all \-t /mnt/sql\_backups \-m full \-n 192.168.1.5:/storage

2\. Daily Incremental Backup with Debugging (Temporary Mount)  
Backs up production\_db, shows output on console for debugging, removes backups older than 7 days, and unmounts the share immediately after.  
./mariadb\_backup.sh \-d production\_db \-t /mnt/backup \-m inc \-n 192.168.1.5:/storage \-p 7 \-u \-v

## **Limitations**

* **No Restore Automation**: This script is strictly for **taking** backups. It does not include logic for restoring data. Restoration must be performed manually using mariadb-backup \--prepare and mariadb-backup \--copy-back.  
* **Global Locking**: Although mariadb-backup is designed for "hot" backups (non-blocking) of InnoDB tables, a brief FLUSH TABLES WITH READ LOCK is required at the end of the backup process.  
* **No Parallel Writes**: The script does not currently support parallel writes to multiple storage nodes.

## **Exit Codes**

The script uses specific exit codes to help with debugging and automation (e.g., in Cron or monitoring tools).

| Code | Type | Meaning |
| :---- | :---- | :---- |
| 0 | Success | Backup completed successfully. |
| 10 | Input Error | Invalid arguments or missing parameters. |
| 11 | Input Error | Unknown backup mode provided. |
| 12 | Input Error | Invalid NFS share format (Expected Server:/Path). |
| 13 | Input Error | Invalid Database name format (Special chars not allowed). |
| 20 | Dependency | mariadb-backup tool is missing. |
| 21 | Dependency | mysql client is missing. |
| 22 | Dependency | mysqlbinlog tool is missing. |
| 23 | Dependency | Sudo check failed (insufficient privileges). |
| 24 | Dependency | Required system tool missing (timeout, findmnt, flock). |
| 25 | Dependency | Script is already running (Lock file active). |
| 26 | Dependency | Log file is not writable. |
| 30 | DB Error | Database does not exist or access denied. |
| 31 | DB Error | Binary Logging is disabled (SHOW BINARY LOGS failed). |
| 32 | DB Error | No Binary Logs found (SHOW BINARY LOGS returned empty). |
| 33 | DB Error | MariaDB Server is unreachable (ping failed). |
| 40 | File System | Missing checkpoint file (cannot start incremental backup). |
| 41 | File System | Base backup directory missing (broken chain). |
| 42 | File System | Write permission test failed on target. |
| 50 | Execution | Full backup execution failed. |
| 51 | Execution | Incremental backup execution failed. |
| 52 | Execution | Transaction log backup execution failed. |
| 60 | Network/Mount | NFS Mount failed (or timed out). |
| 61 | Network/Mount | NFS Unmount failed. |

## **License & Warranty Disclaimer**

This script is provided under the **MIT License**.

⚠️ Disclaimer:  
This script is provided as-is, without any warranty of any kind.  
Use at your own risk. The author(s) are not liable for any loss, data corruption, or system failure resulting from its use.
