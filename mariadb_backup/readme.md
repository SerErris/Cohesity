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

Example /root/.my.cnf:

```bash
[client]  
user=root  
password=your_secure_password
```

**Security Note:** always ensure that this file has only read/write permissions for root user (500).


### **3\. Sudo Configuration (Minimum Privileges)**

The script runs as a standard user but requires sudo privileges for specific operations.

To allow the script to run without a password prompt, add the following configuration to /etc/sudoers or a new file in /etc/sudoers.d/mariadb\_backup.

**Replace your\_backup\_user with the actual username running the script.**

```bash
# Alias for the backup user  
User_Alias BACKUP_USER = your_backup_user

# Command Aliases  
# File System Operations (Includes flock for locking and timeout for safe mounts)  
Cmnd_Alias FS_OPS = /usr/bin/mkdir, /usr/bin/rm, /usr/bin/cp, /usr/bin/ls, /usr/bin/cat, /usr/bin/tee, /usr/bin/touch, /usr/bin/timeout, /usr/bin/flock  
# Mount Operations  
Cmnd_Alias MOUNT_OPS = /usr/bin/mount, /usr/bin/umount, /usr/bin/findmnt  
# Database Operations (Includes mysqladmin for ping checks)  
Cmnd_Alias DB_OPS = /usr/bin/mariadb-backup, /usr/bin/mysql, /usr/bin/mysqlbinlog, /usr/bin/mysqladmin, /usr/bin/find

# Grant privileges without password (including the harmless 'true' command for pre-checks)  
BACKUP\_USER ALL=(root) NOPASSWD: FS\_OPS, MOUNT\_OPS, DB\_OPS, /usr/bin/true
```

**Here is the list of all used commands:**
mkdir, rm, cp, ls, cat, tee, touch, timeout, flock
mount, umount, findmnt
mariadb-backup, mysql, mysqlbinlog, mysqladmin, find

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
```bash
./mariadb\_backup.sh \-d all \-t /mnt/sql\_backups \-m full \-n 192.168.1.5:/storage
```

2\. Daily Incremental Backup with Debugging (Temporary Mount)  
Backs up production\_db, shows output on console for debugging, removes backups older than 7 days, and unmounts the share immediately after.  
```bash
./mariadb\_backup.sh \-d production\_db \-t /mnt/backup \-m inc \-n 192.168.1.5:/storage \-p 7 \-u \-v
```

## Cohesity Remote Adapter Integration for MariaDB Backup

This section describes how to integrate the `mariadb_backup.sh` script with Cohesity using the Remote Adapter feature, including View setup, policy configuration, and Protection Group creation.

---

### **1. Create a Cohesity View**

Configure a Cohesity View to store MariaDB backups. Use the following parameters as a reference:

| Parameter                | Example Value                        | Description                                                                 |
|--------------------------|--------------------------------------|-----------------------------------------------------------------------------|
| **View Name**            | `mariadb`                            | Logical name for the backup container.                                      |
| **Storage Domain**       | `DefaultStorageDomain`               | Storage domain where the view resides.                                      |
| **NFS Mount Path**       | `cohesitycl.lab.local:/mariadb`      | NFS path to use as the backup target in your script.                        |
| **Protocol Access**      | `NFS (ReadWrite)`                    | Protocol and access mode enabled for the view.                              |
| **Subnet Whitelist**     | `192.168.0.0/24` (ReadWrite, RootSquash) | Network allowed to access the view via NFS, with root squash for security.  |
| **Root Squash Setting**  | `uid: 65534, gid: 100`               | NFS root squash maps root to this user/group.                               |
| **Security Mode**        | `NativeMode`                         | Security mode for access control.                                           |
| **QoS Policy**           | `BackupTargetHigh`                   | Quality of Service policy for backup performance.                           |

**Note:**  
The `gid` specified in the root squash setting (`gid: 100`) should correspond to the group used on the MariaDB server for backup operations (commonly the `users` group or a dedicated backup group). This ensures file permissions and access control are consistent between the Cohesity View and your MariaDB server.

---

### **2. Configure a Cohesity Protection Policy**

When creating a Cohesity Protection Policy for MariaDB backups, ensure the following settings are configured in the GUI:

