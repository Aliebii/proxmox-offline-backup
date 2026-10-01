# Proxmox Offline Backup

A Bash backup workflow with explicit safety checks for Proxmox VE virtual machines using removable/offline storage.

The script detects the configured backup filesystem by UUID, validates the environment before mounting, enables the corresponding Proxmox storage, runs `vzdump`, verifies each archive, and attempts storage disable and unmount on success or failure.

This automates standard Proxmox commands for a connect–back up–disconnect
routine. Archive verification is not a substitute for a restore test. Automatic
restore testing, retention and scheduling are outside the current implementation.

The goal is simple:

```text
Connect drive
    ↓
Run one command
    ↓
Detect → Validate → Mount → Backup → Verify → Cleanup
    ↓
SAFE TO DISCONNECT
```

## Features

- Detects the backup filesystem by UUID instead of relying on `/dev/sdX` device names
- Rotates named disks, selecting exactly one connected configured UUID
- Supports per-disk mount types, including tested ext4 and kernel `ntfs3`
- Records a manifest beside each successfully verified archive
- Validates the mount point before mounting
- Refuses to mount over unexpected files
- Validates the configured Proxmox storage path
- Validates all configured VM IDs before starting
- Supports multiple QEMU VMs
- Uses Proxmox `vzdump` snapshot backups
- Uses Zstandard (`zstd`) compression
- Automatically identifies the archive created by each backup run
- Performs full VMA archive verification after backup
- Supports `--dry-run`
- Writes timestamped logs
- Tracks the current workflow stage for useful failure messages
- Automatically performs cleanup on success or failure
- Disables Proxmox storage after use
- Flushes pending filesystem writes before unmounting
- Only reports `SAFE TO DISCONNECT` after successful cleanup
- Prevents concurrent script runs with a host-wide `flock` lock
- Rejects mounts on the backup device and sibling partitions of its backing disk
- Checks required commands before mounting and available space before each VM

## Why Offline Backup?

Keeping a backup drive permanently mounted makes it continuously accessible to the host.

This project is designed for a removable backup workflow:

1. Connect the backup drive.
2. Run the backup script.
3. Wait for backup and verification to complete.
4. Wait for `SAFE TO DISCONNECT`.
5. Physically disconnect the drive.

When not in use, the backup disk can remain offline.

## Requirements

Requires util-linux **2.37 or newer**, specifically an `lsblk` that supports the
`MOUNTPOINTS` column. Preflight probes this capability and exits with code `15`
and an explanatory message if the query fails. Older installations without
this column are unsupported; there is no fallback to `MOUNTPOINT`.

Designed for Proxmox VE hosts using:

- Bash
- Proxmox VE
- QEMU virtual machines
- `vzdump`
- `pvesm`
- `qm`
- `vma`
- `zstd`
- `findfs`
- `findmnt`
- `lsblk`, `flock`, `df`, and standard GNU/Linux command-line utilities

Install and run on the Proxmox host as **root**. The tests require Linux,
Bash and Python **3.10+**; Python is not a runtime dependency of the backup script.
The intended default is ext4. NTFS was tested with the kernel `ntfs3` driver;
that does not establish support for `ntfs-3g`, exFAT or other drivers.

The current implementation reads Proxmox storage configuration from:

```text
/etc/pve/storage.cfg
```

The backup target must already have a filesystem and a persistent filesystem UUID.

The script does **not** partition or format backup disks.

## Repository Files

```text
proxmox-offline-backup/
├── proxmox-offline-backup.sh
├── config.example
├── .gitignore
├── .gitattributes
├── .github/workflows/tests.yml
├── tests/
│   ├── test_safety.py
│   └── test_workflow.py
├── README.md
└── LICENSE
```

The real host configuration should not be committed to the repository.

## Installation

From the repository directory, run as root on the Proxmox host:

```bash
install -o root -g root -m 750 proxmox-offline-backup.sh /usr/local/sbin/proxmox-offline-backup
```

The script and configuration must use Unix (`LF`) line endings. The repository
includes `.gitattributes` to preserve these on checkout.

