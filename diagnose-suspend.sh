#!/bin/bash
# Suspend/resume diagnostics with pm_test, pm_trace and per-device D3cold bisection.
# Usage: sudo ./diagnose-suspend.sh <mode> [args]
#   status               show sleep settings, suspend stats and D3cold state of PCI devices
#   pmtest               run pm_test levels (freezer, devices, platform) for s2idle and deep;
#                        every level resumes by itself after ~5 s
#   trace                pm_test=platform with pm_trace enabled; if it freezes, reboot
#                        within 3 minutes and run: journalctl -b 0 -k | grep -A3 "Magic number"
#                        (WARNING: pm_trace scrambles the RTC clock, NTP fixes it)
#   d3cold-test DEV...   pm_test=platform with D3cold disabled on the given PCI devices
#                        (e.g. 0000:2c:00.0). Bisect until you find the culprit.
# All settings are runtime-only and reset on reboot.
# Every step is written (and synced) to the log BEFORE it runs, so after a freeze
# the last line in the log tells you where it hung.
set -u
LOG="${LOG:-./suspend-diag.log}"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; sync; }
need_root() { [ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }; }

run_pm_test() {  # $1 = s2idle|deep, $2 = level
  echo "$1" > /sys/power/mem_sleep
  echo "$2" > /sys/power/pm_test
  log "START mem_sleep=$1 pm_test=$2 (if this is the last line, it froze here)"
  sleep 1; sync
  if echo mem > /sys/power/state; then r=OK; else r="ERROR $?"; fi
  log "DONE  mem_sleep=$1 pm_test=$2 -> $r"
  dmesg | tail -40 | grep -iE "PM:|error|fail|timeout" >> "$LOG"
  echo none > /sys/power/pm_test
  sleep 3
}

case "${1:-}" in
status)
  echo "mem_sleep: $(cat /sys/power/mem_sleep)   pm_test: $(cat /sys/power/pm_test)"
  for f in success fail last_failed_dev last_failed_step; do
    echo "suspend_stats/$f: $(cat /sys/power/suspend_stats/$f 2>/dev/null)"; done
  for d in /sys/bus/pci/devices/*; do
    [ -f "$d/d3cold_allowed" ] || continue
    printf '%-14s d3cold=%s  %s\n' "$(basename "$d")" "$(cat "$d/d3cold_allowed")" \
      "$(lspci -s "$(basename "$d")" 2>/dev/null | cut -d' ' -f2- | cut -c1-60)"
  done ;;
pmtest)
  need_root
  echo 1 > /sys/power/pm_debug_messages
  for t in freezer devices platform; do run_pm_test s2idle $t; done
  for t in freezer devices platform processors core; do run_pm_test deep $t; done
  echo s2idle > /sys/power/mem_sleep
  log "ALL pm_test LEVELS PASSED" ;;
trace)
  need_root
  echo 1 > /sys/power/pm_trace
  log "pm_trace enabled. If it freezes: reboot NOW (within 3 min)."
  run_pm_test s2idle platform
  echo 0 > /sys/power/pm_trace
  log "trace run passed" ;;
d3cold-test)
  need_root; shift
  [ $# -gt 0 ] || { echo "Give PCI addresses, see: $0 status"; exit 1; }
  for l in "$@"; do echo 0 > "/sys/bus/pci/devices/$l/d3cold_allowed" && log "D3cold disabled: $l"; done
  run_pm_test s2idle platform
  for l in "$@"; do echo 1 > "/sys/bus/pci/devices/$l/d3cold_allowed"; done
  log "PASSED with D3cold disabled on: $*" ;;
*) sed -n 2,16p "$0" ;;
esac
