#!/bin/bash
# ZFS_AllIn — Ubuntu ZFS on Root Installer
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
# Ubuntu ZFS on Root — all-in-one installer
#
# Supports: noble (24.04), resolute (26.04), jammy (22.04)
# Topologies: single, mirror, raid0, raidz1, raidz2, raidz3
# Encryption: NOENC, ZFSENC (native), LUKS (whole-disk)
# Boot: UEFI (GRUB + efibootmgr) and BIOS
# Extras: Dropbear SSH unlock, Sanoid snapshots, APT snapshot hook,
#         Google Authenticator TOTP, zrepl, optional data pool
#
# Usage:
#   sudo bash ubuntu-zfs-root.sh initial       # fresh install from Live USB
#   sudo bash ubuntu-zfs-root.sh postreboot    # run after first login
#   sudo bash ubuntu-zfs-root.sh remoteaccess  # setup Dropbear initramfs SSH
#   sudo bash ubuntu-zfs-root.sh datapool      # create optional data pool
#
# Debug: DEBUG=1 sudo bash ubuntu-zfs-root.sh initial
################################################################################

[[ "${DEBUG:-0}" == "1" ]] && set -x

set -euo pipefail

###############################################################################
# Metadata
###############################################################################
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly BACKTITLE="Ubuntu ZFS AllIn Installer v${SCRIPT_VERSION}"
CONFIG_FILE="${CONFIG:-./ZFS-root.conf}"
LOGDIR="/var/log/zfs-allin"
LOGFILE=""

###############################################################################
# Default configuration values (override in ZFS-root.conf)
###############################################################################
WIPE_FRESH="y"
USERNAME="ubuntu"
UCOMMENT="Ubuntu User"
UPASSWORD=""
MYHOSTNAME="ubuntu-zfs"
POOLNAME="rpool"
SUITE="noble"
RAIDLEVEL="single"
SIZE_SWAP=3000
DISCENC="NOENC"
PASSPHRASE=""
DROPBEAR="n"
RESCUE="y"
GOOGLE="n"
HWE="y"
ZREPL="n"
NVIDIA="none"
NECESSARY_PACKAGES="mc openssh-server"
SSHPUBKEY=""
HOST_ECDSA_KEY=""
HOST_ECDSA_KEY_PUB=""
HOST_RSA_KEY=""
HOST_RSA_KEY_PUB=""
HOST_ED25519_KEY=""
HOST_ED25519_KEY_PUB=""
NET_MODE="dhcp"
NET_IP=""
NET_GW=""
NET_DNS="8.8.8.8,1.1.1.1"
TIMEZONE="UTC"

###############################################################################
# Runtime state (do not set these in config)
###############################################################################
DISKS=()
DISK_IDS=()
EFI_PARTS=()
BOOT_PARTS=()
SWAP_PARTS=()
ROOT_PARTS=()
ROOT_IDS=()
LUKS_DEVS=()
BOOT_MODE="UEFI"
ZFS_PART_NUM=3
POOL_CREATED=0
CLEANUP_DONE=0

###############################################################################
# Colors
###############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

###############################################################################
# Logging
###############################################################################
setup_logging() {
    mkdir -p "$LOGDIR"
    LOGFILE="${LOGDIR}/install-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOGFILE") 2>&1
    log_info "Log file: $LOGFILE"
}

_log() {
    local level="$1" color="$2" msg="$3"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${color}[${level}]${NC} ${ts}  ${msg}"
}

log_info()    { _log "INFO   " "$BLUE"   "$1"; }
log_success() { _log "SUCCESS" "$GREEN"  "$1"; }
log_warning() { _log "WARNING" "$YELLOW" "$1"; }
log_error()   { _log "ERROR  " "$RED"    "$1" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }
log_debug()   { [[ "${DEBUG:-0}" == "1" ]] && _log "DEBUG  " "$YELLOW" "$1" || true; }

###############################################################################
# Config file loading
###############################################################################
load_config() {
    local cfg="${1:-$CONFIG_FILE}"
    if [[ -f "$cfg" ]]; then
        log_info "Loading config: $cfg"
        # shellcheck disable=SC1090
        source "$cfg"
    fi
}

###############################################################################
# Whiptail helpers
###############################################################################
wt_input() {
    local title="$1" prompt="$2" default="${3:-}"
    local result
    result=$(whiptail --title "$title" --backtitle "$BACKTITLE" \
        --inputbox "$prompt" 12 72 "$default" 3>&1 1>&2 2>&3) \
        || { log_info "Cancelled."; exit 0; }
    echo "$result"
}

wt_password() {
    local title="$1" prompt="$2"
    whiptail --title "$title" --backtitle "$BACKTITLE" \
        --passwordbox "$prompt" 10 72 \
        3>&1 1>&2 2>&3 || { log_info "Cancelled."; exit 0; }
}

wt_yesno() {
    local title="$1" prompt="$2" default_no="${3:-false}"
    local flag=""
    [[ "$default_no" == "true" ]] && flag="--defaultno"
    # shellcheck disable=SC2086
    whiptail --title "$title" --backtitle "$BACKTITLE" \
        $flag --yesno "$prompt" 16 74
}

wt_menu() {
    local title="$1" prompt="$2"
    shift 2
    whiptail --title "$title" --backtitle "$BACKTITLE" \
        --menu "$prompt" 22 74 12 "$@" 3>&1 1>&2 2>&3 \
        || { log_info "Cancelled."; exit 0; }
}

wt_checklist() {
    local title="$1" prompt="$2"
    shift 2
    whiptail --title "$title" --backtitle "$BACKTITLE" \
        --checklist "$prompt" 24 80 14 "$@" 3>&1 1>&2 2>&3 \
        || { log_info "Cancelled."; exit 0; }
}

wt_msg() {
    local title="$1" msg="$2"
    whiptail --title "$title" --backtitle "$BACKTITLE" \
        --msgbox "$msg" 20 74
}

###############################################################################
# Utility helpers
###############################################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR]${NC} This script must be run as root."
        echo -e "        Re-run with: ${BOLD}sudo bash $SCRIPT_NAME $*${NC}"
        exit 1
    fi
}

die() { log_error "$1"; exit 1; }

