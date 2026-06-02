#!/bin/bash

# A script to automate the creation of Debian and Ubuntu incus containers or VMs with optional attaching of a NVIDIA MIG or PCI GPU.

# This script depends upon the default incus profile being configured to use a managed incus bridge.

# by Dan MacDonald

# Ensure dependencies exist
if ! command -v pwgen &> /dev/null; then
    echo "Error: 'pwgen' is not installed. Please run: sudo apt install pwgen"
    exit 1
fi

# Default values
OS_IMAGE="images:ubuntu/24.04"
CPU_LIMIT="8"
RAM_LIMIT="32GB"
DISK_LIMIT="900GB"
MIG_ENABLED=false
SPECIFIED_MIG_UUID=""
PASSTHROUGH_PCI=""
CUSTOM_IP=""
NO_GPU_DETACH="false"
FULL_CUDA_INSTALL=false
SKIP_EXPIRY=false
INSTANCE_TYPE="container"

# Calculate expiry date (exactly 2 months from today)
EXPIRY_DATE=$(date -d "+2 months" +%Y-%m-%d)

usage() {
    echo "Usage: $0 [OPTIONS] <instance_name>"
    echo "Options:"
    echo "  -d (Distro)  Set OS: u2404 (Ubuntu 24.04), u2604 (Ubuntu 26.04), d13 (Debian 13)"
    echo "  -i (IP)      Set custom IP eg 10.95.1.11"
    echo "  -c (CPU)     Set CPU cores eg 8"
    echo "  -r (RAM)     Set RAM limit eg 32GB"
    echo "  -s (Storage) Set Disk limit eg 900GB"
    echo "  -g           Enable MIG GPU (Auto-selects free instance)"
    echo "  -m (MIG ID)  Attach specific MIG GPU by UUID"
    echo "  -G (GPU)     Enable PCI Passthrough GPU eg 01:00.0"
    echo "  -n           Set user.nogpudetach to true (Defaults to false. Use with -m)"
    echo "  -f           Full CUDA toolkit install"
    echo "  -x           Skip adding an expiry date to the instance"
    echo "  -v           Create an Incus Virtual Machine instead of a container"
    exit 1
}

while getopts "d:i:c:r:s:gm:G:nfxv" opt; do
    case $opt in
        d)
            case ${OPTARG,,} in
                u2404) OS_IMAGE="images:ubuntu/24.04" ;;
                u2604) OS_IMAGE="images:ubuntu/26.04" ;;
                d13)   OS_IMAGE="images:debian/13" ;;
                *) echo "Error: Invalid distro '$OPTARG'."; exit 1 ;;
            esac
            ;;
        i) CUSTOM_IP=$OPTARG ;;
        c) CPU_LIMIT=$OPTARG ;;
        r) RAM_LIMIT=$OPTARG ;;
        s) DISK_LIMIT=$OPTARG ;;
        g) MIG_ENABLED=true ;;
        m) MIG_ENABLED=true; SPECIFIED_MIG_UUID=$OPTARG ;;
        G) PASSTHROUGH_PCI=$OPTARG ;;
        n) NO_GPU_DETACH="true" ;;
        f) FULL_CUDA_INSTALL=true ;;
        x) SKIP_EXPIRY=true ;;
        v) INSTANCE_TYPE="virtual-machine" ;;
        *) usage ;;
    esac
done

shift $((OPTIND-1))
INSTANCE_NAME=$1

[ -z "$INSTANCE_NAME" ] && usage

if [ "$MIG_ENABLED" = true ] && [ -n "$PASSTHROUGH_PCI" ]; then
    echo "Error: Cannot use MIG (-g/-m) and PCI Passthrough (-G) together."
    exit 1
fi

if incus info "$INSTANCE_NAME" >/dev/null 2>&1; then
    echo "Error: Instance '$INSTANCE_NAME' already exists."
    exit 1
fi

# --- MIG GPU SELECTION ---
SELECTED_MIG_UUID=""
SELECTED_PCI_ID=""
if [ "$MIG_ENABLED" = true ]; then
    if [ -n "$SPECIFIED_MIG_UUID" ]; then
        echo "Status: Using specified MIG UUID: $SPECIFIED_MIG_UUID"
        SELECTED_MIG_UUID=$SPECIFIED_MIG_UUID
    else
        echo "Status: Scanning for available MIG devices..."
        ALL_MIG_UUIDS=$(nvidia-smi -L | grep -o "MIG-[a-f0-9-]\{36\}")
        USED_MIGS=$(incus list -f compact -c n,devices:gpu0.mig.uuid | grep -o "MIG-[a-f0-9-]\{36\}")

        for MIG_UUID in $ALL_MIG_UUIDS; do
            if ! echo "$USED_MIGS" | grep -q "$MIG_UUID"; then
                SELECTED_MIG_UUID=$MIG_UUID
                break
            fi
        done
    fi

    if [ -z "$SELECTED_MIG_UUID" ]; then
        echo "Error: No suitable MIG GPU found."
        exit 1
    fi

    # Derive PCI ID for the selected MIG
    RAW_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader,nounits -i "$SELECTED_MIG_UUID" 2>/dev/null | grep -v "No devices")
    [ -z "$RAW_PCI" ] && RAW_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader,nounits | head -n 1)
    CLEAN_PCI=$(echo "$RAW_PCI" | sed -E 's/^[0-9a-fA-F]{4,8}:?//' | tr -d '[:space:]')
    SELECTED_PCI_ID="0000:$CLEAN_PCI"
