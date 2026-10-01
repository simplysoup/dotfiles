#!/usr/bin/env bash
# bt-reconnect.sh — reconnect (or re-pair) a single-pairing Bluetooth device.
#
# Some single-slot devices only keep one bond / active link.
# Scenarios handled here:
#   1. Device powered off/on          -> clean disconnect + reconnect cycle
#   2. Device paired to another host  -> connection refused -> auto re-pair
#      (prompts to enter pairing mode, scans, pairs, trusts, connects)
#   3. Bond missing on this PC        -> same auto re-pair flow
#
# Config file (~/.config/bluetooth-reconnect/device):
#   line 1: MAC address
#   line 2: device name (used to find it during pairing; some devices
#           advertise a random address while in pairing mode)
# Override the config dir with $BT_RECONNECT_CONFIG.
#
# Usage:
#   bt-reconnect.sh               reconnect, or re-pair if needed
#   bt-reconnect.sh --status      print JSON for a waybar custom module
#   bt-reconnect.sh --device      print the resolved MAC address
#   bt-reconnect.sh --name        print the device name (best effort)

set -euo pipefail

CONFIG_DIR="${BT_RECONNECT_CONFIG:-$HOME/.config/bluetooth-reconnect}"
CONFIG_FILE="$CONFIG_DIR/device"

# The paired device is machine-local state and is deliberately not versioned.
# ------------------------------------------------------------ device config ----

DEVICE=""
DEVICE_NAME="Bluetooth device"
if [[ -f "$CONFIG_FILE" ]]; then
  mapfile -t cfg < <(grep -v '^[[:space:]]*#' "$CONFIG_FILE" | sed '/^[[:space:]]*$/d')
  if [[ "${cfg[0]:-}" =~ ^[[:space:]]*[0-9A-Fa-f:]+[[:space:]]*$ ]]; then
    DEVICE="$(tr -d '[:space:]' <<<"${cfg[0]}")"
  fi
  if [[ -n "${cfg[1]:-}" ]]; then
    DEVICE_NAME="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${cfg[1]}")"
  fi
fi

if ! [[ "$DEVICE" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
  echo "bt-reconnect: missing or invalid device address; configure $CONFIG_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------- helpers ----

bt_status() {
  # prints: CONNECTED | DISCONNECTED | UNKNOWN (not paired / adapter off)
  local out
  out="$(bluetoothctl info "$DEVICE" 2>/dev/null || true)"
  # A missing bond means nothing can connect, even if a stale "Connected: yes"
  # flag lingers after a removal.
  if grep -q "Paired: no" <<<"$out"; then echo "UNKNOWN"; return; fi
  if   grep -q "Connected: yes" <<<"$out"; then echo "CONNECTED"
  elif grep -q "Connected: no"  <<<"$out"; then echo "DISCONNECTED"
  else echo "UNKNOWN"; fi
}

bt_name() {
  bluetoothctl info "$DEVICE" 2>/dev/null | sed -n 's/^[[:space:]]*Name: //p' | head -1 || true
}

notify() {
  command -v notify-send >/dev/null 2>&1 && \
    notify-send -a "bt-reconnect" -i bluetooth "$1" "$2" 2>/dev/null || true
}

refresh_waybar() {
  # Re-trigger the waybar module that declared "signal": 3
  pkill -RTMIN+3 waybar 2>/dev/null || true
}

# wait_state <CONNECTED|DISCONNECTED> <timeout-seconds>
wait_state() {
  local target="$1" tries="$2" i=0
  while (( i < tries )); do
    [[ "$(bt_status)" == "$target" ]] && return 0
    sleep 1
    (( i++ ))
  done
  return 1
}

wait_paired() { # <mac> <timeout-seconds>
  local mac="$1" tries="$2" i=0
  while (( i < tries )); do
    bluetoothctl info "$mac" 2>/dev/null | grep -q "Paired: yes" && return 0
    sleep 1
    (( i++ ))
  done
  return 1
}

# ------------------------------------------------------------- status output ----

if [[ "${1:-}" == "--status" ]]; then
  name="$(bt_name)"
  [[ -n "$name" ]] || name="$DEVICE_NAME"
  case "$(bt_status)" in
    CONNECTED)    printf '{"text":"\uf293","class":"connected","tooltip":"%s: connected"}\n' "$name" ;;
    DISCONNECTED) printf '{"text":"\uf293","class":"disconnected","tooltip":"%s: disconnected"}\n' "$name" ;;
    *)            printf '{"text":"\uf293","class":"unknown","tooltip":"%s: not paired"}\n' "$name" ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "--device" ]]; then echo "$DEVICE"; exit 0; fi
if [[ "${1:-}" == "--name" ]]; then bt_name; exit 0; fi