| Policy Section           | Example Setting                       | Description                                                                 |
|--------------------------|---------------------------------------|-----------------------------------------------------------------------------|
| **Policy Name**          | `MariaDB_policy`                      | Logical name for the policy.                                                |
| **Incremental Backup**   | Every 1 day                           | Schedule regular incremental backups to capture daily changes.               |
| **Full Backup**          | Every Friday                          | Schedule periodic full backups (e.g., weekly on Friday) for restore points.  |
| **Full Backup Retention**| 2 weeks                               | Retain full backups for at least 2 weeks.                                   |
| **Overall Retention**    | 2 weeks                               | Retain all backups (incremental and full) for at least 2 weeks.             |
| **Log Backup**           | Every 4 hours                         | Schedule transaction log (binlog) backups for point-in-time recovery.        |
| **Log Backup Retention** | 2 weeks                               | Retain log backups for at least 2 weeks.                                    |
| **Retry Options**        | 3 retries, 5 min interval             | Configure retries for failed jobs to improve reliability.                    |

---

### **3. Create a Remote Adapter Protection Group**

Follow these steps in the Cohesity UI to set up remote orchestration of MariaDB backups:

#### **a. Select Protection Group Type**
- Choose **Remote Adapter** as the protection group type.

#### **b. Fill in Protection Group Details**
- **Protection Group Name:**  
  Enter a descriptive name, e.g. `mariadb`.

#### **c. Specify Host Information**
- **Linux Hostname or IP:**  
  Enter the hostname or IP address of the MariaDB server, e.g. `mariadb.host.local`.
- **Username:**  
  Enter the username on the host that Cohesity will use to connect via SSH, e.g. `user123`.

#### **d. Set Up SSH Permissions**
- **Cluster SSH Public Key:**  
  Copy the provided Cohesity Cluster SSH Public Key.
- **On the MariaDB server:**  
  - Log in as the specified user (`user123`).
  - Add the Cohesity Cluster SSH Public Key to the user's `~/.ssh/authorized_keys` file.
  - **Set correct permissions:**
    - The `.ssh` directory should have permissions `700` (only accessible by the user).
    - The `authorized_keys` file should have permissions `600` (read/write for the user only).
    - Example commands:
      ```bash
      chmod 700 ~/.ssh
      chmod 600 ~/.ssh/authorized_keys
      ```
  - This ensures secure SSH access and allows Cohesity to execute backup scripts remotely.

#### **e. Select the Protection Policy**
- Choose the policy you created earlier, e.g. `MariaDB_policy`.

After selecting the policy, configure the NFS View and script information for each backup type:

#### **f. NFS View Selection**
- **NFS View:**  
  Select the view named `mariadb` (QoS Policy: Backup Target High).
- **Note:**  
  The associated View must be mounted on your MariaDB server, and the backup script must write to a directory on this mounted View.

#### **g. Enter script Information for Each Schedule**

| Schedule Type      | Script Path                              | Parameters                                                                 |
|--------------------|------------------------------------------|----------------------------------------------------------------------------|
| **Incremental**    | `/home/clinden/mariadb_backup.sh`        | `-d all -t /mnt/backup -m inc -n cohesitycl.lab.local:/mariadb -u`         |
| **Full**           | `/home/clinden/mariadb_backup.sh`        | `-d all -t /mnt/backup -m full -n cohesitycl.lab.local:/mariadb -p 10 -u`  |
| **Log**            | `/home/clinden/mariadb_backup.sh`        | `-d all -t /mnt/backup -m log -n cohesitycl.lab.local:/mariadb -u`         |

#### **h. Start Time**
- **Time:**  
  `08:52`
- **Time Zone:**  
  `Europe/Berlin`

---

**Summary of Steps:**
1. Create and configure the Cohesity View with correct NFS and permission settings.
2. Define a Protection Policy with schedules for incremental, full, and log backups.
3. Create a Remote Adapter Protection Group, set up SSH access, and select the policy.
4. Select the NFS View and configure script paths and parameters for all backup types in the Protection Group.

**Tip:**  
All three backup types (incremental, full, log) must be configured for complete protection and point-in-time recovery. Ensure the NFS View is mounted and accessible on the MariaDB server, and that SSH permissions are set correctly for remote execution.

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
