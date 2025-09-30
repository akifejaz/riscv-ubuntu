#!/usr/bin/env bash
# Interactive wrapper for RISC-V QEMU guest commands with marker-bound streaming

set -euo pipefail

CONTAINER_NAME="${1:-riscv-test}"
CONSOLE_LOG="${CONSOLE_LOG:-./var/log/qemu/console.log}"
GUEST_FIFO="${GUEST_FIFO:-/var/log/qemu/guest.in}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- preflight ---
if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "Error: Container '${CONTAINER_NAME}' is not running"
  exit 1
fi
if [ ! -f "$CONSOLE_LOG" ]; then
  echo "Error: Console log not found at $CONSOLE_LOG"
  echo "Make sure you mounted the log directory: -v \"\$PWD/var/log/qemu:/var/log/qemu\""
  exit 1
fi

echo -e "${BLUE}=== RISC-V Ubuntu Interactive Shell ===${NC}"
echo "Container: ${CONTAINER_NAME}"
echo "Type 'exit' or press Ctrl+D to quit"
echo "Type 'clear' to clear screen"
echo

# Send a raw line to guest TTY via FIFO
send_to_guest() {
  local line="$1"
  docker exec "${CONTAINER_NAME}" bash -lc "printf '%s\n' \"$line\" > '${GUEST_FIFO}'"
}

# Send a raw byte (for SIGINT, etc.)
send_byte_to_guest() {
  local -i code="$1"
  docker exec "${CONTAINER_NAME}" bash -lc "printf '\\x%02x' ${code} > '${GUEST_FIFO}'"
}

# Run a command and stream output until END marker
run_cmd_stream() {
  local cmd="$1"

  # Unique markers per command
  local uid
  uid="$(date +%s%N)-$RANDOM"
  local START="__HOST_START__${uid}__"
  local END="__HOST_END__${uid}__"

  # Compose a single compound command that the guest shell will execute as-is.
  # It prints START, runs user cmd, then prints END with exit code; stderr merged to stdout.
  local inject="{ echo ${START}; { ${cmd}; rc=\$?; }; printf '${END} EXIT=%d\n' \"\${rc}\"; } 2>&1"

  # Start tail in the background (line-buffered) and filter between markers.
  # We terminate the pipeline as soon as END appears.
  local awk_pid tail_pid
  stdbuf -oL -eL tail -n0 -F "${CONSOLE_LOG}" 2>/dev/null \
    | awk -v start="${START}" -v end="${END}" '
        BEGIN { started=0 }
        {
          if (!started) {
            if (index($0, start)) { started=1; next }
            next
          } else {
            if (index($0, end)) {
              # Extract EXIT code if present
              exitidx = index($0, "EXIT=");
              if (exitidx > 0) {
                code = substr($0, exitidx+5);
                printf("[exit %s]\n", code);
              }
              exit 0
            }
            print
          }
        }
      ' &
  awk_pid=$!

  # Handle Ctrl-C while streaming: forward ^C to guest and stop tailer/awk
  trap 'send_byte_to_guest 3 >/dev/null 2>&1 || true; kill -TERM '"$awk_pid"' >/dev/null 2>&1 || true' INT

  # Inject the compound command into the guest
  send_to_guest "${inject}"

  # Wait for awk to finish (END seen)
  wait "${awk_pid}" || true
  trap - INT
}

# --- REPL ---
while true; do
  echo -ne "${GREEN}riscv-ubuntu:${NC} "
  if ! IFS= read -r cmd; then
    echo
    break
  fi

  case "${cmd}" in
    "" )
      continue
      ;;
    exit|quit )
      echo "Exiting..."
      break
      ;;
    clear )
      clear
      continue
      ;;
    # Allow sending a literal Ctrl-C to guest (useful if guest is stuck)
    "^C" )
      send_byte_to_guest 3
      continue
      ;;
  esac

  # Run and stream output until completion marker
  run_cmd_stream "${cmd}"
done
