#!/bin/bash
################################################################################
# Ubuntu 24.04 Encrypted ZFS on Root with EXT4 Boot Installation Script
# Uses disk by-id and partition UUIDs for reliability
################################################################################
# Automates Ubuntu 24.04 installation with native ZFS encryption on root
# and a traditional EXT4 /boot partition.
#
# WARNING: This script will DESTROY all data on the target disk!
#
# Prerequisites:
#   - Boot from Ubuntu 24.04 Live USB
#   - Run as root (sudo bash install-ubuntu-zfs-encrypted-ext4boot.sh)
#   - Internet connection required
################################################################################

set -e          # Exit on error
set -u          # Treat unset variables as errors
set -o pipefail # Catch failures in pipelines

# ------------------------------------------------------------------------------
# Color codes and logging
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'   # Fix: was missing, caused unbound variable with set -u
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $1"; }

# ------------------------------------------------------------------------------
# Cleanup trap — runs on EXIT to leave the system in a clean state
# ------------------------------------------------------------------------------
POOL_NAME="rpool"
cleanup() {
    if [[ "${CLEANUP_DONE:-0}" == "1" ]]; then
        return
    fi
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

# ------------------------------------------------------------------------------
# Root check
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

################################################################################
# Banner
################################################################################
echo ""
echo "==========================================================================="
echo "  Ubuntu 24.04 ZFS Encrypted Root with EXT4 Boot Installation"
echo "  Disk IDs and UUIDs for reliability"
echo "  Features: ZFS Cleanup + IPv6 Disable + Snapshots"
echo "==========================================================================="
echo ""

################################################################################
# ZFS pool cleanup
################################################################################
log_step "Checking for existing ZFS pools..."
EXISTING_POOLS=$(zpool list -H -o name 2>/dev/null || true)

if [[ -n "$EXISTING_POOLS" ]]; then
    log_warning "Found existing ZFS pools:"
    zpool list
    echo ""
    log_warning "These pools will be DESTROYED: $EXISTING_POOLS"
    echo ""
    read -rp "Do you want to destroy ALL existing ZFS pools? (yes/no): " DESTROY_POOLS

    if [[ "$DESTROY_POOLS" == "yes" ]]; then
        log_info "Destroying existing ZFS pools..."
        for pool in $EXISTING_POOLS; do
            log_info "Unmounting and destroying pool: $pool"
            zfs unmount -a 2>/dev/null || true
            zpool export -f "$pool" 2>/dev/null || true
            zpool destroy -f "$pool" 2>/dev/null || true
            log_success "Pool $pool destroyed"
        done
        log_success "All existing ZFS pools destroyed"
    else
        log_error "Cannot proceed with existing ZFS pools. Destroy them manually first."
        log_info "Command: zpool destroy -f <pool_name>"
        exit 1
    fi
else
    log_success "No existing ZFS pools found"
fi

# Clean up any leftover ZFS labels
log_info "Cleaning up ZFS labels..."
sleep 2

################################################################################
# Disk selection
################################################################################
log_info "Available disks (by-id):"
echo ""
ls -lh /dev/disk/by-id/ | grep -v "part" | grep -v "total" \
    | awk '{print $9, "->", $11}' \
    | grep -E "ata|nvme|scsi|usb" | sort
echo ""
log_info "Available disks (traditional names):"
lsblk -d -n -p -o NAME,SIZE,MODEL | grep -E "sd|nvme|vd"
echo ""
log_warning "Using disk by-id paths is strongly recommended for reliability"
echo "Example: /dev/disk/by-id/ata-Samsung_SSD_850_PRO_512GB_S1234567"
echo "Or use traditional names: /dev/sda, /dev/nvme0n1"
echo ""
read -rp "Enter the target disk: " DISK_INPUT

# Resolve disk path
if [[ "$DISK_INPUT" == /dev/disk/by-id/* ]]; then
    DISK_BY_ID="$DISK_INPUT"
    DISK=$(readlink -f "$DISK_BY_ID")
    log_info "Using disk by-id: $DISK_BY_ID"
    log_info "Resolves to: $DISK"
elif [[ -b "$DISK_INPUT" ]]; then
    DISK="$DISK_INPUT"
    DISK_BY_ID=$(ls -l /dev/disk/by-id/ \
        | grep "$(basename "$DISK")$" \
        | grep -v "part" | head -1 \
        | awk '{print "/dev/disk/by-id/" $9}') || true
    if [[ -n "$DISK_BY_ID" ]]; then
        log_info "Found by-id path: $DISK_BY_ID"
        log_info "Device path: $DISK"
    else
        log_warning "Could not find by-id path, using device path: $DISK"
        DISK_BY_ID="$DISK"
    fi
else
    log_error "Disk '$DISK_INPUT' does not exist or is not a block device!"
    exit 1
fi

if [[ ! -b "$DISK" ]]; then
    log_error "Disk $DISK does not exist!"
    exit 1
fi

echo ""
log_warning "ALL DATA ON $DISK WILL BE PERMANENTLY DESTROYED!"
read -rp "Are you sure you want to continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    log_info "Installation cancelled."
    exit 0
fi

################################################################################
# User configuration prompts
################################################################################
echo ""
read -rp  "Enter hostname for the new system: "     HOSTNAME
read -rp  "Enter username for the new user: "       USERNAME
read -rsp "Enter password for $USERNAME: "          USER_PASSWORD; echo ""
read -rsp "Confirm password for $USERNAME: "        USER_PASSWORD_CONFIRM; echo ""
if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
    log_error "Passwords do not match!"
    exit 1
fi

read -rsp "Enter ZFS encryption passphrase: "       ZFS_PASSPHRASE; echo ""
read -rsp "Confirm ZFS encryption passphrase: "     ZFS_PASSPHRASE_CONFIRM; echo ""
if [[ "$ZFS_PASSPHRASE" != "$ZFS_PASSPHRASE_CONFIRM" ]]; then
    log_error "Passphrases do not match!"
    exit 1
fi

################################################################################
# Optional features
################################################################################
echo ""
log_info "ZFS Performance Options:"
read -rp "Enable ZFS compression (lz4)? (yes/no, default: yes): " ENABLE_COMPRESSION
ENABLE_COMPRESSION="${ENABLE_COMPRESSION:-yes}"
COMPRESSION_OPT="off"
[[ "$ENABLE_COMPRESSION" == "yes" ]] && COMPRESSION_OPT="lz4"

echo ""
read -rp "Create a ZFS swap volume (4GB)? (yes/no, default: no): " CREATE_SWAP
CREATE_SWAP="${CREATE_SWAP:-no}"

echo ""
read -rp "Enter timezone (e.g. Europe/Budapest, UTC) [default: UTC]: " TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"

################################################################################
# Boot mode detection
################################################################################
if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="UEFI"
    log_info "Detected UEFI boot mode"
else
    BOOT_MODE="BIOS"
    log_info "Detected BIOS boot mode"
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

# Determine partition naming scheme (nvme/mmcblk use "p" suffix)
if [[ "$DISK" =~ nvme|mmcblk ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi

sgdisk --zap-all "$DISK"

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    sgdisk -n1:1M:+512M -t1:EF00 "$DISK"   # EFI System Partition
    sgdisk -n2:0:+2G    -t2:8300 "$DISK"   # /boot (ext4)
    sgdisk -n3:0:0      -t3:BF00 "$DISK"   # ZFS root pool
    EFI_PART="${PART_PREFIX}1"
    BOOT_PART="${PART_PREFIX}2"
    ROOT_PART="${PART_PREFIX}3"
else
    sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$DISK"  # BIOS boot
    sgdisk -n2:0:+2G          -t2:8300 "$DISK"  # /boot (ext4)
    sgdisk -n3:0:0            -t3:BF00 "$DISK"  # ZFS root pool
    BIOS_PART="${PART_PREFIX}1"
    BOOT_PART="${PART_PREFIX}2"
    ROOT_PART="${PART_PREFIX}3"
fi

sgdisk -p "$DISK"
sleep 2
partprobe "$DISK"
sleep 2

# Resolve partition by-id paths
log_info "Discovering partition identifiers..."
if [[ "$DISK_BY_ID" == /dev/disk/by-id/* ]]; then
    BOOT_PART_BY_ID="${DISK_BY_ID}-part2"
    ROOT_PART_BY_ID="${DISK_BY_ID}-part3"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        EFI_PART_BY_ID="${DISK_BY_ID}-part1"
    fi

    # Fall back to device path if by-id symlinks aren't present yet
    if [[ ! -b "$ROOT_PART_BY_ID" ]]; then
        log_warning "by-id path for root partition not found, using $ROOT_PART"
        ROOT_PART_BY_ID="$ROOT_PART"
    fi
    if [[ ! -b "$BOOT_PART_BY_ID" ]]; then
        log_warning "by-id path for boot partition not found, using $BOOT_PART"
        BOOT_PART_BY_ID="$BOOT_PART"
    fi
else
    ROOT_PART_BY_ID="$ROOT_PART"
    BOOT_PART_BY_ID="$BOOT_PART"
    [[ "$BOOT_MODE" == "UEFI" ]] && EFI_PART_BY_ID="$EFI_PART"
fi

log_info "Root partition: $ROOT_PART_BY_ID"
log_info "Boot partition: $BOOT_PART_BY_ID"
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

# Verify pool was created
zpool list "$POOL_NAME" >/dev/null 2>&1 || {
    log_error "Failed to create pool $POOL_NAME"
    exit 1
}
log_success "Encrypted root pool created"

################################################################################
# Step 5: Create ZFS datasets
################################################################################
log_step "Step 5: Creating ZFS datasets..."

zfs create -o canmount=off  -o mountpoint=none "$POOL_NAME/ROOT"
zfs create -o canmount=noauto -o mountpoint=/ "$POOL_NAME/ROOT/ubuntu"
zfs mount "$POOL_NAME/ROOT/ubuntu"

zfs create -o mountpoint=/home                                    "$POOL_NAME/home"
zfs create -o mountpoint=/root                                    "$POOL_NAME/home/root"
chmod 700 /mnt/root

zfs create -o canmount=off -o mountpoint=/var                     "$POOL_NAME/var"
zfs create -o mountpoint=/var/log                                 "$POOL_NAME/var/log"
zfs create -o mountpoint=/var/spool                               "$POOL_NAME/var/spool"
zfs create -o mountpoint=/var/tmp                                 "$POOL_NAME/var/tmp"
zfs create -o com.sun:auto-snapshot=false  -o mountpoint=/var/cache "$POOL_NAME/var/cache"
# Fix: was mistakenly set to mountpoint=/var/log; correct mountpoint is /var/lib
zfs create -o mountpoint=/var/lib                                 "$POOL_NAME/var/lib"
zfs create -o com.sun:auto-snapshot=false  -o mountpoint=/var/lib/docker "$POOL_NAME/var/lib/docker"
zfs create -o com.sun:auto-snapshot=false  -o mountpoint=/var/lib/nfs    "$POOL_NAME/var/lib/nfs"
zfs create -o com.sun:auto-snapshot=false  -o mountpoint=/tmp            "$POOL_NAME/tmp"

chmod 1777 /mnt/var/tmp /mnt/tmp

# Optional swap ZVOL
if [[ "$CREATE_SWAP" == "yes" ]]; then
    log_info "Creating 4GB swap ZVOL..."
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
    log_step "Step 7: Formatting EFI partition..."
    mkfs.vfat -F32 "$EFI_PART"
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    log_info "EFI partition UUID: $EFI_UUID"
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
    log_success "EFI partition formatted and mounted"
else
    log_step "Step 7: BIOS mode — skipping EFI partition"
fi

################################################################################
# Step 8: Install Ubuntu base system
################################################################################
log_step "Step 8: Installing Ubuntu base system via debootstrap (may take a while)..."
debootstrap \
    --mirror=http://archive.ubuntu.com/ubuntu \
    noble /mnt
log_success "Base system installed"

################################################################################
# Step 9: Pre-chroot system configuration
################################################################################
log_step "Step 9: Configuring system (pre-chroot)..."

# Hostname
echo "$HOSTNAME" > /mnt/etc/hostname

# /etc/hosts
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Network (basic networkd/netplan config)
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

# APT sources — write fresh; do NOT copy live-USB sources
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
# /etc/fstab
# UUID=... /boot ext4 defaults 0 2
UUID=$BOOT_UUID /boot ext4 defaults 0 2
EOF

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    cat >> /mnt/etc/fstab <<EOF
UUID=$EFI_UUID /boot/efi vfat umask=0077 0 1
EOF
fi

if [[ "$CREATE_SWAP" == "yes" ]]; then
    cat >> /mnt/etc/fstab <<EOF
/dev/zvol/$POOL_NAME/swap none swap discard 0 0
EOF
fi

log_success "Pre-chroot configuration complete"

# Bind-mount kernel filesystems for chroot
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys

################################################################################
# Step 10: Chroot — install kernel, ZFS, bootloader packages
################################################################################
log_step "Step 10: Installing packages in chroot..."

# Install kernel first (separate step — ensures kernel is present before ZFS initramfs)
chroot /mnt /bin/bash -e <<CHROOT_KERNEL
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y linux-image-generic linux-headers-generic
CHROOT_KERNEL

# Install ZFS + bootloader + utilities
# Fix: install grub-pc for BIOS, grub-efi-amd64 for UEFI
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

# Locale and timezone
chroot /mnt /bin/bash -e <<CHROOT_LOCALE
set -e
export DEBIAN_FRONTEND=noninteractive
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
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

# Cache ZFS pool config
chroot /mnt zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"

# Rebuild initramfs with ZFS support
chroot /mnt update-initramfs -c -k all

# Install GRUB
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
# Step 14: Create initial snapshots
################################################################################
log_step "Step 14: Creating initial installation snapshots..."
SNAPSHOT_DATE=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_NAME="initial-install-${SNAPSHOT_DATE}"
zfs snapshot -r "${POOL_NAME}@${SNAPSHOT_NAME}"
log_success "Created snapshot: ${POOL_NAME}@${SNAPSHOT_NAME}"
zfs list -t snapshot -r "$POOL_NAME" | grep "$SNAPSHOT_NAME"

################################################################################
# Step 15: Save disk configuration info for post-boot reference
################################################################################
log_step "Step 15: Saving disk configuration to /root/DISK_INFO.txt..."
{
    echo "# Disk Configuration — generated $(date)"
    echo ""
    echo "Installation Disk:       $DISK"
    echo "Disk by-id:              $DISK_BY_ID"
    echo "Boot Partition:          $BOOT_PART"
    echo "Boot Partition UUID:     $BOOT_UUID"
    echo "Boot Partition by-id:    $BOOT_PART_BY_ID"
    echo "Root Pool Partition:     $ROOT_PART"
    echo "Root Pool Partition by-id: $ROOT_PART_BY_ID"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        echo "EFI Partition:           $EFI_PART"
        echo "EFI Partition UUID:      $EFI_UUID"
        echo "EFI Partition by-id:     $EFI_PART_BY_ID"
    fi
    echo "ZFS Pool Name:           $POOL_NAME"
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
CLEANUP_DONE=1  # Tell trap handler we already cleaned up

umount -R /mnt/dev  || true
umount -R /mnt/proc || true
umount -R /mnt/sys  || true

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    umount /mnt/boot/efi || true
fi
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
    echo "  $EFI_PART  (UUID: $EFI_UUID) — EFI 512 MB FAT32"
fi
echo "  $BOOT_PART  (UUID: $BOOT_UUID) — /boot 2 GB ext4"
echo "  $ROOT_PART  — ZFS encrypted root ($POOL_NAME)"
echo ""
echo "IMPORTANT: Keep your ZFS passphrase safe — it cannot be recovered!"
echo ""
echo "Next steps after reboot:"
echo "  1. Remove installation media and reboot"
echo "  2. Enter your ZFS passphrase at the boot prompt"
echo "  3. Log in as $USERNAME"
echo "  4. sudo apt update && sudo apt upgrade"
echo "  5. cat /root/DISK_INFO.txt   # full disk info"
echo ""
echo "==========================================================================="
echo ""
read -rp "Press Enter to reboot or Ctrl-C to stay in live environment..."
reboot
