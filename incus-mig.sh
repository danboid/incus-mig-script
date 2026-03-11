#!/bin/bash

# A script to automate the creation of Incus Ubuntu containers with optional attaching of a NVIDIA MIG or PCI GPU.

# by Dan MacDonald

# Ensure dependencies exist
if ! command -v pwgen &> /dev/null; then
    echo "Error: 'pwgen' is not installed. Please run: sudo apt install pwgen"
    exit 1
fi

# Default Values
OS_IMAGE="images:ubuntu/24.04"
CPU_LIMIT="8"
RAM_LIMIT="32GB"
DISK_LIMIT="900GB"
MIG_ENABLED=false
PASSTHROUGH_PCI=""
CUSTOM_IP=""
NO_GPU_DETACH="false"
FULL_CUDA_INSTALL=false

# Calculate Expiry Date (exactly 2 months from today)
EXPIRY_DATE=$(date -d "+2 months" +%Y-%m-%d)

# Network Defaults
GATEWAY="10.95.1.254"
DNS="146.87.174.121"
SUBNET="/24"

usage() {
    echo "Usage: $0 [OPTIONS] <container_name>"
    echo "Options:"
    echo "  -i (IP)      Set custom IP eg 10.95.1.11"
    echo "  -c (CPU)     Set CPU cores eg 8"
    echo "  -m (RAM)     Set RAM limit eg 32GB"
    echo "  -s (Disk)    Set Disk limit eg 900GB"
    echo "  -g           Enable MIG GPU (Auto-selects free instance)"
    echo "  -G (PCI)     Enable PCI Passthrough GPU eg 01:00.0"
    echo "  -n           Set user.nogpudetach to true (default: false)"
    echo "  -f           Full CUDA toolkit install (compilers/headers)"
    exit 1
}

while getopts "i:c:m:s:gG:nf" opt; do
    case $opt in
        i) CUSTOM_IP=$OPTARG ;;
        c) CPU_LIMIT=$OPTARG ;;
        m) RAM_LIMIT=$OPTARG ;;
        s) DISK_LIMIT=$OPTARG ;;
        g) MIG_ENABLED=true ;;
        G) PASSTHROUGH_PCI=$OPTARG ;;
        n) NO_GPU_DETACH="true" ;;
        f) FULL_CUDA_INSTALL=true ;;
        *) usage ;;
    esac
done

shift $((OPTIND-1))
CONTAINER_NAME=$1

[ -z "$CONTAINER_NAME" ] && usage

if [ "$MIG_ENABLED" = true ] && [ -n "$PASSTHROUGH_PCI" ]; then
    echo "Error: Cannot use both -g (MIG) and -G (Passthrough) together."
    exit 1
fi

if incus info "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "Error: Container '$CONTAINER_NAME' already exists."
    exit 1
fi

# --- MIG GPU SELECTION ---
SELECTED_MIG_UUID=""
SELECTED_PCI_ID=""
if [ "$MIG_ENABLED" = true ]; then
    echo "Status: Scanning for available MIG devices..."
    ALL_MIG_UUIDS=$(nvidia-smi -L | grep -o "MIG-[a-f0-9-]\{36\}")
    USED_MIGS=$(incus list -f compact -c n,devices:gpu0.mig.uuid | grep -o "MIG-[a-f0-9-]\{36\}")

    for MIG_UUID in $ALL_MIG_UUIDS; do
        if ! echo "$USED_MIGS" | grep -q "$MIG_UUID"; then
            SELECTED_MIG_UUID=$MIG_UUID
            RAW_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader,nounits -i "$SELECTED_MIG_UUID" 2>/dev/null | grep -v "No devices")
            [ -z "$RAW_PCI" ] && RAW_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader,nounits | head -n 1)
            CLEAN_PCI=$(echo "$RAW_PCI" | sed -E 's/^[0-9a-fA-F]{4,8}:?//' | tr -d '[:space:]')
            SELECTED_PCI_ID="0000:$CLEAN_PCI"
            break
        fi
    done
    [ -z "$SELECTED_MIG_UUID" ] && { echo "Error: No free MIG GPUs found."; exit 1; }
fi

# --- IP CALCULATION ---
if [ -z "$CUSTOM_IP" ]; then
    LAST_IP=$(incus list -f compact | grep -oE "\b10\.95\.1\.[0-9]{1,3}\b" | sort -t. -k4,4n | tail -n 1)
    TARGET_IP="10.95.1.2"
    if [ -n "$LAST_IP" ]; then
        LAST_OCTET=$(echo "$LAST_IP" | cut -d. -f4)
        TARGET_IP="10.95.1.$((LAST_OCTET + 1))"
    fi
else
    TARGET_IP=$CUSTOM_IP
fi

ROOT_PASSWORD=$(pwgen -s 16 1)

# --- EXECUTION ---
echo "--- Initializing: $CONTAINER_NAME ---"

