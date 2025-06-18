# 📦 Proxmox VM Backup Script

### Description

This Bash script backs up selected Proxmox virtual machines (VMs) using `vzdump`, resolving VM names to IDs automatically and targeting a specified backup storage.

The script supports:
- Cohesity-compatible execution (stdout is used for output)
- Deduplication-optimized storage (no compression or encryption)
- Local or remote backup based on which node hosts the VM
- Clear log output to both console and `/var/log/backup_vms.log`

---

### 🚀 Features

- Supports **short (`-n`, `-t`) and long (`--name`, `--target`) options**
- Automatically resolves VM names to VMIDs and node assignments
- Executes `vzdump` **locally** when VM is hosted on the current node
- Uses **SSH** to trigger `vzdump` remotely for VMs on other nodes
- Logs to **stdout** and `/var/log/backup_vms.log` simultaneously
- Compatible with **Cohesity DataProtect** (stdout captured in UI)
- Ready for use with **logrotate** for long-term log management

---

### 🔧 Prerequisites

- Must run on a Proxmox cluster node with access to `pvesh` and `jq`
- SSH key-based access from local node to other cluster nodes
- Logfile path: `/var/log/backup_vms.log`
- `jq` must be installed:
  ```bash
  apt install jq
  ```

---

### 🧑‍💻 Usage

```bash
./backup_vms.sh -n <vm_names> -t <backup_storage_target>
./backup_vms.sh --name <vm_names> --target <backup_storage_target>
```

#### Parameters

| Option            | Description                                |
|-------------------|--------------------------------------------|
| `-n`, `--name`     | Comma-separated list of VM names to back up |
| `-t`, `--target`   | Proxmox backup storage target              |
| `-d`, `--debug`    | Print debug commands before execution      |
| `-h`, `--help`     | Show usage help                            |

---

### ✅ Example

```bash
./backup_vms.sh --name db01,web01 --target nfs-backup --debug
```

If `db01` is on the current node, `vzdump` runs locally.  
If `web01` is on another node, the script SSHes into that node and runs `vzdump` remotely.

---

### 🗃️ Logging

- Log output is written to:
  - **stdout** (visible in Cohesity UI)
  - **/var/log/backup_vms.log** (persistent audit trail)

To rotate logs, use this `/etc/logrotate.d/backup_vms`:

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

- Designed for deduplicated storage (no compression/encryption).
- Use with **Cohesity Remote Adapter** to automate Proxmox VM protection in **Cohesity DataProtect**.
- Requires passwordless SSH for full automation in multi-node clusters.

---

### 📄 License & Warranty Disclaimer

This script is provided under the **MIT License**.

> ⚠️ **Disclaimer:**  
> This script is provided **as-is**, without any warranty of any kind.  
> Use at your own risk. The author(s) are not liable for any loss, data corruption, or system failure resulting from its use.

