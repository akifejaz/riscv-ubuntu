# Multi-stage Dockerfile for RISC-V QEMU Ubuntu Environment
# Optimized for GitHub Actions and Docker Hub deployment

# Build stage 
FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
      wget xz-utils qemu-utils ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ARG LOCAL_IMG_NAME=ubuntu-riscv64.img.xz
COPY "$LOCAL_IMG_NAME" /build/ 


ARG UBUNTU_URL="https://cdimage.ubuntu.com/releases/24.04.3/release/ubuntu-24.04.3-preinstalled-server-riscv64.img.xz"

# Reuse file if it was COPIED above; otherwise download it
RUN if [ -f "/build/$LOCAL_IMG_NAME" ]; then \
      echo "Reusing local /build/$LOCAL_IMG_NAME"; \
    else \
      echo "Fetching Ubuntu RISC-V image..."; \
      wget -O "/build/$LOCAL_IMG_NAME" "$UBUNTU_URL"; \
    fi

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DISK_SIZE=5G
RUN set -eux; \
  tmp_raw=$(mktemp /build/raw.XXXXXX.img); \
  xz -dc --threads=0 "/build/${LOCAL_IMG_NAME}" > "${tmp_raw}"; \
  qemu-img convert -f raw -O qcow2 -c "${tmp_raw}" "/build/ubuntu-riscv64.qcow2"; \
  qemu-img resize "/build/ubuntu-riscv64.qcow2" "${DISK_SIZE}"; \
  qemu-img info "/build/ubuntu-riscv64.qcow2"; \
  rm -f "${tmp_raw}" "/build/${LOCAL_IMG_NAME}"


# Main stage - create the runtime environment
FROM ubuntu:24.04

# Metadata
LABEL maintainer="Cloud-V Team"
LABEL description="QEMU System RISC-V64 Ubuntu VM for testing"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV RISCV_MEMORY=4G
ENV RISCV_CPUS=2
ENV RISCV_DISK_SIZE=10G
ENV QEMU_OPTS=""
ENV BOOT_TIMEOUT=300

#TODO : Build from source for latest version
#TODO : Build from source for latest version
RUN apt-get update && apt-get install -y \
    # QEMU and RISC-V support
    qemu-system-riscv64 opensbi u-boot-qemu qemu-utils \
    # System utilities 
    curl wget socat netcat-traditional iproute2 iputils-ping \
    # Development tools
    build-essential git vim nano tmux screen \
    # Cloud-init tools
    cloud-init cloud-utils \
    # Networking tools
    openssh-client rsync \
    # File utilities
    unzip zip tree jq \
    && rm -rf /var/lib/apt/lists/*


RUN mkdir -p /opt/riscv-vm \
    && mkdir -p /var/log/qemu \
    && mkdir -p /tmp/cloud-init \
    && mkdir -p /home/ubuntu \
    #&& useradd -m -s /bin/bash ubuntu \
    && usermod -aG sudo ubuntu

# Copy Ubuntu RISC-V image from builder stage
COPY --from=builder --chown=ubuntu:ubuntu --chmod=0644 /build/ubuntu-riscv64.qcow2 /opt/riscv-vm/

# Extract the image in the final location
RUN cd /opt/riscv-vm && ls -lh /opt/riscv-vm/

# Copy scripts and configurations
COPY scripts/ /opt/scripts/
COPY cloud-init/ /opt/cloud-init/

RUN chmod +x /opt/scripts/*.sh /opt/cloud-init/*.sh
RUN /opt/cloud-init/create-seed.sh


# Expose ports that might be forwarded from RISC-V VM
EXPOSE 22 80 443 8080 3000 5000

# Health check to ensure QEMU can start
# HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
#     CMD /opt/scripts/health-check.sh

# Set working directory
WORKDIR /workspace

# Default entrypoint
ENTRYPOINT ["/opt/scripts/entrypoint.sh"]

# Default command - start the VM non-interactively
CMD ["start"]