LAUNCH_FLAGS=(
    "--config" "limits.cpu=$CPU_LIMIT"
    "--config" "limits.memory=$RAM_LIMIT"
    "--config" "raw.lxc=lxc.apparmor.profile=unconfined"
    "--config" "snapshots.schedule=0 */12 * * *"
    "--config" "snapshots.expiry=3m"
    "--config" "snapshots.pattern={{ creation_date|date:'2006-01-02_15-04-05' }}"
    "--config" "user.expiry=$EXPIRY_DATE"
    "--config" "user.nogpudetach=$NO_GPU_DETACH"
)

if [ "$MIG_ENABLED" = true ] || [ -n "$PASSTHROUGH_PCI" ]; then
    LAUNCH_FLAGS+=("--config" "nvidia.runtime=true")
fi

incus launch "$OS_IMAGE" "$CONTAINER_NAME" "${LAUNCH_FLAGS[@]}"
incus config device override "$CONTAINER_NAME" root size="$DISK_LIMIT"

# --- GPU ATTACHMENT ---
if [ "$MIG_ENABLED" = true ]; then
    echo "Status: Attaching MIG device..."
    incus stop "$CONTAINER_NAME"
    incus config device add "$CONTAINER_NAME" gpu0 gpu gputype=mig mig.uuid="$SELECTED_MIG_UUID" pci="$SELECTED_PCI_ID"
    incus config set "$CONTAINER_NAME" nvidia.driver.capabilities all
    incus start "$CONTAINER_NAME"
elif [ -n "$PASSTHROUGH_PCI" ]; then
    echo "Status: Attaching PCI Passthrough GPU ($PASSTHROUGH_PCI)..."
    incus config device add "$CONTAINER_NAME" gpu0 gpu pci="$PASSTHROUGH_PCI"
    incus config set "$CONTAINER_NAME" nvidia.driver.capabilities all
fi

# --- NETWORKING & SSH ---
echo "Status: Configuring Networking & SSH..."
printf "network:\n  version: 2\n  ethernets:\n    eth0:\n      addresses: [%s%s]\n      routes: [{to: default, via: %s}]\n      nameservers: {addresses: [%s]}\n      dhcp4: false" \
    "$TARGET_IP" "$SUBNET" "$GATEWAY" "$DNS" | incus file push - "$CONTAINER_NAME/etc/netplan/10-lxc.yaml"

for i in {1..5}; do
    incus exec "$CONTAINER_NAME" -- netplan apply >/dev/null 2>&1 && break || sleep 3
done

incus exec "$CONTAINER_NAME" -- sh -c "apt update && apt install -y openssh-server"
incus exec "$CONTAINER_NAME" -- sh -c "sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
incus exec "$CONTAINER_NAME" -- systemctl restart ssh
echo "root:$ROOT_PASSWORD" | incus exec "$CONTAINER_NAME" -- chpasswd
incus exec "$CONTAINER_NAME" -- apt upgrade -y

# --- FULL CUDA TOOLKIT INSTALL ---
if [ "$FULL_CUDA_INSTALL" = true ]; then
    echo "Status: Flag -f detected. Preparing for CUDA Toolkit installation..."

    # 1. STOP container first to allow config/device changes
    incus stop "$CONTAINER_NAME"

    # 2. Handle device/runtime removal based on type
    if [ "$MIG_ENABLED" = true ]; then
        incus config device remove "$CONTAINER_NAME" gpu0
    fi
    incus config set "$CONTAINER_NAME" nvidia.runtime false

    # 3. START container for installation
    incus start "$CONTAINER_NAME"

    echo "Status: Installing CUDA Toolkit (compilers/headers only)..."
    incus exec "$CONTAINER_NAME" -- sh -c "DEBIAN_FRONTEND=noninteractive apt update"
    incus exec "$CONTAINER_NAME" -- sh -c "DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends nvidia-cuda-toolkit"

    # 4. STOP to restore GPU configuration
    echo "Status: Restoring NVIDIA runtime and GPU..."
    incus stop "$CONTAINER_NAME"
    incus config set "$CONTAINER_NAME" nvidia.runtime true

    if [ "$MIG_ENABLED" = true ]; then
        incus config device add "$CONTAINER_NAME" gpu0 gpu gputype=mig mig.uuid="$SELECTED_MIG_UUID" pci="$SELECTED_PCI_ID"
        incus config set "$CONTAINER_NAME" nvidia.driver.capabilities all
    fi

    # 5. FINAL START
    incus start "$CONTAINER_NAME"
fi

echo "------------------------------------------------"
echo "Success: $CONTAINER_NAME is online at $TARGET_IP"
echo "EXPIRY: $EXPIRY_DATE | NOGPUDETACH: $NO_GPU_DETACH"
[ "$MIG_ENABLED" = true ] && echo "MIG: $SELECTED_MIG_UUID"
[ -n "$PASSTHROUGH_PCI" ] && echo "PCI: $PASSTHROUGH_PCI"
[ "$FULL_CUDA_INSTALL" = true ] && echo "CUDA: Full Toolkit Installed"
echo "ROOT PASS: $ROOT_PASSWORD"
echo "------------------------------------------------"
