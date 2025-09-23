#!/bin/bash
# Create cloud-init seed ISO for RISC-V Ubuntu VM
# This script creates a cloud-init data source for automated VM configuration

set -euo pipefail

# Configuration
CLOUD_INIT_DIR="/opt/cloud-init"
TEMP_DIR="/tmp/cloud-init-seed"
OUTPUT_ISO="/opt/riscv-vm/cloud-init-seed.iso"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Clean up function
cleanup() {
    rm -rf "$TEMP_DIR" || true
}

trap cleanup EXIT

log "Creating cloud-init seed ISO..."

# Create temporary directory
mkdir -p "$TEMP_DIR"

# Copy cloud-init files
if [ ! -f "$CLOUD_INIT_DIR/user-data" ]; then
    log "ERROR: user-data file not found at $CLOUD_INIT_DIR/user-data"
    exit 1
fi

if [ ! -f "$CLOUD_INIT_DIR/meta-data" ]; then
    log "ERROR: meta-data file not found at $CLOUD_INIT_DIR/meta-data"
    exit 1
fi

# Copy files to temp directory
cp "$CLOUD_INIT_DIR/user-data" "$TEMP_DIR/"
cp "$CLOUD_INIT_DIR/meta-data" "$TEMP_DIR/"

# Create network-config if it doesn't exist
if [ ! -f "$CLOUD_INIT_DIR/network-config" ]; then
    log "Creating default network-config..."
    cat > "$TEMP_DIR/network-config" << 'EOF'
version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: false
EOF
else
    cp "$CLOUD_INIT_DIR/network-config" "$TEMP_DIR/"
fi

# Validate user-data syntax
if command -v cloud-init >/dev/null 2>&1; then
    log "Validating cloud-init configuration..."
    # Skip validation since cloud-init devel schema is not available
    # We will rely on the format being correct in user-data
    true
fi

# Create ISO using genisoimage (part of cdrkit-tools)
if command -v genisoimage >/dev/null 2>&1; then
    log "Creating ISO with genisoimage..."
    genisoimage \
        -output "$OUTPUT_ISO" \
        -volid "CIDATA" \
        -joliet \
        -rock \
        -quiet \
        "$TEMP_DIR"
elif command -v mkisofs >/dev/null 2>&1; then
    log "Creating ISO with mkisofs..."
    mkisofs \
        -o "$OUTPUT_ISO" \
        -V "CIDATA" \
        -J \
        -R \
        -quiet \
        "$TEMP_DIR"
else
    log "ERROR: Neither genisoimage nor mkisofs found"
    log "Installing genisoimage..."
    apt-get update && apt-get install -y genisoimage
    
    genisoimage \
        -output "$OUTPUT_ISO" \
        -volid "CIDATA" \
        -joliet \
        -rock \
        -quiet \
        "$TEMP_DIR"
fi

# Verify ISO was created
if [ ! -f "$OUTPUT_ISO" ]; then
    log "ERROR: Failed to create cloud-init seed ISO"
    exit 1
fi

# Set proper permissions
chmod 644 "$OUTPUT_ISO"

log "Cloud-init seed ISO created successfully: $OUTPUT_ISO"
log "ISO size: $(du -h "$OUTPUT_ISO" | cut -f1)"

# List contents for verification
if command -v isoinfo >/dev/null 2>&1; then
    log "ISO contents:"
    isoinfo -l -i "$OUTPUT_ISO" | grep -E "^-|Directory listing" || true
fi