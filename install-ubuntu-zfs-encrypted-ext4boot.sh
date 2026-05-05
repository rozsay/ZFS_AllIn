#!/bin/bash
# ZFS_AllIn — Ubuntu 24.04 Encrypted ZFS on Root Installer
# Copyright (C) 2025 rozsay
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
################################################################################
# Ubuntu 24.04 — Encrypted ZFS on Root with EXT4 /boot
#
# Features:
#   - Storage topologies: single disk / mirror (2 disks) / RAIDZ1 (3+) / RAIDZ2 (4+)
#   - /boot on mdadm RAID1 across all member disks (redundant boot)
#   - EFI installed on every disk (UEFI multi-boot redundancy)
#   - ZFS native encryption (AES-256-GCM)
#   - Swap outside ZFS, LUKS-encrypted with random key per boot
#   - Network: DHCP or static fixed IP
#   - Full whiptail TUI for all user input
#   - Both UEFI and BIOS boot support
#
# WARNING: This script will DESTROY all data on the selected disk(s)!
#
# Prerequisites:
#   - Boot from Ubuntu 24.04 Live USB
#   - Run as root: sudo bash install-ubuntu-zfs-encrypted-ext4boot.sh
#   - Internet connection required
################################################################################

set -e          # Exit on error
set -u          # Treat unset variables as errors
set -o pipefail # Catch failures in pipelines

################################################################################
# Color codes and logging
################################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $1"; }

################################################################################
# Global state
################################################################################
POOL_NAME="rpool"
CLEANUP_DONE=0
POOL_TOPOLOGY="single"

# Indexed arrays — index i corresponds to DISKS[i]
DISKS=()       # canonical paths: /dev/sda, /dev/nvme0n1, ...
DISK_IDS=()    # by-id paths (or same as DISKS if no by-id available)
EFI_PARTS=()   # EFI partition per disk  (UEFI only)
BOOT_PARTS=()  # /boot partition per disk
SWAP_PARTS=()  # swap partition per disk  (empty string when swap disabled)
ROOT_PARTS=()  # ZFS root partition per disk
ROOT_IDS=()    # by-id paths for ZFS root partitions

BOOT_DEV=""    # /dev/md0  or  BOOT_PARTS[0]  (single disk)
BOOT_UUID=""
EFI_UUID=""    # UUID of the primary (first) EFI partition

################################################################################
# Cleanup trap
################################################################################
cleanup() {
    [[ "$CLEANUP_DONE" == "1" ]] && return
    log_warning "Running cleanup..."
    umount -R /mnt/dev  2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true
    umount -R /mnt/sys  2>/dev/null || true
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt/boot     2>/dev/null || true
    zfs umount -a        2>/dev/null || true
    zpool export "$POOL_NAME" 2>/dev/null || true
    mdadm --stop /dev/md0 2>/dev/null || true
}
trap cleanup EXIT

################################################################################
# Root check
################################################################################
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root: sudo bash $0"
    exit 1
fi

################################################################################
# Banner
################################################################################
clear
echo ""
echo "==========================================================================="
echo "  Ubuntu 24.04 — Encrypted ZFS on Root with EXT4 /boot"
echo "  Single | Mirror | RAIDZ1 | RAIDZ2  ·  LUKS Swap  ·  Static/DHCP IP"
echo "  /boot and EFI redundancy across all pool member disks"
echo "==========================================================================="
echo ""

################################################################################
# Ensure whiptail is available
################################################################################
if ! command -v whiptail &>/dev/null; then
    log_info "Installing whiptail..."
    apt-get install -y whiptail
fi

################################################################################
# Whiptail helper functions
################################################################################

# ask_input <title> <prompt> [default]
# Displays an inputbox. Prints the entered value to stdout. Exits on Cancel.
ask_input() {
    local title="$1" prompt="$2" default="${3:-}"
    local result
    result=$(whiptail \
        --title     "$title" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        --inputbox  "$prompt" 10 65 "$default" \
        3>&1 1>&2 2>&3) || { log_info "Cancelled."; exit 0; }
    echo "$result"
}

# ask_password <title> <prompt>
# Displays a passwordbox. Prints the entered value to stdout. Exits on Cancel.
ask_password() {
    local title="$1" prompt="$2"
    whiptail \
        --title        "$title" \
        --backtitle    "Ubuntu 24.04 Encrypted ZFS Installer" \
        --passwordbox  "$prompt" 10 65 \
        3>&1 1>&2 2>&3 || { log_info "Cancelled."; exit 0; }
}

# ask_yesno <title> <prompt> [default_no=false]
# Returns 0 for Yes, 1 for No.
ask_yesno() {
    local title="$1" prompt="$2" default_no="${3:-false}"
    local flag=""
    [[ "$default_no" == "true" ]] && flag="--defaultno"
    # shellcheck disable=SC2086
    whiptail \
        --title     "$title" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        $flag --yesno "$prompt" 12 70
}

################################################################################
# Pre-installation teardown
# Clears any state left by a previous (partial or full) run of this script,
# in the correct dependency order:
#   umount → close LUKS → zfs umount → zpool export/destroy → mdadm stop
################################################################################
log_step "Pre-installation teardown..."

