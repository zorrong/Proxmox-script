#!/bin/bash

# ==============================================================================
# Script: Create Debian LXC and Install OpenClaw on Proxmox
# Description: Automates the creation of a Debian LXC container on Proxmox.
# Auto-detects storage and installs OpenClaw using the CORRECT URL.
# ==============================================================================

set -e

# --- Configuration ---
BRIDGE="vmbr0" # Proxmox network bridge
MEMORY="2048" # RAM in MB
DISK_SIZE="20" # Disk size in GB
HOSTNAME="openclaw-lxc"
DEBIAN_VERSION="12" # Debian version

# --- Check for Proxmox environment ---
if ! command -v pct &> /dev/null; then
echo "Error: This script must be run on a Proxmox host (pct command not found)."
exit 1
fi

# --- Step 1: Auto-Detect Storage ---
echo "Detecting suitable storage for LXC disks..."
STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n1)

if [ -z "$STORAGE" ]; then
echo "Warning: No storage found that supports 'rootdir' (LXC disks)."
echo "Falling back to 'local-lvm'..."
STORAGE="local-lvm"
fi

echo "Selected Storage: $STORAGE"

# --- Step 2: Find a free Container ID ---
echo "Searching for an available Container ID..."
CTID=$(pvesh get /cluster/nextid)
echo "Using Container ID: $CTID"

# --- Step 3: Update Template List ---
echo "Updating Proxmox template list..."
pveam update || true

AVAILABLE_TEMPLATE=$(pveam available --section system | grep "debian-${DEBIAN_VERSION}" | head -n1 | awk '{print $2}')

if [ -z "$AVAILABLE_TEMPLATE" ]; then
echo "Error: Could not find a Debian ${DEBIAN_VERSION} template."
exit 1
fi

echo "Ensuring template is downloaded..."
pveam download local "$AVAILABLE_TEMPLATE" || true

# --- Step 4: Create LXC Container ---
echo "Creating LXC container $CTID ($HOSTNAME) on storage '$STORAGE'..."
pct create "$CTID" "local:vztmpl/$(basename "$AVAILABLE_TEMPLATE")" \
--hostname "$HOSTNAME" \
--password "clawdbot123" \
--net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
--memory "$MEMORY" \
--swap 512 \
--rootfs "${STORAGE}:${DISK_SIZE}" \
--unprivileged 1 \
--features nesting=1 \
--onboot 1

# --- Step 5: Start and Install ---
echo "Starting the container..."
pct start "$CTID"

echo "Waiting for container network to be ready (up to 30s)..."
for i in {1..30}; do
if pct exec "$CTID" -- ip addr show eth0 | grep -q "inet "; then
echo "Network is ready!"
break
fi
sleep 1
done

echo "Installing Dependencies (git, openssl, redis) and OpenClaw..."
pct exec "$CTID" -- apt-get update
pct exec "$CTID" -- apt-get install -y curl git openssl redis

# FIX: Using the correct URL (openclaw.ai instead of openclawd.ai)
echo "Downloading and running the OpenClaw installer..."
pct exec "$CTID" -- bash -c "curl -fsSL https://openclaw.ai/install.sh | bash"

echo "=============================================================================="
echo "SUCCESS: OpenClaw has been installed in LXC container $CTID."
echo "Access command: pct enter $CTID"
echo "=============================================================================="
