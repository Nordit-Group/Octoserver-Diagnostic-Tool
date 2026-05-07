#!/usr/bin/env bash
# octoserver-quickdiag.sh v2 — fast read-only triage for GPU server hardware faults
# Usage:  sudo bash octoserver-quickdiag.sh
# Output: /tmp/octoserver-quickdiag-<host>-<ts>.txt   (send this back)
#
# Read-only. No reboots, no driver reload, no stress. ~20s runtime.
# Every command is wrapped in `timeout` so a hung tool can't freeze the script.

set -u

HOST=$(hostname -s 2>/dev/null || echo unknown)
TS=$(date -u +%Y%m%d-%H%M%S)
OUT="/tmp/octoserver-quickdiag-${HOST}-${TS}.txt"

exec > >(tee "$OUT") 2>&1

# ---------- helpers --------------------------------------------------------
hr()   { printf '\n══════════ %s ══════════\n' "$*"; }
sub()  { printf '\n── %s ──\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { timeout 10 "$@" 2>&1 || echo "(command failed or timed out: $*)"; }
runl() { timeout 30 "$@" 2>&1 || echo "(command failed or timed out: $*)"; }

# ---------- header ---------------------------------------------------------
hr "OCTOSERVER QUICKDIAG v2 — $HOST"
echo "Date:    $(date -u +%FT%TZ)"
echo "Kernel:  $(uname -r)"
echo "Uptime:  $(uptime -p 2>/dev/null || uptime)"
echo "User:    $(id -un) (uid=$(id -u))"
echo "Cmdline: $(cat /proc/cmdline 2>/dev/null)"
[ "$(id -u)" -ne 0 ] && echo "WARNING: not running as root — some checks will be incomplete"

# ===========================================================================
hr "1. ACTIVE PCIe AER ERRORS (non-zero only)"
found_aer=0
no_aer_sysfs=1
if [ -d /sys/bus/pci/devices ]; then
  for f in /sys/bus/pci/devices/*/aer_dev_fatal \
           /sys/bus/pci/devices/*/aer_dev_nonfatal \
           /sys/bus/pci/devices/*/aer_dev_correctable; do
    [ -e "$f" ] || continue
    no_aer_sysfs=0
    if grep -qE '[1-9]' "$f" 2>/dev/null; then
      found_aer=1
      bdf=$(basename "$(dirname "$f")")
      kind=$(basename "$f" | sed 's/aer_dev_//')
      echo "[$kind] $bdf"
      grep -vE '^[A-Za-z_]+ 0$' "$f" | sed 's/^/  /'
      have lspci && lspci -s "${bdf#0000:}" 2>/dev/null | sed 's/^/  device: /'
      echo
    fi
  done
fi
if [ "$no_aer_sysfs" = 1 ]; then
  echo ">> AER sysfs absent — kernel is in FIRMWARE-FIRST mode."
  echo ">> BIOS must be set to AER → OS-First."
  echo ">> Add to kernel cmdline: pcie_ports=native"
elif [ "$found_aer" = 0 ]; then
  echo "No active AER errors. Clean."
fi

# ===========================================================================
hr "2. KERNEL HARDWARE ERRORS"
if have dmesg; then
  sub "dmesg (last 50 hardware-related)"
  dmesg -T 2>/dev/null \
    | grep -iE 'aer|pcie bus error|hardware error|machine check|mce:|ghes|nvrm|xid|fatal' \
    | tail -50
fi
if have journalctl; then
  sub "journalctl kernel errors (last 30 days)"
  journalctl -k --since "30 days ago" --no-pager 2>/dev/null \
    | grep -iE 'aer|pcie|hardware error|mce|ghes|xid' | tail -30
fi

# ===========================================================================
hr "3. PCIe FULL SCAN"
if have lspci; then
  sub "Topology"
  run lspci -tvnn

  sub "Devices reporting errors in config space (CESta/UESta/DevSta flags)"
  lspci -vvv 2>/dev/null | awk '
    /^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]/ { dev=$0; printed=0 }
    /CESta:.*\+/ || /UESta:.*\+/ || /DevSta:.*(CorrErr|NonFatalErr|FatalErr|UnsuppReq)\+/ {
      if (!printed) { print "\n"dev; printed=1 }
      print "  "$0
    }'

  sub "AMD IOHC root complexes + recent suspect BDFs"
  for s in 00:05.1 80:05.1 80:01.1 81:00; do
    out=$(lspci -s "$s" -nn 2>/dev/null)
    [ -n "$out" ] && echo "$out"
  done

  sub "Secondary bus enumeration — bridges and what's behind them"
  lspci -vt 2>/dev/null | head -80

  sub "Full lspci -vvv (compressed in tarball, see below)"
  echo "Captured separately — too large for inline. See logs/lspci-vvv.txt"
fi

if [ -d /sys/kernel/iommu_groups ]; then
  sub "IOMMU groups"
  for g in /sys/kernel/iommu_groups/*/devices/*; do
    [ -e "$g" ] || continue
    grp=$(basename "$(dirname "$(dirname "$g")")")
    bdf=$(basename "$g")
    name=$(lspci -s "${bdf#0000:}" 2>/dev/null | cut -d' ' -f2-)
    printf "  group %3s  %s  %s\n" "$grp" "$bdf" "$name"
  done | sort -k2 -n
fi

# ===========================================================================
hr "4. NVIDIA GPUs"
if have nvidia-smi; then
  sub "Overview"
  run nvidia-smi
  sub "Driver / GPU info table"
  run nvidia-smi --query-gpu=index,name,pci.bus_id,driver_version,vbios_version,serial,uuid --format=csv
  sub "PCIe link state"
  run nvidia-smi --query-gpu=index,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv
  sub "ECC errors (volatile + aggregate)"
  run nvidia-smi --query-gpu=index,pci.bus_id,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total --format=csv
  sub "Throttle reasons (active + supported)"
  run nvidia-smi --query-gpu=index,clocks_throttle_reasons.active,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.hw_power_brake_slowdown,clocks_throttle_reasons.sw_thermal_slowdown --format=csv
  sub "Power draw / limits / violations"
  run nvidia-smi --query-gpu=index,power.draw,power.limit,enforced.power.limit,power.default_limit,power.max_limit --format=csv
  sub "Row remap / pending / inforom"
  nvidia-smi -q 2>/dev/null | grep -iE 'gpu uuid|product name|xid|pending|remapped rows|sram|dram|inforom|ecc errors' | head -100
  sub "/proc/driver/nvidia/gpus information"
  for g in /proc/driver/nvidia/gpus/*/information; do
    [ -e "$g" ] || continue
    echo "[$g]"
    cat "$g"
    echo
  done
  sub "XID errors in dmesg"
  dmesg -T 2>/dev/null | grep -iE 'xid|nvrm' | tail -20
  if have dcgmi; then
    sub "DCGM health check (read-only)"
    runl dcgmi health -c
  fi
else
  echo "nvidia-smi not present"
fi

# ===========================================================================
hr "5. NVMe SMART"
if have nvme; then
  for n in /dev/nvme?n1; do
    [ -e "$n" ] || continue
    echo
    echo "[$n]"
    nvme smart-log "$n" 2>/dev/null | grep -iE 'critical|media|error|percent|unsafe|temperature'
  done
else
  echo "nvme-cli not installed (apt install nvme-cli)"
fi

# ===========================================================================
hr "6. STORAGE OVERVIEW"
if have lsblk; then
  run lsblk -o NAME,MODEL,SIZE,TRAN,STATE,WWN,MOUNTPOINT
fi

# ===========================================================================
hr "7. CPU / MEMORY"
if have dmidecode; then
  sub "DIMM inventory (populated slots only)"
  dmidecode -t memory 2>/dev/null \
    | awk '/^Memory Device/{flag=1; buf=""} flag{buf=buf"\n"$0} /^$/{if(flag && buf !~ /No Module Installed/) print buf; flag=0}' \
    | grep -E 'Memory Device|Size:|Locator:|Speed:|Manufacturer:|Part Number:|Serial Number:|Configured.*Speed' \
    | sed 's/^[[:space:]]*//'
fi

if have rdmsr || [ -d /sys/devices/system/machinecheck ]; then
  sub "AMD MCE bank status (via /sys/devices/system/machinecheck)"
  for d in /sys/devices/system/machinecheck/machinecheck*/bank*; do
    [ -e "$d" ] || continue
    val=$(cat "$d" 2>/dev/null)
    cpu=$(echo "$d" | grep -oE 'machinecheck[0-9]+')
    bank=$(basename "$d")
    [ "$val" != "0" ] && [ -n "$val" ] && echo "  $cpu/$bank: $val"
  done
  echo "(empty = all MCE banks clean)"
fi

if [ -f /var/log/mcelog ]; then
  sub "/var/log/mcelog tail"
  tail -40 /var/log/mcelog
fi
have mcelog && { sub "mcelog --client"; mcelog --client 2>/dev/null | head -40; }

if [ -d /sys/devices/system/edac ]; then
  sub "EDAC counters"
  for f in /sys/devices/system/edac/mc/mc*/{ce_count,ue_count}; do
    [ -e "$f" ] && echo "  $f = $(cat "$f")"
  done
fi

# ===========================================================================
hr "8. THERMAL SENSORS"
if have sensors; then
  run sensors
else
  echo "lm-sensors not installed (apt install lm-sensors)"
fi

# ===========================================================================
hr "9. IPMI"
if have ipmitool; then
  sub "BMC info"
  ipmitool mc info 2>&1 | grep -iE 'firmware|manufacturer|product' | head -5

  sub "SEL capacity / status"
  run ipmitool sel info

  sub "Power reading"
  run ipmitool dcmi power reading

  sub "Fans"
  run ipmitool sdr type fan

  sub "Temperatures"
  run ipmitool sdr type temperature

  sub "Voltages"
  run ipmitool sdr type voltage

  sub "Sensors in critical / non-recoverable / non-critical state"
  ipmitool sensor 2>/dev/null \
    | awk -F'|' '$4 !~ /^[[:space:]]*ok[[:space:]]*$/ && $4 !~ /^[[:space:]]*ns[[:space:]]*$/ && NF>3 {print}'

  sub "SEL — last 30 entries"
  ipmitool sel elist 2>/dev/null | tail -30

  sub "SEL — critical events only (PSU, PCIe, ECC, thermal, asserted)"
  ipmitool sel elist 2>/dev/null \
    | grep -iE 'psu|power supply|pcie|ecc|memory|thermal|critical|asserted' \
    | tail -30
else
  echo ">> ipmitool not installed."
  echo ">> Install: sudo apt install -y ipmitool && sudo modprobe ipmi_devintf && sudo modprobe ipmi_si"
fi

# ===========================================================================
hr "10. BOOT / CRASH HISTORY"
if have journalctl; then
  sub "Boot list"
  run journalctl --list-boots --no-pager
  sub "Kernel panics / oops / BUG (last 30 days)"
  journalctl -k -p err --since "30 days ago" --no-pager 2>/dev/null \
    | grep -iE 'panic|oops|bug:|call trace|hardware error|fatal' | tail -30
fi
if have last; then
  sub "Reboot history (last 20)"
  last -x reboot 2>/dev/null | head -20
fi

# ===========================================================================
hr "11. AUTO-SUMMARY"
warn=0; crit=0; info=0

if [ "$no_aer_sysfs" = 1 ]; then
  echo "[INFO] AER firmware-first mode — kernel can't see PCIe errors. Set BIOS AER → OS-First."
  info=$((info+1))
fi

if [ "$found_aer" = 1 ]; then
  echo "[CRIT] Active AER errors detected — see section 1"
  crit=$((crit+1))
fi

if dmesg -T 2>/dev/null | grep -qiE 'xid|fatal|pcie bus error|hardware error'; then
  echo "[CRIT] Kernel logged PCIe / GPU XID / fatal errors — see section 2"
  crit=$((crit+1))
fi

if have nvidia-smi && nvidia-smi -q 2>/dev/null | grep -qE 'Pending\s*:\s*Yes|Remapped Rows.*Pending\s*:\s*[1-9]'; then
  echo "[CRIT] GPU has pending row remap — RMA candidate"
  crit=$((crit+1))
fi

if have ipmitool; then
  pcie_sel=$(ipmitool sel elist 2>/dev/null | grep -ciE 'pcie sel log.*assert')
  [ "${pcie_sel:-0}" -gt 0 ] && { echo "[WARN] $pcie_sel PCIe critical_interrupt entries in BMC SEL"; warn=$((warn+1)); }

  ac_lost=$(ipmitool sel elist 2>/dev/null | grep -ciE 'power supply.*input lost')
  [ "${ac_lost:-0}" -gt 0 ] && { echo "[WARN] $ac_lost PSU AC-loss events — check facility power / PDU"; warn=$((warn+1)); }
fi

[ "$crit" = 0 ] && [ "$warn" = 0 ] && echo "No critical or warning conditions auto-detected."
echo
echo "Critical: $crit   Warnings: $warn   Info: $info"

# ===========================================================================
# Capture full lspci -vvv to a separate file, then bundle
LSPCI_FILE="/tmp/octoserver-quickdiag-${HOST}-${TS}-lspci-vvv.txt"
have lspci && lspci -vvv > "$LSPCI_FILE" 2>/dev/null

# Tar + gzip the report and the lspci dump
TAR="/tmp/octoserver-quickdiag-${HOST}-${TS}.tar.gz"
tar -czf "$TAR" -C /tmp \
  "$(basename "$OUT")" \
  "$(basename "$LSPCI_FILE")" 2>/dev/null

hr "DONE"
echo "Text report:   $OUT"
echo "Full lspci:    $LSPCI_FILE"
echo "Tarball:       $TAR  ($(du -h "$TAR" 2>/dev/null | cut -f1))"
echo
echo ">> Send the tarball back to Octoserver support."
echo

exit 0