# 1. Unmount the entire /mnt hierarchy (chroot bind-mounts, ZFS datasets,
#    /boot, /boot/efi from a previous run)
log_info "Unmounting /mnt hierarchy..."
umount -R /mnt/dev  2>/dev/null || true
umount -R /mnt/proc 2>/dev/null || true
umount -R /mnt/sys  2>/dev/null || true
umount -R /mnt      2>/dev/null || true

# 2. Close any open LUKS / dm-crypt swap mappers (cryptswap1, cryptswap2, …)
log_info "Closing dm-crypt devices..."
for dev in /dev/mapper/cryptswap*; do
    [[ -b "$dev" ]] && cryptsetup close "$dev" 2>/dev/null || true
done

# 3. Unmount all ZFS datasets (must happen before export/destroy)
log_info "Unmounting ZFS datasets..."
zfs umount -a 2>/dev/null || true

# 4. Destroy any existing ZFS pools
EXISTING_POOLS=$(zpool list -H -o name 2>/dev/null || true)
if [[ -n "$EXISTING_POOLS" ]]; then
    log_warning "Found existing ZFS pools:"
    zpool list
    echo ""
    POOL_LIST_TEXT=""
    while IFS= read -r p; do
        POOL_LIST_TEXT+="  $p"$'\n'
    done <<< "$EXISTING_POOLS"

    if ask_yesno "Existing ZFS Pools" \
"The following ZFS pools must be destroyed before installation:

${POOL_LIST_TEXT}
This will also stop all mdadm RAID arrays.

Destroy everything and continue?" \
"true"; then
        for pool in $EXISTING_POOLS; do
            log_info "Exporting pool: $pool"
            zpool export -f "$pool" 2>/dev/null || true
            log_info "Destroying pool: $pool"
            zpool destroy -f "$pool" 2>/dev/null || true
            log_success "Pool $pool destroyed"
        done
        log_success "All ZFS pools destroyed"
    else
        log_error "Cannot proceed with existing ZFS pools."
        log_info  "Destroy manually: zpool destroy -f <pool_name>"
        exit 1
    fi
else
    log_success "No existing ZFS pools found"
fi

# 5. Stop all mdadm RAID arrays (md0, md1, …)
log_info "Stopping mdadm arrays..."
mdadm --stop --scan 2>/dev/null || true

# 6. Let udev process all device removals before we proceed
udevadm settle --timeout=15
log_success "Teardown complete"

################################################################################
# Helper: enumerate available disks → stdout (one line per item: tag, label)
################################################################################
list_disks() {
    local dev devname size model byid tag label
    while IFS= read -r dev; do
        devname=$(basename "$dev")
        size=$(lsblk  -dn -o SIZE  "$dev" 2>/dev/null | xargs || echo "?")
        model=$(lsblk -dn -o MODEL "$dev" 2>/dev/null | xargs || echo "")
        byid=$(ls -l /dev/disk/by-id/ 2>/dev/null \
            | grep -v "part" \
            | grep -E "(ata|nvme|scsi|usb)-" \
            | grep " ${devname}$" \
            | head -1 \
            | awk '{print "/dev/disk/by-id/" $9}') || true
        tag="${byid:-$dev}"
        if [[ -n "$model" ]]; then
            label=$(printf "%-12s %-8s %s" "/dev/$devname" "$size" "$model")
        else
            label=$(printf "%-12s %-8s" "/dev/$devname" "$size")
        fi
        printf '%s\n%s\n' "$tag" "$label"
    done < <(lsblk -dn -p -o NAME \
        | grep -E "/dev/(sd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]|hd[a-z])")
}

################################################################################
# Storage topology selection
################################################################################
POOL_TOPOLOGY=$(whiptail \
    --title     "Storage Topology" \
    --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
    --menu \
"Select the ZFS pool topology:

  Mirror needs exactly 2 disks.
  RAIDZ1 needs at least 3 disks.
  RAIDZ2 needs at least 4 disks." \
    18 72 4 \
    "single" "Single disk     — no redundancy" \
    "mirror" "Mirror (RAID1)  — 2 disks, tolerates 1 disk failure" \
    "raidz1" "RAIDZ1          — 3+ disks, tolerates 1 disk failure" \
    "raidz2" "RAIDZ2          — 4+ disks, tolerates 2 disk failures" \
    3>&1 1>&2 2>&3) || { log_info "Cancelled."; exit 0; }

case "$POOL_TOPOLOGY" in
    single) MIN_DISKS=1; EXACT_DISKS=1 ;;
    mirror) MIN_DISKS=2; EXACT_DISKS=2 ;;
    raidz1) MIN_DISKS=3; EXACT_DISKS=0 ;;  # 0 = no upper limit
    raidz2) MIN_DISKS=4; EXACT_DISKS=0 ;;
esac

################################################################################
# Disk selection
################################################################################
log_step "Discovering available disks..."
mapfile -t DISK_ITEMS < <(list_disks)

