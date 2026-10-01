"""Run the complete script against a disposable, mocked Proxmox host.

Only fixed host paths and the root check are replaced in a temporary copy.
Production control flow, locking, traps, pipelines and cleanup are unchanged.
"""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''
import json, os, sys, time
from pathlib import Path
root = Path(os.environ['MOCK_HOST'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get('MOCK_MODE', '')
mounted = root / 'mounted'
try:
    os.fstat(9)
    inherited = True
except OSError:
    inherited = False
with (root / 'events').open('a') as f:
    f.write(json.dumps([name, args, inherited]) + '\n')
def hold(stage):
    if mode == 'hold_' + stage:
        (root / 'ready').touch()
        deadline = time.monotonic() + 10
        while not (root / 'release').exists():
            if time.monotonic() > deadline:
                sys.exit(99)
            time.sleep(.02)
if name == 'findfs':
    if mode == 'no_disk': sys.exit(1)
    if args[0] != 'UUID=test-uuid' and mode != 'multiple_disks': sys.exit(1)
    print('/dev/mock1')
elif name == 'lsblk':
    column = args[args.index('--output') + 1]
    if column == 'MOUNTPOINTS' and mode == 'old_lsblk': sys.exit(1)
    if column == 'NAME': print('/dev/mock1\n/dev/mock')
    elif column == 'MAJ:MIN': print('8:0\n8:1\n8:2')
    elif mode == 'swap': print('swap [SWAP]')
    elif mode == 'btrfs': print('btrfs')
    else: print('ext4')
elif name == 'findmnt':
    if '--mountpoint' in args:
        if not mounted.exists(): sys.exit(1)
        if 'UUID' in args: print('test-uuid')
        elif 'FSTYPE' in args: print(os.environ.get('MOCK_FSTYPE', 'ext4'))
        else: print('mounted')
    else:
        print('0:99 /')
        if mounted.exists(): print('8:1 ' + str(root / 'disk'))
elif name == 'mount':
    mounted.touch()
    hold('mount')
    if mode == 'mount_partial': sys.exit(32)
elif name == 'umount':
    if mode == 'unmount_fail': sys.exit(1)
    mounted.unlink(missing_ok=True)
elif name == 'pvesm':
    if args[0] == 'status': print('Name Type Status\noffline-backup dir active')
    else:
        (root / 'enabled').write_text('yes' if args[-1] == '0' else 'no')
        if args[-1] == '0' and mode == 'enable_partial': sys.exit(7)
elif name == 'df': print('Avail\n9999999999')
elif name == 'vzdump':
    hold('backup')
    if mode == 'backup_fail':
        print('mock backup diagnostic', file=sys.stderr)
        sys.exit(8)
    dump = root / 'disk' / 'dump'
    dump.mkdir(exist_ok=True)
    archive = dump / ('vzdump-qemu-' + args[0] + '-test.vma.zst')
    archive.write_bytes(b'archive')
    if mode == 'manifest_fail': Path(str(archive) + '.manifest.tsv').mkdir()
    os.utime(archive, (time.time() + 1, time.time() + 1))
elif name == 'zstd':
    sys.stdout.buffer.write(Path(args[-1]).read_bytes())
elif name == 'vma':
    sys.stdin.buffer.read()
    if mode == 'verify_fail': sys.exit(9)
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.host = Path(self.tmp.name)
        (self.host / 'disk').mkdir()
        bindir = self.host / 'bin'
        bindir.mkdir()
        mock = bindir / 'mock'
        mock.write_text('#!' + sys.executable + '\n' + MOCK)
        mock.chmod(0o755)
        for command in ('findfs', 'lsblk', 'findmnt', 'qm', 'mount', 'umount',
                        'pvesm', 'df', 'vzdump', 'zstd', 'vma', 'sync'):
            (bindir / command).symlink_to(mock)
        self.env = dict(os.environ, MOCK_HOST=str(self.host),
                        PATH=str(bindir) + os.pathsep + os.environ['PATH'])
        self.config = self.host / 'config'
        self.config.write_text(
            'BACKUP_UUID=test-uuid\nEXPECTED_FSTYPE=ext4\n'
            'MOUNT_POINT=' + shlex.quote(str(self.host / 'disk') + '/') + '\n'
            'PVE_STORAGE=offline-backup\nVM_IDS=(100 101)\n')
        self.storage = self.host / 'storage.cfg'
        self.write_storage()
        script = (ROOT / 'proxmox-offline-backup.sh').read_text()
        replacements = {
            '/etc/proxmox-offline-backup.conf': str(self.config),
            '/etc/pve/storage.cfg': str(self.storage),
            '/var/log/proxmox-offline-backup.log': str(self.host / 'log'),
            '/run/lock/proxmox-offline-backup.lock': str(self.host / 'lock'),
            'if (( EUID != 0 )); then': 'if false; then',
        }
        for old, new in replacements.items():
            assert script.count(old) == 1, old
            script = script.replace(old, new)
        self.script = self.host / 'workflow.sh'
        self.script.write_text(script)

    def write_storage(self, disable='1', mountpoint='1'):
        self.storage.write_text(
            'dir: offline-backup\n\tpath ' + str(self.host / 'disk') + '\n'
            f'\tdisable {disable}\n\tis_mountpoint {mountpoint}\n')

    def run_script(self, mode='', args=()):
        return subprocess.run(['bash', str(self.script), *args],
                              env=dict(self.env, MOCK_MODE=mode),
                              text=True, capture_output=True, timeout=20)

    def events(self):
        return [json.loads(line) for line in (self.host / 'events').read_text().splitlines()]

    def start_held(self, stage):
        proc = subprocess.Popen(['bash', str(self.script)],
                                env=dict(self.env, MOCK_MODE='hold_' + stage),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def stop():
            (self.host / 'release').touch()
            if proc.poll() is None:
                proc.communicate(timeout=15)
        self.addCleanup(stop)
        deadline = time.monotonic() + 8
        while not (self.host / 'ready').exists():
            if proc.poll() is not None or time.monotonic() > deadline:
                self.fail('Mock did not reach held stage')
            time.sleep(.02)
        return proc

    def test_complete_multi_vm_workflow_and_no_inherited_lock(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('SAFE TO DISCONNECT', result.stdout)
        events = self.events()
        self.assertEqual([e[1][0] for e in events if e[0] == 'vzdump'], ['100', '101'])
        mount = next(e for e in events if e[0] == 'mount')
        self.assertEqual(mount[1][:4], ['-t', 'ext4', '-o', 'nodev,nosuid,noexec'])
        for name, args, inherited in events:
            if name in ('mount', 'umount', 'vzdump', 'vma', 'zstd', 'sync') or (name == 'pvesm' and args[0] == 'set'):
                self.assertFalse(inherited, (name, args))
        self.assertFalse((self.host / 'mounted').exists())
        self.assertEqual((self.host / 'enabled').read_text(), 'no')

    def rotating_config(self):
        self.config.write_text(self.config.read_text().replace(
            'BACKUP_UUID=test-uuid',
            'declare -A BACKUP_DISKS=(["Disk A"]=absent-uuid ["Disk B"]=test-uuid)'))

    def test_rotation_selects_attached_disk_and_records_manifests(self):
        self.rotating_config()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Selected disk: Disk B', result.stdout)
        manifests = list((self.host / 'disk' / 'dump').glob('*.manifest.tsv'))
        self.assertEqual(len(manifests), 2)
        for path in manifests:
            fields = dict(line.split('\t', 1) for line in path.read_text().splitlines())
            self.assertEqual(fields['disk_name'], 'Disk B')
            self.assertEqual(fields['filesystem_uuid'], 'test-uuid')
            self.assertEqual(fields['verification'], 'passed')
            self.assertEqual(fields['schema_version'], '1')
            self.assertEqual((self.host / 'disk' / fields['archive']).stat().st_size,
                             int(fields['size_bytes']))

    def test_rotation_rejects_multiple_or_absent_disks(self):
        self.rotating_config()
        with self.config.open('a') as f:
            f.write('declare -A BACKUP_FSTYPES=(["Disk B"]=ntfs3)\n')
        for mode, code in [('multiple_disks', 37), ('no_disk', 20)]:
            result = self.run_script(mode)
            self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertFalse(any(e[0] in ('mount', 'pvesm', 'vzdump') for e in self.events()))

    def test_rotation_uses_selected_disk_type(self):
        self.rotating_config()
        with self.config.open('a') as f:
            f.write('declare -A BACKUP_FSTYPES=(["Disk B"]=ntfs3)\n')
        self.env['MOCK_FSTYPE'] = 'ntfs3'
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('filesystem=ntfs3', result.stdout)
        mount = next(e for e in self.events() if e[0] == 'mount')
        self.assertEqual(mount[1][:4], ['-t', 'ntfs3', '-o', 'nodev,nosuid,noexec'])
        self.assertFalse((self.host / 'mounted').exists())
        self.assertEqual((self.host / 'enabled').read_text(), 'no')
        self.assertEqual(len(list((self.host / 'disk').rglob('*.manifest.tsv'))), 2)

    def test_unselected_override_preserves_default(self):
        self.rotating_config()
        with self.config.open('a') as f:
            f.write('declare -A BACKUP_FSTYPES=(["Disk A"]=ntfs3)\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        mount = next(e for e in self.events() if e[0] == 'mount')
        self.assertEqual(mount[1][1], 'ext4')

    def test_override_type_mismatch_unmounts_before_backup(self):
        self.rotating_config()
        with self.config.open('a') as f:
            f.write('declare -A BACKUP_FSTYPES=(["Disk B"]=ntfs3)\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 25, result.stdout + result.stderr)
        self.assertFalse((self.host / 'mounted').exists())
        self.assertFalse(any(e[0] in ('vzdump', 'pvesm') for e in self.events()))

    def test_invalid_type_overrides_fail_before_disk_detection(self):
        self.rotating_config()
        base = self.config.read_text()
        for declaration in (
            'BACKUP_FSTYPES=ntfs3',
            'declare -a BACKUP_FSTYPES=(ntfs3)',
            'declare -A BACKUP_FSTYPES=(["Unknown disk"]=ext4)',
            'declare -A BACKUP_FSTYPES=(["Disk B"]="")',
            'declare -A BACKUP_FSTYPES=(["Disk B"]="ext4,ntfs3")',
            'declare -A BACKUP_FSTYPES=(["Disk B"]="-o rw")',
        ):
            with self.subTest(declaration=declaration):
                self.config.write_text(base + declaration + '\n')
                result = self.run_script()
                self.assertEqual(result.returncode, 11, result.stdout + result.stderr)
        self.assertFalse(any(e[0] in ('findfs', 'mount', 'vzdump') for e in self.events()))

    def test_type_overrides_require_named_disks(self):
        with self.config.open('a') as f:
            f.write('declare -A BACKUP_FSTYPES=(["Backup disk"]=ext4)\n')
        self.assertEqual(self.run_script().returncode, 11)

    def test_override_dry_run_reports_type_without_mounting(self):
        self.rotating_config()
        with self.config.open('a') as f:
            f.write('declare -A BACKUP_FSTYPES=(["Disk B"]=ntfs3)\n')
        result = self.run_script(args=('--dry-run',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('filesystem=ntfs3', result.stdout)
        self.assertFalse(any(e[0] in ('mount', 'pvesm', 'vzdump') for e in self.events()))

    def test_duplicate_uuids_rejected(self):
        self.rotating_config()
        self.config.write_text(self.config.read_text().replace('absent-uuid', 'test-uuid'))
        self.assertEqual(self.run_script().returncode, 11)

    def test_mixed_disk_configuration_rejected(self):
        self.rotating_config()
        with self.config.open('a') as f:
            f.write('BACKUP_UUID=test-uuid\n')
        self.assertEqual(self.run_script().returncode, 11)

    def test_failed_verification_does_not_publish_manifest(self):
        result = self.run_script('verify_fail')
        self.assertEqual(result.returncode, 33)
        self.assertEqual(list((self.host / 'disk').rglob('*.manifest.tsv')), [])

    def test_manifest_failure_preserves_archive_and_cleans_up(self):
        result = self.run_script('manifest_fail')
        self.assertEqual(result.returncode, 38, result.stdout + result.stderr)
        self.assertEqual(len(list((self.host / 'disk').rglob('*.vma.zst'))), 1)
        self.assertEqual(list((self.host / 'disk').rglob('*.manifest.tmp.*')), [])
        self.assertFalse((self.host / 'mounted').exists())
        self.assertEqual((self.host / 'enabled').read_text(), 'no')

    def test_dry_run_does_not_mutate_storage(self):
        result = self.run_script(args=('--dry-run',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(e[0] in ('mount', 'pvesm', 'vzdump', 'umount') for e in self.events()))

    def test_requires_disabled_storage(self):
        self.write_storage(disable='0')
        result = self.run_script()
        self.assertEqual(result.returncode, 35)
        self.assertFalse((self.host / 'mounted').exists())

    def test_accepts_bare_disable_boolean(self):
        for line in ('\tdisable', '\tdisable   '):
            with self.subTest(line=line):
                self.write_storage()
                self.storage.write_text(self.storage.read_text().replace('\tdisable 1', line))
                result = self.run_script(args=('--dry-run',))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_disable_is_not_assumed_true(self):
        self.storage.write_text(self.storage.read_text().replace('\tdisable 1\n', ''))
        self.assertEqual(self.run_script().returncode, 35)

    def test_missing_mountpoints_capability_fails_in_preflight(self):
        result = self.run_script('old_lsblk')
        self.assertEqual(result.returncode, 15)
        self.assertIn('util-linux 2.37', result.stdout)
        self.assertFalse(any(e[0] in ('findfs', 'mount', 'pvesm', 'vzdump') for e in self.events()))

    def test_pre_mount_failure_reports_no_mount_state_change(self):
        self.config.unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 10)
        self.assertIn('did not change the disk mount state', result.stdout)
        self.assertNotIn('SAFE TO DISCONNECT', result.stdout)
        self.assertNotIn('[WARN]', result.stdout)

    def test_requires_mountpoint_guard(self):
        self.write_storage(mountpoint='0')
        self.assertEqual(self.run_script().returncode, 36)

    def test_rejects_mountpoint_guard_pointing_elsewhere(self):
        self.write_storage(mountpoint=str(self.host))
        self.assertEqual(self.run_script().returncode, 36)

    def test_accepts_explicit_mountpoint_with_trailing_slash(self):
        self.write_storage(mountpoint=str(self.host / 'disk') + '/')
        self.assertEqual(self.run_script(args=('--dry-run',)).returncode, 0)

    def test_partial_storage_enable_is_rolled_back(self):
        result = self.run_script('enable_partial')
        self.assertEqual(result.returncode, 7)
        self.assertEqual((self.host / 'enabled').read_text(), 'no')
        self.assertFalse((self.host / 'mounted').exists())

    def test_partial_mount_is_unmounted(self):
        result = self.run_script('mount_partial')
        self.assertEqual(result.returncode, 32)
        self.assertFalse((self.host / 'mounted').exists())

    def test_failed_backup_reports_safe_cleanup_and_retains_failure(self):
        result = self.run_script('backup_fail')
        self.assertEqual(result.returncode, 31)
        self.assertIn('SAFE TO DISCONNECT', result.stdout)
        self.assertIn('backup workflow FAILED', result.stdout)
        self.assertIn('mock backup diagnostic', (self.host / 'log').read_text())

    def test_verification_failure(self):
        self.assertEqual(self.run_script('verify_fail').returncode, 33)

    def test_swap_and_btrfs_rejected(self):
        for mode in ('swap', 'btrfs'):
            with self.subTest(mode=mode):
                self.assertEqual(self.run_script(mode).returncode, 29)
                self.assertFalse((self.host / 'mounted').exists())

    def test_script_lock_rejects_concurrent_invocation(self):
        proc = self.start_held('backup')
        result = self.run_script(args=('--dry-run',))
        self.assertEqual(result.returncode, 16)
        (self.host / 'release').touch()
        proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, 0)
        with (self.host / 'lock').open('w') as lock:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_signals_during_mount_reconcile_and_unmount(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=sig):
                (self.host / 'ready').unlink(missing_ok=True)
                (self.host / 'release').unlink(missing_ok=True)
                proc = self.start_held('mount')
                proc.send_signal(sig)
                (self.host / 'release').touch()
                out, err = proc.communicate(timeout=15)
                self.assertEqual(proc.returncode, 128 + sig, out + err)
                self.assertFalse((self.host / 'mounted').exists())
                self.assertIn('SAFE TO DISCONNECT', out)

    def test_term_waits_for_backup_before_cleanup(self):
        proc = self.start_held('backup')
        proc.send_signal(signal.SIGTERM)
        time.sleep(.15)
        self.assertIsNone(proc.poll())
        self.assertFalse(any(e[0] == 'umount' for e in self.events()))
        (self.host / 'release').touch()
        out, err = proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, 143, out + err)
        self.assertFalse((self.host / 'mounted').exists())
        self.assertEqual((self.host / 'enabled').read_text(), 'no')


if __name__ == '__main__':
    unittest.main()
