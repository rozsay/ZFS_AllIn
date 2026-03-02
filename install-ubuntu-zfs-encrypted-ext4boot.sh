#!/bin/bash
# ZFS_AllIn — Ubuntu 24.04 Encrypted ZFS on Root with EXT4 Boot Installer
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
# Ubuntu 24.04 Encrypted ZFS on Root with EXT4 Boot Installation Script
#
# Automates Ubuntu 24.04 installation with:
#   - Native ZFS encryption (AES-256-GCM) on root
#   - Traditional EXT4 /boot partition (GRUB-compatible)
#   - Full whiptail TUI for all user input
#   - Disk identification via /dev/disk/by-id/
#   - Optional ZFS compression (lz4) and swap ZVOL
#   - Both UEFI and BIOS boot support
#
# WARNING: This script will DESTROY all data on the target disk!
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
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $1"; }

################################################################################
# ZFS pool name (global — used by cleanup trap)
################################################################################
POOL_NAME="rpool"

################################################################################
# Cleanup trap — unmounts everything and exports pool on EXIT
################################################################################
CLEANUP_DONE=0
cleanup() {
    [[ "$CLEANUP_DONE" == "1" ]] && return
    log_warning "Running cleanup (may be due to error)..."
    umount -R /mnt/dev  2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true
    umount -R /mnt/sys  2>/dev/null || true
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt/boot     2>/dev/null || true
    zfs umount -a        2>/dev/null || true
    zpool export "$POOL_NAME" 2>/dev/null || true
}
trap cleanup EXIT

################################################################################
# Root check
################################################################################
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use: sudo bash $0)"
    exit 1
fi

################################################################################
# Banner
################################################################################
clear
echo ""
echo "==========================================================================="
echo "  Ubuntu 24.04 — Encrypted ZFS on Root with EXT4 /boot"
echo "  ZFS Cleanup · IPv6 Disable · Initial Snapshots"
echo "  Disk identified by /dev/disk/by-id/ for reliability"
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
# Shows an inputbox; prints the entered value to stdout. Exits on Cancel.
ask_input() {
    local title="$1" prompt="$2" default="${3:-}"
    local result
    result=$(whiptail \
        --title     "$title" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        --inputbox  "$prompt" 10 60 "$default" \
        3>&1 1>&2 2>&3) || { log_info "Cancelled."; exit 0; }
    echo "$result"
}