fi

# --- IP CALCULATION & NETWORK DEDUCTION ---
echo "Status: Determining IP Address..."
USED_IPS=$(incus list -c devices:eth0.ipv4.address --format csv | grep -v '^$')

if [ -z "$CUSTOM_IP" ]; then
    # Detect Bridge Interface
    IFACE=$(ip -4 route show default | grep -oP '(?<=dev )incusbr0' || ip -4 route show default | grep -oP '(?<=dev )br0' || echo "")

    # If not on default route, just check if they exist
    if [ -z "$IFACE" ]; then
        [ -d /sys/class/net/incusbr0 ] && IFACE="incusbr0"
        [ -d /sys/class/net/br0 ] && IFACE="br0"
    fi

    if [ -n "$IFACE" ]; then
        # Get IP and Mask (e.g., 10.90.146.75/26)
        ADDR_INFO=$(ip -4 addr show "$IFACE" | grep -oP 'inet \K[\d./]+')
        BRIDGE_IP=$(echo "$ADDR_INFO" | cut -d/ -f1)
        PREFIX=$(echo "$BRIDGE_IP" | cut -d. -f1-3)

        # Determine the network range using the mask
        MASK=$(echo "$ADDR_INFO" | cut -d/ -f2)

        # Calculate the start of the subnet (for small subnets like /26)
        # We'll stick to the current prefix but ensure we don't exceed the mask's capacity
        if [ "$MASK" -eq 32 ]; then
             echo "Error: Subnet mask /32 is too small."; exit 1
        fi

        # Calculate max possible octet based on mask
        # 2^(32-mask) - 2 (for network and broadcast)
        NUM_HOSTS=$(( 2**(32 - MASK) ))
        NETWORK_BASE=$(( $(echo "$BRIDGE_IP" | cut -d. -f4) / NUM_HOSTS * NUM_HOSTS ))
        MAX_OCTET=$(( NETWORK_BASE + NUM_HOSTS - 2 ))
        MIN_OCTET=$(( NETWORK_BASE + 1 ))

        echo "Status: Detected $IFACE ($BRIDGE_IP/$MASK). Range: .$MIN_OCTET to .$MAX_OCTET"
    else
        # Final Fallback
        PREFIX="10.95.1"
        MIN_OCTET=2
        MAX_OCTET=254
        echo "Status: No bridge found. Defaulting to $PREFIX.$MIN_OCTET-$MAX_OCTET"
    fi

    # Find a free IP
    FOUND_IP=false
    CURRENT_OCTET=$MIN_OCTET

    while [ "$FOUND_IP" = false ]; do
        TRY_IP="$PREFIX.$CURRENT_OCTET"

        # Skip the bridge's own IP
        if [ "$TRY_IP" != "$BRIDGE_IP" ]; then
            if ! echo "$USED_IPS" | grep -q "$TRY_IP" && ! ping -c 1 -W 1 "$TRY_IP" >/dev/null 2>&1; then
                TARGET_IP=$TRY_IP
                FOUND_IP=true
            fi
        fi

        CURRENT_OCTET=$((CURRENT_OCTET + 1))

        if [ "$CURRENT_OCTET" -gt "$MAX_OCTET" ]; then
            echo "Error: No free IP found in range .$MIN_OCTET to .$MAX_OCTET"
            exit 1
        fi
    done
else
    TARGET_IP=$CUSTOM_IP
fi

ROOT_PASSWORD=$(pwgen -s 16 1)

# --- EXECUTION ---
echo "--- Initializing: $INSTANCE_NAME ($TARGET_IP) using $OS_IMAGE ---"

LAUNCH_FLAGS=(
    "--config" "limits.cpu=$CPU_LIMIT"
    "--config" "limits.memory=$RAM_LIMIT"
    "--config" "snapshots.schedule=0 */12 * * *"
    "--config" "snapshots.expiry=3m"
    "--config" "snapshots.pattern={{ creation_date|date:'2006-01-02_15-04-05' }}"
    "--config" "user.nogpudetach=$NO_GPU_DETACH"
    "--device" "eth0,ipv4.address=$TARGET_IP"
)

