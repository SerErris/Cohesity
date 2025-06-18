# 📦 Proxmox VM Backup Script

### Description

This Bash script backs up selected Proxmox virtual machines (VMs) using `vzdump`, resolving VM names to IDs automatically and targeting a specified backup storage.

It supports:
- Local or remote execution depending on VM placement
- Cohesity-compatible output (stdout + logfile)
- Automatic pruning of old backups using vzdump's native `--prune-backups keep-last=x`
- Clear log output to both console and `/var/log/backup_vms.log`
- Log rotation support via standard logrotate

---

### 🚀 Features

- Short and long CLI options: `-n`, `--name`, `-t`, `--target`, `-p`, `--prune_versions`
- Automatically resolves VM names to VMIDs and node assignments
- Executes `vzdump` locally when possible, or via SSH for remote nodes
- Logs to `stdout` (Cohesity-compatible) and `/var/log/backup_vms.log`
- Optional `--debug` mode to show each external command before it runs
- Built-in pruning of old backups using vzdump’s native `--prune-backups` flag

---

### 🔧 Prerequisites

- Must run on a Proxmox cluster node with access to `pvesh` and `jq`
- SSH key-based access from the node running the script to other cluster nodes
- Logfile: `/var/log/backup_vms.log` (writable by the executing user)
- `jq` must be installed:
  ```bash
  apt install jq
  ```

---

### 🧑‍💻 Usage

```bash
./backup_vms.sh -n <vm_names> -t <storage_target> [-p <keep_last>] [--debug]
```

#### Parameters

| Option                     | Description                                                        |
|----------------------------|--------------------------------------------------------------------|
| `-n`, `--name`             | Comma-separated list of VM names to back up                        |
| `-t`, `--target`           | Proxmox backup storage target (e.g., 'nfs-backup')                 |
| `-p`, `--prune_versions`   | Keep only the last X backups per VM (uses vzdump prune feature)    |
| `-d`, `--debug`            | Enable debug output (logs all executed commands)                   |
| `-h`, `--help`             | Show usage help                                                    |

---

### ✅ Example

```bash
./backup_vms.sh --name db01,web01 --target nfs-backup --prune_versions 3 --debug
```

- `db01` on local node → runs vzdump locally
- `web01` on another node → vzdump is triggered remotely via SSH
- Only last 3 backups per VM will be retained on the target storage

---

### 🗃️ Logging

- Log output is written to:
  - **stdout** (captured by Cohesity UI)
  - **/var/log/backup_vms.log** (persistent audit trail)

#### Example `/etc/logrotate.d/backup_vms`:

```conf
/var/log/backup_vms.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root adm
}
```

---

### 💡 Notes

- This script is designed for use with **deduplication-optimized storage**.
- Compatible with **Cohesity Remote Adapter** to automate Proxmox VM protection via **Cohesity DataProtect**.
- All pruning is done natively via `vzdump` using the `--prune-backups keep-last=x` flag.

---

### 📄 License & Warranty Disclaimer

This script is provided under the **MIT License**.

> ⚠️ **Disclaimer:**  
> This script is provided **as-is**, without any warranty of any kind.  
> Use at your own risk. The author(s) are not liable for any loss, data corruption, or system failure resulting from its use.