if [[ ${#DISK_ITEMS[@]} -eq 0 ]]; then
    log_error "No suitable disks found!"
    exit 1
fi

if [[ "$POOL_TOPOLOGY" == "single" ]]; then
    # Single-select menu
    SELECTED=$(whiptail \
        --title     "Disk Selection" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        --menu \
"Select the TARGET disk.

WARNING: ALL DATA WILL BE PERMANENTLY DESTROYED!" \
        22 78 10 \
        "${DISK_ITEMS[@]}" \
        3>&1 1>&2 2>&3) || { log_info "Cancelled."; exit 0; }
    DISK_IDS=("$SELECTED")
else
    # Multi-select checklist
    CHECKLIST_ITEMS=()
    for (( i=0; i<${#DISK_ITEMS[@]}; i+=2 )); do
        CHECKLIST_ITEMS+=("${DISK_ITEMS[$i]}" "${DISK_ITEMS[$i+1]}" "OFF")
    done

    while true; do
        SELECTED=$(whiptail \
            --title     "Disk Selection ($POOL_TOPOLOGY)" \
            --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
            --checklist \
"Select disks for the $POOL_TOPOLOGY pool.
Required: at least $MIN_DISKS disk(s).
Press SPACE to toggle, ENTER to confirm.

WARNING: ALL DATA WILL BE PERMANENTLY DESTROYED!" \
            24 78 12 \
            "${CHECKLIST_ITEMS[@]}" \
            3>&1 1>&2 2>&3) || { log_info "Cancelled."; exit 0; }

        mapfile -t DISK_IDS_TMP < \
            <(echo "$SELECTED" | tr ' ' '\n' | tr -d '"' | grep -v '^$')
        COUNT="${#DISK_IDS_TMP[@]}"

        LIMIT_OK=1
        [[ "$EXACT_DISKS" -gt 0 && "$COUNT" -ne "$EXACT_DISKS" ]] && LIMIT_OK=0
        [[ "$COUNT" -lt "$MIN_DISKS" ]] && LIMIT_OK=0

        if [[ "$LIMIT_OK" -eq 1 ]]; then
            DISK_IDS=("${DISK_IDS_TMP[@]}")
            break
        fi

        MSG="Please select exactly $MIN_DISKS disks for $POOL_TOPOLOGY."
        [[ "$EXACT_DISKS" -eq 0 ]] && \
            MSG="Please select at least $MIN_DISKS disks for $POOL_TOPOLOGY."
        whiptail --title "Wrong number of disks selected" \
            --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
            --msgbox "$MSG\nYou selected: $COUNT" 8 60
    done
fi

# Resolve canonical /dev/sdX paths from by-id (or pass-through)
for id in "${DISK_IDS[@]}"; do
    if [[ "$id" == /dev/disk/by-id/* ]]; then
        DISKS+=("$(readlink -f "$id")")
    else
        DISKS+=("$id")
    fi
done

for d in "${DISKS[@]}"; do
    [[ -b "$d" ]] || { log_error "Not a valid block device: $d"; exit 1; }
done

################################################################################
# Confirmation
################################################################################
DISK_LIST_TEXT=""
for i in "${!DISKS[@]}"; do
    DISK_LIST_TEXT+="  ${DISKS[$i]}"$'\n'
    DISK_LIST_TEXT+="  (${DISK_IDS[$i]})"$'\n'
    DISK_LIST_TEXT+=$'\n'
done

if ! ask_yesno "CONFIRM DESTRUCTIVE OPERATION" \
"ALL DATA ON THE FOLLOWING DISK(S) WILL BE PERMANENTLY DESTROYED:

${DISK_LIST_TEXT}Topology: $POOL_TOPOLOGY  (${#DISKS[@]} disk(s))

This operation CANNOT be undone!

Are you absolutely sure?" \
"true"; then
    log_info "Installation cancelled."
    exit 0
fi

################################################################################
# User configuration
################################################################################
HOSTNAME=$(ask_input "System Configuration" \
    "Hostname for the new system:" "ubuntu-zfs")
[[ -z "$HOSTNAME" ]] && { log_error "Hostname cannot be empty!"; exit 1; }

USERNAME=$(ask_input "System Configuration" \
    "Username for the new user:" "")
[[ -z "$USERNAME" ]] && { log_error "Username cannot be empty!"; exit 1; }

while true; do
    USER_PASSWORD=$(ask_password "User Password" \
        "Password for '$USERNAME':")
    USER_PASSWORD_CONFIRM=$(ask_password "User Password" \
        "Confirm password for '$USERNAME':")
    [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]] && break
    whiptail --title "Error" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        --msgbox "Passwords do not match. Please try again." 8 50
done

while true; do
    ZFS_PASSPHRASE=$(ask_password "ZFS Encryption" \
        "ZFS encryption passphrase:")
    ZFS_PASSPHRASE_CONFIRM=$(ask_password "ZFS Encryption" \
        "Confirm ZFS encryption passphrase:")
    [[ "$ZFS_PASSPHRASE" == "$ZFS_PASSPHRASE_CONFIRM" ]] && break
    whiptail --title "Error" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        --msgbox "Passphrases do not match. Please try again." 8 50
done

################################################################################
# Network configuration
################################################################################
NET_MODE="dhcp"
NET_IP=""
NET_GW=""
NET_DNS=""

if ! ask_yesno "Network Configuration" \
"Use DHCP for network configuration?

Select 'No' to configure a static fixed IP address."; then
    NET_MODE="static"
    NET_IP=$(ask_input "Static IP" \
        "IP address with prefix length:" "192.168.1.100/24")
    [[ -z "$NET_IP" ]] && { log_error "IP address cannot be empty!"; exit 1; }

    NET_GW=$(ask_input "Static IP" \
        "Default gateway:" "192.168.1.1")
    [[ -z "$NET_GW" ]] && { log_error "Gateway cannot be empty!"; exit 1; }

    NET_DNS=$(ask_input "Static IP" \
        "DNS servers (comma-separated):" "8.8.8.8,8.8.4.4")
fi

################################################################################
# Optional features
################################################################################
if ask_yesno "ZFS Options" \
"Enable ZFS compression (lz4)?

Recommended: reduces disk usage with minimal CPU overhead."; then
    COMPRESSION_OPT="lz4"
else
    COMPRESSION_OPT="off"
fi

SWAP_SIZE=$(ask_input "Swap Configuration" \
    "Encrypted swap partition size per disk.
Enter 0 to disable swap entirely.
Examples: 4G, 8G, 16G" "4G")
SWAP_SIZE="${SWAP_SIZE:-4G}"

TIMEZONE=$(ask_input "System Configuration" \
    "Timezone (e.g. Europe/Budapest, America/New_York, UTC):" "UTC")
TIMEZONE="${TIMEZONE:-UTC}"

################################################################################
# Boot mode detection
################################################################################
if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="UEFI"
    log_info "Boot mode: UEFI"
else
    BOOT_MODE="BIOS"
    log_info "Boot mode: BIOS (Legacy)"
fi

################################################################################
# Step 1: Install required utilities on the live system
################################################################################
log_step "Step 1: Installing required utilities..."
apt-get update -qq

LIVE_PKGS="debootstrap gdisk zfsutils-linux mdadm"
[[ "$SWAP_SIZE" != "0" ]] && LIVE_PKGS+=" cryptsetup"
# shellcheck disable=SC2086
apt-get install -y $LIVE_PKGS
log_success "Utilities installed"

################################################################################
# Step 2: Partition all selected disks
#
# Partition layout (UEFI, with swap):
#   Part 1:  512 MB   EFI System Partition (FAT32)      type EF00
#   Part 2:  2 GB     /boot ext4 / mdadm RAID1 member   type FD00
#   Part 3:  SWAP_SIZE  swap (LUKS encrypted)            type 8200
#   Part 4:  rest     ZFS root pool member               type BF00
#
# Partition layout (BIOS, with swap):
#   Part 1:  1 MB     BIOS boot                          type EF02
#   Part 2:  2 GB     /boot ext4 / mdadm RAID1 member   type FD00
#   Part 3:  SWAP_SIZE  swap (LUKS encrypted)            type 8200
#   Part 4:  rest     ZFS root pool member               type BF00
#
# Without swap: parts 3 & 4 collapse to a single part 3 for ZFS.
################################################################################
log_step "Step 2: Partitioning ${#DISKS[@]} disk(s)..."

# ZFS root is partition 4 when swap is present, 3 when swap is disabled.
# (Same numbering for both UEFI and BIOS modes.)
[[ "$SWAP_SIZE" != "0" ]] && ZFS_PART_NUM=4 || ZFS_PART_NUM=3

for i in "${!DISKS[@]}"; do
    DISK="${DISKS[$i]}"
    log_info "Partitioning $DISK..."

    # Determine partition naming (nvme/mmcblk use "p" suffix)
    if [[ "$DISK" =~ nvme|mmcblk ]]; then
        PREF="${DISK}p"
    else
        PREF="${DISK}"
    fi

    # 1. Clear ALL existing filesystem and partition signatures so the kernel
    #    releases any cached device-mapper / ZFS / mdadm references.
    wipefs --all --force "$DISK" 2>/dev/null || true
    udevadm settle --timeout=10

    # 2. Zap the existing partition table.
    sgdisk --zap-all "$DISK" 2>/dev/null || true
    udevadm settle --timeout=10

    # 3. Create ALL partitions in ONE sgdisk invocation.
    #    A single call = a single kernel-notification request, which is far
    #    more reliable than four separate calls on a previously-used disk.
    #
    #    BIOS note: -a1 sets 1-sector alignment for the BIOS boot stub only;
    #    -a2048 resets to standard 1 MiB alignment for all subsequent parts.
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        if [[ "$SWAP_SIZE" != "0" ]]; then
            sgdisk \
                -n1:1M:+512M          -t1:EF00 \
                -n2:0:+2G             -t2:FD00 \
                -n3:0:+"${SWAP_SIZE}" -t3:8200 \
                -n4:0:0               -t4:BF00 \
                "$DISK"
            EFI_PARTS+=("${PREF}1")
            BOOT_PARTS+=("${PREF}2")
            SWAP_PARTS+=("${PREF}3")
            ROOT_PARTS+=("${PREF}4")
        else
            sgdisk \
                -n1:1M:+512M -t1:EF00 \
                -n2:0:+2G    -t2:FD00 \
                -n3:0:0      -t3:BF00 \
                "$DISK"
            EFI_PARTS+=("${PREF}1")
            BOOT_PARTS+=("${PREF}2")
            SWAP_PARTS+=("")
            ROOT_PARTS+=("${PREF}3")
        fi
    else
        if [[ "$SWAP_SIZE" != "0" ]]; then
            sgdisk \
                -a1    -n1:24K:+1000K  -t1:EF02 \
                -a2048 -n2:0:+2G       -t2:FD00 \
                       -n3:0:+"${SWAP_SIZE}" -t3:8200 \
                       -n4:0:0         -t4:BF00 \
                "$DISK"
            BOOT_PARTS+=("${PREF}2")
            SWAP_PARTS+=("${PREF}3")
            ROOT_PARTS+=("${PREF}4")
        else
            sgdisk \
                -a1    -n1:24K:+1000K -t1:EF02 \
                -a2048 -n2:0:+2G      -t2:FD00 \
                       -n3:0:0        -t3:BF00 \
                "$DISK"
            BOOT_PARTS+=("${PREF}2")
            SWAP_PARTS+=("")
            ROOT_PARTS+=("${PREF}3")
        fi
    fi

    # 4. Tell the kernel about the new layout and wait for udev to settle.
    #    Fall back to blockdev --rereadpt if partprobe is insufficient.
    partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
    udevadm settle --timeout=30

    # 5. Wait (up to 30 s) for the last partition node to appear in /dev.
    LAST_PART="${PREF}${ZFS_PART_NUM}"
    for attempt in $(seq 1 15); do
        [[ -b "$LAST_PART" ]] && break
        log_info "Waiting for $LAST_PART (attempt $attempt/15)..."
        sleep 2
    done
    if [[ ! -b "$LAST_PART" ]]; then
        log_error "Partition $LAST_PART did not appear after partprobe!"
        log_error "Try running the script again; if it persists, reboot the live USB."
        exit 1
    fi

    # 6. Stop any mdadm arrays the kernel may have auto-assembled from stale
    #    superblocks still present in the partition data area (sgdisk --zap-all
    #    only clears the GPT headers; the mdadm metadata=1.0 superblock lives at
    #    the very end of the partition and survives).  Then wipe every newly
    #    created partition's signatures so mkfs / mdadm --create start clean.
    mdadm --stop --scan 2>/dev/null || true
    for PNUM in $(seq 1 "${ZFS_PART_NUM}"); do
        PDEV="${PREF}${PNUM}"
        [[ -b "$PDEV" ]] && wipefs --all --force "$PDEV" 2>/dev/null || true
    done
    udevadm settle --timeout=10

    log_success "Disk $DISK partitioned"
done

# Show layout of the first disk for reference (read-only, no kernel side effects)
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "${DISKS[0]}" || true

# Resolve by-id paths for ZFS root partitions
for i in "${!DISKS[@]}"; do
    DISK_ID="${DISK_IDS[$i]}"
    if [[ "$DISK_ID" == /dev/disk/by-id/* ]]; then
        CANDIDATE="${DISK_ID}-part${ZFS_PART_NUM}"
        if [[ -b "$CANDIDATE" ]]; then
            ROOT_IDS+=("$CANDIDATE")
        else
            log_warning "by-id not found for ZFS partition on disk $((i+1)), using ${ROOT_PARTS[$i]}"
            ROOT_IDS+=("${ROOT_PARTS[$i]}")
        fi
    else
        ROOT_IDS+=("${ROOT_PARTS[$i]}")
    fi
done

log_success "All disks partitioned"

################################################################################
# Step 3: Create /boot filesystem
#
# Single disk:  mkfs.ext4 directly on the boot partition
# Multi-disk:   mdadm RAID1 across all boot partitions, then mkfs.ext4 on md0
#               --metadata=1.0 stores the superblock at the end of the
#               partition so GRUB can read ext4 from the start.
################################################################################
log_step "Step 3: Setting up /boot..."

NDISKS="${#DISKS[@]}"
if [[ "$NDISKS" -eq 1 ]]; then
    BOOT_DEV="${BOOT_PARTS[0]}"
    mkfs.ext4 -F -L boot "$BOOT_DEV"
else
    mdadm --create /dev/md0 \
        --level=1 \
        --raid-devices="$NDISKS" \
        --metadata=1.0 \
        --quiet \
        "${BOOT_PARTS[@]}"
    BOOT_DEV="/dev/md0"
    mkfs.ext4 -F -L boot "$BOOT_DEV"
fi

BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV")
log_info "Boot device: $BOOT_DEV  (UUID: $BOOT_UUID)"
log_success "/boot ready"

################################################################################
# Step 4: Create encrypted ZFS root pool
################################################################################
log_step "Step 4: Creating encrypted ZFS pool ($POOL_NAME)..."

case "$POOL_TOPOLOGY" in
    single) ZPOOL_VDEV_ARGS=("${ROOT_IDS[0]}") ;;
    mirror) ZPOOL_VDEV_ARGS=(mirror "${ROOT_IDS[@]}") ;;
    raidz1) ZPOOL_VDEV_ARGS=(raidz  "${ROOT_IDS[@]}") ;;
    raidz2) ZPOOL_VDEV_ARGS=(raidz2 "${ROOT_IDS[@]}") ;;
esac

echo -n "$ZFS_PASSPHRASE" | zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -O encryption=aes-256-gcm \
    -O keylocation=prompt \
    -O keyformat=passphrase \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression="$COMPRESSION_OPT" \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=/ \
    -R /mnt \
    "$POOL_NAME" "${ZPOOL_VDEV_ARGS[@]}" -f

zpool list "$POOL_NAME" >/dev/null 2>&1 || {
    log_error "Failed to create ZFS pool $POOL_NAME"
    exit 1
}
log_success "ZFS pool created ($POOL_TOPOLOGY)"

################################################################################
# Step 5: Create ZFS datasets
################################################################################
log_step "Step 5: Creating ZFS datasets..."

zfs create -o canmount=off    -o mountpoint=none  "$POOL_NAME/ROOT"
zfs create -o canmount=noauto -o mountpoint=/     "$POOL_NAME/ROOT/ubuntu"
zfs mount "$POOL_NAME/ROOT/ubuntu"

zfs create -o mountpoint=/home                    "$POOL_NAME/home"
zfs create -o mountpoint=/root                    "$POOL_NAME/home/root"
chmod 700 /mnt/root

zfs create -o canmount=off -o mountpoint=/var     "$POOL_NAME/var"
zfs create -o mountpoint=/var/log                 "$POOL_NAME/var/log"
zfs create -o mountpoint=/var/spool               "$POOL_NAME/var/spool"
zfs create -o mountpoint=/var/tmp                 "$POOL_NAME/var/tmp"
zfs create -o com.sun:auto-snapshot=false \
           -o mountpoint=/var/cache               "$POOL_NAME/var/cache"
zfs create -o mountpoint=/var/lib                 "$POOL_NAME/var/lib"
zfs create -o com.sun:auto-snapshot=false \
           -o mountpoint=/var/lib/docker          "$POOL_NAME/var/lib/docker"
zfs create -o com.sun:auto-snapshot=false \
           -o mountpoint=/var/lib/nfs             "$POOL_NAME/var/lib/nfs"
zfs create -o com.sun:auto-snapshot=false \
           -o mountpoint=/tmp                     "$POOL_NAME/tmp"
chmod 1777 /mnt/var/tmp /mnt/tmp

log_success "ZFS datasets created"

################################################################################
# Step 6: Mount /boot
################################################################################
log_step "Step 6: Mounting /boot..."
mkdir -p /mnt/boot
mount "$BOOT_DEV" /mnt/boot
log_success "/boot mounted"

################################################################################
# Step 7: EFI partitions (UEFI only)
#
# Format all EFI partitions as FAT32.  Mount the first one now so debootstrap
# and GRUB installation can proceed.  The remaining EFI partitions will have
# GRUB installed in Step 12 (mount each in turn).
################################################################################
EFI_UUID=""
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    log_step "Step 7: Formatting EFI partition(s)..."
    for (( i=0; i<${#EFI_PARTS[@]}; i++ )); do
        mkfs.vfat -F32 "${EFI_PARTS[$i]}"
        log_info "Formatted EFI: ${EFI_PARTS[$i]}"
    done
    EFI_UUID=$(blkid -s UUID -o value "${EFI_PARTS[0]}")
    mkdir -p /mnt/boot/efi
    mount "${EFI_PARTS[0]}" /mnt/boot/efi
    log_info "Primary EFI UUID: $EFI_UUID"
    log_success "EFI partitions ready"
else
    log_step "Step 7: BIOS mode — EFI not applicable, skipping"
fi

################################################################################
# Step 8: Install Ubuntu base system
################################################################################
log_step "Step 8: Installing Ubuntu base system via debootstrap..."
debootstrap \
    --mirror=http://archive.ubuntu.com/ubuntu \
    noble /mnt
log_success "Base system installed"

################################################################################
# Step 9: Pre-chroot configuration
################################################################################
log_step "Step 9: Configuring system (pre-chroot)..."

# Hostname
echo "$HOSTNAME" > /mnt/etc/hostname

cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Netplan — DHCP or static fixed IP
mkdir -p /mnt/etc/netplan
if [[ "$NET_MODE" == "dhcp" ]]; then
    cat > /mnt/etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: en*
      dhcp4: true
EOF
else
    # Build YAML DNS list from comma-separated input
    DNS_YAML=$(echo "$NET_DNS" | tr ',' '\n' | \
        awk '{printf "        - %s\n", $1}')
    cat > /mnt/etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: en*
      addresses:
        - $NET_IP
      routes:
        - to: default
          via: $NET_GW
      nameservers:
        addresses:
${DNS_YAML}
EOF
fi

# APT sources (never copy from live USB)

cat > /mnt/etc/apt/sources.list.d/ubuntu.sources  <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

## Ubuntu security updates. Aside from URIs and Suites,
## this should mirror your choices in the previous section.
Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

# Disable IPv6 system-wide
cat > /mnt/etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# /etc/fstab
cat > /mnt/etc/fstab <<EOF
# <file system>                         <mount>     <type>  <options>     <dump> <pass>
UUID=$BOOT_UUID                         /boot       ext4    defaults      0      2
EOF
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    cat >> /mnt/etc/fstab <<EOF
UUID=$EFI_UUID                          /boot/efi   vfat    umask=0077    0      1
EOF
fi

# Encrypted swap — one entry per disk in /etc/crypttab + /etc/fstab
if [[ "$SWAP_SIZE" != "0" ]]; then
    : > /mnt/etc/crypttab
    for i in "${!SWAP_PARTS[@]}"; do
        [[ -z "${SWAP_PARTS[$i]}" ]] && continue
        CRYPTNAME="cryptswap$((i+1))"

        # Prefer by-id path in crypttab for stability
        DISK_ID="${DISK_IDS[$i]}"
        if [[ "$DISK_ID" == /dev/disk/by-id/* ]]; then
            SWAP_DEV_ID="${DISK_ID}-part3"
            [[ -b "$SWAP_DEV_ID" ]] || SWAP_DEV_ID="${SWAP_PARTS[$i]}"
        else
            SWAP_DEV_ID="${SWAP_PARTS[$i]}"
        fi

        echo "${CRYPTNAME}  ${SWAP_DEV_ID}  /dev/urandom  swap,cipher=aes-xts-plain64,size=512" \
            >> /mnt/etc/crypttab
        echo "/dev/mapper/${CRYPTNAME}  none  swap  defaults  0  0" \
            >> /mnt/etc/fstab
        log_info "Encrypted swap entry: $CRYPTNAME → $SWAP_DEV_ID"
    done
fi

# mdadm config — write from live system so chroot initramfs picks it up
if [[ "$NDISKS" -gt 1 ]]; then
    mkdir -p /mnt/etc/mdadm
    echo "HOMEHOST <ignore>" > /mnt/etc/mdadm/mdadm.conf
    mdadm --detail --scan >> /mnt/etc/mdadm/mdadm.conf
    log_info "mdadm.conf written"
fi

log_success "Pre-chroot configuration complete"

# Bind-mount kernel virtual filesystems
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys

################################################################################
# Step 10: Install packages in chroot
################################################################################
log_step "Step 10: Installing packages in chroot..."

# Install kernel first so ZFS initramfs module is built against correct version
chroot /mnt /bin/bash -e <<CHROOT_KERNEL
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y linux-image-generic linux-headers-generic
CHROOT_KERNEL

# Select GRUB variant
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    GRUB_PKG="grub-efi-amd64 grub-efi-amd64-signed shim-signed"
else
    GRUB_PKG="grub-pc"
fi

# Extra packages based on features selected
EXTRA_PKGS="openssh-server dosfstools nano wget curl mc"
[[ "$NDISKS" -gt 1 ]]       && EXTRA_PKGS+=" mdadm"
[[ "$SWAP_SIZE" != "0" ]]   && EXTRA_PKGS+=" cryptsetup cryptsetup-initramfs"

chroot /mnt /bin/bash -e <<CHROOT_PACKAGES
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y \
    zfs-initramfs \
    $GRUB_PKG \
    $EXTRA_PKGS
CHROOT_PACKAGES

chroot /mnt /bin/bash -e <<CHROOT_LOCALE
set -e
export DEBIAN_FRONTEND=noninteractive
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata
CHROOT_LOCALE

log_success "Packages installed"

################################################################################
# Step 11: Create user and set passwords
################################################################################
log_step "Step 11: Creating user '$USERNAME'..."
chroot /mnt /bin/bash -e <<CHROOT_USER
set -e
useradd -m -s /bin/bash -G sudo,adm "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "root:$USER_PASSWORD"      | chpasswd
CHROOT_USER
log_success "User '$USERNAME' created"

################################################################################
# Step 12: Configure bootloader
#
# Single disk:  standard GRUB install
# Multi-disk:   UEFI → install GRUB on each disk's EFI partition in turn
#               BIOS → install GRUB (MBR) on every disk
################################################################################
log_step "Step 12: Configuring bootloader..."

chroot /mnt zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"

# Rebuild initramfs — includes ZFS, mdadm (if multi-disk), cryptsetup (if swap)
if [[ "$NDISKS" -gt 1 ]]; then
    chroot /mnt /bin/bash -e <<CHROOT_MDADM
set -e
mdadm --detail --scan > /etc/mdadm/mdadm.conf
update-initramfs -c -k all
CHROOT_MDADM
else
    chroot /mnt update-initramfs -c -k all
fi

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    # Install GRUB on each disk's EFI partition
    for (( i=0; i<${#EFI_PARTS[@]}; i++ )); do
        # For i>0 we need to unmount the previous EFI and mount the current one
        if [[ "$i" -gt 0 ]]; then
            umount /mnt/boot/efi
            mount "${EFI_PARTS[$i]}" /mnt/boot/efi
        fi
        chroot /mnt grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=ubuntu \
            --recheck
        # log_info "GRUB installed on EFI: ${EFI_PARTS[$i]}"
    done
    # Leave primary EFI mounted for update-grub
    if [[ "${#EFI_PARTS[@]}" -gt 1 ]]; then
        umount /mnt/boot/efi
        mount "${EFI_PARTS[0]}" /mnt/boot/efi
    fi
else
    # BIOS: install GRUB on every disk's MBR
    for DISK in "${DISKS[@]}"; do
        chroot /mnt grub-install "$DISK"
        log_info "GRUB installed on: $DISK"
    done
fi

chroot /mnt update-grub
log_success "Bootloader configured"

################################################################################
# Step 13: Enable ZFS services
################################################################################
log_step "Step 13: Enabling ZFS services..."
chroot /mnt systemctl enable zfs-import-cache
chroot /mnt systemctl enable zfs-mount
chroot /mnt systemctl enable zfs.target
log_success "ZFS services enabled"

################################################################################
# Step 14: Create initial installation snapshots
################################################################################
log_step "Step 14: Creating initial snapshots..."
SNAPSHOT_NAME="initial-install-$(date +%Y%m%d-%H%M%S)"
zfs snapshot -r "${POOL_NAME}@${SNAPSHOT_NAME}"
log_success "Snapshot created: ${POOL_NAME}@${SNAPSHOT_NAME}"
zfs list -t snapshot -r "$POOL_NAME" | grep "$SNAPSHOT_NAME"

################################################################################
# Step 15: Save disk configuration to /root/DISK_INFO.txt
################################################################################
log_step "Step 15: Saving disk configuration..."
{
    echo "# Disk Configuration — generated $(date)"
    echo ""
    echo "Topology  : $POOL_TOPOLOGY"
    echo "Boot mode : $BOOT_MODE"
    echo "Network   : $NET_MODE"
    [[ "$NET_MODE" == "static" ]] && echo "IP        : $NET_IP"
    echo ""
    for i in "${!DISKS[@]}"; do
        echo "Disk $((i+1)):"
        echo "  Device      : ${DISKS[$i]}"
        echo "  by-id       : ${DISK_IDS[$i]}"
        if [[ "$BOOT_MODE" == "UEFI" && -n "${EFI_PARTS[$i]:-}" ]]; then
            echo "  EFI part    : ${EFI_PARTS[$i]}"
        fi
        echo "  Boot part   : ${BOOT_PARTS[$i]}"
        if [[ -n "${SWAP_PARTS[$i]:-}" ]]; then
            echo "  Swap part   : ${SWAP_PARTS[$i]} (LUKS, random key per boot)"
        fi
        echo "  ZFS part    : ${ROOT_PARTS[$i]}"
        echo "  ZFS by-id   : ${ROOT_IDS[$i]}"
        echo ""
    done
    echo "Boot device : $BOOT_DEV"
    echo "Boot UUID   : $BOOT_UUID"
    [[ -n "$EFI_UUID" ]] && echo "EFI UUID    : $EFI_UUID"
    echo "ZFS pool    : $POOL_NAME"
    echo ""
    echo "# Useful commands"
    echo "zpool status $POOL_NAME"
    echo "zpool list -v $POOL_NAME"
    [[ "$NDISKS" -gt 1 ]] && echo "mdadm --detail /dev/md0"
    echo ""
    echo "# Re-import pool"
    echo "zpool export $POOL_NAME"
    echo "zpool import -d /dev/disk/by-id $POOL_NAME"
} > /mnt/root/DISK_INFO.txt
log_success "Configuration saved to /root/DISK_INFO.txt"

################################################################################
# Step 16: Cleanup and unmount
################################################################################
log_step "Step 16: Unmounting filesystems and exporting pool..."
CLEANUP_DONE=1

umount -R /mnt/dev  || true
umount -R /mnt/proc || true
umount -R /mnt/sys  || true
[[ "$BOOT_MODE" == "UEFI" ]] && umount /mnt/boot/efi || true
umount /mnt/boot || true
zfs umount -a
zpool export "$POOL_NAME"
[[ "$NDISKS" -gt 1 ]] && mdadm --stop /dev/md0 || true
log_success "Pool exported — installation complete!"

################################################################################
# Summary
################################################################################
SWAP_LABEL="$SWAP_SIZE per disk (LUKS, random key per boot)"
[[ "$SWAP_SIZE" == "0" ]] && SWAP_LABEL="disabled"

echo ""
echo "==========================================================================="
echo "  Installation Complete!"
echo "==========================================================================="
echo ""
echo "  Hostname   : $HOSTNAME"
echo "  User       : $USERNAME"
echo "  Timezone   : $TIMEZONE"
echo "  ZFS pool   : $POOL_NAME  ($POOL_TOPOLOGY, AES-256-GCM encrypted)"
echo "  Compress   : $COMPRESSION_OPT"
echo "  Swap       : $SWAP_LABEL"
echo "  Network    : $NET_MODE"
[[ "$NET_MODE" == "static" ]] && echo "  IP address : $NET_IP  GW: $NET_GW"
echo "  Disks      : ${#DISKS[@]} disk(s)"
echo ""
echo "IMPORTANT: Keep your ZFS passphrase safe — it cannot be recovered!"
echo ""
echo "==========================================================================="
echo ""

NET_LABEL="$NET_MODE"
[[ "$NET_MODE" == "static" ]] && NET_LABEL="static  ($NET_IP)"

whiptail \
    --title     "Installation Complete" \
    --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
    --yesno \
"Installation finished successfully!

  Hostname : $HOSTNAME
  User     : $USERNAME
  ZFS pool : $POOL_NAME ($POOL_TOPOLOGY, AES-256-GCM)
  Swap     : $SWAP_LABEL
  Network  : $NET_LABEL
  Disks    : ${#DISKS[@]}

Remove installation media, then reboot.
Enter your ZFS passphrase at the boot prompt.

Reboot now?" \
    18 65 || exit 0

reboot