For a **first installation**, create the configuration only if it is absent:

```bash
if [ ! -e /etc/proxmox-offline-backup.conf ]; then
    install -o root -g root -m 600 config.example /etc/proxmox-offline-backup.conf
fi
```

Edit `/etc/proxmox-offline-backup.conf`: set the filesystem UUID, mount type,
storage name and VM IDs. The examples below are placeholders, not host settings.
Create the chosen mount directory (this does not format or mount a disk):

```bash
mkdir -p /mnt/backup
```

Complete the [Proxmox storage setup](#proxmox-storage), then run
`proxmox-offline-backup --dry-run`. Only after that succeeds, run
`proxmox-offline-backup` for a real backup. Dry-run cannot validate the mounted
filesystem or prove there will be enough space for the backup.

For upgrades, preserve a copy of the installed script first and keep your
existing configuration. Do not replace it with `config.example`.

## Configuration

Example:

```bash
BACKUP_UUID="YOUR-BACKUP-FILESYSTEM-UUID"
EXPECTED_FSTYPE="ext4"

MOUNT_POINT="/mnt/backup"
PVE_STORAGE="offline-backup"

VM_IDS=(100)
MIN_FREE_BYTES=1073741824
```

Multiple VMs can be configured:

```bash
VM_IDS=(100 101 102 103)
```

### BACKUP_UUID

Filesystem UUID of the removable backup filesystem.

You can inspect filesystems with:

```bash
lsblk -f
```

or locate a known UUID with:

```bash
findfs UUID="YOUR-UUID"
```

Using a filesystem UUID avoids depending on names such as `/dev/sdb1`, which can change between boots or when USB devices are reconnected.

### Rotating offline disks

For rotation, **replace** `BACKUP_UUID` with an associative array:

```bash
declare -A BACKUP_DISKS=(
    ["Disk A"]="FILESYSTEM-UUID-A"
    ["Disk B"]="FILESYSTEM-UUID-B"
    ["Disk C"]="FILESYSTEM-UUID-C"
)
```

Connect exactly one configured disk per run. The script selects it by UUID and
logs its name during selection and cleanup. No connected configured disk exits
with code `20`; multiple connected configured disks exit with code `37`, before
mount or storage changes. Unlisted disks are not selected. Duplicate configured
UUIDs, an empty array, or combining `BACKUP_UUID` with `BACKUP_DISKS` are errors.
Disk names may contain spaces, but not tabs or line breaks.

All disks share `MOUNT_POINT` and `PVE_STORAGE`. `EXPECTED_FSTYPE` remains the
required default mount type. Optionally override it by disk name:

```bash
declare -A BACKUP_FSTYPES=(
    ["Disk B"]="ntfs3"
)
```

Here Disk B uses the Linux kernel NTFS driver; disks without an override use
`EXPECTED_FSTYPE` (for example, `ext4`). Overrides require `BACKUP_DISKS`;
unknown names and empty or malformed types are configuration errors. A valid
type name does not establish driver availability or filesystem support. The
selected type is logged, passed to mount, and checked after mounting. Dry-run
does not mount or verify the actual filesystem type.

Each disk must be prepared separately with a unique filesystem UUID; cloned filesystems retaining
the same UUID are unsupported. This is rotation, not replication: an invocation
backs up only to the attached disk. Existing `BACKUP_UUID` configurations keep
working, with the display name `Backup disk`.

### Per-archive manifest

After each successful VMA verification, the script writes
`dump/<archive>.vma.zst.manifest.tsv` beside the archive on the selected disk.
It is a UTF-8 text file of tab-separated key/value lines with schema version `1`:

- `disk_name`, `filesystem_uuid`, `vm_id`
- `archive` (path relative to the disk mount point), `size_bytes`
- `backup_started_epoch` (Unix seconds), `verified_at_utc` (UTC timestamp)
- `verification` (`passed`), `schema_version`

The file is written to a temporary file in the archive directory and published
by rename. A recording failure exits with code `38`, keeps the archive and runs
cleanup. Failed backups or verification do not create success manifests.
Earlier verified VMs retain their manifests if a later VM fails. The manifest
records archive verification, not a successful restore or guest boot test.

No central database, checksum pass, retention or restore automation is added.
The manifest is metadata, not proof against later corruption or permission to
delete archives. Dry-run writes no manifests. Interrupted runs can leave temporary
files after uncatchable termination or power loss; only `.manifest.tsv` files
are published records. Final `sync` and unmount remain required for safe removal.

### EXPECTED_FSTYPE

Expected filesystem type after mounting.

Example:

```bash
EXPECTED_FSTYPE="ext4"
```

The script checks the mounted filesystem and aborts if it does not match.

### MOUNT_POINT

Directory where the removable filesystem will temporarily be mounted.

Example:

```bash
MOUNT_POINT="/mnt/backup"
```

The directory must already exist.

### PVE_STORAGE

The Proxmox storage ID corresponding to the backup directory.

Example:

```bash
PVE_STORAGE="offline-backup"
```

The storage must already exist in Proxmox and its configured `path` must match `MOUNT_POINT`.

### VM_IDS

Bash array containing the QEMU VM IDs to back up.

Example:

```bash
VM_IDS=(100 101 102)
```

All configured VM IDs are validated before the script mounts the backup filesystem or starts a backup.

### MIN_FREE_BYTES

Minimum free bytes required before starting each VM backup. Defaults to
`1073741824` (1 GiB). Increase this to suit your backup sizes. This is a minimum
threshold, not a prediction or reservation of the space required by the next
backup; a backup can still run out of space. No old archives are deleted.

## Proxmox Storage

Create a Proxmox **Directory** storage that points to the same directory configured as `MOUNT_POINT`.

For a new setup, use **Datacenter → Storage → Add → Directory** in the Proxmox
web interface. Set the directory to the existing mount path, select backup
content, restrict it to the intended node, and leave it disabled. Use its ID
as `PVE_STORAGE`. The command below configures an **existing** storage; it does
not create one. Do not start backup jobs until mountpoint protection is set.

Example concept:

```text
Storage ID: offline-backup
Directory:  /mnt/backup
Content:    Backup
```

The storage **must be disabled at startup**, including for dry-run. It must also
have `is_mountpoint` enabled, or set to the same mount path. Configure these once
on the Proxmox host, while no jobs are using this storage:

```bash
pvesm set offline-backup --disable 1 --is_mountpoint 1
```

Example `/etc/pve/storage.cfg` entry:

```text
dir: offline-backup
    path /mnt/backup
    content backup
    disable 1
    is_mountpoint 1
```

`is_mountpoint` makes Proxmox consider the storage offline when its expected
mount is absent, protecting against writes into the host filesystem. See the
[official Proxmox storage command reference](https://pve.proxmox.com/pve-docs/pvesm.1.html).
The script validates both settings before mounting and refuses an unsafe
configuration; it does not change these prerequisites during preflight.
For compatibility with Proxmox boolean parsing, a present `disable` line without
a value is accepted as `disable 1`. A missing `disable` setting is still rejected.
Paths are resolved before comparison, so a trailing slash is accepted.

The script enables it during the backup workflow and disables it again during cleanup.

### Important Safety Consideration

A directory such as:

```text
/mnt/backup
```

still exists on the Proxmox root filesystem when the removable disk is not mounted.

If software writes backup data to that directory while the external filesystem is absent, the data could be written to the Proxmox system disk instead.

To reduce this risk, the script:

- expects the mount point to be unmounted at startup
- checks that the unmounted directory is empty
- mounts the configured filesystem itself
- validates its UUID and filesystem type
- requires Proxmox `is_mountpoint` protection and initially disabled storage
- only then enables the Proxmox storage

If unexpected files exist in the unmounted mount point, the script refuses to continue.

## Dry Run

Before the first real backup, run:

```bash
/usr/local/sbin/proxmox-offline-backup --dry-run
```

Dry-run mode performs preflight validation without:

- mounting the backup filesystem
- enabling Proxmox storage
- creating VM backups

A successful dry run should finish with:

```text
[OK] DRY-RUN completed successfully.
[OK] Cleanup completed successfully.
```

## Running a Backup

Connect the configured backup drive.

Do not manually mount it.

Other partitions on the same backing disk must also be unmounted. The script
checks the block-device topology and the current mount table before starting
and again during cleanup. Use a dedicated removable disk, and do not mount it
or start other jobs using it while this workflow is running. These checks cover
the host's current mount namespace; they do not coordinate other mount
namespaces or unrelated storage users.

Active swap reported by `lsblk` on the disk or its descendants is rejected.
Disks with any Btrfs filesystem in this device family are also rejected, even
when unmounted: the mount-table device-number check cannot reliably establish
Btrfs safety. A dedicated ext4 disk remains the intended setup. This check is
not a general inventory of raw block-device users or multi-device filesystems.

Mount uses `-t "$EXPECTED_FSTYPE" -o nodev,nosuid,noexec`. Commands run through
the logging wrapper, including mount helpers, receive file descriptor 9 closed;
a background FUSE helper cannot keep the workflow lock through that descriptor.

Run:

```bash
/usr/local/sbin/proxmox-offline-backup
```

The script will perform approximately this workflow:

```text
Load configuration
        ↓
Locate filesystem by UUID
        ↓
Validate mount point
        ↓
Validate Proxmox storage definition
        ↓
Validate configured VMs
        ↓
Mount backup filesystem
        ↓
Validate mounted UUID + filesystem type
        ↓
Enable Proxmox storage
        ↓
Backup VM
        ↓
Identify newly created archive
        ↓
Verify archive
        ↓
Repeat for remaining VMs
        ↓
Disable Proxmox storage
        ↓
sync
        ↓
Unmount
        ↓
SAFE TO DISCONNECT
```

Do not physically disconnect the backup drive while the script is running.

## Backup Method

Each configured VM is backed up using:

```bash
vzdump VMID \
    --storage STORAGE_ID \
    --mode snapshot \
    --compress zstd \
    --remove 0
```

This uses Proxmox snapshot backup mode and Zstandard compression.

`--remove 0` means the backup command itself does not remove older backups.

## Archive Identification

Before starting each VM backup, the script creates a temporary timestamp marker.

After `vzdump` completes, it searches for a new archive matching:

```text
vzdump-qemu-VMID-*.vma.zst
```

that is newer than the marker.

The script refuses to guess if zero or multiple new matching archives are detected.

## Backup Verification

A completed `vzdump` operation is not treated as the end of the workflow.

The resulting compressed archive is streamed through:

```bash
zstd -dc BACKUP_FILE | vma verify - -v
```

This decompresses the archive as a stream and sends the VMA data directly to Proxmox `vma verify`.

No temporary uncompressed copy of the VM backup is required.

If verification fails, the workflow exits with an error and performs cleanup.

## Cleanup and Failure Handling

An `EXIT` trap runs the cleanup routine when the script finishes.

`INT`, `TERM`, and `HUP` request a failing exit through cleanup. Forced termination
(`SIGKILL`) and power loss cannot run cleanup. A host-wide lock at
`/run/lock/proxmox-offline-backup.lock` remains held through cleanup; a second
invocation, including dry-run, exits with code `16`. Do not delete the lock file
to bypass an active run. The lock coordinates this script, not other Proxmox jobs.

A signal sent only to the Bash process does **not** immediately cancel a running
foreground command. Bash defers its trap until that command/pipeline finishes;
for `vzdump` this may take hours. The script does not forward signals to backup
workers. See [Bash signal handling](https://www.gnu.org/software/bash/manual/html_node/Signals.html).
Wait for cleanup before disconnecting the disk. During a mount attempt, cleanup
checks the actual mounted UUID to recover a successful mount whose command
failed or whose success flag was interrupted. Storage disable responsibility is
recorded before attempting enable, so a partial enable is also cleaned up.

If the script attempted to enable Proxmox storage, cleanup attempts to disable it.

If the script mounted the backup filesystem, cleanup:

1. runs `sync`
2. attempts to unmount the filesystem

A failed log write does not stop cleanup. A failed disable, sync, or unmount
operation is recorded, and remaining cleanup steps are still attempted. A failed
final disk mount-state check also prevents the safe-disconnect message.

The script only prints:

```text
SAFE TO DISCONNECT the backup drive.
```

after successful cleanup and a final disk-state check. If the backup failed but
cleanup succeeded, it explicitly reports that disconnecting is safe **and the
backup workflow failed**; the exit status remains nonzero. When preflight fails
before disk safety is established, no safe-disconnect claim is made.

If cleanup fails, it explicitly warns:

```text
DO NOT disconnect the backup drive.
```

## Logging

The script writes logs to:

```text
/var/log/proxmox-offline-backup.log
```

Example:

```text
[2026-09-28 20:56:42] [OK] Configuration loaded and validated.
[2026-09-28 20:56:43] [INFO] Mounting backup filesystem...
[2026-09-28 21:01:16] [OK] Backup completed for VM 100...
[2026-09-28 21:05:01] [OK] Backup verification passed for VM 100.
[2026-09-28 21:05:02] [OK] SAFE TO DISCONNECT the backup drive.
```

The log records the workflow stage and VM ID when relevant, making failures easier to diagnose.

Backup, verification, mount, storage enable/disable, sync, and unmount output
(including stderr) is also captured. Command failures retain their exit status
through the logging pipeline. If the log file is unavailable, warnings are sent
to stderr and cleanup continues; the log may be incomplete in that case.

## Exit Codes

The script uses dedicated exit codes for common failure conditions.

| Code | Meaning |
|---:|---|
| `0` | Successful completion |
| `10` | Configuration file not found |
| `11` | Missing or invalid configuration, including disk/type mappings |
| `12` | Invalid or missing `VM_IDS` configuration |
| `13` | Unknown command-line option |
| `14` | Script was not run as root |
| `15` | Required command is missing or the lsblk MOUNTPOINTS query fails |
| `16` | Another invocation holds the workflow lock |
| `20` | Configured backup filesystem UUID not found |
| `21` | Mount point does not exist |
| `22` | Mount point is already mounted/in use |
| `23` | Unmounted mount point contains files |
| `24` | Mounted filesystem UUID mismatch |
| `25` | Mounted filesystem type mismatch |
| `26` | Unable to determine Proxmox storage path |
| `27` | Proxmox storage path does not match mount point |
| `28` | Proxmox storage did not become active |
| `29` | Backup disk has mounted filesystems or its mount state cannot be checked |
| `30` | Configured VM does not exist |
| `31` | `vzdump` backup failed |
| `32` | New backup archive could not be uniquely identified |
| `33` | VMA archive verification failed |
| `34` | Available backup space cannot be determined or is below the configured minimum |
| `35` | Proxmox storage is not disabled at startup |
| `36` | Proxmox `is_mountpoint` protection is missing or points elsewhere |
| `37` | Multiple configured backup disks are connected |
| `38` | Verified archive manifest could not be recorded |
| `90` | Main workflow succeeded but safe cleanup failed |

## Retention

Automatic retention cleanup is intentionally **disabled in the current version**.

The script does not automatically delete old backup archives.

This is deliberate: retention requirements depend on VM sizes, backup frequency, available disk capacity, and the number of protected VMs.

Until a retention policy is implemented, monitor available space on the backup filesystem and manage older backups manually.

## Restoring

This project automates backup creation and archive verification.

Restore remains a standard Proxmox operation.

For example:

```bash
qmrestore /path/to/vzdump-qemu-VMID-DATE-TIME.vma.zst NEW_VMID --storage TARGET_STORAGE --start 0 --ha-managed 0
```

Always choose an unused VM ID and appropriate target storage.

These are placeholders: replace the archive path, VM ID and destination storage.
Identify the source disk by UUID and mount it for reading first; do not run the
backup script concurrently. The archive is a standard Proxmox VMA.ZST file:
restoring it does not require this script or its TSV manifest.

For a **restore drill**, keep the restored VM stopped while disabling autostart
and removing all network interfaces. Inspect passthrough devices, hooks and
custom QEMU arguments before booting; they can expose host resources even when
NICs are absent. Then boot in isolation and check the guest and its data.
Unmount the source disk when the restore has finished. A disaster recovery
restore and an isolated test have different network requirements.

For production systems, periodically perform an actual restore test. Archive verification confirms archive integrity, while a restore test additionally validates the practical recovery process.

## Tested Workflow

On 2026-09-30, mixed-filesystem rotation was tested on a Proxmox host running
kernel `7.0.2-6-pve`, using two USB flash drives (ext4 and kernel `ntfs3`). The
same configuration, including `BACKUP_FSTYPES`, was used for both runs; its
SHA256 stayed unchanged when the drives were exchanged. The source was a
stopped CirrOS VM with a 1 GiB virtual disk and an 8 MiB random test file.
Both runs selected the correct UUID and mount type, produced approximately
38.7 MB archives, passed VMA verification and independent manifest checks,
and disabled storage and unmounted successfully. Each archive was restored
to a separate VM without networking; both guests booted and their test files
matched the original SHA256 hashes. The restored guests were shut down after
verification. The tested script SHA256 was
`b0194b6b71ff1cc8d13925516afb1e7308ce99156a523b7d8c65e9fc5f5a2864`.

This validates the tested configuration, not every NTFS driver or USB device.
The mixed-filesystem test did not cover a running guest, power loss, physical
disk failure, or guest-agent checks. Simultaneous-disk rejection was tested
on the preceding script revision and is covered by the current mock tests.

Local safety regression tests use mocked storage and backup commands, without
mounting disks or running Proxmox operations:

```bash
python3 -B -m unittest discover -s tests -v
bash -n proxmox-offline-backup.sh
```

The full-workflow suite runs a temporary copy with only host-specific paths and
the root check replaced. It covers multiple VMs, dry-run, storage prerequisites,
partial mount/enable failures, backup and verification failures, concurrent
script invocations, inherited lock descriptors, and signals during mount/backup.

These tests do not replace validation on a Proxmox host. The historical
end-to-end test below predates the safety changes described above.

The initial end-to-end validation was performed on Proxmox VE 9.2.2 with:

- removable ext4 backup storage
- QEMU VM backup
- snapshot mode
- Zstandard compression
- guest agent filesystem freeze/thaw
- full streamed VMA verification
- successful cleanup and unmount

A separate restore test was also performed manually before automating the workflow.

That test included:

- restoring the archive to a different VM ID
- isolating its network interface before the first boot
- booting the restored VM
- confirming application data was present
- shutting down and deleting the temporary restore VM

> Testing on one environment does not guarantee compatibility with every Proxmox version, storage backend, guest configuration, or filesystem. Test with `--dry-run` and perform recovery testing in your own environment before relying on it for production backups.

## Current Scope

The current version is intentionally focused on local/offline Proxmox VM backups.

Not currently implemented:

- automatic retention
- cloud replication
- email or external alerting managed by this script
- scheduled automatic backups
- automatic restore testing
- web dashboard
- container (LXC) backup support

These can be added independently without changing the core offline-backup safety model.

Future work may include explicit disk identity, recovery history/status and
isolated restore drills. These are plans, not available commands.

## Security Notes

The local configuration file is sourced by Bash and should therefore be writable only by trusted administrators.

Recommended permissions:

```bash
chmod 600 /etc/proxmox-offline-backup.conf
```

The script itself should also be protected from unauthorized modification.

Example:

```bash
chown root:root /usr/local/sbin/proxmox-offline-backup
chmod 750 /usr/local/sbin/proxmox-offline-backup
```

Do not commit the real local configuration file to Git.

## License

See [LICENSE](LICENSE).
