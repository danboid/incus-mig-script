#!/bin/bash

# A script to automate the creation of Incus Ubuntu containers using NVIDIA MIG GPUs.
# by Dan MacDonald

# Default Values
OS_IMAGE="images:ubuntu/24.04"
CPU_LIMIT="8"
RAM_LIMIT="64GB"
DISK_LIMIT="50GB"
MIG_ENABLED=false
CUSTOM_IP=""

# Network Defaults
GATEWAY="10.95.1.254"
DNS="146.87.174.121"
SUBNET="/24"

usage() {
    echo "Usage: $0 [OPTIONS] <container_name>"
    echo "Options: -i (IP), -c (CPU), -m (RAM), -s (Disk), -g (MIG)"
    exit 1
}

while getopts "i:c:m:s:g" opt; do
    case $opt in
        i) CUSTOM_IP=$OPTARG ;;
        c) CPU_LIMIT=$OPTARG ;;
        m) RAM_LIMIT=$OPTARG ;;
        s) DISK_LIMIT=$OPTARG ;;
        g) MIG_ENABLED=true ;;
        *) usage ;;
    esac
done

shift $((OPTIND-1))
CONTAINER_NAME=$1

[ -z "$CONTAINER_NAME" ] && usage

if incus info "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "Error: Container '$CONTAINER_NAME' already exists."
    exit 1
fi

# --- ROBUST MIG GPU SELECTION ---
SELECTED_MIG_UUID=""
SELECTED_PCI_ID=""
if [ "$MIG_ENABLED" = true ]; then
    echo "Status: Scanning for available MIG devices..."
    ALL_MIG_UUIDS=$(nvidia-smi -L | grep -o "MIG-[a-f0-9-]\{36\}")
    USED_MIGS=$(incus list -f compact -c n,devices:gpu0.mig.uuid | grep -o "MIG-[a-f0-9-]\{36\}")
    
    for MIG_UUID in $ALL_MIG_UUIDS; do
        if ! echo "$USED_MIGS" | grep -q "$MIG_UUID"; then
            SELECTED_MIG_UUID=$MIG_UUID
            
            # Try 1: Query by UUID directly
            RAW_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader,nounits -i "$SELECTED_MIG_UUID" 2>/dev/null | grep -v "No devices")
            
            # Try 2: Fallback to first available physical GPU's PCI ID if UUID query fails
            if [ -z "$RAW_PCI" ]; then
                RAW_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader,nounits | head -n 1)
            fi

            # Clean the string: strip '00000000:' or '0000:' and any whitespace
            CLEAN_PCI=$(echo "$RAW_PCI" | sed -E 's/^[0-9a-fA-F]{4,8}:?//' | tr -d '[:space:]')
            
            # Re-format to the standard 0000:XX:XX.X
            SELECTED_PCI_ID="0000:$CLEAN_PCI"
            
            # Sanity check: Ensure it matches a PCI pattern (e.g., 0000:01:00.0)
            if [[ ! "$SELECTED_PCI_ID" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
                echo "Warning: Could not determine a valid PCI ID for $MIG_UUID. Trying next..."
                continue
            fi

            echo "Status: Selected MIG $SELECTED_MIG_UUID on PCI $SELECTED_PCI_ID"
            break
        fi
    done
    [ -z "$SELECTED_MIG_UUID" ] && { echo "Error: No free MIG GPUs or PCI detection failed."; exit 1; }
fi

# --- IP & PASSWORD ---
if [ -z "$CUSTOM_IP" ]; then
    LAST_IP=$(incus list -f compact | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | sort -V | tail -n 1)
    [ -z "$LAST_IP" ] && TARGET_IP="10.95.1.2" || TARGET_IP="$(echo $LAST_IP | cut -d. -f1-3).$(( $(echo $LAST_IP | cut -d. -f4) + 1 ))"
else
    TARGET_IP=$CUSTOM_IP
fi
ROOT_PASSWORD=$(pwgen -s 16 1)

echo "--- Initializing: $CONTAINER_NAME ---"

# 1. Launch & Snapshot Configuration
LAUNCH_FLAGS=(
    "--config" "limits.cpu=$CPU_LIMIT"
    "--config" "limits.memory=$RAM_LIMIT"
    "--config" "raw.lxc=lxc.apparmor.profile=unconfined"
    "--config" "snapshots.schedule=0 */12 * * *"
    "--config" "snapshots.expiry=3m"
    "--config" "snapshots.pattern={{ creation_date|date:'2006-01-02_15-04-05' }}"
)
[ "$MIG_ENABLED" = true ] && LAUNCH_FLAGS+=("--config" "nvidia.runtime=true")

incus launch "$OS_IMAGE" "$CONTAINER_NAME" "${LAUNCH_FLAGS[@]}"
incus config device override "$CONTAINER_NAME" root size="$DISK_LIMIT"

# 2. GPU Attachment
if [ "$MIG_ENABLED" = true ]; then
    echo "Status: Attaching MIG device..."
    incus stop "$CONTAINER_NAME"
    incus config device add "$CONTAINER_NAME" gpu0 gpu \
        gputype=mig \
        mig.uuid="$SELECTED_MIG_UUID" \
        pci="$SELECTED_PCI_ID"
    incus start "$CONTAINER_NAME"
fi

# 3. Networking Setup
CAT_NETPLAN=$(cat <<EOF
network:
  version: 2
  ethernets:
    eth0:
      addresses: [$TARGET_IP$SUBNET]
      routes: [{to: default, via: $GATEWAY}]
      nameservers: {addresses: [$DNS]}
      dhcp4: false
EOF
)
echo "$CAT_NETPLAN" | incus file push - "$CONTAINER_NAME/etc/netplan/10-lxc.yaml"

for i in {1..5}; do
    echo "Status: Applying Netplan (Attempt $i)..."
    if incus exec "$CONTAINER_NAME" -- netplan apply >/dev/null 2>&1; then
        break
    else
        sleep 3
    fi
done

# 4. SSH & Root Setup
echo "Status: Installing OpenSSH and configuring root access..."
incus exec "$CONTAINER_NAME" -- sh -c "apt update && apt install -y openssh-server"
incus exec "$CONTAINER_NAME" -- sh -c "echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config"
incus exec "$CONTAINER_NAME" -- sh -c "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
incus exec "$CONTAINER_NAME" -- systemctl restart ssh
echo "root:$ROOT_PASSWORD" | incus exec "$CONTAINER_NAME" -- chpasswd

# 5. Final Upgrade
incus exec "$CONTAINER_NAME" -- sh -c "apt upgrade -y"

echo "------------------------------------------------"
echo "Success: $CONTAINER_NAME is online at $TARGET_IP"
[ "$MIG_ENABLED" = true ] && echo "GPU Attached: $SELECTED_MIG_UUID (PCI $SELECTED_PCI_ID)"
echo "ROOT PASSWORD: $ROOT_PASSWORD"
echo "------------------------------------------------"
