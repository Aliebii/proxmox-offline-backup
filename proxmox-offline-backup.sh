#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Proxmox Offline Backup
# Fail-safe backup workflow for removable/offline storage
# ============================================================

CONFIG_FILE="/etc/proxmox-offline-backup.conf"
LOG_FILE="/var/log/proxmox-offline-backup.log"
LOCK_FILE="/run/lock/proxmox-offline-backup.lock"

DRY_RUN=false

# Runtime state
MOUNTED_BY_SCRIPT=false
STORAGE_ENABLED_BY_SCRIPT=false
MARKER_FILE=""
CURRENT_VM=""
CURRENT_STAGE="startup"
DISK_CHECK_REQUIRED=false
MOUNT_ATTEMPTED=false
MANIFEST_TEMP=""


# ============================================================
# Basic logging before configuration is loaded
# ============================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" || true
    if ! { printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" >> "$LOG_FILE"; } 2>/dev/null; then
        printf 'WARNING: Log file unavailable: %s\n' "$LOG_FILE" >&2 || true
    fi
    return 0
}

# Preserve command/pipeline failures while capturing diagnostic output.
run_logged() {
    local -a statuses
    "$@" 9>&- 2>&1 | tee -a "$LOG_FILE" 9>&- || {
        statuses=("${PIPESTATUS[@]}")
        if (( statuses[1] != 0 )); then
            printf 'WARNING: Could not capture command output in %s\n' "$LOG_FILE" >&2 || true
        fi
        return "${statuses[0]}"
    }
    return 0
}

verify_archive() {
    zstd -dc "$1" | vma verify - -v
}

# One sidecar per verified archive; publish with a same-directory
# rename so an interrupted write never leaves a partial final manifest.
write_manifest() {
    local relative_path="${BACKUP_FILE#"$MOUNT_POINT/"}" verified_at
    [[ "$relative_path" != "$BACKUP_FILE" && "$relative_path" != *$'\t'* &&
       "$relative_path" != *$'\n'* && "$relative_path" != *$'\r'* ]] || return 1
    verified_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
    MANIFEST_TEMP="$(mktemp "${BACKUP_FILE}.manifest.tmp.XXXXXX")" || return 1
    printf '%s\t%s\n' \
        schema_version 1 disk_name "$BACKUP_DISK_NAME" filesystem_uuid "$BACKUP_UUID" \
        vm_id "$VM_ID" archive "$relative_path" size_bytes "$BACKUP_SIZE_BYTES" \
        backup_started_epoch "$BACKUP_START" verified_at_utc "$verified_at" \
        verification passed > "$MANIFEST_TEMP" || return 1
    mv -fT -- "$MANIFEST_TEMP" "${BACKUP_FILE}.manifest.tsv" || return 1
    MANIFEST_TEMP=""
}

# Include sibling partitions of the backing disk, not just our mount point.
# Failure to inspect the device or mount table is a safety failure.
check_disk_unmounted() {
    local ancestors device ids="" current_ids mounts matches usage
    ancestors="$(lsblk --inverse --noheadings --raw --paths --output NAME "$BACKUP_DEVICE")" || return 1
    [[ -n "$ancestors" ]] || return 1
    while IFS= read -r device; do
        current_ids="$(lsblk --noheadings --raw --output MAJ:MIN "$device")" || return 1
        [[ -n "$current_ids" ]] || return 1
        ids+="$current_ids"$'\n'
        usage="$(lsblk --noheadings --raw --output FSTYPE,MOUNTPOINTS "$device")" || return 1
        if [[ "$usage" == *'[SWAP]'* ]] || grep -Eq '(^|[[:space:]])btrfs([[:space:]]|$)' <<< "$usage"; then
            log "ERROR" "Active swap or unsupported Btrfs filesystem on backup disk: $device"
            return 1
        fi
    done <<< "$ancestors"
    mounts="$(findmnt --kernel --list --noheadings --output MAJ:MIN,TARGET)" || return 1
    matches="$(awk -v ids="$ids" 'BEGIN { n=split(ids,a,"\n"); for(i=1;i<=n;i++) seen[a[i]]=1 } seen[$1]' <<< "$mounts")" || return 1
    if [[ -n "$matches" ]]; then
        log "ERROR" "Backup disk still has mounted filesystems: $matches"
        return 1
    fi
}