# check_deps — verify and install all required tools before any work begins.
#
# Maps each required binary to the apt package that provides it.
# Separates "always needed" tools from conditional ones (LUKS, UEFI, Dropbear).
# Reports every missing package at once, then offers to install them in a
# single apt-get run rather than failing on the first missing tool.
check_deps() {
    # binary_name:apt_package  (same string when they match)
    local -a always_needed=(
        "whiptail:whiptail"
        "sgdisk:gdisk"
        "zpool:zfsutils-linux"
        "zfs:zfsutils-linux"
        "mkfs.vfat:dosfstools"
        "debootstrap:debootstrap"
        "curl:curl"
        "wget:wget"
        "lsblk:util-linux"
        "wipefs:util-linux"
        "partprobe:parted"
        "udevadm:udev"
    )

    local -a conditional=()
    [[ "$DISCENC" == "LUKS" ]]  && conditional+=("cryptsetup:cryptsetup-bin")
    [[ "$BOOT_MODE" == "UEFI" ]] && conditional+=("efibootmgr:efibootmgr")
    [[ "$DROPBEAR" == "y" ]]    && conditional+=("dropbear:dropbear-initramfs")

    local -a all_pairs=("${always_needed[@]}" "${conditional[@]}")
    local -a missing_bins=()
    local -a missing_pkgs=()

    log_step "Dependency check"

    for pair in "${all_pairs[@]}"; do
        local bin="${pair%%:*}"
        local pkg="${pair##*:}"
        if ! command -v "$bin" &>/dev/null; then
            missing_bins+=("$bin")
            # Avoid duplicate package names
            local already=0
            for p in "${missing_pkgs[@]:-}"; do [[ "$p" == "$pkg" ]] && already=1; done
            [[ $already -eq 0 ]] && missing_pkgs+=("$pkg")
        else
            log_debug "OK  $bin"
        fi
    done

    if [[ ${#missing_bins[@]} -eq 0 ]]; then
        log_success "All dependencies satisfied"
        return 0
    fi

    # Report what is missing
    log_warning "Missing tools: ${missing_bins[*]}"
    log_info    "Required packages: ${missing_pkgs[*]}"

    apt-get update -qq || die "apt-get update failed — check your internet connection"
    apt-get install -y "${missing_pkgs[@]}" \
        || die "Failed to install: ${missing_pkgs[*]}"

    # Verify everything is actually available now
    local still_missing=()
    for pair in "${all_pairs[@]}"; do
        local bin="${pair%%:*}"
        command -v "$bin" &>/dev/null || still_missing+=("$bin")
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
        die "Still missing after install: ${still_missing[*]}\nAbort."
    fi

    log_success "All dependencies installed successfully"
}

get_part() {
    local disk="$1" num="$2"
    [[ "$disk" =~ nvme|mmcblk ]] && echo "${disk}p${num}" || echo "${disk}${num}"
}

wait_for_dev() {
    local dev="$1" timeout="${2:-30}" elapsed=0
    while [[ ! -b "$dev" && $elapsed -lt $timeout ]]; do
        sleep 2; elapsed=$((elapsed + 2))
        log_debug "Waiting for $dev ($elapsed/${timeout}s)..."
    done
    [[ -b "$dev" ]] || die "Device $dev did not appear after ${timeout}s"
}

list_disks() {
    local dev devname size model byid tag label
    while IFS= read -r dev; do
        devname=$(basename "$dev")
        size=$(lsblk -dn -o SIZE  "$dev" 2>/dev/null | xargs || echo "?")
        model=$(lsblk -dn -o MODEL "$dev" 2>/dev/null | xargs || echo "")
        byid=$(ls -l /dev/disk/by-id/ 2>/dev/null \
            | grep -v "part" \
            | grep -E "(ata|nvme|scsi|usb)-" \
            | grep " ${devname}$" | head -1 \
            | awk '{print "/dev/disk/by-id/" $9}') || true
        tag="${byid:-$dev}"
        label=$(printf "%-14s %-8s %s" "/dev/$devname" "$size" "$model")
        printf '%s\n%s\n' "$tag" "$label"
    done < <(lsblk -dn -p -o NAME \
        | grep -E "/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+)")
}

###############################################################################
# Cleanup trap
###############################################################################
cleanup_trap() {
    [[ "$CLEANUP_DONE" == "1" ]] && return
    log_warning "Running cleanup on exit..."
    umount -R /mnt/dev  2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true
    umount -R /mnt/sys  2>/dev/null || true
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt/boot     2>/dev/null || true
    zfs umount -a 2>/dev/null || true
    [[ -n "${POOLNAME:-}" ]] && zpool export "$POOLNAME" 2>/dev/null || true
    for dev in /dev/mapper/luks-*; do
        [[ -b "$dev" ]] && cryptsetup close "$dev" 2>/dev/null || true
    done
}
trap cleanup_trap EXIT
cleanup_mounts() {
    log_step "Pre-installation teardown"
    umount -R /mnt/dev  2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true
    umount -R /mnt/sys  2>/dev/null || true
    umount -R /mnt      2>/dev/null || true

    for dev in /dev/mapper/luks-* /dev/mapper/cryptswap*; do
        [[ -b "$dev" ]] && cryptsetup close "$dev" 2>/dev/null || true
    done

    zfs umount -a 2>/dev/null || true

    local existing
    existing=$(zpool list -H -o name 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        local ptext=""
        while IFS= read -r p; do ptext+="  $p\n"; done <<< "$existing"
        if wt_yesno "Existing ZFS Pools" \
"Found existing ZFS pools:\n\n${ptext}\nDestroy all and continue?" "true"; then
            while IFS= read -r pool; do
                zpool export -f "$pool" 2>/dev/null || true
                zpool destroy -f "$pool" 2>/dev/null || true
                log_info "Destroyed pool: $pool"
            done <<< "$existing"
        else
            die "Cannot continue with existing pools. Destroy them manually."
        fi
    fi

    mdadm --stop --scan 2>/dev/null || true
    udevadm settle --timeout=15
    log_success "Teardown complete"
}

###############################################################################
# Pre-installation teardown
###############################################################################
do_teardown() {
    log_step "Pre-installation teardown"
    umount -R /mnt/dev  2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true
    umount -R /mnt/sys  2>/dev/null || true
    umount -R /mnt      2>/dev/null || true

    for dev in /dev/mapper/luks-* /dev/mapper/cryptswap*; do
        [[ -b "$dev" ]] && cryptsetup close "$dev" 2>/dev/null || true
    done

    zfs umount -a 2>/dev/null || true

    local existing
    existing=$(zpool list -H -o name 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        local ptext=""
        while IFS= read -r p; do ptext+="  $p\n"; done <<< "$existing"
        if wt_yesno "Existing ZFS Pools" \
"Found existing ZFS pools:\n\n${ptext}\nDestroy all and continue?" "true"; then
            while IFS= read -r pool; do
                zpool export -f "$pool" 2>/dev/null || true
                zpool destroy -f "$pool" 2>/dev/null || true
                log_info "Destroyed pool: $pool"
            done <<< "$existing"
        else
            die "Cannot continue with existing pools. Destroy them manually."
        fi
    fi

    mdadm --stop --scan 2>/dev/null || true
    udevadm settle --timeout=15
    log_success "Teardown complete"
}

###############################################################################
# Interactive configuration gathering
###############################################################################
gather_config_interactive() {
    log_step "Interactive configuration"

    # Installation mode
    if wt_yesno "Installation Mode" \
"Full fresh installation?

YES — Wipe disk(s) and install a complete new Ubuntu+ZFS system.
NO  — Only create a new <pool>/ROOT/<suite> dataset on an existing pool
      (useful for adding another Ubuntu version to an existing ZFS system)."; then
        WIPE_FRESH="y"
    else
        WIPE_FRESH="n"
    fi

    # Ubuntu suite
    SUITE=$(wt_menu "Ubuntu Suite" "Select the Ubuntu version to install:" \
        "noble"    "Ubuntu 24.04 LTS  (Noble Numbat)     — current LTS" \
        "resolute" "Ubuntu 26.04 LTS  (Resolute Ruminant) — next LTS" \
        "jammy"    "Ubuntu 22.04 LTS  (Jammy Jellyfish)  — previous LTS")

    # System identity
    MYHOSTNAME=$(wt_input "System Configuration" \
        "Hostname for the new system:" "$MYHOSTNAME")
    [[ -z "$MYHOSTNAME" ]] && die "Hostname cannot be empty"

    POOLNAME=$(wt_input "System Configuration" \
        "ZFS root pool name:" "$POOLNAME")
    [[ -z "$POOLNAME" ]] && die "Pool name cannot be empty"

    # User account
    USERNAME=$(wt_input "User Account" "Username:" "$USERNAME")
    [[ -z "$USERNAME" ]] && die "Username cannot be empty"
    UCOMMENT=$(wt_input "User Account" "Full name / comment:" "$UCOMMENT")

    while true; do
        local p1 p2
        p1=$(wt_password "User Password" "Password for '$USERNAME':")
        p2=$(wt_password "User Password" "Confirm password:")
        [[ "$p1" == "$p2" ]] && { UPASSWORD="$p1"; break; }
        wt_msg "Password Mismatch" "Passwords do not match. Try again."
    done

    # Storage topology
    RAIDLEVEL=$(wt_menu "Storage Topology" \
"Select the ZFS root pool topology:

  mirror — 2 disks, tolerates 1 failure
  raidz1 — 3+ disks, tolerates 1 failure
  raidz2 — 4+ disks, tolerates 2 failures
  raidz3 — 5+ disks, tolerates 3 failures
  raid0  — stripe, no redundancy" \
        "single" "Single disk (no redundancy)" \
        "mirror" "Mirror / RAID1   (2 disks)" \
        "raidz1" "RAIDZ1           (3+ disks, 1-disk tolerance)" \
        "raidz2" "RAIDZ2           (4+ disks, 2-disk tolerance)" \
        "raidz3" "RAIDZ3           (5+ disks, 3-disk tolerance)" \
        "raid0"  "RAID0 Stripe     (2+ disks, no redundancy)")

    # Encryption
    DISCENC=$(wt_menu "Disk Encryption" \
"Select encryption method:

  NOENC  — No encryption (plain ZFS)
  ZFSENC — ZFS native encryption (AES-256-GCM, passphrase at pool level)
  LUKS   — LUKS whole-disk encryption (ZFS sits on top of LUKS device)" \
        "NOENC"  "No encryption" \
        "ZFSENC" "ZFS native encryption  (AES-256-GCM)" \
        "LUKS"   "LUKS whole-disk encryption")

    if [[ "$DISCENC" != "NOENC" ]]; then
        while true; do
            local p1 p2
            p1=$(wt_password "Encryption Passphrase" \
                "Passphrase for $DISCENC encryption:")
            [[ -z "$p1" ]] && { wt_msg "Error" "Passphrase cannot be empty."; continue; }
            p2=$(wt_password "Encryption Passphrase" "Confirm passphrase:")
            [[ "$p1" == "$p2" ]] && { PASSPHRASE="$p1"; break; }
            wt_msg "Passphrase Mismatch" "Passphrases do not match. Try again."
        done

        if wt_yesno "Dropbear SSH (Remote Unlock)" \
"Install Dropbear SSH in the initramfs?

This enables remote unlocking of the encrypted pool at boot via SSH:
  ssh -p 2222 root@<ip>

Recommended for headless or remote servers."; then
            DROPBEAR="y"
        else
            DROPBEAR="n"
        fi
    fi

    # Swap
    local swap_input
    swap_input=$(wt_input "Swap" \
"Swap partition size in MB per disk (0 = disable).
For hibernation: set to at least your RAM size.
For NOENC/ZFSENC: a ZFS zvol is used instead of a partition." \
        "$SIZE_SWAP")
    SIZE_SWAP="${swap_input:-$SIZE_SWAP}"

    # Kernel
    if wt_yesno "Kernel" \
"Install HWE (Hardware Enablement) kernel?

YES — linux-image-hwe-* (newer kernel, better hardware support)
NO  — linux-image-generic (standard LTS kernel)"; then
        HWE="y"
    else
        HWE="n"
    fi

    # Rescue clone
    if wt_yesno "Rescue Dataset" \
"Create a rescue clone of the base install snapshot?

Creates: ${POOLNAME}/ROOT/${SUITE}_rescue_base
This is a bootable fallback if the main install breaks."; then
        RESCUE="y"
    else
        RESCUE="n"
    fi

    # Snapshot management
    if wt_yesno "zrepl" \
"Install zrepl for additional snapshot management?

Sanoid is always configured for automatic snapshots.
zrepl adds 15-minute periodic snapshots with configurable pruning."; then
        ZREPL="y"
    else
        ZREPL="n"
    fi

    # Google Authenticator
    if wt_yesno "Google Authenticator" \
"Install Google Authenticator for SSH TOTP?

When enabled, SSH logins without a key require a TOTP code.
The QR code will be shown during postreboot setup."; then
        GOOGLE="y"
    else
        GOOGLE="n"
    fi

    # NVIDIA
    NVIDIA=$(wt_menu "NVIDIA Drivers" "Select NVIDIA driver (or none):" \
        "none" "No NVIDIA driver" \
        "470"  "Legacy 470 (Kepler cards)" \
        "525"  "Driver 525" \
        "550"  "Driver 550 (current)" \
        "570"  "Driver 570 (latest)")

    # Additional packages
    NECESSARY_PACKAGES=$(wt_input "Additional Packages" \
        "Extra packages to install (space-separated):" \
        "$NECESSARY_PACKAGES")

    # SSH public key
    SSHPUBKEY=$(wt_input "SSH Public Key" \
        "Paste SSH public key for '$USERNAME' (blank to skip):" \
        "$SSHPUBKEY")

    # Network
    if wt_yesno "Network" "Use DHCP for network configuration?"; then
        NET_MODE="dhcp"
    else
        NET_MODE="static"
        NET_IP=$(wt_input  "Static IP" "IP address with prefix (e.g. 192.168.1.10/24):" "")
        NET_GW=$(wt_input  "Static IP" "Default gateway:" "")
        NET_DNS=$(wt_input "Static IP" "DNS servers (comma-separated):" "8.8.8.8,1.1.1.1")
    fi

    # Timezone
    TIMEZONE=$(wt_input "Timezone" \
        "Timezone (e.g. UTC, Europe/Budapest, America/New_York):" "$TIMEZONE")
    TIMEZONE="${TIMEZONE:-UTC}"
}

###############################################################################
# Disk selection
###############################################################################
select_disks_for_pool() {
    local topology="$1"
    local min_disks=1 exact_disks=0

    case "$topology" in
        single) min_disks=1; exact_disks=1 ;;
        mirror) min_disks=2; exact_disks=2 ;;
        raidz1) min_disks=3 ;;
        raidz2) min_disks=4 ;;
        raidz3) min_disks=5 ;;
        raid0)  min_disks=2 ;;
    esac

    log_step "Disk selection — topology: $topology"
    mapfile -t DISK_ITEMS < <(list_disks)
    [[ ${#DISK_ITEMS[@]} -eq 0 ]] && die "No suitable disks found"

    if [[ "$topology" == "single" ]]; then
        local sel
        sel=$(wt_menu "Disk Selection" \
"Select the TARGET disk.

⚠  ALL DATA ON THIS DISK WILL BE PERMANENTLY DESTROYED!" \
            "${DISK_ITEMS[@]}")
        DISK_IDS=("$sel")
    else
        local checklist=()
        for (( i=0; i<${#DISK_ITEMS[@]}; i+=2 )); do
            checklist+=("${DISK_ITEMS[$i]}" "${DISK_ITEMS[$i+1]}" "OFF")
        done

        while true; do
            local raw
            raw=$(wt_checklist "Disk Selection ($topology)" \
"Select disks for the $topology pool.
Required: at least $min_disks disk(s). SPACE=toggle, ENTER=confirm.

⚠  ALL DATA ON SELECTED DISKS WILL BE PERMANENTLY DESTROYED!" \
                "${checklist[@]}")

            mapfile -t DISK_IDS < \
                <(echo "$raw" | tr ' ' '\n' | tr -d '"' | grep -v '^$')
            local count="${#DISK_IDS[@]}"
            local ok=1
            [[ $exact_disks -gt 0 && $count -ne $exact_disks ]] && ok=0
            [[ $count -lt $min_disks ]] && ok=0
            [[ $ok -eq 1 ]] && break

            local msg="Need at least $min_disks disk(s) for $topology."
            [[ $exact_disks -gt 0 ]] && msg="Need exactly $exact_disks disk(s) for $topology."
            wt_msg "Wrong disk count" "$msg\nYou selected: $count"
        done
    fi

    # Resolve canonical paths
    DISKS=()
    for id in "${DISK_IDS[@]}"; do
        if [[ "$id" == /dev/disk/by-id/* ]]; then
            DISKS+=("$(readlink -f "$id")")
        else
            DISKS+=("$id")
        fi
    done
    for d in "${DISKS[@]}"; do [[ -b "$d" ]] || die "Not a block device: $d"; done

    # Confirmation
    local disk_text=""
    for d in "${DISKS[@]}"; do disk_text+="  $d\n"; done
    wt_yesno "CONFIRM — DESTRUCTIVE OPERATION" \
"ALL DATA ON THE FOLLOWING DISK(S) WILL BE PERMANENTLY DESTROYED:

${disk_text}
Topology  : $topology  (${#DISKS[@]} disk(s))
Encryption: $DISCENC

THIS OPERATION CANNOT BE UNDONE!" "true" || { log_info "Cancelled."; exit 0; }
}

###############################################################################
# Disk partitioning
###############################################################################
partition_disks() {
    log_step "Partitioning ${#DISKS[@]} disk(s)"
    EFI_PARTS=(); BOOT_PARTS=(); SWAP_PARTS=(); ROOT_PARTS=()

    local swap_mb="${SIZE_SWAP:-0}"
    local root_type="BF00"
    [[ "$DISCENC" == "LUKS" ]] && root_type="8309"
    [[ "$swap_mb" -gt 0 ]] && ZFS_PART_NUM=4 || ZFS_PART_NUM=3

    for i in "${!DISKS[@]}"; do
        local disk="${DISKS[$i]}"
        local pref
        [[ "$disk" =~ nvme|mmcblk ]] && pref="${disk}p" || pref="$disk"

        log_info "Wiping and partitioning $disk..."
        wipefs --all --force "$disk" 2>/dev/null || true
        sgdisk --zap-all "$disk" 2>/dev/null || true
        udevadm settle --timeout=10

        if [[ "$BOOT_MODE" == "UEFI" ]]; then
            if [[ "$swap_mb" -gt 0 ]]; then
                sgdisk \
                    -n1:1M:+512M             -t1:EF00 -c1:EFI  \
                    -n2:0:+1792M             -t2:8300 -c2:Boot \
                    -n3:0:+"${swap_mb}M"     -t3:8200 -c3:Swap \
                    -n4:0:0                  -t4:"$root_type" -c4:ZFS  \
                    "$disk"
                EFI_PARTS+=("${pref}1"); BOOT_PARTS+=("${pref}2")
                SWAP_PARTS+=("${pref}3"); ROOT_PARTS+=("${pref}4")
            else
                sgdisk \
                    -n1:1M:+512M  -t1:EF00 -c1:EFI  \
                    -n2:0:+1792M  -t2:8300 -c2:Boot \
                    -n3:0:0       -t3:"$root_type" -c3:ZFS  \
                    "$disk"
                EFI_PARTS+=("${pref}1"); BOOT_PARTS+=("${pref}2")
                SWAP_PARTS+=(""); ROOT_PARTS+=("${pref}3")
            fi
        else  # BIOS
            if [[ "$swap_mb" -gt 0 ]]; then
                sgdisk \
                    -a1    -n1:24K:+1000K    -t1:EF02 -c1:BIOS \
                    -a2048 -n2:0:+1792M      -t2:8300 -c2:Boot \
                           -n3:0:+"${swap_mb}M" -t3:8200 -c3:Swap \
                           -n4:0:0           -t4:"$root_type" -c4:ZFS  \
                    "$disk"
                BOOT_PARTS+=("${pref}2"); SWAP_PARTS+=("${pref}3")
                ROOT_PARTS+=("${pref}4")
            else
                sgdisk \
                    -a1    -n1:24K:+1000K  -t1:EF02 -c1:BIOS \
                    -a2048 -n2:0:+1792M    -t2:8300 -c2:Boot \
                           -n3:0:0         -t3:"$root_type" -c3:ZFS  \
                    "$disk"
                BOOT_PARTS+=("${pref}2"); SWAP_PARTS+=("")
                ROOT_PARTS+=("${pref}3")
            fi
        fi

        partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" || true
        udevadm settle --timeout=30
        wait_for_dev "${pref}${ZFS_PART_NUM}"

        mdadm --stop --scan 2>/dev/null || true
        for pnum in $(seq 1 "$ZFS_PART_NUM"); do
            local pdev; pdev=$(get_part "$disk" "$pnum")
            [[ -b "$pdev" ]] && wipefs --all --force "$pdev" 2>/dev/null || true
        done
        udevadm settle --timeout=10
        log_success "Partitioned: $disk"
    done

    # Resolve by-id paths for ZFS root partitions
    ROOT_IDS=()
    for i in "${!DISKS[@]}"; do
        local disk_id="${DISK_IDS[$i]}"
        if [[ "$disk_id" == /dev/disk/by-id/* ]]; then
            local cand="${disk_id}-part${ZFS_PART_NUM}"
            [[ -b "$cand" ]] && ROOT_IDS+=("$cand") || ROOT_IDS+=("${ROOT_PARTS[$i]}")
        else
            ROOT_IDS+=("${ROOT_PARTS[$i]}")
        fi
    done

    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "${DISKS[0]}" || true
}

###############################################################################
# LUKS setup
###############################################################################
setup_luks() {
    [[ "$DISCENC" != "LUKS" ]] && return
    log_step "Setting up LUKS encryption"
    LUKS_DEVS=()

    for i in "${!ROOT_PARTS[@]}"; do
        local part="${ROOT_PARTS[$i]}"
        log_info "Encrypting $part..."

        echo -n "$PASSPHRASE" | cryptsetup luksFormat \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha256 \
            --key-file - \
            "$part"

        local uuid; uuid=$(blkid -s UUID -o value "$part")
        local mapper="luks-${uuid}"

        echo -n "$PASSPHRASE" | cryptsetup open --key-file - "$part" "$mapper"
        wait_for_dev "/dev/mapper/$mapper"

        LUKS_DEVS+=("/dev/mapper/$mapper")
        ROOT_IDS[$i]="/dev/mapper/$mapper"
        log_success "LUKS: $part → /dev/mapper/$mapper"
    done
}

###############################################################################
# ZFS pool creation
###############################################################################
create_pool() {
    log_step "Creating ZFS pool '$POOLNAME' ($RAIDLEVEL, $DISCENC)"

    local vdev_args=()
    case "$RAIDLEVEL" in
        single) vdev_args=("${ROOT_IDS[0]}") ;;
        mirror) vdev_args=(mirror "${ROOT_IDS[@]}") ;;
        raidz1) vdev_args=(raidz  "${ROOT_IDS[@]}") ;;
        raidz2) vdev_args=(raidz2 "${ROOT_IDS[@]}") ;;
        raidz3) vdev_args=(raidz3 "${ROOT_IDS[@]}") ;;
        raid0)  vdev_args=("${ROOT_IDS[@]}") ;;
    esac

    local enc_opts=()
    [[ "$DISCENC" == "ZFSENC" ]] && enc_opts=(
        -O encryption=aes-256-gcm
        -O keylocation=prompt
        -O keyformat=passphrase
    )

    local create_cmd=(zpool create
        -o ashift=12
        -o autotrim=on
        -O acltype=posixacl
        -O canmount=off
        -O compression=lz4
        -O dnodesize=auto
        -O normalization=formD
        -O relatime=on
        -O xattr=sa
        -O mountpoint=/
        -R /mnt
        "${enc_opts[@]}"
        "$POOLNAME"
        "${vdev_args[@]}"
        -f
    )

    if [[ "$DISCENC" == "ZFSENC" ]]; then
        echo -n "$PASSPHRASE" | "${create_cmd[@]}"
    else
        "${create_cmd[@]}"
    fi

    zpool list "$POOLNAME" || die "Pool creation failed"
    log_success "Pool '$POOLNAME' created"
    POOL_CREATED=1
}

###############################################################################
# ZFS dataset creation
###############################################################################
create_datasets() {
    log_step "Creating ZFS datasets"
    local pool="$POOLNAME"

    # Root container
    zfs create -o canmount=off -o mountpoint=none "${pool}/ROOT"

    # Main root filesystem
    zfs create -o canmount=noauto -o mountpoint=/ "${pool}/ROOT/${SUITE}"
    zfs mount "${pool}/ROOT/${SUITE}"
    zpool set bootfs="${pool}/ROOT/${SUITE}" "$pool"

    # usr
    zfs create -o canmount=off -o mountpoint=/usr "${pool}/usr"
    zfs create                                    "${pool}/usr/local"

    # var
    zfs create -o canmount=off -o mountpoint=/var "${pool}/var"
    zfs create                                    "${pool}/var/lib"
    zfs create -o com.sun:auto-snapshot=false     "${pool}/var/lib/docker"
    zfs create                                    "${pool}/var/log"
    zfs create                                    "${pool}/var/mail"
    zfs create -o com.sun:auto-snapshot=false     "${pool}/var/snap"
    zfs create                                    "${pool}/var/spool"
    zfs create                                    "${pool}/var/www"

    # tmp
    zfs create -o com.sun:auto-snapshot=false \
               -o mountpoint=/tmp "${pool}/tmp"
    chmod 1777 /mnt/tmp

    # ZFS swap zvol (when not using LUKS partition swap)
    if [[ "$DISCENC" != "LUKS" && "${SIZE_SWAP:-0}" -gt 0 ]]; then
        # volblocksize 16384: ZFS warns if < 16384 due to metadata overhead.
        # 4096 (page size) causes a visible warning without meaningful benefit.
        zfs create \
            -V "${SIZE_SWAP}M" \
            -b 16384 \
            -o compression=zle \
            -o logbias=throughput \
            -o sync=always \
            -o primarycache=metadata \
            -o secondarycache=none \
            -o com.sun:auto-snapshot=false \
            "${pool}/swap"
        mkswap -f "/dev/zvol/${pool}/swap"
        log_info "ZFS swap zvol: ${pool}/swap"
    fi

    # Home datasets
    if [[ "$DISCENC" == "ZFSENC" ]]; then
        mkdir -p /mnt/etc/zfs

        # Generate a 32-byte random key (binary, keyformat=raw).
        # Must be exactly 32 bytes — do NOT pipe through base64.
        dd if=/dev/urandom bs=32 count=1 2>/dev/null \
            > /mnt/etc/zfs/zroot.homekey
        chmod 400 /mnt/etc/zfs/zroot.homekey

        # keylocation must point to the HOST path (/mnt/…) at creation time
        # because zfs runs on the host and opens the file directly.
        # After creation, update to the in-chroot path so the installed system
        # can load the key from /etc/zfs/zroot.homekey on every boot.
        zfs create \
            -o canmount=off \
            -o encryption=on \
            -o keylocation="file:///mnt/etc/zfs/zroot.homekey" \
            -o keyformat=raw \
            "${pool}/home"
        zfs set keylocation="file:///etc/zfs/zroot.homekey" "${pool}/home"
    else
        zfs create -o canmount=off "${pool}/home"
    fi

    zfs create -o mountpoint=/root              "${pool}/home/root"
    zfs create -o mountpoint="/home/${USERNAME}" "${pool}/home/${USERNAME}"
    chmod 700 /mnt/root

    # Docker dataset
    zfs create -o com.sun:auto-snapshot=false "${pool}/docker"

    log_success "Datasets created"
}

###############################################################################
# Boot partition formatting
###############################################################################
setup_boot_partitions() {
    log_step "Setting up boot partitions"

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        for part in "${EFI_PARTS[@]}"; do
            mkfs.vfat -F32 -n EFI "$part"
        done
        mkdir -p /mnt/boot/efi
        mount "${EFI_PARTS[0]}" /mnt/boot/efi
    fi

    for part in "${BOOT_PARTS[@]}"; do
        mkfs.ext4 -F -L boot "$part"
    done
    mkdir -p /mnt/boot
    mount "${BOOT_PARTS[0]}" /mnt/boot

    log_success "Boot partitions ready"
}

###############################################################################
# debootstrap
###############################################################################
install_base_system() {
    log_step "Installing Ubuntu $SUITE via debootstrap"
    debootstrap "$SUITE" /mnt "http://archive.ubuntu.com/ubuntu"
    log_success "Base system installed"
}

###############################################################################
# Pre-chroot configuration
###############################################################################
configure_prechroot() {
    log_step "Pre-chroot system configuration"

    echo "$MYHOSTNAME" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   ${MYHOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # APT sources
    cat > /mnt/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: ${SUITE} ${SUITE}-updates ${SUITE}-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: ${SUITE}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

    # Netplan
    mkdir -p /mnt/etc/netplan
    if [[ "$NET_MODE" == "static" ]]; then
        local dns_yaml
        dns_yaml=$(echo "$NET_DNS" | tr ',' '\n' | awk '{printf "        - %s\n", $1}')
        cat > /mnt/etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: en*
      addresses:
        - ${NET_IP}
      routes:
        - to: default
          via: ${NET_GW}
      nameservers:
        addresses:
${dns_yaml}
EOF
    else
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
    fi

    # fstab
    local boot_uuid efi_uuid
    boot_uuid=$(blkid -s UUID -o value "${BOOT_PARTS[0]}")
    cat > /mnt/etc/fstab <<EOF
# <file system>                    <mount>   <type>  <options>    <dump> <pass>
UUID=${boot_uuid}                  /boot     ext4    defaults     0      2
EOF
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        efi_uuid=$(blkid -s UUID -o value "${EFI_PARTS[0]}")
        echo "UUID=${efi_uuid}   /boot/efi   vfat   umask=0077   0   1" \
            >> /mnt/etc/fstab
    fi

    # Swap entries
    if [[ "$DISCENC" == "LUKS" && "${SIZE_SWAP:-0}" -gt 0 ]]; then
        : > /mnt/etc/crypttab
        for i in "${!SWAP_PARTS[@]}"; do
            [[ -z "${SWAP_PARTS[$i]:-}" ]] && continue
            local cname="cryptswap$((i+1))"
            local swap_uuid; swap_uuid=$(blkid -s UUID -o value "${SWAP_PARTS[$i]}")
            echo "${cname}  UUID=${swap_uuid}  /dev/urandom  swap,cipher=aes-xts-plain64,size=512" \
                >> /mnt/etc/crypttab
            echo "/dev/mapper/${cname}  none  swap  sw  0  0" >> /mnt/etc/fstab
        done
    elif [[ "$DISCENC" != "LUKS" && "${SIZE_SWAP:-0}" -gt 0 ]]; then
        echo "/dev/zvol/${POOLNAME}/swap  none  swap  sw  0  0" >> /mnt/etc/fstab
    fi

    # LUKS crypttab entries for root partitions
    if [[ "$DISCENC" == "LUKS" ]]; then
        [[ -f /mnt/etc/crypttab ]] || : > /mnt/etc/crypttab
        for i in "${!ROOT_PARTS[@]}"; do
            local puuid; puuid=$(blkid -s UUID -o value "${ROOT_PARTS[$i]}")
            echo "luks-${puuid}  UUID=${puuid}  none  luks,discard" >> /mnt/etc/crypttab
        done
    fi

    # vm.swappiness tweak
    echo "vm.swappiness=10" > /mnt/etc/sysctl.d/99-zfs-allin.conf

    # ZFS pool cache — must point inside /mnt so the chroot sees it as /etc/zfs/zpool.cache
    mkdir -p /mnt/etc/zfs
    zpool set cachefile=/mnt/etc/zfs/zpool.cache "$POOLNAME"

    log_success "Pre-chroot config done"
}

###############################################################################
# Chroot: bind mounts
###############################################################################
bind_mounts() {
    mount --rbind /dev  /mnt/dev
    mount --rbind /proc /mnt/proc
    mount --rbind /sys  /mnt/sys
}

###############################################################################
# Chroot: package installation
###############################################################################
install_packages_chroot() {
    log_step "Installing packages in chroot"

    local kernel_pkg="linux-image-generic linux-headers-generic"
    if [[ "$HWE" == "y" ]]; then
        case "$SUITE" in
            noble)    kernel_pkg="linux-image-hwe-24.04 linux-headers-hwe-24.04" ;;
            resolute) kernel_pkg="linux-image-hwe-26.04 linux-headers-hwe-26.04" ;;
            jammy)    kernel_pkg="linux-image-hwe-22.04 linux-headers-hwe-22.04" ;;
            *)        kernel_pkg="linux-image-generic linux-headers-generic" ;;
        esac
    fi

    local boot_pkgs="zfs-initramfs zfsutils-linux"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        boot_pkgs+=" grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr dosfstools"
    else
        boot_pkgs+=" grub-pc"
    fi

    local enc_pkgs=""
    [[ "$DISCENC" == "LUKS" ]] && enc_pkgs="cryptsetup cryptsetup-initramfs"
    # dropbear-initramfs is intentionally installed later in configure_dropbear()
    # so that authorized_keys is written before the first initramfs build.

    local opt_pkgs="sanoid openssh-server curl wget nano"
    [[ -n "${NECESSARY_PACKAGES:-}" ]] && opt_pkgs+=" ${NECESSARY_PACKAGES}"
    [[ "$NVIDIA" != "none" ]]  && opt_pkgs+=" nvidia-driver-${NVIDIA}"
    [[ "$GOOGLE" == "y" ]]     && opt_pkgs+=" libpam-google-authenticator qrencode"

    chroot /mnt /bin/bash -e <<CHROOT_END
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ${kernel_pkg}
apt-get install -y ${boot_pkgs} ${enc_pkgs} ${opt_pkgs}

# zrepl from its own repo if requested.
# The zrepl apt repo may not publish packages for every Ubuntu suite;
# probe the InRelease URL first and fall back to "noble" if the suite
# is not listed, rather than letting curl exit non-zero and abort the install.
if [[ "${ZREPL}" == "y" ]]; then
    ZREPL_BASE="https://zrepl.github.io/apt"
    ZREPL_SUITE="${SUITE}"
    if curl -fsSL "${ZREPL_BASE}/apt.gpg" \
            | gpg --dearmor > /etc/apt/trusted.gpg.d/zrepl.gpg 2>/dev/null; then
        # Check whether the suite-specific repo exists; fall back to noble
        if ! curl -fsSL --head \
                "${ZREPL_BASE}/dists/${ZREPL_SUITE}/InRelease" \
                -o /dev/null 2>/dev/null; then
            echo "[INFO] zrepl repo has no packages for ${ZREPL_SUITE}, using noble"
            ZREPL_SUITE="noble"
        fi
        echo "deb ${ZREPL_BASE}/ ${ZREPL_SUITE} main" \
            > /etc/apt/sources.list.d/zrepl.list
        apt-get update -qq 2>/dev/null || true
        apt-get install -y zrepl 2>/dev/null \
            || echo "[WARNING] zrepl install failed, skipping"
    else
        echo "[WARNING] Could not fetch zrepl GPG key — skipping zrepl"
    fi
fi

locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata
CHROOT_END

    log_success "Packages installed"
}

###############################################################################
# Chroot: user setup
###############################################################################
setup_user() {
    log_step "Creating user '$USERNAME'"

    chroot /mnt /bin/bash -e <<CHROOT_USER
set -e
useradd -m -s /bin/bash -c "${UCOMMENT}" -G sudo,adm "${USERNAME}"
echo "${USERNAME}:${UPASSWORD}" | chpasswd
echo "root:${UPASSWORD}" | chpasswd
passwd -l root
CHROOT_USER

    if [[ -n "${SSHPUBKEY:-}" ]]; then
        mkdir -p "/mnt/home/${USERNAME}/.ssh"
        echo "$SSHPUBKEY" > "/mnt/home/${USERNAME}/.ssh/authorized_keys"
        chmod 700 "/mnt/home/${USERNAME}/.ssh"
        chmod 600 "/mnt/home/${USERNAME}/.ssh/authorized_keys"
        chroot /mnt chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.ssh"
    fi

    # Optional predefined host keys (handy for repeated test installs)
    if [[ -n "${HOST_ECDSA_KEY:-}" ]]; then
        printf '%s\n' "$HOST_ECDSA_KEY"     > /mnt/etc/ssh/ssh_host_ecdsa_key
        printf '%s\n' "$HOST_ECDSA_KEY_PUB" > /mnt/etc/ssh/ssh_host_ecdsa_key.pub
        chmod 600 /mnt/etc/ssh/ssh_host_ecdsa_key
    fi
    if [[ -n "${HOST_RSA_KEY:-}" ]]; then
        printf '%s\n' "$HOST_RSA_KEY"     > /mnt/etc/ssh/ssh_host_rsa_key
        printf '%s\n' "$HOST_RSA_KEY_PUB" > /mnt/etc/ssh/ssh_host_rsa_key.pub
        chmod 600 /mnt/etc/ssh/ssh_host_rsa_key
    fi
    if [[ -n "${HOST_ED25519_KEY:-}" ]]; then
        printf '%s\n' "$HOST_ED25519_KEY"     > /mnt/etc/ssh/ssh_host_ed25519_key
        printf '%s\n' "$HOST_ED25519_KEY_PUB" > /mnt/etc/ssh/ssh_host_ed25519_key.pub
        chmod 600 /mnt/etc/ssh/ssh_host_ed25519_key
    fi

    log_success "User '$USERNAME' created"
}

###############################################################################
# Sanoid + APT snapshot hook
###############################################################################
configure_sanoid() {
    log_step "Configuring Sanoid"
    mkdir -p /mnt/etc/sanoid

    cat > /mnt/etc/sanoid/sanoid.conf <<EOF
# Sanoid snapshot management — generated by ZFS AllIn
[${POOLNAME}/ROOT/${SUITE}]
use_template = production

[${POOLNAME}/home]
use_template = home_data
recursive = yes

[template_production]
frequently = 0
hourly     = 24
daily      = 14
monthly    = 3
yearly     = 0
autosnap   = yes
autoprune  = yes

[template_home_data]
frequently = 0
hourly     = 24
daily      = 30
monthly    = 6
yearly     = 0
autosnap   = yes
autoprune  = yes
EOF

    # APT pre-invoke hook: snapshot root dataset before any apt operation
    local snap_dataset="${POOLNAME}/ROOT/${SUITE}"
    cat > /mnt/etc/apt/apt.conf.d/60-zfs-snapshot <<EOF
DPkg::Pre-Invoke {
    "if zfs list ${snap_dataset} > /dev/null 2>&1; then \\
        zfs snapshot '${snap_dataset}@apt_\$(date +%Y-%m-%d-%H%M%S)' \\
        2>/dev/null || true; \\
    fi";
};
EOF

    log_success "Sanoid configured"
}

###############################################################################
# Dropbear initramfs
###############################################################################
configure_dropbear() {
    [[ "$DROPBEAR" != "y" ]] && return
    log_step "Configuring Dropbear initramfs SSH"

    # Install dropbear-initramfs HERE — after authorized_keys is written below —
    # so that the first update-initramfs triggered by the package sees a valid key
    # and does not emit "Invalid authorized_keys" warnings.
    mkdir -p /mnt/etc/dropbear/initramfs

    # Write authorized_keys BEFORE installing the package
    if [[ -n "${SSHPUBKEY:-}" ]]; then
        echo "$SSHPUBKEY" > /mnt/etc/dropbear/initramfs/authorized_keys
    else
        log_warning "No SSH public key — generating a one-time unlock key pair"
        ssh-keygen -t ed25519 -f /tmp/dropbear_unlock -N "" -C "zfs-allin-unlock" \
            -q 2>/dev/null
        cp /tmp/dropbear_unlock.pub /mnt/etc/dropbear/initramfs/authorized_keys
        local key_dest="${LOGDIR}/dropbear_unlock_key"
        cp /tmp/dropbear_unlock "$key_dest"
        log_warning "Private key saved to: $key_dest — copy it before rebooting!"
    fi
    chmod 600 /mnt/etc/dropbear/initramfs/authorized_keys

    cat > /mnt/etc/dropbear/initramfs/dropbear.conf <<'EOF'
DROPBEAR_OPTIONS="-p 2222 -s -j -k -I 60"
EOF

    # Enable DROPBEAR flag before the package triggers update-initramfs
    if grep -q "^DROPBEAR=" /mnt/etc/initramfs-tools/initramfs.conf 2>/dev/null; then
        sed -i 's/^DROPBEAR=.*/DROPBEAR=y/' /mnt/etc/initramfs-tools/initramfs.conf
    else
        echo "DROPBEAR=y" >> /mnt/etc/initramfs-tools/initramfs.conf
    fi

    # Now install — the package's post-install trigger runs update-initramfs
    # and will find the already-valid authorized_keys
    chroot /mnt /bin/bash -e <<'DROPBEAR_INSTALL'
export DEBIAN_FRONTEND=noninteractive
apt-get install -y dropbear-initramfs
DROPBEAR_INSTALL

    # zfsunlock helper script (used inside the initramfs SSH session)
    cat > /mnt/usr/local/bin/zfsunlock <<'ZFSEOF'
#!/bin/bash
# Unlock ZFS encryption from Dropbear SSH session at boot
printf 'ZFS passphrase: '
read -rs passphrase
echo
echo -n "$passphrase" | zfs load-key -a
zfs mount -a 2>/dev/null || true
pkill -HUP systemd 2>/dev/null || true
echo "ZFS pools unlocked — system will continue booting."
ZFSEOF
    chmod +x /mnt/usr/local/bin/zfsunlock

    log_success "Dropbear configured (port 2222)"
    log_info "At boot: ssh -p 2222 root@<ip>  then: zfsunlock"
}

###############################################################################
# zrepl configuration
###############################################################################
configure_zrepl() {
    [[ "$ZREPL" != "y" ]] && return
    log_step "Configuring zrepl"
    mkdir -p /mnt/etc/zrepl

    cat > /mnt/etc/zrepl/zrepl.yml <<EOF
global:
  logging:
    - type: syslog
      format: human
      level: warn

jobs:
  - name: snap_root
    type: snap
    filesystems:
      "${POOLNAME}/ROOT/${SUITE}": true
    snapshotting:
      type: periodic
      prefix: zrepl_
      interval: 15m
      hooks:
        - type: command
          path: /usr/local/bin/zrepl_threshold.sh
          timeout: 30s
          err_is_fatal: false
    pruning:
      keep:
        - type: grid
          grid: 1x1h(keep=all) | 24x1h | 14x1d
          regex: "^zrepl_"
        - type: regex
          negate: true
          regex: "^zrepl_"

  - name: snap_home
    type: snap
    filesystems:
      "${POOLNAME}/home": true
    snapshotting:
      type: periodic
      prefix: zrepl_
      interval: 15m
    pruning:
      keep:
        - type: grid
          grid: 1x1h(keep=all) | 24x1h | 30x1d
          regex: "^zrepl_"
        - type: regex
          negate: true
          regex: "^zrepl_"
EOF

    cat > /mnt/usr/local/bin/zrepl_threshold.sh <<'TEOF'
#!/bin/bash
# Skip snapshot when written bytes are below the dataset's threshold property
DATASET="${ZREPL_FS:-}"
[[ -z "$DATASET" ]] && exit 0
THRESHOLD=$(zfs get -H -o value com.zrepl:snapshot-threshold "$DATASET" 2>/dev/null || echo 0)
[[ "$THRESHOLD" == "-" || "$THRESHOLD" == "0" ]] && exit 0
WRITTEN=$(zfs get -H -o value written "$DATASET" 2>/dev/null || echo 0)
[[ "$WRITTEN" -lt "$THRESHOLD" ]] && exit 1
exit 0
TEOF
    chmod +x /mnt/usr/local/bin/zrepl_threshold.sh

    # 120 MB write threshold on root dataset
    zfs set com.zrepl:snapshot-threshold=120000000 \
        "${POOLNAME}/ROOT/${SUITE}" 2>/dev/null || true

    log_success "zrepl configured"
}

###############################################################################
# Bootloader
###############################################################################
# _efi_partnum <partition-device>  →  prints the partition number (works for
# both /dev/sda1 and /dev/nvme0n1p1 by reading the kernel attribute directly).
_efi_partnum() {
    local part="$1"
    cat "/sys/class/block/$(basename "$part")/partition" 2>/dev/null || echo "1"
}

# _efi_bootmgr_entry <disk> <efi-part> <label>
_efi_bootmgr_entry() {
    local disk="$1" efi_part="$2" label="$3"
    local partnum; partnum=$(_efi_partnum "$efi_part")
    efibootmgr --create \
        --disk "$disk" \
        --part "$partnum" \
        --label "$label" \
        --loader '\EFI\ubuntu\shimx64.efi' \
        2>/dev/null \
        && log_info "efibootmgr entry: $label" \
        || log_warning "efibootmgr failed for $disk (skip in non-UEFI env)"
}

install_bootloader() {
    log_step "Installing bootloader"

    chroot /mnt update-initramfs -c -k all

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        # Primary disk: full GRUB install with explicit device argument.
        # Passing the disk prevents the "More than one install device?" error
        # that occurs when grub-install auto-scans and finds multiple FAT32/EF00
        # partitions across the member disks.
        chroot /mnt grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=ubuntu \
            --recheck \
            "${DISKS[0]}"
        chroot /mnt update-grub
        _efi_bootmgr_entry "${DISKS[0]}" "${EFI_PARTS[0]}" "Ubuntu ZFS"
        log_info "GRUB installed on primary EFI: ${EFI_PARTS[0]}"

        # Additional disks: copy the EFI tree instead of re-running grub-install.
        # This avoids the multi-device confusion and keeps all ESPs in sync.
        for i in $(seq 1 $((${#EFI_PARTS[@]} - 1))); do
            local tmp="/mnt/boot/efi_tmp${i}"
            mkdir -p "$tmp"
            mount "${EFI_PARTS[$i]}" "$tmp"
            mkdir -p "${tmp}/EFI/ubuntu"
            cp -a /mnt/boot/efi/EFI/ubuntu/. "${tmp}/EFI/ubuntu/"
            umount "$tmp" && rmdir "$tmp"
            _efi_bootmgr_entry "${DISKS[$i]}" "${EFI_PARTS[$i]}" \
                "Ubuntu ZFS (${DISKS[$i]##*/})"
            log_info "EFI files mirrored to: ${EFI_PARTS[$i]}"
        done
    else
        # BIOS: write GRUB to the MBR of every member disk
        for disk in "${DISKS[@]}"; do
            chroot /mnt grub-install "$disk"
            log_info "GRUB installed on: $disk"
        done
        chroot /mnt update-grub
    fi

    log_success "Bootloader installed"
}

###############################################################################
# ZFS services
###############################################################################
enable_zfs_services() {
    log_step "Enabling ZFS services"
    chroot /mnt systemctl enable \
        zfs-import-cache zfs-mount zfs.target sanoid.timer 2>/dev/null || true
    [[ "$ZREPL" == "y" ]] && chroot /mnt systemctl enable zrepl 2>/dev/null || true
    log_success "Services enabled"
}

###############################################################################
# Base install snapshots
###############################################################################
take_base_snapshots() {
    log_step "Creating base install snapshots"

    zfs snapshot "${POOLNAME}/ROOT/${SUITE}@base_install"
    log_success "Snapshot: ${POOLNAME}/ROOT/${SUITE}@base_install"

    if [[ "$RESCUE" == "y" ]]; then
        zfs clone \
            "${POOLNAME}/ROOT/${SUITE}@base_install" \
            "${POOLNAME}/ROOT/${SUITE}_rescue_base"
        log_success "Rescue clone: ${POOLNAME}/ROOT/${SUITE}_rescue_base"
    fi
}

###############################################################################
# Save install info to home dataset
###############################################################################
save_system_info() {
    log_step "Saving install summary"
    local info="/mnt/home/${USERNAME}/zfs-allin-install-info.txt"

    {
        echo "# ZFS AllIn Install Summary — $(date)"
        echo "Hostname   : $MYHOSTNAME"
        echo "Suite      : $SUITE"
        echo "Username   : $USERNAME"
        echo "Pool       : $POOLNAME  ($RAIDLEVEL)"
        echo "Encryption : $DISCENC"
        echo "Boot mode  : $BOOT_MODE"
        echo "Dropbear   : $DROPBEAR"
        echo ""
        echo "Disks:"
        for i in "${!DISKS[@]}"; do
            echo "  [$((i+1))] ${DISKS[$i]}  (${DISK_IDS[$i]})"
        done
        echo ""
        echo "Datasets:"
        zfs list -r "$POOLNAME" 2>/dev/null || true
        echo ""
        echo "Snapshots:"
        zfs list -t snapshot -r "$POOLNAME" 2>/dev/null || true
        echo ""
        echo "# Change default boot dataset:"
        echo "  zfs set bootfs=${POOLNAME}/ROOT/<suite> ${POOLNAME}"
        echo ""
        echo "# Rollback to rescue:"
        echo "  zfs rollback -r ${POOLNAME}/ROOT/${SUITE}@base_install"
    } > "$info"
    chmod 600 "$info"
    chroot /mnt chown "${USERNAME}:${USERNAME}" \
        "/home/${USERNAME}/zfs-allin-install-info.txt" 2>/dev/null || true
    log_success "Info saved: /home/${USERNAME}/zfs-allin-install-info.txt"
}

###############################################################################
# Final cleanup and export
###############################################################################
do_cleanup() {
    log_step "Unmounting and exporting pool"
    CLEANUP_DONE=1
    umount -R /mnt/dev  2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true
    umount -R /mnt/sys  2>/dev/null || true
    [[ "$BOOT_MODE" == "UEFI" ]] && umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt/boot 2>/dev/null || true
    zfs umount -a
    zpool export "$POOLNAME"
    for dev in /dev/mapper/luks-*; do
        [[ -b "$dev" ]] && cryptsetup close "$dev" 2>/dev/null || true
    done
    log_success "Pool exported"
}

###############################################################################
# Add dataset to existing pool (WIPE_FRESH=n path)
###############################################################################
add_dataset_to_existing_pool() {
    log_step "Adding ${POOLNAME}/ROOT/${SUITE} to existing pool"

    if ! zpool list "$POOLNAME" &>/dev/null; then
        zpool import -d /dev/disk/by-id -a 2>/dev/null || true
        zpool list "$POOLNAME" || die "Pool '$POOLNAME' not found. Import it manually."
    fi

    [[ "$DISCENC" == "ZFSENC" ]] && \
        echo -n "$PASSPHRASE" | zfs load-key -a 2>/dev/null || true

    if zfs list "${POOLNAME}/ROOT/${SUITE}" &>/dev/null; then
        wt_yesno "Dataset Exists" \
"${POOLNAME}/ROOT/${SUITE} already exists!
Destroy it and reinstall?" "true" || die "Aborted."
        zfs destroy -r "${POOLNAME}/ROOT/${SUITE}"
    fi

    zfs create -o canmount=noauto -o mountpoint=/ "${POOLNAME}/ROOT/${SUITE}"
    zfs mount "${POOLNAME}/ROOT/${SUITE}"

    mkdir -p /mnt/boot
    mount "${BOOT_PARTS[0]:-$(lsblk -ln -o MOUNTPOINT,NAME | grep " boot" | awk '{print "/dev/"$2}' | head -1)}" \
        /mnt/boot 2>/dev/null || true

    install_base_system
    configure_prechroot
    bind_mounts
    install_packages_chroot
    setup_user
    configure_sanoid
    configure_zrepl
    install_bootloader

    zfs snapshot "${POOLNAME}/ROOT/${SUITE}@base_install"
    [[ "$RESCUE" == "y" ]] && \
        zfs clone "${POOLNAME}/ROOT/${SUITE}@base_install" \
            "${POOLNAME}/ROOT/${SUITE}_rescue_base"

    save_system_info

    log_success "New dataset ready: ${POOLNAME}/ROOT/${SUITE}"
    log_info "Set as default boot: zfs set bootfs=${POOLNAME}/ROOT/${SUITE} ${POOLNAME}"
}

###############################################################################
# cmd_initial — full installation from Live USB
###############################################################################
cmd_initial() {
    log_step "ZFS AllIn — Initial Installation"
    check_root
    check_deps

    [[ -d /sys/firmware/efi ]] && BOOT_MODE="UEFI" || BOOT_MODE="BIOS"
    log_info "Boot mode: $BOOT_MODE"

    # Gather any missing config interactively
    if [[ -z "${UPASSWORD:-}" ]]; then
        gather_config_interactive
    fi

    do_teardown

    if [[ "$WIPE_FRESH" == "y" ]]; then
        select_disks_for_pool "$RAIDLEVEL"
        partition_disks
        [[ "$DISCENC" == "LUKS" ]] && setup_luks
        create_pool
        create_datasets
        setup_boot_partitions
        install_base_system
        configure_prechroot
        bind_mounts
        install_packages_chroot
        setup_user
        configure_sanoid
        configure_dropbear
        configure_zrepl
        install_bootloader
        enable_zfs_services
        take_base_snapshots
        save_system_info
        do_cleanup
    else
        add_dataset_to_existing_pool
    fi

    local enc_note=""
    [[ "$DISCENC" != "NOENC" ]] && \
        enc_note="\nYou will be prompted for your passphrase at boot."
    [[ "$DROPBEAR" == "y" ]] && \
        enc_note+="\nDropbear SSH on port 2222 for remote unlock."

    wt_msg "Installation Complete" \
"Ubuntu $SUITE ZFS installation finished!

  Hostname   : $MYHOSTNAME
  User       : $USERNAME
  Pool       : $POOLNAME  ($RAIDLEVEL)
  Encryption : $DISCENC
  Boot mode  : $BOOT_MODE
${enc_note}

Remove installation media and reboot.
After first login, run:  sudo bash ${SCRIPT_NAME} postreboot"

    wt_yesno "Reboot" "Reboot now?" "true" && reboot || true
}

###############################################################################
# cmd_postreboot — run after first login on the new system
###############################################################################
cmd_postreboot() {
    log_step "ZFS AllIn — Post-Reboot Setup"
    check_root
    load_config

    log_info "Updating system packages..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    # Google Authenticator TOTP
    if [[ "${GOOGLE:-n}" == "y" ]]; then
        if ! command -v google-authenticator &>/dev/null; then
            apt-get install -y libpam-google-authenticator qrencode
        fi

        log_info "Setting up TOTP for $USERNAME..."
        sudo -u "$USERNAME" google-authenticator \
            --time-based --disallow-reuse --force \
            --rate-limit=3 --rate-time=30 --window-size=3

        # PAM: require TOTP for keyboard-interactive (SSH without key)
        if ! grep -q "pam_google_authenticator" /etc/pam.d/sshd 2>/dev/null; then
            sed -i '1s/^/auth required pam_google_authenticator.so nullok\n/' \
                /etc/pam.d/sshd
        fi

        grep -q "AuthenticationMethods" /etc/ssh/sshd_config 2>/dev/null || \
            cat >> /etc/ssh/sshd_config <<'EOF'
# Require pubkey or (TOTP + password) for SSH
AuthenticationMethods publickey,keyboard-interactive keyboard-interactive
ChallengeResponseAuthentication yes
EOF
        sed -i 's/^UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
        systemctl restart sshd || true
        log_success "Google Authenticator configured"
    fi

    # Ensure services are running
    systemctl enable --now sanoid.timer 2>/dev/null || true
    [[ "${ZREPL:-n}" == "y" ]] && systemctl enable --now zrepl 2>/dev/null || true

    # Post-reboot snapshot
    local pool; pool=$(zpool list -H -o name 2>/dev/null | head -1)
    local rootfs; rootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || true)
    if [[ -n "${rootfs:-}" ]]; then
        zfs snapshot "${rootfs}@postreboot_$(date +%Y%m%d-%H%M%S)" 2>/dev/null && \
            log_success "Post-reboot snapshot created"
    fi

    wt_msg "Post-Reboot Complete" \
"Post-reboot setup finished!

Sanoid automatic snapshots are active.
APT hook will snapshot before every system update.

Optional next steps:
  sudo bash ${SCRIPT_NAME} remoteaccess   — enable SSH at boot for remote unlock
  sudo bash ${SCRIPT_NAME} datapool       — add a ZFS data pool"
}

###############################################################################
# cmd_remoteaccess — configure Dropbear for remote initramfs unlock
###############################################################################
cmd_remoteaccess() {
    log_step "ZFS AllIn — Remote Access (Dropbear)"
    check_root
    load_config
    DROPBEAR="y" check_deps

    dpkg -l dropbear-initramfs &>/dev/null || apt-get install -y dropbear-initramfs
    mkdir -p /etc/dropbear/initramfs

    local pubkey="${SSHPUBKEY:-}"
    [[ -z "$pubkey" ]] && pubkey=$(wt_input "SSH Public Key" \
"Paste the SSH public key for remote unlock.
This key will be added to the initramfs authorized_keys:" "")

    if [[ -n "$pubkey" ]]; then
        echo "$pubkey" > /etc/dropbear/initramfs/authorized_keys
        chmod 600 /etc/dropbear/initramfs/authorized_keys
        log_success "Authorized key installed"
    else
        log_warning "No key provided — remote access may require a password"
    fi

    cat > /etc/dropbear/initramfs/dropbear.conf <<'EOF'
DROPBEAR_OPTIONS="-p 2222 -s -j -k -I 60"
EOF

    grep -q "^DROPBEAR=" /etc/initramfs-tools/initramfs.conf 2>/dev/null \
        && sed -i 's/^DROPBEAR=.*/DROPBEAR=y/' /etc/initramfs-tools/initramfs.conf \
        || echo "DROPBEAR=y" >> /etc/initramfs-tools/initramfs.conf

    # zfsunlock helper
    cat > /usr/local/bin/zfsunlock <<'ZFSEOF'
#!/bin/bash
printf 'ZFS passphrase: '
read -rs passphrase
echo
echo -n "$passphrase" | zfs load-key -a
zfs mount -a 2>/dev/null || true
pkill -HUP systemd 2>/dev/null || true
echo "Unlocked — system continuing boot."
ZFSEOF
    chmod +x /usr/local/bin/zfsunlock

    log_info "Rebuilding initramfs..."
    update-initramfs -u -k all
    log_success "Dropbear configured"

    wt_msg "Remote Access Ready" \
"Dropbear SSH is now active in the initramfs.

Connect at boot:
  ssh -p 2222 root@<your-ip>

Then unlock ZFS:
  zfsunlock

Sample ~/.ssh/config entry:
  Host unlock-${MYHOSTNAME:-myhost}
    Hostname <ip>
    User root
    Port 2222
    IdentityFile ~/.ssh/your_unlock_key
    HostKeyAlgorithms ssh-rsa
    RequestTTY yes"
}

###############################################################################
# cmd_datapool — create an additional encrypted ZFS data pool
###############################################################################
cmd_datapool() {
    log_step "ZFS AllIn — Data Pool Setup"
    check_root
    load_config
    check_deps

    local dpool
    dpool=$(wt_input "Data Pool" "Name for the new data pool:" "data")
    [[ -z "$dpool" ]] && die "Pool name cannot be empty"

    local denc
    denc=$(wt_menu "Data Pool Encryption" "Encryption for data pool:" \
        "NOENC"  "No encryption" \
        "ZFSENC" "ZFS native encryption  (AES-256-GCM)" \
        "LUKS"   "LUKS whole-disk encryption")

    local dpass=""
    if [[ "$denc" != "NOENC" ]]; then
        while true; do
            local p1 p2
            p1=$(wt_password "Data Pool Passphrase" "Passphrase:")
            [[ -z "$p1" ]] && { wt_msg "Error" "Cannot be empty."; continue; }
            p2=$(wt_password "Data Pool Passphrase" "Confirm:")
            [[ "$p1" == "$p2" ]] && { dpass="$p1"; break; }
            wt_msg "Mismatch" "Passphrases do not match."
        done
    fi

    local draid
    draid=$(wt_menu "Data Pool Topology" "Select topology:" \
        "single" "Single disk" \
        "mirror" "Mirror (RAID1, 2 disks)" \
        "raidz1" "RAIDZ1 (3+ disks)" \
        "raidz2" "RAIDZ2 (4+ disks)" \
        "raidz3" "RAIDZ3 (5+ disks)" \
        "raid0"  "RAID0 Stripe (2+ disks)")

    # Temporarily override globals for select_disks_for_pool
    local save_raidlevel="$RAIDLEVEL" save_discenc="$DISCENC"
    RAIDLEVEL="$draid"; DISCENC="$denc"
    select_disks_for_pool "$draid"
    local data_disks=("${DISKS[@]}")
    local data_disk_ids=("${DISK_IDS[@]}")
    RAIDLEVEL="$save_raidlevel"; DISCENC="$save_discenc"

    # Partition data disks (single partition, full disk)
    log_step "Partitioning data disks"
    local data_root_ids=()
    local data_luks_devs=()

    for i in "${!data_disks[@]}"; do
        local disk="${data_disks[$i]}"
        local pref; [[ "$disk" =~ nvme|mmcblk ]] && pref="${disk}p" || pref="$disk"

        wipefs --all --force "$disk" 2>/dev/null || true
        sgdisk --zap-all "$disk" 2>/dev/null || true
        udevadm settle --timeout=10

        local ptype="BF00"; [[ "$denc" == "LUKS" ]] && ptype="8309"
        sgdisk -n1:1M:0 -t1:"$ptype" -c1:ZFS "$disk"

        partprobe "$disk" 2>/dev/null || true
        udevadm settle --timeout=30
        wait_for_dev "${pref}1"

        local bid; bid=$(ls -l /dev/disk/by-id/ 2>/dev/null \
            | grep "${disk##*/}$" | grep -v part \
            | grep -E "(ata|nvme|scsi)-" | head -1 \
            | awk '{print "/dev/disk/by-id/" $9}') || true
        [[ -n "$bid" && -b "${bid}-part1" ]] \
            && data_root_ids+=("${bid}-part1") \
            || data_root_ids+=("${pref}1")
    done

    # LUKS for data pool
    if [[ "$denc" == "LUKS" ]]; then
        data_luks_devs=()
        for i in "${!data_disks[@]}"; do
            local disk="${data_disks[$i]}"
            local pref; [[ "$disk" =~ nvme|mmcblk ]] && pref="${disk}p" || pref="$disk"
            local part="${pref}1"

            echo -n "$dpass" | cryptsetup luksFormat \
                --type luks2 --cipher aes-xts-plain64 \
                --key-size 512 --hash sha256 --key-file - "$part"
            local uuid; uuid=$(blkid -s UUID -o value "$part")
            echo -n "$dpass" | cryptsetup open --key-file - "$part" "luks-data-${uuid}"
            wait_for_dev "/dev/mapper/luks-data-${uuid}"
            data_luks_devs+=("/dev/mapper/luks-data-${uuid}")
        done
        data_root_ids=("${data_luks_devs[@]}")
    fi

    # Build vdev args
    local vdev_args=()
    case "$draid" in
        single) vdev_args=("${data_root_ids[0]}") ;;
        mirror) vdev_args=(mirror "${data_root_ids[@]}") ;;
        raidz1) vdev_args=(raidz  "${data_root_ids[@]}") ;;
        raidz2) vdev_args=(raidz2 "${data_root_ids[@]}") ;;
        raidz3) vdev_args=(raidz3 "${data_root_ids[@]}") ;;
        raid0)  vdev_args=("${data_root_ids[@]}") ;;
    esac

    log_step "Creating data pool '$dpool'"
    if [[ "$denc" == "ZFSENC" ]]; then
        echo -n "$dpass" | zpool create \
            -o ashift=12 -o autotrim=on \
            -O acltype=posixacl -O compression=lz4 \
            -O dnodesize=auto -O xattr=sa \
            -O canmount=off -O mountpoint=/data \
            -O encryption=aes-256-gcm \
            -O keylocation=prompt \
            -O keyformat=passphrase \
            "$dpool" "${vdev_args[@]}" -f
    else
        zpool create \
            -o ashift=12 -o autotrim=on \
            -O acltype=posixacl -O compression=lz4 \
            -O dnodesize=auto -O xattr=sa \
            -O canmount=off -O mountpoint=/data \
            "$dpool" "${vdev_args[@]}" -f
    fi

    zpool list "$dpool" || die "Data pool creation failed"
    zfs create -o mountpoint=/data "${dpool}/data"

    # Store key file for auto-unlock on next boot (ZFS native enc only)
    if [[ "$denc" == "ZFSENC" ]]; then
        local key_file="/etc/zfs/${dpool}.key"
        echo -n "$dpass" > "$key_file"
        chmod 400 "$key_file"
        zfs set keylocation="file://${key_file}" "$dpool"
        log_info "Auto-unlock key: $key_file"
    fi

    zpool set cachefile=/etc/zfs/zpool.cache "$dpool" 2>/dev/null || true
    systemctl enable zfs-import-cache zfs-mount zfs.target 2>/dev/null || true

    log_success "Data pool '$dpool' ready"
    wt_msg "Data Pool Created" \
"Data pool '${dpool}' created!

  Topology   : $draid  (${#data_disks[@]} disk(s))
  Encryption : $denc
  Mountpoint : /data/${dpool}

Pool status:
$(zpool status "$dpool" 2>/dev/null | head -12)"
}

###############################################################################
# Usage
###############################################################################
show_usage() {
    cat <<EOF
$(echo -e "${BOLD}${CYAN}Ubuntu ZFS AllIn Installer v${SCRIPT_VERSION}${NC}")

Usage:  sudo bash ${SCRIPT_NAME} <command>

Commands:
  initial       Full fresh install from Ubuntu Live USB
                (or add new dataset if WIPE_FRESH=n in config)
  postreboot    Post-reboot setup (run after first login on new system)
  remoteaccess  Configure Dropbear SSH for remote unlock at boot
  datapool      Create an optional additional ZFS data pool

Config file:    ./ZFS-root.conf  (see ZFS-root.conf.example)
Override path:  CONFIG=/path/to/conf sudo bash ${SCRIPT_NAME} initial

Debug mode:     DEBUG=1 sudo bash ${SCRIPT_NAME} initial

Workflow:
  1. Boot from Ubuntu Live USB
  2. sudo bash ${SCRIPT_NAME} initial
  3. Remove media, reboot, log in
  4. sudo bash ${SCRIPT_NAME} postreboot
  5. (optional) sudo bash ${SCRIPT_NAME} remoteaccess
  6. (optional) sudo bash ${SCRIPT_NAME} datapool

For help / bugs: https://github.com/rozsay/ZFS_AllIn
EOF
}

###############################################################################
# Entry point
###############################################################################
# Root check before anything else — setup_logging needs mkdir (root-only dir)
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root."
    echo -e "        Re-run with: ${BOLD}sudo bash $SCRIPT_NAME ${1:-}${NC}"
    exit 1
fi

# Load config early (before logging) so LOGDIR can be overridden
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

# Ensure whiptail is available before we can use the TUI
command -v whiptail &>/dev/null \
    || { apt-get update -qq; apt-get install -y whiptail; }

setup_logging

case "${1:-}" in
    initial)      cmd_initial ;;
    postreboot)   cmd_postreboot ;;
    remoteaccess) cmd_remoteaccess ;;
    datapool)     cmd_datapool ;;
    *)            show_usage ;;
esac