# Apparmor profile manipulation is container-specific; omit for VMs
if [ "$INSTANCE_TYPE" = "container" ]; then
    LAUNCH_FLAGS+=("--config" "raw.lxc=lxc.apparmor.profile=unconfined")
else
    LAUNCH_FLAGS+=("--vm")
fi

# Conditionally add expiry date if -x flag is used.
if [ "$SKIP_EXPIRY" = false ]; then
    LAUNCH_FLAGS+=("--config" "user.expiry=$EXPIRY_DATE")
else
    EXPIRY_DATE="None"
fi

if [ "$MIG_ENABLED" = true ] || [ -n "$PASSTHROUGH_PCI" ]; then
    LAUNCH_FLAGS+=("--config" "nvidia.runtime=true")
fi

# Launch instance with settings injected
incus launch "$OS_IMAGE" "$INSTANCE_NAME" "${LAUNCH_FLAGS[@]}"

# Override root disk limit (safe to run directly after launch)
incus config device override "$INSTANCE_NAME" root size="$DISK_LIMIT"

# --- GPU ATTACHMENT ---
if [ "$MIG_ENABLED" = true ] || [ -n "$PASSTHROUGH_PCI" ]; then
    echo "Status: Waiting for instance agent to initialize before modifying hardware config..."
    incus wait "$INSTANCE_NAME" agent
fi

if [ "$MIG_ENABLED" = true ]; then
    echo "Status: Attaching MIG device ($SELECTED_MIG_UUID)..."
    incus stop "$INSTANCE_NAME"
    incus config device add "$INSTANCE_NAME" gpu0 gpu gputype=mig mig.uuid="$SELECTED_MIG_UUID" pci="$SELECTED_PCI_ID"
    incus config set "$INSTANCE_NAME" nvidia.driver.capabilities all
    incus start "$INSTANCE_NAME"
elif [ -n "$PASSTHROUGH_PCI" ]; then
    echo "Status: Attaching PCI Passthrough GPU ($PASSTHROUGH_PCI)..."
    incus config device add "$INSTANCE_NAME" gpu0 gpu pci="$PASSTHROUGH_PCI"
    incus config set "$INSTANCE_NAME" nvidia.driver.capabilities all
fi

# --- SSH SETUP ---
echo "Status: Waiting for instance environment to become fully ready..."
incus wait "$INSTANCE_NAME" agent

echo "Status: Configuring SSH..."
incus exec "$INSTANCE_NAME" -- sh -c "apt update && apt install -y openssh-server"
incus exec "$INSTANCE_NAME" -- sh -c "sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
incus exec "$INSTANCE_NAME" -- systemctl restart ssh
echo "root:$ROOT_PASSWORD" | incus exec "$INSTANCE_NAME" -- chpasswd
incus exec "$INSTANCE_NAME" -- apt upgrade -y

# --- FULL CUDA TOOLKIT INSTALL FOR CUDA DEV - WIP ---
if [ "$FULL_CUDA_INSTALL" = true ]; then
    echo "Status: Flag -f detected. Installing CUDA Toolkit..."
    incus stop "$INSTANCE_NAME"
    [ "$MIG_ENABLED" = true ] && incus config device remove "$INSTANCE_NAME" gpu0
    incus config set "$INSTANCE_NAME" nvidia.runtime false
    incus start "$INSTANCE_NAME"

    incus exec "$INSTANCE_NAME" -- sh -c "DEBIAN_FRONTEND=noninteractive apt update && apt install -y --no-install-recommends nvidia-cuda-toolkit"

    incus stop "$INSTANCE_NAME"
    incus config set "$INSTANCE_NAME" nvidia.runtime true
    if [ "$MIG_ENABLED" = true ]; then
        incus config device add "$INSTANCE_NAME" gpu0 gpu gputype=mig mig.uuid="$SELECTED_MIG_UUID" pci="$SELECTED_PCI_ID"
        incus config set "$INSTANCE_NAME" nvidia.driver.capabilities all
    fi
    incus start "$INSTANCE_NAME"
fi

echo "------------------------------------------------"
echo "Success: $INSTANCE_NAME is online at $TARGET_IP"
echo "TYPE: $INSTANCE_TYPE"
echo "IMAGE: $OS_IMAGE"
echo "EXPIRY: $EXPIRY_DATE | NOGPUDETACH: $NO_GPU_DETACH"
[ "$MIG_ENABLED" = true ] && echo "MIG: $SELECTED_MIG_UUID"
[ -n "$PASSTHROUGH_PCI" ] && echo "PCI: $PASSTHROUGH_PCI"
[ "$FULL_CUDA_INSTALL" = true ] && echo "CUDA: Full toolkit installed"
echo "ROOT PASS: $ROOT_PASSWORD"
echo "------------------------------------------------"