# ============================================================
# Cleanup
# ============================================================

cleanup() {
    local original_exit_code=$?
    local cleanup_failed=false

    # Prevent the EXIT trap from running recursively.
    trap - EXIT
    trap '' INT TERM HUP
    set +e

    log "INFO" "Starting cleanup."

    # A command may mount successfully then fail or receive a deferred signal
    # before the success flag is assigned. Reconcile against the actual UUID.
    if [[ "${MOUNT_ATTEMPTED:-false}" == true && "$MOUNTED_BY_SCRIPT" == false ]]; then
        local observed_uuid
        observed_uuid="$(findmnt -no UUID --mountpoint "$MOUNT_POINT" 9>&-)"
        if [[ -n "$observed_uuid" && "$observed_uuid" == "$BACKUP_UUID" ]]; then
            MOUNTED_BY_SCRIPT=true
        elif [[ -n "$observed_uuid" ]]; then
            log "ERROR" "Unexpected filesystem at backup mount point; refusing to unmount it."
            cleanup_failed=true
        fi
    fi

    if [[ -n "${MANIFEST_TEMP:-}" ]]; then
        rm -f -- "$MANIFEST_TEMP" || cleanup_failed=true
    fi

    if [[ -n "${BACKUP_DISK_NAME:-}" ]]; then
        log "INFO" "Cleanup disk: $BACKUP_DISK_NAME (UUID=$BACKUP_UUID)"
    fi

    # Remove temporary marker if it still exists.
    if [[ -n "${MARKER_FILE:-}" && -f "$MARKER_FILE" ]]; then
        rm -f "$MARKER_FILE" || true
        MARKER_FILE=""
    fi

    # Disable storage whenever enable was attempted, even if it returned failure.
    if [[ "$STORAGE_ENABLED_BY_SCRIPT" == true ]]; then
        log "INFO" "Disabling Proxmox storage: $PVE_STORAGE"

        if run_logged pvesm set "$PVE_STORAGE" --disable 1; then
            STORAGE_ENABLED_BY_SCRIPT=false
            log "OK" "Proxmox storage disabled: $PVE_STORAGE"
        else
            log "ERROR" "Failed to disable Proxmox storage: $PVE_STORAGE"
            cleanup_failed=true
        fi
    fi

    # Flush and unmount only if this script mounted the filesystem.
    if [[ "$MOUNTED_BY_SCRIPT" == true ]]; then
        log "INFO" "Flushing pending filesystem writes."
        if ! run_logged sync; then
            log "ERROR" "Failed to flush filesystem writes."
            cleanup_failed=true
        fi

        log "INFO" "Unmounting backup storage: $MOUNT_POINT"

        if run_logged umount "$MOUNT_POINT"; then
            MOUNTED_BY_SCRIPT=false
            log "OK" "Backup storage unmounted successfully."
        else
            log "ERROR" "Failed to unmount backup storage: $MOUNT_POINT"
            cleanup_failed=true
        fi
    fi

    if [[ "$DISK_CHECK_REQUIRED" == true ]]; then
        if ! check_disk_unmounted; then
            log "ERROR" "Cannot confirm that the backup disk is unmounted."
            cleanup_failed=true
        fi
    fi

    if [[ "$cleanup_failed" == true ]]; then
        log "ERROR" "Cleanup did not complete safely."
        log "ERROR" "DO NOT disconnect the backup drive."

        if (( original_exit_code == 0 )); then
            exit 90
        else
            exit "$original_exit_code"
        fi
    fi

    if (( original_exit_code == 0 )); then
        log "OK" "Cleanup completed successfully."

        if [[ "$DRY_RUN" == false && "$DISK_CHECK_REQUIRED" == true ]]; then
            log "OK" "SAFE TO DISCONNECT the backup drive."
        fi

        exit 0
    fi

    log "ERROR" "Backup workflow failed."
    log "ERROR" "Stage: $CURRENT_STAGE"

    if [[ -n "$CURRENT_VM" ]]; then
        log "ERROR" "VM: $CURRENT_VM"
    fi

    log "ERROR" "Exit code: $original_exit_code"

    if [[ "$DRY_RUN" == false && "$DISK_CHECK_REQUIRED" == true ]]; then
        log "OK" "Cleanup completed successfully. SAFE TO DISCONNECT the backup drive; backup workflow FAILED."
    else
        log "INFO" "This run did not change the disk mount state; disconnection safety was not checked."
    fi

    exit "$original_exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP


# ============================================================
# Command-line options
# ============================================================

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            log "ERROR" "Unknown option: $arg"
            log "ERROR" "Supported option: --dry-run"
            exit 13
            ;;
    esac
done


# ============================================================
# Root privilege check
# ============================================================

CURRENT_STAGE="root-check"

if (( EUID != 0 )); then
    log "ERROR" "This script must be run as root."
    exit 14
fi

# Lock before inspecting mutable storage state; keep the descriptor open
# through EXIT cleanup. Never unlink the lock file (that would create races).
CURRENT_STAGE="preflight"
for command in date tee flock findfs findmnt lsblk awk find qm mount pvesm vzdump zstd vma mktemp stat sync umount rm grep df realpath mv; do
    if ! command -v "$command" >/dev/null 2>&1; then
        log "ERROR" "Required command is missing: $command"
        exit 15
    fi
done
if ! lsblk --noheadings --raw --output MOUNTPOINTS >/dev/null 2>&1; then
    log "ERROR" "Cannot query lsblk MOUNTPOINTS. util-linux 2.37 or newer with working block-device inspection is required."
    exit 15
fi
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "ERROR" "Another backup workflow is already running."
    exit 16
fi

# ============================================================
# Configuration
# ============================================================

CURRENT_STAGE="configuration"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR" "Configuration file not found: $CONFIG_FILE"
    log "ERROR" "Backup has not started."
    exit 10
fi

# Load host-specific configuration.
# shellcheck source=/dev/null
source "$CONFIG_FILE"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-1073741824}"
if [[ ! "$MIN_FREE_BYTES" =~ ^[0-9]{1,18}$ ]]; then
    log "ERROR" "MIN_FREE_BYTES must be a nonnegative integer (up to 18 digits)."
    exit 11
