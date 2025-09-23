#!/usr/bin/bash
set -Eeuo pipefail

# Keep your existing envs
VM_IMAGE="/opt/riscv-vm/ubuntu-riscv64.qcow2"
SEED_ISO="/opt/riscv-vm/cloud-init-seed.iso"
RISCV_MEMORY=4G
RISCV_CPUS=2
QEMU_OPTS=""
LOG_DIR="/var/log/qemu"
BOOT_LOG="$LOG_DIR/qemu.boot.log"         # QEMU's own stdout/stderr (to capture PTY line)
CONSOLE_LOG="$LOG_DIR/console.log"        # Guest serial (what you normally see on console)
MON_SOCK="/tmp/qemu-monitor.sock"         # HMP monitor (unix)
QEMU_PID_FILE="/tmp/qemu.pid"

info() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

build_qemu_cmd() {
  # Use a dedicated PTY for the guest serial so we can automate then attach
  # Provide a monitor socket for "sendkey ret" if needed
  QEMU_CMD=(/usr/bin/qemu-system-riscv64
    -machine virt
    -m "${RISCV_MEMORY:-4G}"
    -smp "${RISCV_CPUS:-2}"
    -bios /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin
    -kernel /usr/lib/u-boot/qemu-riscv64_smode/uboot.elf
    -nographic
    -drive "file="$VM_IMAGE",format=qcow2,if=virtio"
    -netdev user,id=eth0,ipv6=off
    -device virtio-net-device,netdev=eth0
    -drive "file=${SEED_ISO},if=virtio,format=raw,readonly=on"
    -append "root=/dev/vda1 rw console=ttyS0,115200n8"
    -monitor "unix:${MON_SOCK},server,nowait"
    -serial pty
  )

  
  # Extra opts (e.g., -s, -S, -device ...)
  if [[ -n "${QEMU_OPTS:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_OPTS=(${QEMU_OPTS})
    QEMU_CMD+=("${EXTRA_OPTS[@]}")
  fi
}

# Extract the PTY device path from QEMU's output ("char device redirected to /dev/pts/X")
find_console_pty() {
  local pty=""
  for _ in {1..60}; do
    if [[ -f "$BOOT_LOG" ]]; then
      pty="$(grep -oE 'char device redirected to (/dev/pts/[0-9]+)' "$BOOT_LOG" | awk '{print $5}' | tail -n1 || true)"
      if [[ -n "$pty" && -e "$pty" ]]; then
        echo "$pty"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

# Wait for a line to appear in the console log
wait_for_console_line() {
  local pattern="$1" timeout_s="${2:-600}"
  local start_ts now_ts
  start_ts=$(date +%s)

  : > "$CONSOLE_LOG.tmp"  # temp buffer for new lines during wait
  # Tail only new lines; 'timeout' will stop it if needed
  timeout "${timeout_s}s" bash -c "tail -Fn0 '$CONSOLE_LOG' >> '$CONSOLE_LOG.tmp'" &
  local tail_pid=$!

  info "Waiting for console text: $pattern (timeout ${timeout_s}s)"
  while true; do
    if grep -qE "$pattern" "$CONSOLE_LOG" "$CONSOLE_LOG.tmp" 2>/dev/null; then
      kill "$tail_pid" 2>/dev/null || true
      wait "$tail_pid" 2>/dev/null || true
      return 0
    fi
    now_ts=$(date +%s)
    (( now_ts - start_ts > timeout_s )) && { kill "$tail_pid" 2>/dev/null || true; return 1; }
    sleep 1
  done
}

# Send a raw string to the guest serial PTY (e.g., "\r", "uname -a\n")
send_to_console() {
  local pty="$1"; shift
  printf "%b" "$*" > "$pty"
}

# Use the HMP monitor to send a key (e.g., "ret" for Enter)
monitor_sendkey() {
  local key="$1"
  # HMP over unix socket (send "sendkey KEY\n")
  printf 'sendkey %s\n' "$key" | socat - UNIX-CONNECT:"$MON_SOCK" 2>/dev/null || true
}

# Gracefully kill background jobs and QEMU on exit (only if we aren't handing off)
cleanup() {
  local qpid
  if [[ -f "$QEMU_PID_FILE" ]]; then
    qpid="$(cat "$QEMU_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$qpid" ]] && kill -0 "$qpid" 2>/dev/null; then
      kill "$qpid" 2>/dev/null || true
      sleep 1
      kill -9 "$qpid" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

cmd_start() {
  mkdir -p "$LOG_DIR"
  : > "$BOOT_LOG"
  : > "$CONSOLE_LOG"

  build_qemu_cmd

  info "Launching QEMU (logging to $BOOT_LOG)..."
  # Run QEMU in background; capture stdout/stderr to BOOT_LOG (to parse PTY line)
  # Use stdbuf to line-buffer logs for timely grep
  stdbuf -oL -eL "${QEMU_CMD[@]}" >"$BOOT_LOG" 2>&1 &
  QEMU_PID=$!
  echo "$QEMU_PID" > "$QEMU_PID_FILE"

  # Find the PTY for the guest serial
  PTY="$(find_console_pty)" || die "Could not discover guest console PTY from $BOOT_LOG"
  info "Guest serial PTY: $PTY"

  # Start a temporary reader to collect console output for our checks
  # (We will hand over the PTY to the user later.)
  stdbuf -oL cat "$PTY" >> "$CONSOLE_LOG" &
  CONSOLE_READER_PID=$!

  # --- Sanity checks ---

  # 1) Wait for boot-ready message
  if wait_for_console_line "RISC-V Ubuntu image is ready\.|Ubuntu .* ttyS0|cloud-init.*finished"; then
    info "Boot-ready line detected."
  else
    info "Boot-ready line not found before timeout; proceeding anyway."
  fi

  # 2) If shell not visible, "press Enter"
  # Heuristics: look for a prompt or 'login:'; if not present, press Enter
  if ! grep -Eq "login:|# $|~\$ $|root@|ubuntu@" "$CONSOLE_LOG" 2>/dev/null; then
    info "Shell prompt not obvious; sending Enter..."
    # Try both via monitor and direct PTY
    monitor_sendkey ret
    send_to_console "$PTY" "\r"
  fi

  # 3) Print basic info
  info "Querying uname and cpuinfo (printing to console)..."
  send_to_console "$PTY" "echo '--- uname -a ---'\n"
  send_to_console "$PTY" "uname -a\n"
  send_to_console "$PTY" "echo '--- cpuinfo (first 20 lines) ---'\n"
  send_to_console "$PTY" "head -n 20 /proc/cpuinfo\n"

  # Give the guest a moment to print those
  sleep 2

  # Stop the temporary reader (we're about to hand off the PTY to the user)
  kill "$CONSOLE_READER_PID" 2>/dev/null || true
  wait "$CONSOLE_READER_PID" 2>/dev/null || true

  info "Handing over interactive console. (To exit QEMU: press Ctrl+A then X)"
  # From now on, user is directly attached to the guest serial
  # Replace our shell with a bidirectional PTY bridge
  trap - EXIT
  exec socat -,raw,echo=0 FILE:"$PTY",raw,echo=0
}

case "${1:-start}" in
  start) cmd_start ;;
  *) exec "$@" ;;
esac