# ask_password <title> <prompt>
# Shows a passwordbox; prints the entered value to stdout. Exits on Cancel.
ask_password() {
    local title="$1" prompt="$2"
    whiptail \
        --title        "$title" \
        --backtitle    "Ubuntu 24.04 Encrypted ZFS Installer" \
        --passwordbox  "$prompt" 10 60 \
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
# ZFS pool cleanup (if existing pools are found)
################################################################################
log_step "Checking for existing ZFS pools..."
EXISTING_POOLS=$(zpool list -H -o name 2>/dev/null || true)

if [[ -n "$EXISTING_POOLS" ]]; then
    log_warning "Found existing ZFS pools:"
    zpool list
    echo ""

    if ask_yesno "Existing ZFS Pools" \
"The following ZFS pools already exist and must be destroyed before installation:

$(echo "$EXISTING_POOLS" | sed 's/^/  /')

Do you want to DESTROY ALL existing ZFS pools?" \
"true"; then
        log_info "Destroying existing ZFS pools..."
        for pool in $EXISTING_POOLS; do
            log_info "Unmounting and destroying pool: $pool"
            zfs unmount -a      2>/dev/null || true
            zpool export -f "$pool" 2>/dev/null || true
            zpool destroy -f "$pool" 2>/dev/null || true
            log_success "Pool $pool destroyed"
        done
        log_success "All existing ZFS pools destroyed"
    else
        log_error "Cannot proceed with existing ZFS pools."
        log_info  "Destroy them manually: zpool destroy -f <pool_name>"
        exit 1
    fi
else
    log_success "No existing ZFS pools found"
fi

# Allow udev to settle after pool operations
sleep 2

################################################################################
# Disk selection — whiptail menu
################################################################################
log_step "Discovering disks for selection..."

select_disk_dialog() {
    local menu_items=()
    local dev devname size model byid tag label

    while IFS= read -r dev; do
        devname=$(basename "$dev")
        size=$(lsblk  -dn -o SIZE  "$dev" 2>/dev/null | xargs || echo "?")
        model=$(lsblk -dn -o MODEL "$dev" 2>/dev/null | xargs || echo "")

        # Prefer by-id; keep ata/nvme/scsi/usb, skip wwn/dm and partition entries
        byid=$(ls -l /dev/disk/by-id/ 2>/dev/null \
            | grep -v "part" \
            | grep -E "(ata|nvme|scsi|usb)-" \
            | grep " ${devname}$" \
            | head -1 \
            | awk '{print "/dev/disk/by-id/" $9}') || true

        tag="${byid:-$dev}"

        if [[ -n "$model" ]]; then
            label=$(printf "%-12s  %-8s  %s" "/dev/$devname" "$size" "$model")
        else
            label=$(printf "%-12s  %-8s" "/dev/$devname" "$size")
        fi

        menu_items+=("$tag" "$label")
    done < <(lsblk -dn -p -o NAME \
        | grep -E "/dev/(sd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]|hd[a-z])")

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        log_error "No suitable disks found!"
        exit 1
    fi

    whiptail \
        --title     "Disk Selection" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        --menu \
"Select the TARGET disk.

WARNING: ALL DATA WILL BE PERMANENTLY DESTROYED!

Internal path: /dev/disk/by-id/...
Display:       /dev/sda  SIZE  MODEL" \
        22 78 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3
}

DISK_BY_ID=$(select_disk_dialog) || {
    log_info "Disk selection cancelled."
    exit 0
}

# Resolve canonical device node from whatever tag was returned
if [[ "$DISK_BY_ID" == /dev/disk/by-id/* ]]; then
    DISK=$(readlink -f "$DISK_BY_ID")
else
    DISK="$DISK_BY_ID"
fi

if [[ ! -b "$DISK" ]]; then
    log_error "Disk '$DISK' is not a valid block device!"
    exit 1
fi

log_info "Selected disk:   $DISK"
log_info "Disk identifier: $DISK_BY_ID"

if ! ask_yesno "CONFIRM DESTRUCTIVE OPERATION" \
"ALL DATA ON THE FOLLOWING DISK WILL BE PERMANENTLY DESTROYED:

  $DISK
  ($DISK_BY_ID)

This operation CANNOT be undone!

Are you absolutely sure you want to continue?" \
"true"; then
    log_info "Installation cancelled."
    exit 0
fi

################################################################################
# User configuration prompts
################################################################################

HOSTNAME=$(ask_input "System Configuration" \
    "Enter hostname for the new system:" "ubuntu-zfs")
[[ -z "$HOSTNAME" ]] && { log_error "Hostname cannot be empty!"; exit 1; }

USERNAME=$(ask_input "System Configuration" \
    "Enter username for the new user:" "")
[[ -z "$USERNAME" ]] && { log_error "Username cannot be empty!"; exit 1; }

while true; do
    USER_PASSWORD=$(ask_password "User Password" \
        "Enter password for '$USERNAME':")
    USER_PASSWORD_CONFIRM=$(ask_password "User Password" \
        "Confirm password for '$USERNAME':")
    if [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]]; then
        break
    fi
    whiptail --title "Error" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        --msgbox "Passwords do not match. Please try again." 8 50
done

while true; do
    ZFS_PASSPHRASE=$(ask_password "ZFS Encryption" \
        "Enter ZFS encryption passphrase:")
    ZFS_PASSPHRASE_CONFIRM=$(ask_password "ZFS Encryption" \
        "Confirm ZFS encryption passphrase:")
    if [[ "$ZFS_PASSPHRASE" == "$ZFS_PASSPHRASE_CONFIRM" ]]; then
        break
    fi
    whiptail --title "Error" \
        --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
        --msgbox "Passphrases do not match. Please try again." 8 50
done

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

if ask_yesno "ZFS Options" "Create a ZFS swap volume (4 GB)?"; then
    CREATE_SWAP="yes"
else
    CREATE_SWAP="no"
fi

TIMEZONE=$(ask_input "System Configuration" \
    "Enter timezone (e.g. Europe/Budapest, America/New_York, UTC):" "UTC")
TIMEZONE="${TIMEZONE:-UTC}"

################################################################################
# Boot mode detection
################################################################################
if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="UEFI"
    log_info "Detected boot mode: UEFI"
else
    BOOT_MODE="BIOS"
    log_info "Detected boot mode: BIOS (Legacy)"
fi

################################################################################
# Step 1: Install ZFS utilities
################################################################################
log_step "Step 1: Installing ZFS utilities..."
apt-get update -qq
apt-get install -y debootstrap gdisk zfsutils-linux
log_success "ZFS utilities installed"

################################################################################
# Step 2: Partition the disk
################################################################################
log_step "Step 2: Partitioning disk $DISK..."

# nvme and mmcblk devices use a "p" suffix before the partition number
if [[ "$DISK" =~ nvme|mmcblk ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi

sgdisk --zap-all "$DISK"

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    sgdisk -n1:1M:+512M  -t1:EF00 "$DISK"   # EFI System Partition (512 MB FAT32)
    sgdisk -n2:0:+2G     -t2:8300 "$DISK"   # /boot (2 GB ext4)
    sgdisk -n3:0:0       -t3:BF00 "$DISK"   # ZFS root pool (remaining space)
    EFI_PART="${PART_PREFIX}1"
    BOOT_PART="${PART_PREFIX}2"
    ROOT_PART="${PART_PREFIX}3"
else
    sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$DISK"  # BIOS boot partition (1 MB)
    sgdisk     -n2:0:+2G      -t2:8300 "$DISK"  # /boot (2 GB ext4)
    sgdisk     -n3:0:0        -t3:BF00 "$DISK"  # ZFS root pool (remaining space)
    BIOS_PART="${PART_PREFIX}1"
    BOOT_PART="${PART_PREFIX}2"
    ROOT_PART="${PART_PREFIX}3"
fi

sgdisk -p "$DISK"
sleep 2
partprobe "$DISK"
sleep 2

# Resolve partition by-id paths (fall back to /dev/sdXN if symlinks not ready)
log_info "Discovering partition identifiers..."
if [[ "$DISK_BY_ID" == /dev/disk/by-id/* ]]; then
    BOOT_PART_BY_ID="${DISK_BY_ID}-part2"
    ROOT_PART_BY_ID="${DISK_BY_ID}-part3"
    [[ "$BOOT_MODE" == "UEFI" ]] && EFI_PART_BY_ID="${DISK_BY_ID}-part1"

    if [[ ! -b "$ROOT_PART_BY_ID" ]]; then
        log_warning "by-id path not found for root partition, falling back to $ROOT_PART"
        ROOT_PART_BY_ID="$ROOT_PART"
    fi
    if [[ ! -b "$BOOT_PART_BY_ID" ]]; then
        log_warning "by-id path not found for boot partition, falling back to $BOOT_PART"
        BOOT_PART_BY_ID="$BOOT_PART"
    fi
else
    ROOT_PART_BY_ID="$ROOT_PART"
    BOOT_PART_BY_ID="$BOOT_PART"
    [[ "$BOOT_MODE" == "UEFI" ]] && EFI_PART_BY_ID="${EFI_PART}"
fi

log_info "Boot partition: $BOOT_PART_BY_ID"
log_info "Root partition: $ROOT_PART_BY_ID"
log_success "Disk partitioned"

################################################################################
# Step 3: Format /boot partition (ext4)
################################################################################
log_step "Step 3: Formatting /boot partition as ext4..."
mkfs.ext4 -F -L boot "$BOOT_PART"
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
log_info "Boot partition UUID: $BOOT_UUID"
log_success "/boot partition formatted"

################################################################################
# Step 4: Create encrypted ZFS root pool
################################################################################
log_step "Step 4: Creating encrypted ZFS root pool ($POOL_NAME)..."
log_info "Device: $ROOT_PART_BY_ID"

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
    "$POOL_NAME" "$ROOT_PART_BY_ID" -f

zpool list "$POOL_NAME" >/dev/null 2>&1 || {
    log_error "Failed to create ZFS pool $POOL_NAME"
    exit 1
}
log_success "Encrypted root pool created"

################################################################################
# Step 5: Create ZFS datasets
################################################################################
log_step "Step 5: Creating ZFS datasets..."

zfs create -o canmount=off    -o mountpoint=none             "$POOL_NAME/ROOT"
zfs create -o canmount=noauto -o mountpoint=/                "$POOL_NAME/ROOT/ubuntu"
zfs mount "$POOL_NAME/ROOT/ubuntu"

zfs create -o mountpoint=/home                               "$POOL_NAME/home"
zfs create -o mountpoint=/root                               "$POOL_NAME/home/root"
chmod 700 /mnt/root

zfs create -o canmount=off -o mountpoint=/var                "$POOL_NAME/var"
zfs create -o mountpoint=/var/log                            "$POOL_NAME/var/log"
zfs create -o mountpoint=/var/spool                          "$POOL_NAME/var/spool"
zfs create -o mountpoint=/var/tmp                            "$POOL_NAME/var/tmp"
zfs create -o com.sun:auto-snapshot=false \
           -o mountpoint=/var/cache                          "$POOL_NAME/var/cache"
zfs create -o mountpoint=/var/lib                            "$POOL_NAME/var/lib"
zfs create -o com.sun:auto-snapshot=false \
           -o mountpoint=/var/lib/docker                     "$POOL_NAME/var/lib/docker"
zfs create -o com.sun:auto-snapshot=false \
           -o mountpoint=/var/lib/nfs                        "$POOL_NAME/var/lib/nfs"
zfs create -o com.sun:auto-snapshot=false \
           -o mountpoint=/tmp                                "$POOL_NAME/tmp"
chmod 1777 /mnt/var/tmp /mnt/tmp

# Optional swap ZVOL
if [[ "$CREATE_SWAP" == "yes" ]]; then
    log_info "Creating 4 GB swap ZVOL..."
    zfs create \
        -V 4G \
        -b "$(getconf PAGESIZE)" \
        -o compression=zle \
        -o logbias=throughput \
        -o sync=always \
        -o primarycache=metadata \
        -o secondarycache=none \
        "$POOL_NAME/swap"
    mkswap -f "/dev/zvol/$POOL_NAME/swap"
    log_success "Swap ZVOL created"
fi

log_success "ZFS datasets created"

################################################################################
# Step 6: Mount /boot partition
################################################################################
log_step "Step 6: Mounting /boot partition..."
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot
log_success "/boot mounted"

################################################################################
# Step 7: Format and mount EFI partition (UEFI only)
################################################################################
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    log_step "Step 7: Formatting and mounting EFI partition..."
    mkfs.vfat -F32 "$EFI_PART"
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    log_info "EFI partition UUID: $EFI_UUID"
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
    log_success "EFI partition formatted and mounted"
else
    log_step "Step 7: BIOS mode — EFI partition not needed, skipping"
    EFI_UUID=""
    EFI_PART_BY_ID=""
fi

################################################################################
# Step 8: Install Ubuntu base system via debootstrap
################################################################################
log_step "Step 8: Installing Ubuntu base system (this may take several minutes)..."
debootstrap \
    --mirror=http://archive.ubuntu.com/ubuntu \
    noble /mnt
log_success "Base system installed"

################################################################################
# Step 9: Pre-chroot system configuration
################################################################################
log_step "Step 9: Configuring system (pre-chroot)..."

echo "$HOSTNAME" > /mnt/etc/hostname

cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

mkdir -p /mnt/etc/netplan
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

# Write APT sources — do NOT copy from live USB
cat > /mnt/etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF

# Disable IPv6 system-wide
cat > /mnt/etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# /etc/fstab using UUIDs
cat > /mnt/etc/fstab <<EOF
# <file system>                         <mount>     <type>  <options>     <dump> <pass>
UUID=$BOOT_UUID                         /boot       ext4    defaults      0      2
EOF

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    cat >> /mnt/etc/fstab <<EOF
UUID=$EFI_UUID                          /boot/efi   vfat    umask=0077    0      1
EOF
fi

if [[ "$CREATE_SWAP" == "yes" ]]; then
    cat >> /mnt/etc/fstab <<EOF
/dev/zvol/$POOL_NAME/swap               none        swap    discard       0      0
EOF
fi

log_success "Pre-chroot configuration complete"

# Bind-mount kernel virtual filesystems for chroot
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys

################################################################################
# Step 10: Chroot — install kernel, ZFS, bootloader
################################################################################
log_step "Step 10: Installing packages in chroot..."

# Install kernel first so initramfs picks up ZFS modules later
chroot /mnt /bin/bash -e <<CHROOT_KERNEL
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y linux-image-generic linux-headers-generic
CHROOT_KERNEL

# Determine GRUB package for boot mode
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    GRUB_PKG="grub-efi-amd64 grub-efi-amd64-signed shim-signed"
else
    GRUB_PKG="grub-pc"
fi

chroot /mnt /bin/bash -e <<CHROOT_PACKAGES
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y \
    zfs-initramfs \
    $GRUB_PKG \
    openssh-server \
    dosfstools \
    nano \
    wget \
    curl \
    mc
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

log_success "Package installation complete"

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
################################################################################
log_step "Step 12: Configuring bootloader..."

chroot /mnt zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"
chroot /mnt update-initramfs -c -k all

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    chroot /mnt grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=ubuntu \
        --recheck
else
    chroot /mnt grub-install "$DISK"
fi

chroot /mnt update-grub
log_success "Bootloader installed"

################################################################################
# Step 13: Enable ZFS services
################################################################################
log_step "Step 13: Enabling ZFS services..."
chroot /mnt systemctl enable zfs-import-cache
chroot /mnt systemctl enable zfs-mount
chroot /mnt systemctl enable zfs.target
[[ "$CREATE_SWAP" == "yes" ]] && chroot /mnt systemctl enable swap.target || true
log_success "ZFS services enabled"

################################################################################
# Step 14: Create initial installation snapshots
################################################################################
log_step "Step 14: Creating initial installation snapshots..."
SNAPSHOT_DATE=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_NAME="initial-install-${SNAPSHOT_DATE}"
zfs snapshot -r "${POOL_NAME}@${SNAPSHOT_NAME}"
log_success "Created snapshot: ${POOL_NAME}@${SNAPSHOT_NAME}"
zfs list -t snapshot -r "$POOL_NAME" | grep "$SNAPSHOT_NAME"

################################################################################
# Step 15: Save disk configuration for post-boot reference
################################################################################
log_step "Step 15: Saving disk configuration to /root/DISK_INFO.txt..."
{
    echo "# Disk Configuration — generated $(date)"
    echo ""
    echo "Installation Disk:          $DISK"
    echo "Disk by-id:                 $DISK_BY_ID"
    echo ""
    echo "Boot Partition:             $BOOT_PART"
    echo "Boot Partition by-id:       $BOOT_PART_BY_ID"
    echo "Boot Partition UUID:        $BOOT_UUID"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        echo ""
        echo "EFI Partition:              $EFI_PART"
        echo "EFI Partition by-id:        $EFI_PART_BY_ID"
        echo "EFI Partition UUID:         $EFI_UUID"
    fi
    echo ""
    echo "Root Pool Partition:        $ROOT_PART"
    echo "Root Pool Partition by-id:  $ROOT_PART_BY_ID"
    echo "ZFS Pool Name:              $POOL_NAME"
    echo ""
    echo "# Useful commands"
    echo "zpool status $POOL_NAME"
    echo "zpool list -v $POOL_NAME"
    echo "zpool status -P $POOL_NAME"
    echo ""
    echo "# Re-import pool by-id"
    echo "zpool export $POOL_NAME"
    echo "zpool import -d /dev/disk/by-id $POOL_NAME"
} > /mnt/root/DISK_INFO.txt
log_success "Configuration saved to /root/DISK_INFO.txt"

################################################################################
# Step 16: Cleanup and unmount
################################################################################
log_step "Step 16: Unmounting filesystems and exporting pool..."
CLEANUP_DONE=1  # Prevent the trap from running a second cleanup

umount -R /mnt/dev  || true
umount -R /mnt/proc || true
umount -R /mnt/sys  || true

[[ "$BOOT_MODE" == "UEFI" ]] && umount /mnt/boot/efi || true
umount /mnt/boot || true

zfs umount -a
zpool export "$POOL_NAME"
log_success "Pool exported — installation complete!"

################################################################################
# Summary
################################################################################
echo ""
echo "==========================================================================="
echo "  Installation Complete!"
echo "==========================================================================="
echo ""
echo "Installed system:"
echo "  Hostname     : $HOSTNAME"
echo "  Username     : $USERNAME"
echo "  Timezone     : $TIMEZONE"
echo "  ZFS pool     : $POOL_NAME  (AES-256-GCM encrypted)"
echo "  Compression  : $COMPRESSION_OPT"
echo "  Swap volume  : $CREATE_SWAP"
echo ""
echo "Disk layout:"
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    echo "  $EFI_PART   (UUID: $EFI_UUID) — EFI 512 MB FAT32"
fi
echo "  $BOOT_PART   (UUID: $BOOT_UUID) — /boot 2 GB ext4"
echo "  $ROOT_PART   — ZFS encrypted root ($POOL_NAME)"
echo ""
echo "IMPORTANT: Keep your ZFS passphrase safe — it cannot be recovered!"
echo ""
echo "Next steps after reboot:"
echo "  1. Remove installation media"
echo "  2. Reboot — enter your ZFS passphrase at the boot prompt"
echo "  3. Log in as $USERNAME"
echo "  4. sudo apt update && sudo apt upgrade"
echo "  5. cat /root/DISK_INFO.txt   # full disk configuration"
echo ""
echo "==========================================================================="
echo ""

whiptail \
    --title     "Installation Complete" \
    --backtitle "Ubuntu 24.04 Encrypted ZFS Installer" \
    --yesno \
"Installation finished successfully!

  Hostname : $HOSTNAME
  User     : $USERNAME
  ZFS pool : $POOL_NAME (AES-256-GCM)

Remove the installation media, then reboot.
Enter your ZFS passphrase at the boot prompt.

Reboot now?" \
    15 60 || exit 0

reboot