fi


# ============================================================
# Validate configuration
# ============================================================

REQUIRED_VARS=(
    EXPECTED_FSTYPE
    MOUNT_POINT
    PVE_STORAGE
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log "ERROR" "Required configuration value is missing: $var"
        log "ERROR" "Backup has not started."
        exit 11
    fi
done

# Per-disk types are only meaningful with named rotation disks.
if declare -p BACKUP_FSTYPES >/dev/null 2>&1; then
    if [[ "$(declare -p BACKUP_FSTYPES)" != "declare -A "* ]] ||
       ! declare -p BACKUP_DISKS >/dev/null 2>&1; then
        log "ERROR" "BACKUP_FSTYPES must be an associative array used with BACKUP_DISKS."
        exit 11
    fi
else
    declare -A BACKUP_FSTYPES=()
fi

# Keep legacy single-disk configurations compatible, but reject mixed models.
if declare -p BACKUP_DISKS >/dev/null 2>&1; then
    if [[ "$(declare -p BACKUP_DISKS)" != "declare -A "* || -n "${BACKUP_UUID:-}" ]]; then
        log "ERROR" "Use either BACKUP_UUID or an associative BACKUP_DISKS array, not both."
        exit 11
    fi
else
    if [[ -z "${BACKUP_UUID:-}" ]]; then
        log "ERROR" "Configure BACKUP_UUID or BACKUP_DISKS."
        exit 11
    fi
    declare -A BACKUP_DISKS=(["Backup disk"]="$BACKUP_UUID")
fi
if (( ${#BACKUP_DISKS[@]} == 0 )); then
    log "ERROR" "BACKUP_DISKS must not be empty."
    exit 11
fi
declare -A SEEN_UUIDS=()
for disk_name in "${!BACKUP_DISKS[@]}"; do
    uuid="${BACKUP_DISKS[$disk_name]}"
    if [[ "$disk_name" == *$'\t'* || "$disk_name" == *$'\n'* || "$disk_name" == *$'\r'* ||
          ! "$uuid" =~ ^[a-zA-Z0-9-]+$ ]]; then
        log "ERROR" "Invalid disk name or filesystem UUID in BACKUP_DISKS."
        exit 11
    fi
    if [[ -n "${SEEN_UUIDS[$uuid]:-}" ]]; then
        log "ERROR" "Duplicate filesystem UUID in disk configuration: $uuid"
        exit 11
    fi
    SEEN_UUIDS[$uuid]=1
done
for disk_name in "${!BACKUP_FSTYPES[@]}"; do
    if [[ -z "${BACKUP_DISKS[$disk_name]:-}" ||
          ! "${BACKUP_FSTYPES[$disk_name]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log "ERROR" "BACKUP_FSTYPES requires a known disk name and a nonempty filesystem type."
        exit 11
    fi
done

if ! declare -p VM_IDS >/dev/null 2>&1; then
    log "ERROR" "VM_IDS is not defined in the configuration file."
    exit 12
fi

if [[ "$(declare -p VM_IDS 2>/dev/null)" != "declare -a"* ]]; then
    log "ERROR" "VM_IDS must be a Bash indexed array."
    log "ERROR" 'Example: VM_IDS=(100 101 102)'
    exit 12
fi

if (( ${#VM_IDS[@]} == 0 )); then
    log "ERROR" "No VM IDs are configured in VM_IDS."
    exit 12
fi

for VM_ID in "${VM_IDS[@]}"; do
    if [[ ! "$VM_ID" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Invalid VM ID in configuration: $VM_ID"
        exit 12
    fi
done

log "OK" "Configuration loaded and validated."


# ============================================================
# Start workflow
# ============================================================

log "INFO" "Proxmox Offline Backup started."

if [[ "$DRY_RUN" == true ]]; then
    log "INFO" "DRY-RUN mode enabled. No mount, storage enable, or backup will be performed."
fi


# ============================================================
# Locate backup filesystem
# ============================================================

CURRENT_STAGE="disk-detection"

# Exactly one configured disk must be attached. Never pick the first match.
BACKUP_DEVICE=""
CONNECTED_DISKS=0
for disk_name in "${!BACKUP_DISKS[@]}"; do
    device="$(findfs UUID="${BACKUP_DISKS[$disk_name]}" 2>/dev/null || true)"
    if [[ -n "$device" ]]; then
        CONNECTED_DISKS=$((CONNECTED_DISKS + 1))
        BACKUP_DEVICE="$device"
        BACKUP_UUID="${BACKUP_DISKS[$disk_name]}"
        BACKUP_DISK_NAME="$disk_name"
    fi
done
if (( CONNECTED_DISKS == 0 )); then
    log "ERROR" "No configured backup disk found. Connect one permitted disk."
    exit 20
elif (( CONNECTED_DISKS != 1 )); then
    log "ERROR" "Multiple configured backup disks are connected. Connect only one."
    exit 37
fi
EXPECTED_FSTYPE="${BACKUP_FSTYPES[$BACKUP_DISK_NAME]:-$EXPECTED_FSTYPE}"
log "OK" "Selected disk: $BACKUP_DISK_NAME (UUID=$BACKUP_UUID, device=$BACKUP_DEVICE, filesystem=$EXPECTED_FSTYPE)"
if ! check_disk_unmounted; then
    log "ERROR" "Backup disk is mounted or its mount state could not be checked."
    exit 29
fi


# ============================================================
# Validate mount point
# ============================================================

CURRENT_STAGE="mountpoint-validation"

if [[ ! -d "$MOUNT_POINT" ]]; then
    log "ERROR" "Mount point does not exist: $MOUNT_POINT"
    exit 21
fi
MOUNT_POINT="$(realpath -e -- "$MOUNT_POINT")"

if findmnt --mountpoint "$MOUNT_POINT" >/dev/null 2>&1; then
    log "ERROR" "Mount point is already in use: $MOUNT_POINT"
    log "ERROR" "The script expects to mount the backup filesystem itself."
    exit 22
fi

if [[ -n "$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    log "ERROR" "Unmounted mount point is not empty: $MOUNT_POINT"
    log "ERROR" "Files may have been written to the Proxmox root filesystem by mistake."
    log "ERROR" "Refusing to mount over existing files."
    exit 23
fi

log "OK" "Mount point is unmounted and empty: $MOUNT_POINT"


# ============================================================
# Validate Proxmox storage definition
# ============================================================

CURRENT_STAGE="storage-validation"

STORAGE_SETTINGS="$(
    awk -v storage="$PVE_STORAGE" '
        $1 == "dir:" && $2 == storage {
            in_storage = 1
            next
        }

        in_storage && /^[^[:space:]]/ {
            exit
        }

        in_storage && ($1 == "path" || $1 == "disable" || $1 == "is_mountpoint") {
            key = $1
            # Proxmox treats a present boolean without a value as true.
            # Do not apply this to missing keys or string-valued properties.
            if (key == "disable" && NF == 1) {
                print key "\t1"
                next
            }
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            print key "\t" $0
        }
    ' /etc/pve/storage.cfg
)"
STORAGE_PATH=""
STORAGE_DISABLED=""
STORAGE_MOUNTPOINT=""
while IFS=$'\t' read -r key value; do
    case "$key" in
        path) STORAGE_PATH="$value" ;;
        disable) STORAGE_DISABLED="$value" ;;
        is_mountpoint) STORAGE_MOUNTPOINT="$value" ;;
    esac
done <<< "$STORAGE_SETTINGS"

if [[ -z "$STORAGE_PATH" ]]; then
    log "ERROR" "Could not determine the configured path for Proxmox storage: $PVE_STORAGE"
    exit 26
fi

if [[ "$(realpath -e -- "$STORAGE_PATH")" != "$MOUNT_POINT" ]]; then
    log "ERROR" "Proxmox storage path does not match the configured mount point."
    log "ERROR" "Storage: $PVE_STORAGE"
    log "ERROR" "Expected path: $MOUNT_POINT"
    log "ERROR" "Proxmox path: $STORAGE_PATH"
    exit 27
fi

case "$STORAGE_DISABLED" in
    1|yes|true|on) ;;
    *) log "ERROR" "Storage must be disabled before starting: pvesm set $PVE_STORAGE --disable 1"; exit 35 ;;
esac
case "$STORAGE_MOUNTPOINT" in
    1|yes|true|on) ;;
    /*)
        if [[ "$(realpath -e -- "$STORAGE_MOUNTPOINT")" != "$MOUNT_POINT" ]]; then
            log "ERROR" "is_mountpoint must refer to the backup mount point."
            exit 36
        fi
        ;;
    *) log "ERROR" "Storage requires protection: pvesm set $PVE_STORAGE --is_mountpoint 1"; exit 36 ;;
esac

log "OK" "Proxmox storage configuration validated: $PVE_STORAGE -> $STORAGE_PATH"


# ============================================================
# Validate configured VMs before making changes
# ============================================================

CURRENT_STAGE="vm-validation"

for VM_ID in "${VM_IDS[@]}"; do
    if ! qm status "$VM_ID" >/dev/null 2>&1; then
        log "ERROR" "Configured VM does not exist on this Proxmox node: $VM_ID"
        exit 30
    fi

    log "OK" "VM $VM_ID exists."
done


# ============================================================
# Dry-run stops before changing system state
# ============================================================

if [[ "$DRY_RUN" == true ]]; then
    log "INFO" "[DRY-RUN] Would mount $BACKUP_DEVICE on $MOUNT_POINT"
    log "INFO" "[DRY-RUN] Would validate UUID and filesystem type after mount."
    log "INFO" "[DRY-RUN] Would enable Proxmox storage: $PVE_STORAGE"

    for VM_ID in "${VM_IDS[@]}"; do
        log "INFO" "[DRY-RUN] Would back up and verify VM $VM_ID."
    done

    log "OK" "DRY-RUN completed successfully."
    exit 0
fi


# ============================================================
# Mount backup filesystem
# ============================================================

CURRENT_STAGE="mount"

log "INFO" "Mounting backup filesystem: $BACKUP_DEVICE -> $MOUNT_POINT"

# Record the attempt first so cleanup can reconcile a partial/deferred failure.
DISK_CHECK_REQUIRED=true
MOUNT_ATTEMPTED=true
run_logged mount -t "$EXPECTED_FSTYPE" -o nodev,nosuid,noexec "$BACKUP_DEVICE" "$MOUNT_POINT"
MOUNTED_BY_SCRIPT=true

MOUNTED_UUID="$(findmnt -no UUID --mountpoint "$MOUNT_POINT" || true)"
MOUNTED_FSTYPE="$(findmnt -no FSTYPE --mountpoint "$MOUNT_POINT" || true)"

if [[ "$MOUNTED_UUID" != "$BACKUP_UUID" ]]; then
    log "ERROR" "Mounted filesystem UUID does not match configuration."
    log "ERROR" "Expected UUID: $BACKUP_UUID"
    log "ERROR" "Detected UUID: ${MOUNTED_UUID:-unknown}"
    exit 24
fi

if [[ "$MOUNTED_FSTYPE" != "$EXPECTED_FSTYPE" ]]; then
    log "ERROR" "Mounted filesystem type does not match configuration."
    log "ERROR" "Expected filesystem: $EXPECTED_FSTYPE"
    log "ERROR" "Detected filesystem: ${MOUNTED_FSTYPE:-unknown}"
    exit 25
fi

log "OK" "Backup filesystem mounted and validated successfully."


# ============================================================
# Enable Proxmox backup storage
# ============================================================

CURRENT_STAGE="storage-enable"

log "INFO" "Enabling Proxmox storage: $PVE_STORAGE"

STORAGE_ENABLED_BY_SCRIPT=true
run_logged pvesm set "$PVE_STORAGE" --disable 0

if ! pvesm status --storage "$PVE_STORAGE" |
    awk 'NR > 1 {print $3}' |
    grep -qx "active"; then

    log "ERROR" "Proxmox storage did not become active: $PVE_STORAGE"
    exit 28
fi

log "OK" "Proxmox storage is active: $PVE_STORAGE"


# ============================================================
# Backup and verify configured VMs
# ============================================================

for VM_ID in "${VM_IDS[@]}"; do
    CURRENT_VM="$VM_ID"
    CURRENT_STAGE="capacity-check"
    FREE_BYTES="$(df --block-size=1 --output=avail "$MOUNT_POINT" | awk 'NR == 2 {print $1}')"
    if [[ ! "$FREE_BYTES" =~ ^[0-9]{1,18}$ ]]; then
        log "ERROR" "Could not determine available backup space."
        exit 34
    fi
    log "INFO" "Available backup space: $FREE_BYTES bytes."
    if (( 10#$FREE_BYTES < 10#$MIN_FREE_BYTES )); then
        log "ERROR" "Available space is below MIN_FREE_BYTES=$MIN_FREE_BYTES."
        exit 34
    fi
    CURRENT_STAGE="backup"

    log "INFO" "Preparing backup for VM $VM_ID"

    MARKER_FILE="$(mktemp)"

    BACKUP_START="$(date +%s)"

    log "INFO" "Starting backup for VM $VM_ID"

    if run_logged vzdump "$VM_ID" \
        --storage "$PVE_STORAGE" \
        --mode snapshot \
        --compress zstd \
        --remove 0; then

        BACKUP_END="$(date +%s)"
        BACKUP_DURATION=$((BACKUP_END - BACKUP_START))

        log "OK" "Backup completed for VM $VM_ID in ${BACKUP_DURATION}s."
    else
        BACKUP_EXIT_CODE=$?

        log "ERROR" "Backup failed for VM $VM_ID."
        log "ERROR" "vzdump exit code: $BACKUP_EXIT_CODE"

        exit 31
    fi


    # --------------------------------------------------------
    # Identify archive created by this backup run
    # --------------------------------------------------------

    CURRENT_STAGE="archive-identification"

    mapfile -t NEW_BACKUPS < <(
        find "$MOUNT_POINT/dump" \
            -maxdepth 1 \
            -type f \
            -name "vzdump-qemu-${VM_ID}-*.vma.zst" \
            -newer "$MARKER_FILE" \
            -print
    )

    if (( ${#NEW_BACKUPS[@]} == 0 )); then
        log "ERROR" "Backup completed, but no new archive could be identified for VM $VM_ID."
        exit 32
    fi

    if (( ${#NEW_BACKUPS[@]} > 1 )); then
        log "ERROR" "More than one new backup archive was detected for VM $VM_ID."
        log "ERROR" "Refusing to guess which archive should be verified."

        for candidate in "${NEW_BACKUPS[@]}"; do
            log "ERROR" "Candidate archive: $candidate"
        done

        exit 32
    fi

    BACKUP_FILE="${NEW_BACKUPS[0]}"

    log "OK" "New backup archive identified: $BACKUP_FILE"


    # --------------------------------------------------------
    # Record archive size
    # --------------------------------------------------------

    BACKUP_SIZE_BYTES="$(stat -c '%s' "$BACKUP_FILE")"

    log "INFO" "Backup archive size: ${BACKUP_SIZE_BYTES} bytes"


    # --------------------------------------------------------
    # Verify archive integrity
    # --------------------------------------------------------

    CURRENT_STAGE="verification"

    log "INFO" "Verifying backup archive for VM $VM_ID"

    if run_logged verify_archive "$BACKUP_FILE"; then
        log "OK" "Backup verification passed for VM $VM_ID."
    else
        VERIFY_EXIT_CODE=$?

        log "ERROR" "Backup verification failed for VM $VM_ID."
        log "ERROR" "Verification pipeline exit code: $VERIFY_EXIT_CODE"

        exit 33
    fi

    CURRENT_STAGE="manifest"
    if ! write_manifest; then
        log "ERROR" "Verified archive exists, but its manifest could not be recorded: $BACKUP_FILE"
        exit 38
    fi
    log "OK" "Manifest recorded for $BACKUP_DISK_NAME: ${BACKUP_FILE}.manifest.tsv"

    rm -f "$MARKER_FILE"
    MARKER_FILE=""

    log "OK" "VM $VM_ID backup cycle completed successfully."
done


# ============================================================
# Retention
# ============================================================

CURRENT_STAGE="retention"

# Retention is intentionally not destructive yet.
# A retention policy will be added after backup sizes and
# multi-VM capacity requirements have been evaluated.

log "INFO" "Retention cleanup is currently disabled."


# ============================================================
# Successful completion
# ============================================================

CURRENT_VM=""
CURRENT_STAGE="completed"

log "OK" "All configured VM backups completed and verified successfully."

exit 0