# ------------------------------------------------------- auto re-pair flow ----
# Requires the device to be put in pairing mode by the user. Only reached when a
# plain connect fails or the bond is missing.

# scan_for_device <budget-seconds> — bounded discovery; prints found MAC.
# Uses `--timeout` scans (verified reliable on this machine; long-running
# `scan on` sessions were found to start without emitting results).
scan_for_device() {
  local budget="$1" elapsed=0 mac="" out line
  while (( elapsed < budget )); do
    out="$(bluetoothctl --timeout 5 scan on 2>&1 || true)"
    line="$(grep -m1 -E "(^| )Device .*(${DEVICE}|${DEVICE_NAME})" <<<"$out" || true)"
    if [[ -n "$line" ]]; then
      mac="$(sed -nE 's/.*(Device )?([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}).*/\2/p' <<<"$line" | head -1)"
      [[ -n "$mac" ]] && { echo "$mac"; return 0; }
    fi
    elapsed=$(( elapsed + 6 ))
  done
  return 1
}

repair() {
  local mac="$1" found attempt

  notify "Pairing needed" "Put the headphones in pairing mode (hold the power button). Waiting up to 90s…"

  if ! found="$(scan_for_device 90)"; then
    notify "Bluetooth" "Could not find $DEVICE_NAME in pairing mode. Power it on / enter pairing mode and try again."
    return 1
  fi

  # Device found. If a stale bond exists (single-slot devices dropped it on the
  # other host), remove it so a fresh pair is accepted.
  if bluetoothctl info "$found" 2>/dev/null | grep -q "Paired: yes"; then
    bluetoothctl remove "$found" >/dev/null 2>&1 || true
    sleep 1
  fi

  attempt=0
  while (( attempt < 3 )); do
    bluetoothctl pair "$found" >/dev/null 2>&1 || true
    wait_paired "$found" 12 && break
    (( attempt++ ))
    sleep 2
  done

  if ! bluetoothctl info "$found" 2>/dev/null | grep -q "Paired: yes"; then
    notify "Bluetooth" "Pairing with $found failed. Make sure it is in pairing mode and not connected to the other device."
    return 1
  fi

  bluetoothctl trust "$found" >/dev/null 2>&1 || true
  notify "Pairing $DEVICE_NAME" "Paired. Connecting…"
  bluetoothctl connect "$found" >/dev/null 2>&1 || true

  if wait_state CONNECTED 20; then
    if [[ "$found" != "$DEVICE" ]]; then
      # Device was found under a different (e.g. random) address — persist it
      cp "$CONFIG_FILE" "$CONFIG_FILE.bak" 2>/dev/null || true
      printf '%s\n%s\n' "$found" "$DEVICE_NAME" >"$CONFIG_FILE"
      notify "Bluetooth" "$DEVICE_NAME re-paired (address updated to $found)"
    else
      notify "Bluetooth" "$DEVICE_NAME re-paired and connected"
    fi
    refresh_waybar
    return 0
  fi

  notify "Bluetooth" "Paired but could not connect $DEVICE_NAME. Try again in a few seconds."
  return 1
}

# ------------------------------------------------------------ reconnect flow ----

name="$(bt_name)"
[[ -n "$name" ]] || name="$DEVICE_NAME"

# connect_or_repair <mac>: plain connect; on failure, verify the device is
# actually advertising (never touch the bond while it might just be off or
# booting), retry once, and only then fall back to the destructive re-pair.
connect_or_repair() {
  local mac="$1" found

  notify "Reconnecting $name" "Connecting…"
  bluetoothctl connect "$mac" >/dev/null 2>&1 || true
  if wait_state CONNECTED 20; then
    notify "Bluetooth" "$name reconnected"
    refresh_waybar
    return 0
  fi

  # Device may be powered off / out of range / still booting. Verify it is
  # actually advertising before doing anything that could hurt the bond.
  if ! found="$(scan_for_device 30)"; then
    notify "Bluetooth" "$name is off or out of range — power it on, then try again."
    return 1
  fi

  # It is up (and may have just finished booting) — one clean retry.
  notify "Reconnecting $name" "Retrying connection…"
  bluetoothctl connect "$mac" >/dev/null 2>&1 || true
  if wait_state CONNECTED 15; then
    notify "Bluetooth" "$name reconnected"
    refresh_waybar
    return 0
  fi

  # Still refused: the bond is genuinely stale (device paired elsewhere or
  # dropped the key). Only now remove it and re-pair.
  repair "$found"
}

case "$(bt_status)" in
  CONNECTED)
    notify "Reconnecting $name" "Disconnecting…"
    bluetoothctl disconnect "$DEVICE" >/dev/null 2>&1 || true
    if ! wait_state DISCONNECTED 15; then
      notify "Bluetooth" "Failed to disconnect $name"
      exit 1
    fi
    ;;
esac

connect_or_repair "$DEVICE"
