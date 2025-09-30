#!/usr/bin/bash
set -Eeuo pipefail

VM_IMAGE="/opt/riscv-vm/ubuntu-riscv64.qcow2"
SEED_ISO="/opt/riscv-vm/cloud-init-seed.iso"
RISCV_MEMORY=4G
RISCV_CPUS=2
QEMU_OPTS=""
LOG_DIR="/var/log/qemu"
BOOT_LOG="$LOG_DIR/qemu.boot.log"         # QEMU's own stdout/stderr (to capture PTY line)
CONSOLE_LOG="$LOG_DIR/console.log"        # Guest serial (what you normally see on console)
MON_SOCK="/tmp/qemu-monitor.sock"         # HMP monitor (unix)
CONSOLE_TMP="$CONSOLE_LOG.tmp"
QEMU_PID_FILE="/tmp/qemu.pid"
PTY_PATH_FILE="$LOG_DIR/pty.path"         # For automation discovery
GUEST_IN_FIFO="$LOG_DIR/guest.in"         # FIFO for headless command injection

# Control whether to attach interactively or run headless (CI/local script)
AUTO_ATTACH="${AUTO_ATTACH:-1}"

info() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
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
    QEMU_CMD=("${EXTRA_OPTS[@]}")
  fi
}

# Extract the PTY device path from QEMU's output ("char device redirected to /dev/pts/X")
find_console_pty() {
  local pty=""
  for _ in {1..60}; do
    if [[ -f "$BOOT_LOG" ]]; then
      pty="$(grep -oE 'char device redirected to (/dev/pts/[0-9])' "$BOOT_LOG" | awk '{print $5}' | tail -n1 || true)"
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
# Enhanced with retry logic and error handling
send_to_console() {
  local pty="$1"; shift
  local max_retries=3
  local retry=0
  
  while (( retry < max_retries )); do
    if [[ -e "$pty" ]]; then
      if printf "%b" "$*" > "$pty" 2>/dev/null; then
        return 0
      fi
    fi
    retry=$((retry + 1))
    if (( retry < max_retries )); then
      warn "Failed to write to PTY (attempt $retry/$max_retries), retrying..."
      sleep 1
    fi
  done
  
  warn "Failed to write to PTY after $max_retries attempts"
  return 1
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

  echo "$PTY" > "$PTY_PATH_FILE"
  chmod 644 "$PTY_PATH_FILE"

  # --- Enhanced Boot Detection Flow ---

  # 1: Wait for initial boot completion
  info "Waiting for boot to complete..."
  if wait_for_console_line "Ubuntu .* ttyS0|cloud-init.*finished"; then
    info "✓ Boot sequence completed (cloud-init finished)."
  else
    warn "Boot completion marker not detected before timeout."
  fi

  # 2: Wait for auto-login to complete
  info "Waiting for auto-login..."
  if wait_for_console_line "RISC-V Ubuntu image is ready\."; then
    info "✓ Auto-login successful - shell is ready."
  else
    warn "Auto-login confirmation not detected; attempting to proceed."
    # Fallback: send Enter to trigger prompt
    info "Sending Enter to activate shell..."
    send_to_console "$PTY" "\r"
    sleep 2
  fi

  # 3: Verify shell is responsive
  info "Verifying shell responsiveness..."
  sleep 1

  kill "$CONSOLE_READER_PID" 2>/dev/null || true
  wait "$CONSOLE_READER_PID" 2>/dev/null || true

  stdbuf -oL cat "$PTY" >> "$CONSOLE_LOG" &
  CONSOLE_READER_PID=$!

  
  # Send a simple test command to verify shell is ready
  local shell_responsive=0
  if send_to_console "$PTY" "echo SHELL_READY\n"; then
    sleep 2
    
    if grep -q "SHELL_READY" "$CONSOLE_LOG" 2>/dev/null; then
      info "✓ Shell is responsive."
      shell_responsive=1
    else
      warn "Shell not responding to test command; attempting recovery..."
      # Fallback: press Enter and retry
      send_to_console "$PTY" "\r"
      sleep 1
      
      # Clear marker and try again
      send_to_console "$PTY" "echo SHELL_READY_RETRY\n"
      sleep 2
      
      if grep -q "SHELL_READY_RETRY" "$CONSOLE_LOG" 2>/dev/null; then
        info "✓ Shell is responsive after Enter press."
        shell_responsive=1
      else
        warn "Shell still not responsive; continuing anyway - manual intervention may be needed."
      fi
    fi
  else
    warn "Unable to send test command to PTY; continuing anyway."
  fi

  # 4: Run sanity checks
  info "Running system sanity checks..."
  send_to_console "$PTY" "echo '=== System Information ==='\n"
  sleep 1
  
  send_to_console "$PTY" "echo '--- Kernel Version ---'\n"
  send_to_console "$PTY" "uname -a\n"
  sleep 1
  
  send_to_console "$PTY" "echo '--- CPU Information ---'\n"
  send_to_console "$PTY" "head -n 20 /proc/cpuinfo\n"
  sleep 1
  
  send_to_console "$PTY" "echo '--- Memory Information ---'\n"
  send_to_console "$PTY" "free -h\n"
  sleep 1
  
  send_to_console "$PTY" "echo '--- Disk Usage ---'\n"
  send_to_console "$PTY" "df -h /\n"
  sleep 1

  send_to_console "$PTY" "echo '=== Sanity Checks Complete ==='\n"
  
  # Give output time to appear
  sleep 2

  # 5: Transfer control to user
  if [[ "$AUTO_ATTACH" == "0" ]]; then
    # ---- Headless/CI mode ----
    info "Headless mode enabled (AUTO_ATTACH=0). Keeping console reader and exposing FIFO."

    # Create a FIFO for safe command injection from outside
    if [[ -p "$GUEST_IN_FIFO" ]]; then
      rm -f "$GUEST_IN_FIFO"
    fi
    mkfifo "$GUEST_IN_FIFO"
    chmod 666 "$GUEST_IN_FIFO"

    # Start a background writer that forwards FIFO -> PTY
    # Use a while loop to keep reading from FIFO and writing to PTY
    (
      while true; do
        if read -r line < "$GUEST_IN_FIFO"; then
          printf "%s\n" "$line" > "$PTY"
        fi
      done
    ) &
    FIFO_WRITER_PID=$!

    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "System is ready for headless operation"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "PTY path: $(cat "$PTY_PATH_FILE")"
    info "Write guest commands to: $GUEST_IN_FIFO"
    info "View console at: $CONSOLE_LOG"
    info "HMP monitor socket: $MON_SOCK (e.g., 'sendkey ret')"

    # Keep the entrypoint alive; let docker logs show our boot log as well
    # Do not kill the console reader; we want continuous logging.
    trap - EXIT
    # Idle loop instead of 'tail -f' to avoid exit if file rotates
    while :; do sleep 3600; done
  else
    # ---- Interactive mode ----
    # Stop the temporary reader (we're about to hand off the PTY to the user)
    kill "$CONSOLE_READER_PID" 2>/dev/null || true
    wait "$CONSOLE_READER_PID" 2>/dev/null || true

    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "System ready - transferring control to user"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "(To exit QEMU: press Ctrl-A then X)"
    
    # Brief pause so user sees the message
    sleep 1
    
    # From now on, user is directly attached to the guest serial
    # Replace our shell with a bidirectional PTY bridge
    trap - EXIT
    exec socat -,raw,echo=0 FILE:"$PTY",raw,echo=0
  fi
}

case "${1:-start}" in
  start) cmd_start ;;
  *) exec "$@" ;;
esac
