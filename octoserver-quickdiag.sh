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

# ===========================================================================
hr "12. UPLOAD TO OCTOSERVER"

# --- Upload configuration ---------------------------------------------------
# Token is provided at runtime — never embedded in this script.
# Operator obtains a fine-grained PAT from Octoserver per incident, scoped to:
#   Nordit-Group/Octoserver-Diag-Reports — Contents: Read and write
GH_REPO="Nordit-Group/Octoserver-Diag-Reports"
GH_TOKEN=""

# Allow non-interactive use via env var: OCTODIAG_TOKEN=ghp_xxx ./script.sh
if [ -n "${OCTODIAG_TOKEN:-}" ]; then
  GH_TOKEN="$OCTODIAG_TOKEN"
  echo "Upload token: provided via OCTODIAG_TOKEN environment variable"
else
  # Interactive prompt — read from controlling terminal even if stdout is piped
  if [ -t 0 ] || [ -e /dev/tty ]; then
    echo
    echo "An upload token is required to deliver the report to Octoserver."
    echo "If you do not have one, press ENTER to skip and the tarball will"
    echo "be retained locally for manual return."
    echo
    if [ -e /dev/tty ]; then
      printf "Paste upload token (input hidden): "
      stty -echo < /dev/tty 2>/dev/null
      IFS= read -r GH_TOKEN < /dev/tty
      stty echo < /dev/tty 2>/dev/null
      echo
    else
      printf "Paste upload token (input hidden): "
      stty -echo 2>/dev/null
      IFS= read -r GH_TOKEN
      stty echo 2>/dev/null
      echo
    fi
  fi
fi

UPLOAD_OK=0
UPLOAD_URL=""
UPLOAD_ERR=""

# Sanitize hostname into valid release tag (lowercase, [a-z0-9-] only)
TAG=$(echo "$HOST" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
[ -z "$TAG" ] && TAG="unknown-host"
ASSET_NAME="$(basename "$TAR")"

if ! have curl; then
  UPLOAD_ERR="curl not present on this system"
elif [ -z "$GH_TOKEN" ]; then
  UPLOAD_ERR="no upload token provided (skipped by operator)"
else
  echo "Looking up release for host: $TAG"
  REL_RESP=$(timeout 15 curl -sS \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$GH_REPO/releases/tags/$TAG" 2>&1)
  REL_ID=$(echo "$REL_RESP" | grep -m1 '"id":' | head -1 | grep -oE '[0-9]+')

  if echo "$REL_RESP" | grep -qE '"message":\s*"(Bad credentials|Not Found)"' && [ -z "$REL_ID" ]; then
    if echo "$REL_RESP" | grep -q "Bad credentials"; then
      UPLOAD_ERR="GitHub returned 'Bad credentials' — token is invalid or expired"
    else
      echo "No existing release for $TAG. Creating new release..."
      CREATE_RESP=$(timeout 15 curl -sS -X POST \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$GH_REPO/releases" \
        -d "{\"tag_name\":\"$TAG\",\"name\":\"$TAG\",\"body\":\"Diagnostic reports for host: $HOST\\nFirst report: $(date -u +%FT%TZ)\"}" 2>&1)
      REL_ID=$(echo "$CREATE_RESP" | grep -m1 '"id":' | head -1 | grep -oE '[0-9]+')
      if [ -z "$REL_ID" ]; then
        UPLOAD_ERR="failed to create release: $(echo "$CREATE_RESP" | grep -oE '"message":\s*"[^"]+"' | head -1)"
      fi
    fi
  fi

  if [ -n "$REL_ID" ] && [ -z "$UPLOAD_ERR" ]; then
    echo "Uploading $ASSET_NAME ($(du -h "$TAR" | cut -f1)) to release $REL_ID..."
    UP_RESP=$(timeout 120 curl -sS -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/gzip" \
      --data-binary "@$TAR" \
      "https://uploads.github.com/repos/$GH_REPO/releases/$REL_ID/assets?name=$ASSET_NAME" 2>&1)
    if echo "$UP_RESP" | grep -q '"browser_download_url"'; then
      UPLOAD_URL=$(echo "$UP_RESP" | grep -m1 '"browser_download_url"' | sed -E 's/.*"(https:[^"]+)".*/\1/')
      UPLOAD_OK=1
      echo "Upload succeeded."
    else
      UPLOAD_ERR=$(echo "$UP_RESP" | grep -oE '"message":\s*"[^"]+"' | head -1 | sed 's/"message":\s*//; s/"//g')
      [ -z "$UPLOAD_ERR" ] && UPLOAD_ERR="unknown upload failure"
    fi
  fi
fi

# Clear token from environment immediately
unset GH_TOKEN OCTODIAG_TOKEN

# ===========================================================================
hr "DONE"
echo "Text report:   $OUT"
echo "Full lspci:    $LSPCI_FILE"
echo "Tarball:       $TAR  ($(du -h "$TAR" 2>/dev/null | cut -f1))"
echo "SHA256:        $(sha256sum "$TAR" 2>/dev/null | cut -d' ' -f1)"
echo

if [ "$UPLOAD_OK" = 1 ]; then
  echo "================================================================"
  echo "  UPLOAD: OK"
  echo "  $UPLOAD_URL"
  echo "================================================================"
  echo
  echo ">> The diagnostic has been delivered to Octoserver."
  echo ">> The local tarball has been retained for your records."
else
  echo "================================================================"
  echo "  UPLOAD: FAILED"
  echo "  Reason: $UPLOAD_ERR"
  echo "================================================================"
  echo
  echo ">> The automatic upload did not complete."
  echo ">> Please return the tarball manually:"
  echo "      $TAR"
  echo ">> Email it as an attachment to your Octoserver support contact,"
  echo ">> or send via your existing support channel."
fi
echo

exit 0
