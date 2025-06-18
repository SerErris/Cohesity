#!/bin/bash
#
# backup_vms.sh – Proxmox VM Backup Script
#
# Copyright (c) 2025 Christoph Linden
# License: MIT
#
# This script is provided as-is, without warranty of any kind.
# Use at your own risk.

set -u

SCRIPT_VERSION="2.3"
DEBUG_MODE=0
LOG_FILE="/var/log/backup_vms.log"
HOST_NODE=$(hostname)

# ─────────────────────────────
# Logging Helpers
# ─────────────────────────────
function log() {
    echo "$1"
    echo "$1" >> "$LOG_FILE"
}

function error_exit {
    log "[ERROR] $1"
    exit 1
}

function usage {
    echo "Usage: $0 -n <vm_names> -t <storage_target> [-d|--debug]"
    echo ""
    echo "  -n, --name      Comma-separated list of VM names to back up"
    echo "  -t, --target    Backup storage target (e.g. 'nfs-backup')"
    echo "  -d, --debug     Enable debug output (show executed commands)"
    echo "  -h, --help      Show this help message"
    exit 1
}

function run_cmd() {
    if [[ $DEBUG_MODE -eq 1 ]]; then
        log "[DEBUG] $*"
    fi
    eval "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# ─────────────────────────────
# Startup Banner
# ─────────────────────────────
log "──────────────────────────────────────────────"
log "  Proxmox VM Backup Script (via vzdump + ssh/local)"
log "  Version: $SCRIPT_VERSION"
log "  Copyright (c) 2025 Christoph Linden"
log "  Started: $(date)"
log "──────────────────────────────────────────────"

# ─────────────────────────────
# Parse Arguments
# ─────────────────────────────
PARSED_ARGS=$(getopt -o n:t:dh --long name:,target:,debug,help -- "$@")
if [[ $? -ne 0 ]]; then
    usage
fi
eval set -- "$PARSED_ARGS"

VM_NAMES_RAW=""
STORAGE_TARGET=""

while true; do
    case "$1" in
        -n|--name)
            VM_NAMES_RAW="$2"
            shift 2
            ;;
        -t|--target)
            STORAGE_TARGET="$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG_MODE=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "$VM_NAMES_RAW" || -z "$STORAGE_TARGET" ]]; then
    usage
fi

# ─────────────────────────────
# Parse VM Names
# ─────────────────────────────
log "[INFO] Parsing input VM names..."
IFS=',' read -ra VM_NAMES <<< "$VM_NAMES_RAW"
if [[ ${#VM_NAMES[@]} -eq 0 ]]; then
    error_exit "No VM names provided."
fi

log "[INFO] VM names to back up:"
for NAME in "${VM_NAMES[@]}"; do
    log "  - $NAME"
done

# ─────────────────────────────
# Fetch Cluster VM Info
# ─────────────────────────────
log "[INFO] Querying cluster VM info..."
VM_INFO_JSON=$(pvesh get /cluster/resources --type vm --output-format json) || error_exit "Failed to retrieve VM info."

# ─────────────────────────────
# Group VMs by Node
# ─────────────────────────────
declare -A NODE_TO_VMIDS
for NAME in "${VM_NAMES[@]}"; do
    VM_RECORD=$(echo "$VM_INFO_JSON" | jq -c --arg name "$NAME" '.[] | select(.name == $name)')
    if [[ -z "$VM_RECORD" ]]; then
        error_exit "VM with name '$NAME' not found in cluster."
    fi

    NODE=$(echo "$VM_RECORD" | jq -r '.node')
    VMID=$(echo "$VM_RECORD" | jq -r '.vmid')

    if [[ -z "$NODE" || -z "$VMID" ]]; then
        error_exit "Failed to resolve node or VMID for VM '$NAME'"
    fi

    log "[INFO] VM '$NAME' is on node '$NODE' with VMID '$VMID'"
    NODE_TO_VMIDS["$NODE"]+="$VMID "
done

# ─────────────────────────────
# Execute vzdump per Node
# ─────────────────────────────
for NODE in "${!NODE_TO_VMIDS[@]}"; do
    VMID_LIST="${NODE_TO_VMIDS[$NODE]}"
    log "[INFO] Starting vzdump for node '$NODE' with VMIDs: $VMID_LIST"

    CMD="vzdump $VMID_LIST --storage '$STORAGE_TARGET' --mode snapshot --compress 0 --remove 0 --node '$NODE'"

    if [[ "$NODE" == "$HOST_NODE" ]]; then
        run_cmd "$CMD"
        STATUS=$?
    else
        if [[ $DEBUG_MODE -eq 1 ]]; then
            log "[DEBUG] ssh root@$NODE \"$CMD\""
        fi
        run_cmd "ssh root@$NODE \"$CMD\""
        STATUS=$?
    fi

    if [[ $STATUS -eq 0 ]]; then
        log "[INFO] Backup on node '$NODE' completed successfully."
    else
        log "[ERROR] Backup on node '$NODE' failed with exit code $STATUS."
    fi
done

exit 0
